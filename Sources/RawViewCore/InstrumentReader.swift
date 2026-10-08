import CryptoKit
import Foundation

public enum ReaderError: Error, LocalizedError, Equatable {
    case invalidProject
    case sourceOutsideRaw(String)
    case cancelled
    case invalidSource(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProject: "Choose a project containing a readable data/raw directory."
        case .sourceOutsideRaw(let path): "\(path): resolves outside this project's data/raw folder."
        case .cancelled: "The operation was cancelled."
        case .invalidSource(let message): message
        }
    }
}

public struct ReaderInspectionReport: Sendable {
    public let results: [SourceInspectionResult]
    public let profileIssues: [String]
}

/// App-owned reader for declarative instrument profiles. It never executes project
/// code: profiles are data, the extraction runs in-process, and every failure is
/// reported on the affected source without blocking unrelated sources.
public enum InstrumentReader {
    public static let version = "1.2.0"
    static let progressBatchSize = 64
    static let headerSampleBytes = 64 * 1024
    /// Malformed-input bounds: one source line and the accumulated header
    /// section each stay below 1 MiB. Complete value arrays, row counts, and
    /// valid measurement sizes are never capped.
    static let maximumSourceLineBytes = 1 << 20
    static let maximumHeaderBytes = 1 << 20

    public static func inspectMany(
        _ sources: [RawSource],
        project: ProjectContext,
        cache: MeasurementCache? = nil,
        onProgress: (@Sendable ([SourceInspectionResult], Int) async -> Void)? = nil
    ) async -> ReaderInspectionReport {
        let catalog = ProfileCatalog.load(project: project)
        let catalogFingerprint = catalog.fingerprint
        var results: [SourceInspectionResult] = []
        results.reserveCapacity(sources.count)
        let maxConcurrency = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 16))
        var index = 0
        while index < sources.count {
            if Task.isCancelled {
                for source in sources[index...] {
                    results.append(SourceInspectionResult(source: source, inspection: nil, error: ReaderError.cancelled.localizedDescription))
                }
                await onProgress?(Array(results[index...]), sources.count)
                break
            }
            let end = min(index + progressBatchSize, sources.count)
            let slice = Array(sources[index..<end])
            let batchResults = await withTaskGroup(of: (Int, SourceInspectionResult).self) { group in
                var concurrentTasks = 0
                var batchOutcomes: [(Int, SourceInspectionResult)] = []
                batchOutcomes.reserveCapacity(slice.count)
                for (offset, source) in slice.enumerated() {
                    if Task.isCancelled {
                        batchOutcomes.append((offset, SourceInspectionResult(source: source, inspection: nil, error: ReaderError.cancelled.localizedDescription)))
                        continue
                    }
                    if concurrentTasks >= maxConcurrency {
                        if let completed = await group.next() {
                            batchOutcomes.append(completed)
                            concurrentTasks -= 1
                        }
                    }
                    concurrentTasks += 1
                    group.addTask {
                        if Task.isCancelled {
                            return (offset, SourceInspectionResult(source: source, inspection: nil, error: ReaderError.cancelled.localizedDescription))
                        }
                        if let cache {
                            let cached = try? await cache.inspection(for: source, project: project, catalogFingerprint: catalogFingerprint) { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
                                try inspectPinned(source: source, project: project, catalog: catalog, prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
                            }
                            if let cached {
                                switch cached.outcome {
                                case .supported(let inspection):
                                    return (offset, SourceInspectionResult(source: source, inspection: inspection, error: nil))
                                case .blocked(let message):
                                    return (offset, SourceInspectionResult(source: source, inspection: nil, error: message))
                                }
                            }
                        }
                        return (offset, inspect(source, project: project, catalog: catalog))
                    }
                }
                for await completed in group {
                    batchOutcomes.append(completed)
                }
                batchOutcomes.sort { $0.0 < $1.0 }
                return batchOutcomes.map(\.1)
            }
            results.append(contentsOf: batchResults)
            await onProgress?(batchResults, end)
            index = end
        }
        return ReaderInspectionReport(results: results, profileIssues: catalog.issues)
    }

    /// Rejection for a symlink source, classified from the link text alone:
    /// a lexically inside-`data/raw` link fails closed with the symlink
    /// diagnostic, and only a lexically outside link reports the outside
    /// diagnostic. The target is never resolved, stat-ed, opened, or read.
    private static func sourceLinkRejection(_ source: URL, project: ProjectContext, linkTarget: String) -> ReaderError {
        if project.symlinkTargetResolvesInsideRaw(source: source, linkTarget: linkTarget) {
            return .invalidSource("\(project.claimedPath(of: source)): source file is a symlink or was replaced by one during open; symlinks are never followed.")
        }
        return .sourceOutsideRaw(project.claimedPath(of: source))
    }

    public static func load(_ source: URL, project: ProjectContext, cache: MeasurementCache? = nil) async throws -> NormalizedMeasurement {
        // Excluded files are rejected from the claimed name alone, before any open.
        guard !ProjectContext.skippedRawExtensions.contains(source.pathExtension.lowercased()) else {
            throw ReaderError.invalidSource("\(project.claimedPath(of: source)): RawView skips .spe and .affm files.")
        }
        // Clear diagnostic for a claimed symlink; the open below is the gate.
        if let linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: source.path) {
            throw sourceLinkRejection(source, project: project, linkTarget: linkTarget)
        }
        do {
            try Task.checkCancellation()
            let catalog = ProfileCatalog.load(project: project)
            guard let relativePath = project.relativePath(of: source), relativePath.hasPrefix("data/raw/") else {
                throw ReaderError.sourceOutsideRaw(project.claimedPath(of: source))
            }
            // The selected path supplies source identity and filename evidence;
            // the opened descriptor independently proves the bytes stay in raw.
            let handle: FileHandle
            do {
                handle = try SecureFile.openVerified(resolvedPath: source.path, beneath: project.rawRoot.path)
            } catch let error as SecureOpenError {
                throw error.readerError(display: project.claimedPath(of: source))
            } catch {
                throw ReaderError.invalidSource("\(project.claimedPath(of: source)): could not open the source file: \(error.localizedDescription)")
            }
            let fileExtension = "." + source.pathExtension.lowercased()
            let basename = source.lastPathComponent
            let prefixData: Data
            do {
                prefixData = try handle.read(upToCount: headerSampleBytes) ?? Data()
            } catch {
                try? handle.close()
                throw ReaderError.invalidSource("\(relativePath): could not read the source file: \(error.localizedDescription)")
            }
            let prefixDigest = sha256Hex(prefixData)
            // Descriptor size via stat on the already-pinned descriptor: it
            // must not move the handle's read offset (seekToEnd would make the
            // subsequent stream start at EOF). A failed fstat fails closed.
            var fileStat = stat()
            guard fstat(handle.fileDescriptor, &fileStat) == 0 else {
                try? handle.close()
                throw ReaderError.invalidSource("\(relativePath): could not read the source file.")
            }
            let descriptorSize = Int64(fileStat.st_size)
            // Measurement cache candidate: identity from the descriptor
            // (relative path, extension, size, exact prefix digest) plus the
            // complete catalog fingerprint; the entry's recorded full-content
            // digest is verified inside the cache before decode.
            if let cache,
               let cached = try? cache.measurement(
                   for: RawSource(relativePath: relativePath, url: source, byteSize: descriptorSize),
                   project: project,
                   profileFingerprint: catalog.fingerprint) {
                try? handle.close()
                return cached
            }
            var hasher = SHA256()
            hasher.update(data: prefixData)
            // The selected unique profile/format's declared encoding drives
            // decoding: candidates are resolved using each candidate's own
            // encoding, and only one unique profile/format may match.
            let encoded = resolveEncoded(prefix: prefixData, catalog: catalog, extension: fileExtension, basename: basename)
            let match: ProfileMatch
            let sample: String
            let selectedEncoding: String.Encoding?
            let pending: Data
            switch encoded.resolution {
            case .failed(let message):
                try? handle.close()
                if message.contains("could not be decoded") {
                    throw ReaderError.invalidSource("\(relativePath): \(message)")
                }
                throw ReaderError.invalidSource(message)
            case .matched(let value):
                guard let enc = encoded.encoding, let text = encoded.text, let pend = encoded.pending else {
                    try? handle.close()
                    throw ReaderError.invalidSource("\(relativePath): no decoding was selected for this source.")
                }
                match = value
                sample = text
                selectedEncoding = enc
                pending = pend
            }
            guard let encoding = selectedEncoding else {
                try? handle.close()
                throw ReaderError.invalidSource("\(relativePath): no decoding was selected for this source.")
            }
            let extracted: TabularExtraction
            if match.format.kind == "comment-tsv" {
                extracted = try CommentTsvExtractor.extractStreaming(
                    relativePath: relativePath, format: match.format, mode: match.mode,
                    encoding: encoding, initialText: sample, initialPending: pending,
                    handle: handle, hasher: hasher
                )
            } else if match.format.kind == "first-row-header" {
                extracted = try FirstRowHeaderExtractor.extractStreaming(
                    relativePath: relativePath, format: match.format, mode: match.mode,
                    encoding: encoding, initialText: sample, initialPending: pending,
                    handle: handle, hasher: hasher
                )
            } else {
                extracted = try TabularExtractor.extractStreaming(
                    relativePath: relativePath, format: match.format, mode: match.mode,
                    encoding: encoding, initialText: sample, initialPending: pending,
                    handle: handle, hasher: hasher
                )
            }
            try Task.checkCancellation()
            let channels = zip(extracted.columns, extracted.reasons).map { column, reasons in
                MeasurementChannel(name: column.0.key, label: column.0.label, unit: column.0.unit, quantity: column.0.quantity, values: column.1, gapReasons: reasons)
            }
            let rowCount = extracted.columns.first?.1.count ?? 0
            let gapCount = extracted.columns.reduce(0) { $0 + $1.1.filter({ $0 == nil }).count }
            let facts = parseFilename(basename)
            let measurement = NormalizedMeasurement(
                source: SourceIdentity(path: relativePath, sha256: extracted.sha256),
                instrument: InstrumentIdentity(id: match.profile.instrumentID, name: match.profile.instrumentName,
                                               vendor: match.profile.vendor, model: match.profile.model),
                applicationMode: match.mode.id,
                view: MeasurementView(kind: "xy", x: match.mode.x, y: match.mode.y, preserveOrder: true),
                channels: channels,
                metadataSections: metadataSections(headerFields: extracted.headerFields, filename: basename, facts: facts, channelCount: channels.count, rowCount: rowCount, gapCount: gapCount),
                warnings: extracted.warnings,
                supportStatus: "supported",
                provenance: [
                    "reader_version": version,
                    "profile_id": match.profile.instrumentID,
                    "profile_hash": match.profile.sha256,
                    "profile_schema_version": String(match.profile.schemaVersion),
                    "mode": match.mode.id
                ]
            )
            // Cache only the successful, deterministic outcome. Cancellation
            // and transient failures never reach this line (they throw), and
            // cancellation is re-checked immediately before store.
            if let cache, !Task.isCancelled {
                try? cache.store(
                    measurement: measurement,
                    profileFingerprint: catalog.fingerprint,
                    source: RawSource(relativePath: relativePath, url: source, byteSize: descriptorSize),
                    prefixSHA256: prefixDigest)
            }
            return measurement
        } catch is CancellationError {
            throw ReaderError.cancelled
        } catch let error as ReaderError {
            throw error
        } catch {
            throw ReaderError.invalidSource("\(project.claimedPath(of: source)): could not read the source file: \(error.localizedDescription)")
        }
    }

    private static func inspect(_ source: RawSource, project: ProjectContext, catalog: ProfileCatalog) -> SourceInspectionResult {
        do {
            switch try inspectAccess(source, project: project, catalog: catalog) {
            case .supported(let inspection):
                return SourceInspectionResult(source: source, inspection: inspection, error: nil)
            case .blocked(let message):
                return SourceInspectionResult(source: source, inspection: nil, error: message)
            }
        } catch {
            return SourceInspectionResult(source: source, inspection: nil, error: error.localizedDescription)
        }
    }

    /// Typed inspection resolution. Returns deterministic outcomes — the
    /// supported inspection or the exact profile/header/mode diagnostic — and
    /// THROWS for anything non-deterministic: cancellation, access/security
    /// failures (missing, unreadable, symlinked, escaped), and open/read
    /// errors. Only returned values may reach the inspection cache.
    static func inspectAccess(_ source: RawSource, project: ProjectContext, catalog: ProfileCatalog) throws -> MeasurementCache.CachedInspection {
        // Excluded files are rejected from the claimed name alone, before any open.
        guard !ProjectContext.skippedRawExtensions.contains(source.url.pathExtension.lowercased()) else {
            return .blocked("\(project.claimedPath(of: source.url)): RawView skips .spe and .affm files.")
        }
        guard project.relativePath(of: source.url) == source.relativePath,
              source.relativePath.hasPrefix("data/raw/") else {
            throw ReaderError.sourceOutsideRaw(project.claimedPath(of: source.url))
        }
        try Task.checkCancellation()
        // Clear diagnostic for a claimed symlink; the open below is the gate.
        if let linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: source.url.path) {
            throw sourceLinkRejection(source.url, project: project, linkTarget: linkTarget)
        }
        let handle: FileHandle
        do {
            handle = try SecureFile.openVerified(resolvedPath: source.url.path, beneath: project.rawRoot.path)
        } catch let error as SecureOpenError {
            // Display from the claimed path; the descriptor check already failed closed.
            throw error.readerError(display: project.claimedPath(of: source.url))
        } catch {
            throw ReaderError.invalidSource("\(project.claimedPath(of: source.url)): could not read the source file: \(error.localizedDescription)")
        }
        let selectedRelative = source.relativePath
        let prefixData: Data
        do {
            prefixData = try handle.read(upToCount: headerSampleBytes) ?? Data()
        } catch {
            try? handle.close()
            throw ReaderError.invalidSource("\(selectedRelative): could not read the source file: \(error.localizedDescription)")
        }
        var fileStat = stat()
        guard fstat(handle.fileDescriptor, &fileStat) == 0 else {
            try? handle.close()
            throw ReaderError.invalidSource("\(selectedRelative): could not read the source file.")
        }
        let descriptorSize = Int64(fileStat.st_size)
        try? handle.close()
        try Task.checkCancellation()
        return try inspectPinned(source: source, project: project, catalog: catalog, prefix: prefixData, descriptorSize: descriptorSize, actualURL: source.url)
    }

    /// Pinned inspection production for the cache seam: computes the outcome
    /// from the exact prefix bytes, descriptor size, and descriptor canonical
    /// URL obtained by the cache's secured open, without reopening the path.
    /// The descriptor URL is not source identity: hardlinks may have another
    /// F_GETPATH alias, so selectors and diagnostics use the selected source.
    static func inspectPinned(source: RawSource, project: ProjectContext, catalog: ProfileCatalog, prefix: Data, descriptorSize: Int64, actualURL _: URL) throws -> MeasurementCache.CachedInspection {
        guard !ProjectContext.skippedRawExtensions.contains(source.url.pathExtension.lowercased()) else {
            return .blocked("\(project.claimedPath(of: source.url)): RawView skips .spe and .affm files.")
        }
        try Task.checkCancellation()
        let fileExtension = "." + source.url.pathExtension.lowercased()
        let basename = source.url.lastPathComponent
        let relativePath = source.relativePath
        let encoded = resolveEncoded(prefix: prefix, catalog: catalog, extension: fileExtension, basename: basename)
        switch encoded.resolution {
        case .failed(let message):
            if message.contains("could not be decoded") {
                return .blocked("\(relativePath): \(message)")
            }
            return .blocked(message)
        case .matched(let match):
            let facts = parseFilename(basename)
            let inspection = SourceInspection(
                source: relativePath, size: descriptorSize,
                instrumentID: match.profile.instrumentID, instrumentName: match.profile.instrumentName,
                applicationMode: match.mode.id, timestamp: facts.timestamp, deviceID: facts.deviceID, category: facts.category,
                supportStatus: "supported",
                validationState: "profile valid; source not loaded",
                readerVersion: version, profileID: match.profile.instrumentID, profileHash: match.profile.sha256, error: nil
            )
            return .supported(inspection)
        }
    }

    /// Decodes the bounded prefix with one format's declared encodings only.
    /// A UTF-8 prefix cut mid-scalar backs off to the scalar boundary.
    private static func decodeWithFormat(_ prefix: Data, format: ProfileFormat) -> (encoding: String.Encoding, text: String, pending: Data)? {
        for encoding in format.encodings {
            if encoding == .utf8 {
                var candidate = prefix
                for _ in 0..<4 {
                    if let text = String(data: candidate, encoding: .utf8) {
                        return (encoding, text, prefix.suffix(prefix.count - candidate.count))
                    }
                    guard !candidate.isEmpty else { break }
                    candidate = candidate.dropLast()
                }
            } else if let text = String(data: prefix, encoding: encoding) {
                return (encoding, text, Data())
            }
        }
        return nil
    }

    /// Resolves the unique profile/format using each candidate's own declared
    /// encoding to decode the header. Combining every encoding claimed for the
    /// extension would let one format's encoding rescue bytes another format
    /// cannot read; only one unique profile/format/mode may match.
    private static func resolveEncoded(prefix: Data, catalog: ProfileCatalog, extension fileExtension: String, basename: String) -> (resolution: ProfileResolution, encoding: String.Encoding?, text: String?, pending: Data?) {
        var candidates: [(profile: InstrumentProfile, format: ProfileFormat)] = []
        for profile in catalog.profiles {
            for format in profile.formats where format.extensions.contains(fileExtension) {
                candidates.append((profile, format))
            }
        }
        guard !candidates.isEmpty else {
            return (catalog.resolve(extension: fileExtension, headerSample: "", basename: basename), nil, nil, nil)
        }
        struct CandidateHit {
            let match: ProfileMatch
            let encoding: String.Encoding
            let text: String
            let pending: Data
        }
        var hits: [CandidateHit] = []
        var decodedAny = false
        var firstSample = ""
        var firstDecoded = false
        for (profile, format) in candidates {
            guard let decoded = decodeWithFormat(prefix, format: format) else { continue }
            if !firstDecoded { firstSample = decoded.text; firstDecoded = true }
            decodedAny = true
            let sampleLower = decoded.text.lowercased()
            let baseLower = basename.lowercased()
            for mode in profile.modes.filter({ $0.formatID == format.id }) {
                let filenameOK = mode.filenameContainsAll.map { $0.allSatisfy { baseLower.contains($0.lowercased()) } } ?? true
                let headerOK = mode.detect.contains { sampleLower.contains($0.lowercased()) }
                if filenameOK && headerOK {
                    hits.append(CandidateHit(match: ProfileMatch(profile: profile, format: format, mode: mode), encoding: decoded.encoding, text: decoded.text, pending: decoded.pending))
                }
            }
        }
        if hits.count == 1 {
            let unique = hits[0]
            let blocking = catalog.brokenClaims.filter { $0.blocks(sample: unique.text.lowercased(), basename: basename) }
            if blocking.isEmpty {
                return (.matched(unique.match), unique.encoding, unique.text, unique.pending)
            }
            let note = "A valid profile (\(unique.match.profile.relativePath) mode \(unique.match.mode.id)) also matches this source; the source stays blocked until the invalid profile is fixed or removed."
            return (.failed((blocking.flatMap(\.issues) + [note]).joined(separator: "\n")), nil, nil, nil)
        }
        if hits.count > 1 {
            let described = hits.map { "\($0.match.profile.relativePath) mode \($0.match.mode.id)" }.joined(separator: ", ")
            return (.failed("Ambiguous profile match: \(described). Keep one profile mode per source format."), nil, nil, nil)
        }
        guard decodedAny else {
            if catalog.hasBrokenClaim(for: fileExtension) {
                return (catalog.resolve(extension: fileExtension, headerSample: "", basename: basename), nil, nil, nil)
            }
            return (.failed("the file header could not be decoded with any accepted profile encoding."), nil, nil, nil)
        }
        let fallback = catalog.resolve(extension: fileExtension, headerSample: firstSample, basename: basename)
        switch fallback {
        case .failed:
            return (fallback, nil, nil, nil)
        case .matched(let foreign):
            // At least one candidate encoding decoded the prefix, but no mode
            // matched using its own declared encoding. A foreign-encoding match
            // must never report supported: load would have no selected decoding.
            return (.failed("No profile mode matched this source using its own declared encoding (basename \"\(basename)\"). A mode (\(foreign.profile.relativePath) mode \(foreign.mode.id)) matches only in another candidate's decoded text and cannot decode this source."), nil, nil, nil)
        }
    }

    /// Filename facts matching the project-local reader convention
    /// (`_parse_filename` in `data/instruments/reader.py`, read-only):
    /// leading `DDMMYY-HHMMSS` timestamp, `[device]` token, and the trailing
    /// category token (e.g. `iv.dual-sweep`). The category is a filename grouping
    /// aid, not scientific study membership. Unknown stays nil.
    static func parseFilename(_ filename: String) -> (timestamp: String?, deviceID: String?, category: String?) {
        var timestamp: String?
        if let match = filename.range(of: #"^\d{6}(?:-\d{6})?"#, options: .regularExpression) {
            let token = String(filename[match])
            // The contract promises calendar validation: impossible dates and
            // invalid times stay unknown instead of entering Identity.
            if isValidFilenameTimestamp(token) {
                timestamp = token
            }
        }
        var deviceID: String?
        var category: String?
        if let open = filename.firstIndex(of: "["), let close = filename.firstIndex(of: "]"), open < close {
            deviceID = String(filename[filename.index(after: open)..<close])
            let after = String(filename[filename.index(after: close)...])
            if let regex = try? NSRegularExpression(pattern: #"^_([A-Za-z0-9.\-_]+?)(?:_\d{3})?\.[A-Za-z0-9]+$"#),
               let match = regex.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)),
               let range = Range(match.range(at: 1), in: after) {
                category = String(after[range])
            }
        }
        if category == nil {
            let parts = filename.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 4 {
                category = parts.last?.split(separator: ".").first.map(String.init)
            }
        }
        return (timestamp, deviceID, category)
    }

    /// Validates a filename timestamp token (`DDMMYY` with optional `-HHMMSS`)
    /// as a Gregorian calendar date with 24-hour time. Two-digit years pivot
    /// to 2000–2099. Pure integer logic: no locale or timezone surface, and
    /// the token text itself is preserved unchanged when valid.
    private static func isValidFilenameTimestamp(_ token: String) -> Bool {
        let digits = Array(token)
        guard digits.count == 6 || digits.count == 13 else { return false }
        if digits.count == 13, digits[6] != "-" { return false }
        func number(_ from: Int, _ to: Int) -> Int? {
            Int(String(digits[from..<to]))
        }
        guard let day = number(0, 2), let month = number(2, 4), let yearSuffix = number(4, 6) else { return false }
        guard (1...12).contains(month) else { return false }
        let year = 2000 + yearSuffix
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1 && day <= monthLengths[month - 1] else { return false }
        if digits.count == 13 {
            guard let hour = number(7, 9), let minute = number(9, 11), let second = number(11, 13) else { return false }
            guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return false }
        }
        return true
    }

    private static func metadataSections(headerFields: [(key: String, value: String)], filename: String, facts: (timestamp: String?, deviceID: String?, category: String?), channelCount: Int, rowCount: Int, gapCount: Int) -> [MetadataSection] {
        var sections: [MetadataSection] = []
        if !headerFields.isEmpty {
            let fields = headerFields.map { key, value in
                MetadataField(key: key, label: key.replacingOccurrences(of: "_", with: " ").capitalized, value: .string(value), unit: nil, kind: "string")
            }
            sections.append(MetadataSection(title: "Acquisition", fields: fields))
        }
        var idFields: [MetadataField] = []
        if let deviceID = facts.deviceID {
            idFields.append(MetadataField(key: "device_id", label: "Device id", value: .string(deviceID), unit: nil, kind: "string"))
        }
        if let timestamp = facts.timestamp {
            idFields.append(MetadataField(key: "timestamp", label: "Timestamp", value: .string(timestamp), unit: nil, kind: "string"))
        }
        if let category = facts.category {
            idFields.append(MetadataField(key: "category", label: "Category", value: .string(category), unit: nil, kind: "string"))
        }
        idFields.append(MetadataField(key: "filename", label: "Filename", value: .string(filename), unit: nil, kind: "string"))
        sections.append(MetadataSection(title: "Identity", fields: idFields))
        sections.append(MetadataSection(title: "Data", fields: [
            MetadataField(key: "channel_count", label: "Channel count", value: .number(Double(channelCount)), unit: nil, kind: "number"),
            MetadataField(key: "point_count", label: "Point count", value: .number(Double(rowCount)), unit: nil, kind: "number"),
            MetadataField(key: "gap_count", label: "Gap count", value: .number(Double(gapCount)), unit: nil, kind: "number")
        ]))
        return sections
    }
}

struct TabularExtraction: Sendable {
    /// Row-aligned columns in acquisition order; `nil` is a preserved gap.
    let columns: [(ProfileColumn, [Double?])]
    /// Parallel gap classification aligned with `columns`.
    let reasons: [[GapReason?]]
    /// Per-gap diagnostics naming file, line, column, and raw token.
    let warnings: [String]
    /// Ordered header fields from lines before the names row.
    let headerFields: [(key: String, value: String)]
    /// SHA-256 hex of exactly the bytes parsed from the secured handle.
    let sha256: String
}

/// Row-aligned gap ledger shared by every positional extractor, so blank,
/// NaN, infinity, and saturation cells keep one classification and one
/// warning shape no matter which layout produced them.
struct CellLedger: Sendable {
    var values: [[Double?]]
    var reasons: [[GapReason?]]
    var warnings: [String] = []
    var gapTotal = 0

    init(count: Int) {
        values = [[Double?]](repeating: [], count: count)
        reasons = [[GapReason?]](repeating: [], count: count)
    }

    mutating func record(column: Int, reason: GapReason, message: String) {
        values[column].append(nil)
        reasons[column].append(reason)
        gapTotal += 1
        if warnings.count < 32 { warnings.append(message) }
    }

    func summarize(relativePath: String) -> [String] {
        var warnings = warnings
        if gapTotal > warnings.count {
            warnings.append("\(relativePath): ... and \(gapTotal - warnings.count) more gap cells shown as gaps.")
        }
        return warnings
    }
}

enum CellParser {
    /// Classifies one trimmed source cell with the shared gap contract: blank
    /// and recorded NaN/infinity spellings are gaps, numeric overflow that
    /// parses to a non-finite value is saturation, and any other non-numeric
    /// text blocks the source naming file, line, column, and value.
    static func append(raw: String, column: Int, key: String, lineNumber: Int, relativePath: String, decimal: Character, ledger: inout CellLedger) throws {
        if let reason = TabularExtractor.gapReason(for: raw) {
            let kind = reason == .blank ? "is blank" : "records \(reason == .nan ? "NaN" : "infinity")"
            ledger.record(column: column, reason: reason, message: "\(relativePath) line \(lineNumber): column \"\(key)\" value \"\(raw)\" \(kind); shown as a gap.")
        } else {
            let normalized = TabularExtractor.decimalNumber(raw, decimal: decimal)
            // Decimal lexical gate before Double: supported signs, decimal
            // separators, and exponents pass; Swift-only hex floats (0x1.0p+1)
            // and other non-decimal spellings fail closed here.
            guard TabularExtractor.isValidDecimal(normalized) else {
                throw ReaderError.invalidSource("\(relativePath) line \(lineNumber): column \"\(key)\" value \"\(raw)\" is not a finite number.")
            }
            if let value = Double(normalized) {
                if value.isFinite {
                    ledger.values[column].append(value)
                    ledger.reasons[column].append(nil)
                } else {
                    ledger.record(column: column, reason: .saturated, message: "\(relativePath) line \(lineNumber): column \"\(key)\" value \"\(raw)\" overflowed to a non-finite value (saturation); shown as a gap.")
                }
            } else {
                throw ReaderError.invalidSource("\(relativePath) line \(lineNumber): column \"\(key)\" value \"\(raw)\" is not a finite number.")
            }
        }
    }
}

/// Incremental line source over one secured file handle: 64 KiB raw chunks
/// feed the running SHA-256 and a single-encoding incremental decoder, so
/// hashing and row parsing read the same opened object without retaining
/// whole-file Data/String/line arrays. Complete output arrays are still
/// retained; no file-size or point cap is imposed.
struct LinePuller {
    static let chunkBytes = 65536
    var handle: FileHandle
    var hasher: SHA256
    var encoding: String.Encoding
    var relativePath: String
    var pendingBytes = Data()
    var textBuffer = ""
    var readyLines: [String] = []
    var readyIndex = 0
    var eof = false
    var finalFlushed = false
    var linesEmitted = 0
    // A trailing carriage return is held back: it may complete a CRLF pair
    // with the next chunk's first byte. (Swift treats "\r\n" as one grapheme
    // Character, so line splitting must run on normalized text.)
    var pendingCR = false

    mutating func stageText(_ text: String, final: Bool) throws {
        textBuffer += normalizeChunk(text)
        try drainLines(final: final)
    }

    mutating func nextLine() throws -> String? {
        while true {
            if readyIndex < readyLines.count {
                linesEmitted += 1
                var line = readyLines[readyIndex]
                readyIndex += 1
                // O(1) amortized consumption: drop the consumed prefix in bulk
                // instead of shifting per row; reset when fully drained.
                if readyIndex == readyLines.count {
                    readyLines.removeAll(keepingCapacity: true)
                    readyIndex = 0
                } else if readyIndex > 1024 && readyIndex > readyLines.count / 2 {
                    readyLines.removeFirst(readyIndex)
                    readyIndex = 0
                }
                if linesEmitted == 1, line.hasPrefix("\u{FEFF}") {
                    line = String(line.dropFirst())
                }
                if line.utf8.count > InstrumentReader.maximumSourceLineBytes {
                    throw ReaderError.invalidSource("\(relativePath): source line \(linesEmitted) exceeds the 1 MiB line limit.")
                }
                return line
            }
            if eof {
                guard !finalFlushed else { return nil }
                finalFlushed = true
                if pendingCR {
                    pendingCR = false
                    textBuffer += "\n"
                }
                if !pendingBytes.isEmpty {
                    guard let tail = String(data: pendingBytes, encoding: encoding) else {
                        throw ReaderError.invalidSource("\(relativePath): could not decode the file using the selected encoding.")
                    }
                    pendingBytes = Data()
                    try stageText(tail, final: true)
                } else {
                    try drainLines(final: true)
                }
                continue
            }
            try fill()
        }
    }

    mutating func digestHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func fill() throws {
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: Self.chunkBytes) ?? Data()
        } catch {
            throw ReaderError.invalidSource("\(relativePath): could not read the source file: \(error.localizedDescription)")
        }
        guard !chunk.isEmpty else { eof = true; return }
        hasher.update(data: chunk)
        try Task.checkCancellation()
        try stageText(try decodeChunk(chunk), final: false)
    }

    private mutating func drainLines(final: Bool) throws {
        var parts = textBuffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        textBuffer = final ? "" : (parts.popLast() ?? "")
        // Bound each complete line and the pending incomplete tail so a
        // malformed file without line breaks cannot grow memory without bound.
        for part in parts where part.utf8.count > InstrumentReader.maximumSourceLineBytes {
            throw ReaderError.invalidSource("\(relativePath): source line exceeds the 1 MiB line limit.")
        }
        if !final, textBuffer.utf8.count > InstrumentReader.maximumSourceLineBytes {
            throw ReaderError.invalidSource("\(relativePath): source line exceeds the 1 MiB line limit.")
        }
        readyLines.append(contentsOf: parts)
    }

    /// Collapses CRLF pairs and lone carriage returns exactly like the former
    /// whole-text normalization, chunk by chunk. A trailing "\r" is held until
    /// the next chunk (or EOF) decides whether it completes a CRLF pair.
    private mutating func normalizeChunk(_ text: String) -> String {
        var combined = (pendingCR ? "\r" : "") + text
        pendingCR = false
        if combined.hasSuffix("\r") {
            combined = String(combined.dropLast())
            pendingCR = true
        }
        return combined.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private mutating func decodeChunk(_ chunk: Data) throws -> String {
        if encoding != .utf8 {
            guard let text = String(data: chunk, encoding: encoding) else {
                throw ReaderError.invalidSource("\(relativePath): could not decode the file using the selected encoding.")
            }
            return text
        }
        // Plain [UInt8]: Data slices keep their original index base, so
        // integer positions are only valid on a zero-based array.
        var octets = Array(pendingBytes)
        octets.append(contentsOf: chunk)
        pendingBytes = Data()
        // Hold back at most a truncated trailing scalar; anything else that
        // fails to decode is corrupt input, reported fail-closed below.
        let carry = Self.utf8IncompleteTailLength(octets)
        let cut = octets.count - carry
        guard let text = String(bytes: Array(octets.prefix(cut)), encoding: .utf8) else {
            throw ReaderError.invalidSource("\(relativePath): could not decode the file using the selected encoding.")
        }
        pendingBytes = Data(octets.suffix(carry))
        return text
    }

    private static func utf8IncompleteTailLength(_ bytes: [UInt8]) -> Int {
        let n = bytes.count
        guard n > 0 else { return 0 }
        var idx = n
        var cont = 0
        while idx > 0, cont < 3, (bytes[idx - 1] & 0xC0) == 0x80 { idx -= 1; cont += 1 }
        if cont == 0 {
            let last = bytes[n - 1]
            if last < 0x80 { return 0 }
            return utf8ExpectedLength(lead: last) > 1 ? 1 : 0
        }
        guard idx > 0 else { return cont }
        let need = utf8ExpectedLength(lead: bytes[idx - 1])
        guard need > 0 else { return 0 }
        let have = 1 + cont
        return have < need ? have : 0
    }

    private static func utf8ExpectedLength(lead: UInt8) -> Int {
        if lead < 0x80 { return 1 }
        if lead & 0xE0 == 0xC0 { return 2 }
        if lead & 0xF0 == 0xE0 { return 3 }
        if lead & 0xF8 == 0xF0 { return 4 }
        return 0
    }
}

enum TabularExtractor {
    /// Classifies a trimmed source cell. An empty cell is a blank gap;
    /// case-insensitive NaN/Infinity spellings are recorded gaps. Anything else
    /// returns nil and is either parsed as a number or rejected as corrupt:
    /// arbitrary text is never silently turned into data. Numeric overflow
    /// that parses to a non-finite value is recorded as `.saturated`.
    static func gapReason(for raw: String) -> GapReason? {
        if raw.isEmpty { return .blank }
        switch raw.lowercased() {
        case "nan", "+nan", "-nan": return .nan
        case "inf", "+inf", "-inf", "infinity", "+infinity", "-infinity": return .infinite
        default: return nil
        }
    }

    /// Declared decimal separator as a lexical property (not a transform):
    /// a comma decimal rewrites `12,345` to `12.345` before parsing. The
    /// schema guarantees the delimiter is never a comma in that case, so no
    /// thousands separator can hide inside a cell.
    static func decimalNumber(_ raw: String, decimal: Character) -> String {
        decimal == "," ? raw.replacingOccurrences(of: ",", with: ".") : raw
    }

    /// Decimal lexical gate: optional sign, digits with at most one dot
    /// (either side may be empty only with digits on the other side), and an
    /// optional decimal exponent. Preserves supported signs, separators, and
    /// exponents; rejects Swift-only hex floats such as `0x1.0p+1`.
    static func isValidDecimal(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var index = text.startIndex
        if text[index] == "+" || text[index] == "-" {
            index = text.index(after: index)
            guard index < text.endIndex else { return false }
        }
        func isDigit(_ character: Character) -> Bool { character >= "0" && character <= "9" }
        var intDigits = 0
        while index < text.endIndex, isDigit(text[index]) {
            intDigits += 1
            index = text.index(after: index)
        }
        var fracDigits = 0
        if index < text.endIndex, text[index] == "." {
            index = text.index(after: index)
            while index < text.endIndex, isDigit(text[index]) {
                fracDigits += 1
                index = text.index(after: index)
            }
        }
        guard intDigits > 0 || fracDigits > 0 else { return false }
        if index < text.endIndex, text[index] == "e" || text[index] == "E" {
            index = text.index(after: index)
            guard index < text.endIndex else { return false }
            if text[index] == "+" || text[index] == "-" {
                index = text.index(after: index)
                guard index < text.endIndex else { return false }
            }
            var expDigits = 0
            while index < text.endIndex, isDigit(text[index]) {
                expDigits += 1
                index = text.index(after: index)
            }
            guard expDigits > 0 else { return false }
        }
        return index == text.endIndex
    }

    /// Every format-declared channel resolves by exact primary header first,
    /// aliases only as fallback. The ordered table keeps all of them; only
    /// the mode's x/y channels drive the plot. Shared by the row-block and
    /// first-row-header layouts; `rowLabel` names the header row in
    /// diagnostics (`DataName row` or `header row`).
    static func resolveColumns(headers: [String], format: ProfileFormat, mode: ProfileMode, relativePath: String, rowLabel: String) throws -> [(ProfileColumn, Int)] {
        var columns: [(ProfileColumn, Int)] = []
        for column in format.columns {
            let want = column.header ?? column.key
            let primary = headers.indices.filter {
                headers[$0].compare(want, options: .caseInsensitive) == .orderedSame
            }
            if primary.count > 1 {
                throw ReaderError.invalidSource("\(relativePath): header for column \"\(column.key)\" (\(want)) matches more than one cell in the \(rowLabel) [\(headers.joined(separator: ", "))].")
            }
            if let hit = primary.first {
                columns.append((column, hit))
                continue
            }
            let fallback = headers.indices.filter { index in
                column.aliases.contains { headers[index].compare($0, options: .caseInsensitive) == .orderedSame }
            }
            if fallback.count > 1 {
                throw ReaderError.invalidSource("\(relativePath): header for column \"\(column.key)\" (\(want)) matches more than one cell via aliases [\(column.aliases.joined(separator: ", "))] in the \(rowLabel) [\(headers.joined(separator: ", "))].")
            }
            guard let hit = fallback.first else {
                // An optional channel resolves when its header is present and
                // is skipped when absent: no values are invented for it, and
                // the required channels load unchanged.
                if !column.required { continue }
                throw ReaderError.invalidSource("\(relativePath): header for column \"\(column.key)\" (\(want)) was not found in the \(rowLabel) [\(headers.joined(separator: ", "))].")
            }
            columns.append((column, hit))
        }
        // Two semantic channels resolving to one source column is ambiguous.
        var resolvedByColumn: [Int: String] = [:]
        for (column, index) in columns {
            if let other = resolvedByColumn[index] {
                throw ReaderError.invalidSource("\(relativePath): columns \"\(other)\" and \"\(column.key)\" resolve to the same source column \(index + 1) (\(headers[index])).")
            }
            resolvedByColumn[index] = column.key
        }
        guard columns.contains(where: { $0.0.key == mode.x }),
              mode.y.allSatisfy({ y in columns.contains(where: { $0.0.key == y }) }) else {
            throw ReaderError.invalidSource("\(relativePath): profile mode \"\(mode.id)\" references a column missing from format \"\(format.id)\".")
        }
        return columns
    }

    static func extractStreaming(
        relativePath: String,
        format: ProfileFormat,
        mode: ProfileMode,
        encoding: String.Encoding,
        initialText: String,
        initialPending: Data,
        handle: FileHandle,
        hasher: SHA256
    ) throws -> TabularExtraction {
        // Bytes stream in 64 KiB chunks: the incremental hash covers exactly
        // the parsed bytes, complete output arrays are retained, and no
        // file-size or point cap is imposed.
        var puller = LinePuller(handle: handle, hasher: hasher, encoding: encoding, relativePath: relativePath, pendingBytes: initialPending)
        try puller.stageText(initialText, final: false)
        guard let namesPrefix = format.namesPrefix, let dataPrefix = format.dataPrefix else {
            throw ReaderError.invalidSource("\(relativePath): format \"\(format.id)\" has no row-block markers for kind \"\(format.kind)\".")
        }
        // Phase 1: header rows up to the names row.
        var headerLineTexts: [String] = []
        var headerBytes = 0
        var headers: [String]? = nil
        var lineNumber = 0
        while let line = try puller.nextLine() {
            lineNumber += 1
            let fields = try split(line, delimiter: format.delimiter, context: "\(relativePath) line \(lineNumber)")
            if fields.first == namesPrefix { headers = fields; break }
            headerBytes += line.utf8.count + 1
            guard headerBytes <= InstrumentReader.maximumHeaderBytes else {
                throw ReaderError.invalidSource("\(relativePath): header section exceeds the 1 MiB header limit.")
            }
            headerLineTexts.append(line)
        }
        guard let headers else {
            throw ReaderError.invalidSource("\(relativePath): no \"\(namesPrefix)\" header row was found.")
        }

        let columns = try resolveColumns(headers: headers, format: format, mode: mode, relativePath: relativePath, rowLabel: "\(namesPrefix) row")

        // Phase 2: data rows in file order.
        var ledger = CellLedger(count: columns.count)
        var rowCount = 0
        while let line = try puller.nextLine() {
            lineNumber += 1
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let fields = try split(line, delimiter: format.delimiter, context: "\(relativePath) line \(lineNumber)")
            // An empty data_prefix matches every non-blank line after the
            // header row; otherwise only the marked rows are data.
            if !dataPrefix.isEmpty {
                guard fields.first == dataPrefix else { continue }
            }
            for (columnIndex, column) in columns.enumerated() {
                let cellIndex = column.1
                if cellIndex >= fields.count {
                    ledger.record(column: columnIndex, reason: .blank, message: "\(relativePath) line \(lineNumber): column \"\(column.0.key)\" has no cell \(cellIndex + 1); shown as a gap.")
                } else {
                    try CellParser.append(raw: fields[cellIndex], column: columnIndex, key: column.0.key, lineNumber: lineNumber, relativePath: relativePath, decimal: format.decimalSeparator, ledger: &ledger)
                }
            }
            rowCount += 1
            if rowCount.isMultiple(of: 4096) { try Task.checkCancellation() }
        }
        guard rowCount > 0 else {
            if dataPrefix.isEmpty {
                throw ReaderError.invalidSource("\(relativePath): no data rows were found after the header.")
            }
            throw ReaderError.invalidSource("\(relativePath): no \"\(dataPrefix)\" data rows were found after the header.")
        }
        let headerFields = try headerMetadata(lines: headerLineTexts, delimiter: format.delimiter, relativePath: relativePath)
        return TabularExtraction(columns: columns.enumerated().map { ($0.element.0, ledger.values[$0.offset]) }, reasons: ledger.reasons, warnings: ledger.summarize(relativePath: relativePath), headerFields: headerFields, sha256: puller.digestHex())
    }

    /// Ordered header fields from lines before the names row. Lines are split on
    /// the profile delimiter; the key is the first cell (plus the second cell when
    /// the first cell repeats, e.g. `MetaData TestRecord.RecordTime`) so repeated
    /// section prefixes stay distinct without inventing values. Empty values are
    /// skipped, values over 512 chars are truncated, fields capped at 256 (the real
    /// Keysight B1500A header carries ~148 fields including trailing Dimension rows).
    private static func headerMetadata(lines: [String], delimiter: Character, relativePath: String) throws -> [(key: String, value: String)] {
        var rows: [[String]] = []
        var firstCounts: [String: Int] = [:]
        for (index, line) in lines.enumerated() {
            let cells = try split(line, delimiter: delimiter, context: "\(relativePath) line \(index + 1)")
            guard let first = cells.first, !first.isEmpty else { continue }
            rows.append(cells)
            firstCounts[first, default: 0] += 1
        }
        var result: [(key: String, value: String)] = []
        var usedKeys = Set<String>()
        for cells in rows {
            guard result.count < 256 else { break }
            let first = cells[0]
            let baseKey: String
            let value: String
            if cells.count == 1 {
                continue
            } else if cells.count == 2 {
                baseKey = first
                value = cells[1]
            } else if (firstCounts[first] ?? 0) > 1 {
                baseKey = "\(first) \(cells[1])"
                value = cells[2...].joined(separator: ", ")
            } else {
                baseKey = first
                value = cells[1...].joined(separator: ", ")
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Repeated rows keep every distinct value under a stable unique key.
            var key = baseKey
            var suffix = 2
            while usedKeys.contains(key) {
                key = "\(baseKey) #\(suffix)"
                suffix += 1
            }
            usedKeys.insert(key)
            result.append((key, trimmed.count > 512 ? String(trimmed.prefix(509)) + "..." : trimmed))
        }
        return result
    }

    /// Delimiter split that keeps quoted delimiters inside one cell: `"` opens a
    /// quoted section, `""` inside one is an escaped quote, and a closing `"`
    /// ends it. Cells are trimmed; a trimmed cell wrapped in quotes unquotes,
    /// while any other `"` is malformed and fails with the caller's file/line
    /// context instead of shifting columns silently.
    static func split(_ line: String, delimiter: Character, context: String) throws -> [String] {
        var rawCells: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"\"")
                    index = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
                current.append(character)
            } else if character == delimiter, !inQuotes {
                rawCells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        guard !inQuotes else {
            throw ReaderError.invalidSource("\(context): malformed quoted field (unterminated quote).")
        }
        rawCells.append(current)
        return try rawCells.map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\"") {
                guard trimmed.count >= 2, trimmed.hasSuffix("\"") else {
                    throw ReaderError.invalidSource("\(context): malformed quoted field \(trimmed).")
                }
                return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
            }
            if trimmed.contains("\"") {
                throw ReaderError.invalidSource("\(context): malformed quoted field \(trimmed).")
            }
            return trimmed
        }
    }
}

/// Headerless positional layout for comment-header tables (Horiba LabRAM
/// TSV): `#` lines are Acquisition metadata (`key=value`), every other
/// non-blank line is one acquisition row, and columns resolve by declared
/// source index. Cell classification reuses the shared gap contract, so
/// values stay bitwise exact and in file order with no transforms.
enum CommentTsvExtractor {
    static func extractStreaming(
        relativePath: String,
        format: ProfileFormat,
        mode: ProfileMode,
        encoding: String.Encoding,
        initialText: String,
        initialPending: Data,
        handle: FileHandle,
        hasher: SHA256
    ) throws -> TabularExtraction {
        var puller = LinePuller(handle: handle, hasher: hasher, encoding: encoding, relativePath: relativePath, pendingBytes: initialPending)
        try puller.stageText(initialText, final: false)
        var indexed: [(ProfileColumn, Int)] = []
        for column in format.columns {
            guard let position = column.index else {
                throw ReaderError.invalidSource("\(relativePath): column \"\(column.key)\" has no column_index for kind \"comment-tsv\".")
            }
            indexed.append((column, position))
        }
        guard indexed.contains(where: { $0.0.key == mode.x }),
              mode.y.allSatisfy({ y in indexed.contains(where: { $0.0.key == y }) }) else {
            throw ReaderError.invalidSource("\(relativePath): profile mode \"\(mode.id)\" references a column missing from format \"\(format.id)\".")
        }
        var comments: [(key: String, value: String)] = []
        var usedKeys = Set<String>()
        var ledger = CellLedger(count: indexed.count)
        var lineNumber = 0
        var rowCount = 0
        var headerBytes = 0
        while let line = try puller.nextLine() {
            lineNumber += 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                let lineBytes = line.utf8.count + 1
                guard lineBytes <= InstrumentReader.maximumHeaderBytes - headerBytes else {
                    throw ReaderError.invalidSource("\(relativePath): comment-tsv header exceeds the 1 MiB limit.")
                }
                headerBytes += lineBytes
                let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard let separator = body.firstIndex(of: "=") else { continue }
                let key = String(body[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(body[body.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !value.isEmpty, comments.count < 256 else { continue }
                var unique = key
                var suffix = 2
                while usedKeys.contains(unique) {
                    unique = "\(key) #\(suffix)"
                    suffix += 1
                }
                usedKeys.insert(unique)
                comments.append((unique, value.count > 512 ? String(value.prefix(509)) + "..." : value))
                continue
            }
            let fields = try TabularExtractor.split(line, delimiter: format.delimiter, context: "\(relativePath) line \(lineNumber)")
            for (columnIndex, column) in indexed.enumerated() {
                if column.1 >= fields.count {
                    ledger.record(column: columnIndex, reason: .blank, message: "\(relativePath) line \(lineNumber): column \"\(column.0.key)\" has no cell \(column.1 + 1); shown as a gap.")
                } else {
                    try CellParser.append(raw: fields[column.1], column: columnIndex, key: column.0.key, lineNumber: lineNumber, relativePath: relativePath, decimal: format.decimalSeparator, ledger: &ledger)
                }
            }
            rowCount += 1
            if rowCount.isMultiple(of: 4096) { try Task.checkCancellation() }
        }
        guard rowCount > 0 else {
            throw ReaderError.invalidSource("\(relativePath): no data rows were found after the comment header.")
        }
        return TabularExtraction(columns: indexed.enumerated().map { ($0.element.0, ledger.values[$0.offset]) }, reasons: ledger.reasons, warnings: ledger.summarize(relativePath: relativePath), headerFields: comments, sha256: puller.digestHex())
    }
}

/// Explicit first-row-header layout (WGFMU pulse tables): the first non-blank
/// line is the header row and every later non-blank line is one acquisition
/// row. Column resolution, cell classification, and gap warnings reuse the
/// shared row-block helpers, so values stay bitwise exact and in file order
/// with no transforms. Leading blanks before the header are bounded like the
/// row-block header section.
enum FirstRowHeaderExtractor {
    static func extractStreaming(
        relativePath: String,
        format: ProfileFormat,
        mode: ProfileMode,
        encoding: String.Encoding,
        initialText: String,
        initialPending: Data,
        handle: FileHandle,
        hasher: SHA256
    ) throws -> TabularExtraction {
        var puller = LinePuller(handle: handle, hasher: hasher, encoding: encoding, relativePath: relativePath, pendingBytes: initialPending)
        try puller.stageText(initialText, final: false)
        var headers: [String]? = nil
        var skippedBytes = 0
        var lineNumber = 0
        while let line = try puller.nextLine() {
            lineNumber += 1
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                skippedBytes += line.utf8.count + 1
                guard skippedBytes <= InstrumentReader.maximumHeaderBytes else {
                    throw ReaderError.invalidSource("\(relativePath): header section exceeds the 1 MiB header limit.")
                }
                continue
            }
            headers = try TabularExtractor.split(line, delimiter: format.delimiter, context: "\(relativePath) line \(lineNumber)")
            break
        }
        guard let headers else {
            throw ReaderError.invalidSource("\(relativePath): no header row was found.")
        }
        let columns = try TabularExtractor.resolveColumns(headers: headers, format: format, mode: mode, relativePath: relativePath, rowLabel: "header row")
        var ledger = CellLedger(count: columns.count)
        var rowCount = 0
        while let line = try puller.nextLine() {
            lineNumber += 1
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let fields = try TabularExtractor.split(line, delimiter: format.delimiter, context: "\(relativePath) line \(lineNumber)")
            for (columnIndex, column) in columns.enumerated() {
                if column.1 >= fields.count {
                    ledger.record(column: columnIndex, reason: .blank, message: "\(relativePath) line \(lineNumber): column \"\(column.0.key)\" has no cell \(column.1 + 1); shown as a gap.")
                } else {
                    try CellParser.append(raw: fields[column.1], column: columnIndex, key: column.0.key, lineNumber: lineNumber, relativePath: relativePath, decimal: format.decimalSeparator, ledger: &ledger)
                }
            }
            rowCount += 1
            if rowCount.isMultiple(of: 4096) { try Task.checkCancellation() }
        }
        guard rowCount > 0 else {
            throw ReaderError.invalidSource("\(relativePath): no data rows were found after the header.")
        }
        return TabularExtraction(columns: columns.enumerated().map { ($0.element.0, ledger.values[$0.offset]) }, reasons: ledger.reasons, warnings: ledger.summarize(relativePath: relativePath), headerFields: [], sha256: puller.digestHex())
    }
}
