import CryptoKit
import Foundation

public enum ReaderError: Error, LocalizedError, Equatable {
    case invalidProject
    case sourceOutsideRaw(String, dataRoot: String)
    case cancelled
    case invalidSource(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProject: "Choose a project containing a readable data/raw directory."
        case .sourceOutsideRaw(let path, let dataRoot): "\(path): resolves outside this project's data root (\"\(dataRoot)\")."
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
    public static let version = "1.3.0"
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
        let v3grammar = V3Reader.context(project: project)
        let catalogFingerprint = V3Reader.cacheFingerprint(catalog: catalog, grammarSHA256: v3grammar.sha256)
        var results: [SourceInspectionResult] = []
        results.reserveCapacity(sources.count)
        let maxConcurrency = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 16))
        var index = 0
        while index < sources.count {
            if Task.isCancelled {
                for source in sources[index...] {
                    results.append(SourceInspectionResult(source: source, inspection: nil, disposition: .cancelled, error: ReaderError.cancelled.localizedDescription))
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
                        batchOutcomes.append((offset, SourceInspectionResult(source: source, inspection: nil, disposition: .cancelled, error: ReaderError.cancelled.localizedDescription)))
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
                            return (offset, SourceInspectionResult(source: source, inspection: nil, disposition: .cancelled, error: ReaderError.cancelled.localizedDescription))
                        }
                        if let cache {
                            let cached = try? await cache.inspection(for: source, project: project, catalogFingerprint: catalogFingerprint) { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
                                try inspectPinned(source: source, project: project, catalog: catalog, prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL, v3grammar: v3grammar)
                            }
                            if let cached {
                                switch cached.outcome {
                                case .supported(let inspection, let disposition):
                                    return (offset, SourceInspectionResult(source: source, inspection: inspection, disposition: disposition, error: nil))
                                case .blocked(let message):
                                    return (offset, SourceInspectionResult(source: source, inspection: nil, disposition: .deterministicBlocked, error: message))
                                }
                            }
                        }
                        return (offset, inspect(source, project: project, catalog: catalog, v3grammar: v3grammar))
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
    /// a lexically inside-data-root link fails closed with the symlink
    /// diagnostic, and only a lexically outside link reports the outside
    /// diagnostic naming the configured root. The target is never resolved,
    /// stat-ed, opened, or read.
    private static func sourceLinkRejection(_ source: URL, project: ProjectContext, linkTarget: String) -> ReaderError {
        if project.symlinkTargetResolvesInsideRaw(source: source, linkTarget: linkTarget) {
            return .invalidSource("\(project.claimedPath(of: source)): source file is a symlink or was replaced by one during open; symlinks are never followed.")
        }
        return .sourceOutsideRaw(project.claimedPath(of: source), dataRoot: project.dataRootRelativePath)
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
            let v3grammar = V3Reader.context(project: project)
            let cacheFingerprint = V3Reader.cacheFingerprint(catalog: catalog, grammarSHA256: v3grammar.sha256)
            // Single claimed-path containment helper: the claimed (unresolved)
            // selection must sit inside the configured data root, and the
            // project-relative identity it yields is the source identity. The
            // descriptor verification below remains independent.
            guard let relativePath = project.sourceRelativePath(of: source) else {
                throw ReaderError.sourceOutsideRaw(project.claimedPath(of: source), dataRoot: project.dataRootRelativePath)
            }
            // The selected path supplies source identity and filename evidence;
            // the opened descriptor independently proves the bytes stay in raw.
            let handle: FileHandle
            do {
                handle = try SecureFile.openVerified(resolvedPath: source.path, beneath: project.rawRoot.path)
            } catch let error as SecureOpenError {
                throw error.readerError(display: project.claimedPath(of: source), dataRoot: project.dataRootRelativePath)
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
                   profileFingerprint: cacheFingerprint) {
                try? handle.close()
                return cached
            }
            var hasher = SHA256()
            hasher.update(data: prefixData)
            // Schema-v3 routes first with the same exactly-one-variant rule as
            // inspection. A claimed failure throws here and never reaches the
            // generic fallback in the legacy path below.
            switch V3Reader.resolve(prefix: prefixData, extension: fileExtension, basename: basename,
                                    relativePath: relativePath, descriptorSize: descriptorSize,
                                    catalog: catalog, grammar: v3grammar) {
            case .unclaimed:
                break
            case .failed(let message):
                try? handle.close()
                throw ReaderError.invalidSource(message)
            case .matched(let match, let v3encoding, let v3sample, let v3pending):
                let v3extracted = try V3StreamExtractor.extractStreaming(
                    relativePath: relativePath, match: match, encoding: v3encoding,
                    initialText: v3sample, initialPending: v3pending, handle: handle, hasher: hasher)
                try Task.checkCancellation()
                let v3measurement = try V3Reader.measurement(
                    relativePath: relativePath, basename: basename, match: match, extracted: v3extracted)
                if let cache, !Task.isCancelled {
                    try? cache.store(
                        measurement: v3measurement,
                        profileFingerprint: cacheFingerprint,
                        source: RawSource(relativePath: relativePath, url: source, byteSize: descriptorSize),
                        prefixSHA256: prefixDigest,
                        project: project)
                }
                return v3measurement
            }
            // The selected unique profile/format's declared encoding drives
            // decoding: candidates are resolved using each candidate's own
            // encoding, and only one unique profile/format may match.
            let grammar = ProfileWhenMatcher.grammarContextFromCatalog(
                (v3grammar ?? V3Reader.context(project: project)).catalog, basename: basename)
            let encoded = resolveEncoded(
                prefix: prefixData, catalog: catalog, extension: fileExtension, basename: basename, grammar: grammar)
            let match: ProfileMatch
            let sample: String
            let selectedEncoding: String.Encoding?
            let pending: Data
            switch encoded.resolution {
            case .failed(let message):
                if let measurement = try? GenericTableReader.loadMeasurement(url: source, sourceID: relativePath) {
                    try? handle.close()
                    return measurement
                }
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
            case .ambiguousProfile(let candidateIDs):
                try? handle.close()
                throw ReaderError.invalidSource(ProfileWhenMatcher.formatAmbiguous(candidateIDs))
            case .grammarMatchedNoProfile:
                try? handle.close()
                throw ReaderError.invalidSource(
                    "Filename matched the project grammar but no instrument profile mode matched this source.")
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
                    "profile_id": match.profile.profileID,
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
                    profileFingerprint: cacheFingerprint,
                    source: RawSource(relativePath: relativePath, url: source, byteSize: descriptorSize),
                    prefixSHA256: prefixDigest,
                    project: project)
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

    private static func inspect(_ source: RawSource, project: ProjectContext, catalog: ProfileCatalog, v3grammar: V3GrammarContext) -> SourceInspectionResult {
        do {
            switch try inspectAccess(source, project: project, catalog: catalog, v3grammar: v3grammar) {
            case .supported(let inspection, let disposition):
                return SourceInspectionResult(source: source, inspection: inspection, disposition: disposition, error: nil)
            case .blocked(let message):
                return SourceInspectionResult(source: source, inspection: nil, disposition: .deterministicBlocked, error: message)
            }
        } catch is CancellationError {
            return SourceInspectionResult(source: source, inspection: nil, disposition: .cancelled, error: ReaderError.cancelled.localizedDescription)
        } catch let error as ReaderError {
            if case .cancelled = error {
                return SourceInspectionResult(source: source, inspection: nil, disposition: .cancelled, error: error.localizedDescription)
            }
            return SourceInspectionResult(source: source, inspection: nil, disposition: .transientFailure, error: error.localizedDescription)
        } catch {
            return SourceInspectionResult(source: source, inspection: nil, disposition: .transientFailure, error: error.localizedDescription)
        }
    }

    /// Typed inspection resolution. Returns deterministic outcomes — the
    /// supported inspection or the exact profile/header/mode diagnostic — and
    /// THROWS for anything non-deterministic: cancellation, access/security
    /// failures (missing, unreadable, symlinked, escaped), and open/read
    /// errors. Only returned values may reach the inspection cache.
    static func inspectAccess(_ source: RawSource, project: ProjectContext, catalog: ProfileCatalog, v3grammar: V3GrammarContext? = nil) throws -> MeasurementCache.CachedInspection {
        // Excluded files are rejected from the claimed name alone, before any open.
        guard !ProjectContext.skippedRawExtensions.contains(source.url.pathExtension.lowercased()) else {
            return .blocked("\(project.claimedPath(of: source.url)): RawView skips .spe and .affm files.")
        }
        guard project.sourceRelativePath(of: source.url) == source.relativePath else {
            throw ReaderError.sourceOutsideRaw(project.claimedPath(of: source.url), dataRoot: project.dataRootRelativePath)
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
            throw error.readerError(display: project.claimedPath(of: source.url), dataRoot: project.dataRootRelativePath)
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
        return try inspectPinned(source: source, project: project, catalog: catalog, prefix: prefixData, descriptorSize: descriptorSize, actualURL: source.url, v3grammar: v3grammar)
    }

    /// Pinned inspection production for the cache seam: computes the outcome
    /// from the exact prefix bytes, descriptor size, and descriptor canonical
    /// URL obtained by the cache's secured open, without reopening the path.
    /// The descriptor URL is not source identity: hardlinks may have another
    /// F_GETPATH alias, so selectors and diagnostics use the selected source.
    static func inspectPinned(source: RawSource, project: ProjectContext, catalog: ProfileCatalog, prefix: Data, descriptorSize: Int64, actualURL _: URL, v3grammar: V3GrammarContext? = nil) throws -> MeasurementCache.CachedInspection {
        guard !ProjectContext.skippedRawExtensions.contains(source.url.pathExtension.lowercased()) else {
            return .blocked("\(project.claimedPath(of: source.url)): RawView skips .spe and .affm files.")
        }
        try Task.checkCancellation()
        let fileExtension = "." + source.url.pathExtension.lowercased()
        let basename = source.url.lastPathComponent
        let relativePath = source.relativePath
        // Schema-v3 routes first: a claimed source resolves to exactly one
        // variant or a deterministic diagnostic. Claimed failures never reach
        // the legacy path or the generic fallback below.
        switch V3Reader.resolve(prefix: prefix, extension: fileExtension, basename: basename,
                                relativePath: relativePath, descriptorSize: descriptorSize,
                                catalog: catalog, grammar: v3grammar ?? V3Reader.context(project: project)) {
        case .unclaimed:
            break
        case .failed(let message):
            return .blocked(message)
        case .matched(let match, _, _, _):
            let inspection = SourceInspection(
                source: relativePath, size: descriptorSize,
                instrumentID: match.document.instrumentID, instrumentName: match.document.instrumentName,
                applicationMode: match.variant.id,
                timestamp: match.facts.timestamp, deviceID: match.facts.deviceID, category: match.facts.category,
                supportStatus: "supported",
                validationState: "profile valid; source not loaded; variant \(match.variant.id); grammar \(match.document.grammarID) \(String(match.grammarSHA256.prefix(12)))",
                readerVersion: version, profileID: match.document.profileID, profileHash: match.documentSHA256, error: nil
            )
            return .supported(inspection, .profileMatched)
        }
        let grammar = ProfileWhenMatcher.grammarContextFromCatalog(
            V3Reader.context(project: project).catalog, basename: basename)
        let encoded = resolveEncoded(
            prefix: prefix, catalog: catalog, extension: fileExtension, basename: basename, grammar: grammar)
        switch encoded.resolution {
        case .failed(let message):
            if let generic = try? GenericTableReader.inspect(prefix: prefix) {
                let facts = parseFilename(basename)
                let delimName = generic.delimiter == "\t" ? "TSV" : (generic.delimiter == "," ? "CSV" : (generic.delimiter == ";" ? "Semicolon" : "Whitespace"))
                let inspection = SourceInspection(
                    source: relativePath, size: descriptorSize,
                    instrumentID: "generic-table",
                    instrumentName: "Generic Table (\(delimName))",
                    applicationMode: "table-view",
                    timestamp: facts.timestamp,
                    deviceID: facts.deviceID,
                    category: facts.category,
                    supportStatus: "supported",
                    validationState: "generic table; unprofiled (structural candidate)",
                    readerVersion: version,
                    profileID: "generic-table",
                    profileHash: "generic-fallback",
                    error: nil
                )
                return .supported(inspection, .structuralCandidate)
            }
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
                readerVersion: version, profileID: match.profile.profileID, profileHash: match.profile.sha256, error: nil
            )
            return .supported(inspection, .profileMatched)
        case .ambiguousProfile(let candidateIDs):
            return .blocked(ProfileWhenMatcher.formatAmbiguous(candidateIDs))
        case .grammarMatchedNoProfile:
            return .blocked(
                "Filename matched the project grammar but no instrument profile mode matched this source.")
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
    private static func resolveEncoded(
        prefix: Data,
        catalog: ProfileCatalog,
        extension fileExtension: String,
        basename: String,
        grammar: ProfileWhenMatcher.GrammarMatchContext
    ) -> (resolution: ProfileResolution, encoding: String.Encoding?, text: String?, pending: Data?) {
        var candidates: [(profile: InstrumentProfile, format: ProfileFormat)] = []
        for profile in catalog.profiles {
            for format in profile.formats where format.extensions.contains(fileExtension) {
                candidates.append((profile, format))
            }
        }
        guard !candidates.isEmpty else {
            return (
                catalog.resolve(
                    extension: fileExtension, headerSample: "", basename: basename, grammar: grammar),
                nil, nil, nil)
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
        let basenameTokens = ProfileWhenMatcher.tokenizeBasename(basename)
        let grammarFields = grammar.matchedFields
        for (profile, format) in candidates {
            guard let decoded = decodeWithFormat(prefix, format: format) else { continue }
            if !firstDecoded { firstSample = decoded.text; firstDecoded = true }
            decodedAny = true
            let profileWhen = profile.profileWhen
            for mode in profile.modes.filter({ $0.formatID == format.id }) {
                let merged = ProfileWhenMatcher.mergeWhen(profile: profileWhen, variant: mode.when)
                guard ProfileWhenMatcher.modeIsCandidate(merged, grammar: grammar) else { continue }
                if ProfileWhenMatcher.matchesWhen(
                    merged,
                    grammarFields: grammarFields,
                    basenameTokens: basenameTokens,
                    headerSample: decoded.text,
                    basenameForContent: basename
                ) {
                    hits.append(
                        CandidateHit(
                            match: ProfileMatch(profile: profile, format: format, mode: mode),
                            encoding: decoded.encoding, text: decoded.text, pending: decoded.pending))
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
            var candidateIDs = hits.map { ProfileWhenMatcher.candidateProfileID($0.match.profile) }.sorted()
            candidateIDs = Array(Set(candidateIDs)).sorted()
            return (.ambiguousProfile(candidateIDs: candidateIDs), nil, nil, nil)
        }
        guard decodedAny else {
            if catalog.hasBrokenClaim(for: fileExtension) {
                return (
                    catalog.resolve(
                        extension: fileExtension, headerSample: "", basename: basename, grammar: grammar),
                    nil, nil, nil)
            }
            return (.failed("the file header could not be decoded with any accepted profile encoding."), nil, nil, nil)
        }
        let fallback = catalog.resolve(
            extension: fileExtension, headerSample: firstSample, basename: basename, grammar: grammar)
        switch fallback {
        case .failed, .ambiguousProfile, .grammarMatchedNoProfile:
            return (fallback, nil, nil, nil)
        case .matched(let foreign):
            return (
                .failed(
                    "No profile mode matched this source using its own declared encoding (basename \"\(basename)\"). A mode (\(foreign.profile.relativePath) mode \(foreign.mode.id)) matches only in another candidate's decoded text and cannot decode this source."),
                nil, nil, nil)
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
    static func headerMetadata(lines: [String], delimiter: Character, relativePath: String) throws -> [(key: String, value: String)] {
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

// MARK: - Schema-v3 exact variant resolution and extraction

/// Project grammar state for v3 routing: the validated catalog plus the exact
/// source-bytes digest. A missing file and a malformed file stay distinct;
/// both fail closed at resolve time.
struct V3GrammarContext: Sendable {
    let catalog: FilenameGrammarCatalog?
    let sha256: String?
    let error: String?
}

/// One exactly resolved schema-v3 variant with its routing evidence.
struct V3Match: Sendable {
    let document: ProfileDocumentV3
    let variant: ProfileVariantV3
    let grammar: FilenameGrammar
    let facts: ExtractedGrammarFacts
    let grammarSHA256: String
    let documentPath: String
    let documentSHA256: String
}

enum V3Outcome: Sendable {
    case unclaimed
    case matched(V3Match, encoding: String.Encoding, sample: String, pending: Data)
    case failed(String)
}

/// Thrown when the bounded prefix ends before the header row: inspection
/// passes the variant and the full-stream load decides.
private struct V3DeferHeader: Error {
    let message: String
}

enum V3Reader {
    static func context(project: ProjectContext) -> V3GrammarContext {
        let url = project.root.appendingPathComponent(FilenameGrammarEngine.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return V3GrammarContext(catalog: nil, sha256: nil,
                                    error: "grammar catalog \(FilenameGrammarEngine.relativePath) not found")
        }
        guard let data = try? Data(contentsOf: url) else {
            return V3GrammarContext(catalog: nil, sha256: nil,
                                    error: "grammar catalog \(FilenameGrammarEngine.relativePath) could not be read")
        }
        do {
            return V3GrammarContext(catalog: try FilenameGrammarEngine.load(fileURL: url),
                                    sha256: sha256Hex(data), error: nil)
        } catch {
            return V3GrammarContext(catalog: nil, sha256: sha256Hex(data),
                                    error: error.localizedDescription)
        }
    }

    /// Cache identity: the complete catalog fingerprint (which already covers
    /// every v3 document's bytes) plus the exact grammar bytes. Legacy-only
    /// projects keep the bare catalog fingerprint so their keys never move.
    /// No payload schema change: provenance already round-trips as free-form
    /// strings, so the cache version stays put.
    static func cacheFingerprint(catalog: ProfileCatalog, grammarSHA256: String?) -> String {
        guard !catalog.v3Documents.isEmpty || grammarSHA256 != nil else { return catalog.fingerprint }
        return sha256Hex(Data("v3cache|\(catalog.fingerprint)|\(grammarSHA256 ?? "absent")".utf8))
    }

    static func cacheFingerprint(catalog: ProfileCatalog, project: ProjectContext) -> String {
        cacheFingerprint(catalog: catalog, grammarSHA256: context(project: project).sha256)
    }

    /// Decodes the bounded prefix with one variant's declared encodings only,
    /// mirroring the legacy per-candidate decoding (UTF-8 backs off a split
    /// trailing scalar). Alternatives are explicit, never invented.
    static func decodePrefix(_ prefix: Data, names: [String]) -> (encoding: String.Encoding, text: String, pending: Data)? {
        for name in names {
            guard let encoding = ProfileSchema.encoding(named: name) else { continue }
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

    /// Full grammar match (partial never routes) → exact raw key tuple
    /// (case-sensitive) → compatibility selectors and declared stream/header
    /// checks → exactly one variant. Anything claimed but undecidable is a
    /// deterministic failure, never a silent route to generic success.
    static func resolve(prefix: Data, extension fileExtension: String, basename: String,
                        relativePath: String, descriptorSize: Int64,
                        catalog: ProfileCatalog, grammar: V3GrammarContext) -> V3Outcome {
        let ext = fileExtension.lowercased()
        let claiming = catalog.v3Documents.filter { loaded in
            loaded.document.variants.contains { $0.rawStream.extensions.map({ $0.lowercased() }).contains(ext) }
        }
        guard !claiming.isEmpty else { return .unclaimed }
        guard let grammarCatalog = grammar.catalog else {
            return .failed("\(relativePath): schema-v3 profiles claim \"\(ext)\" but the grammar catalog cannot be used (\(grammar.error ?? "missing")); fix \(FilenameGrammarEngine.relativePath) or remove the v3 profiles.")
        }
        let truncated = descriptorSize > Int64(prefix.count)
        struct Candidate {
            let match: V3Match
            let encoding: String.Encoding
            let text: String
            let pending: Data
        }
        var candidates: [Candidate] = []
        var blockingNotes: [String] = []
        var matchNotes: [String] = []
        var sawFullMatch = false
        var decodedCache: [String: (encoding: String.Encoding, text: String, pending: Data)] = [:]
        for loaded in claiming {
            let document = loaded.document
            guard let grammarDef = grammarCatalog.grammars.first(where: { $0.id == document.grammarID }) else {
                blockingNotes.append("\(loaded.relativePath): filename.grammar_id \"\(document.grammarID)\" is not in the grammar catalog.")
                continue
            }
            let facts = FilenameGrammarEngine.extract(from: basename, grammar: grammarDef)
            guard facts.isMatched else { continue }
            sawFullMatch = true
            var tuple: [String: String] = [:]
            var tupleComplete = true
            for key in document.variantKeys {
                guard let value = facts.extractedFields[key] else { tupleComplete = false; break }
                tuple[key] = value
            }
            guard tupleComplete else { continue }
            for variant in document.variants where variant.rawStream.extensions.map({ $0.lowercased() }).contains(ext) {
                guard document.variantKeys.allSatisfy({ variant.keyValues[$0] == tuple[$0] }) else { continue }
                let cacheKey = variant.rawStream.encodings.joined(separator: "\u{0}")
                let decoded: (encoding: String.Encoding, text: String, pending: Data)?
                if let hit = decodedCache[cacheKey] {
                    decoded = hit
                } else {
                    decoded = decodePrefix(prefix, names: variant.rawStream.encodings)
                    if let decoded { decodedCache[cacheKey] = decoded }
                }
                guard let decoded else {
                    matchNotes.append("\(loaded.relativePath) variant \"\(variant.id)\": the file header could not be decoded with declared encodings [\(variant.rawStream.encodings.joined(separator: ", "))].")
                    continue
                }
                if let required = variant.match?.filenameContainsAll,
                   !required.allSatisfy({ basename.lowercased().contains($0.lowercased()) }) { continue }
                if let any = variant.match?.contentContainsAny,
                   !any.contains(where: { decoded.text.lowercased().contains($0.lowercased()) }) { continue }
                do {
                    try checkHeader(sample: decoded.text, variant: variant, relativePath: relativePath,
                                    completePrefix: !truncated)
                    candidates.append(Candidate(
                        match: V3Match(document: document, variant: variant, grammar: grammarDef, facts: facts,
                                       grammarSHA256: grammar.sha256 ?? "absent",
                                       documentPath: loaded.relativePath, documentSHA256: loaded.sha256),
                        encoding: decoded.encoding, text: decoded.text, pending: decoded.pending))
                } catch is V3DeferHeader {
                    // ponytail: bounded-prefix deferral; the full-stream load
                    // re-runs every check, so a wrong pass still fails closed.
                    candidates.append(Candidate(
                        match: V3Match(document: document, variant: variant, grammar: grammarDef, facts: facts,
                                       grammarSHA256: grammar.sha256 ?? "absent",
                                       documentPath: loaded.relativePath, documentSHA256: loaded.sha256),
                        encoding: decoded.encoding, text: decoded.text, pending: decoded.pending))
                } catch {
                    matchNotes.append("\(loaded.relativePath) variant \"\(variant.id)\": \(error.localizedDescription)")
                    continue
                }
            }
        }
        if candidates.count > 1 {
            let described = candidates.map { "\($0.match.documentPath) variant \($0.match.variant.id)" }.joined(separator: ", ")
            return .failed("\(relativePath): Ambiguous profile match: \(described). Keep one variant per source: refine variant keys, compatibility selectors, or stream headers.")
        }
        if let unique = candidates.first {
            if !blockingNotes.isEmpty {
                return .failed("\(relativePath): variant \"\(unique.match.variant.id)\" matches, but another claiming profile cannot route (\(blockingNotes.joined(separator: " "))). Resolve every claiming variant before loading.")
            }
            if case .matched(let foreign) = catalog.resolve(
                extension: ext, headerSample: unique.text, basename: basename,
                grammar: ProfileWhenMatcher.grammarContextFromCatalog(grammar.catalog, basename: basename)
            ) {
                return .failed("\(relativePath): Ambiguous profile match: schema-v3 \(unique.match.documentPath) variant \(unique.match.variant.id) and legacy \(foreign.profile.relativePath) mode \(foreign.mode.id) both match. Keep one profile per source.")
            }
            let blocking = catalog.brokenClaims.filter { $0.blocks(sample: unique.text.lowercased(), basename: basename) }
            if !blocking.isEmpty {
                let note = "A valid v3 profile (\(unique.match.documentPath) variant \(unique.match.variant.id)) also matches this source; the source stays blocked until the invalid profile is fixed or removed."
                return .failed((blocking.flatMap(\.issues) + [note]).joined(separator: "\n"))
            }
            return .matched(unique.match, encoding: unique.encoding, sample: unique.text, pending: unique.pending)
        }
        if sawFullMatch {
            let detail = matchNotes.isEmpty
                ? "no variant of \(claiming.map(\.relativePath).joined(separator: ", ")) declares those key values"
                : matchNotes.joined(separator: " ")
            return .failed("\(relativePath): the filename matches a schema-v3 grammar but \(detail).")
        }
        return .unclaimed
    }

    /// Header locator plus data-column resolution over the available sample.
    /// A missing header in a complete prefix is definitive; in a truncated
    /// prefix it defers to the full-stream load.
    static func checkHeader(sample: String, variant: ProfileVariantV3, relativePath: String, completePrefix: Bool) throws {
        let lines = sample.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let usable = completePrefix ? lines : Array(lines.dropLast())
        let numbered = usable.enumerated().map { (number: $0.offset + 1, text: $0.element) }
        do {
            guard let (_, headers) = try resolveHeaderRow(lines: numbered, variant: variant, relativePath: relativePath) else { return }
            _ = try resolveDataColumns(headers: headers, variant: variant, relativePath: relativePath)
        } catch let deferral as V3DeferHeader {
            if completePrefix { throw ReaderError.invalidSource("\(relativePath): \(deferral.message).") }
            throw deferral
        }
    }

    static func resolveHeaderRow(lines: [(number: Int, text: String)], variant: ProfileVariantV3, relativePath: String) throws -> (Int, [String])? {
        let stream = variant.rawStream
        guard let delimiter = stream.delimiter.first, stream.delimiter.count == 1 else {
            throw ReaderError.invalidSource("\(relativePath): variant \"\(variant.id)\" declares an unusable delimiter.")
        }
        func splitHeader(_ text: String, _ number: Int) throws -> [String] {
            try TabularExtractor.split(text, delimiter: delimiter, context: "\(relativePath) line \(number)")
        }
        switch stream.rows.header {
        case .none:
            return nil
        case .row(let physical):
            guard physical - 1 < lines.count else {
                throw V3DeferHeader(message: "header row \(physical) was not found")
            }
            let line = lines[physical - 1]
            return (line.number, try splitHeader(line.text, line.number))
        case .firstNonBlank:
            for line in lines where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (line.number, try splitHeader(line.text, line.number))
            }
            throw V3DeferHeader(message: "no non-blank header row was found")
        case .prefix(let marker):
            for line in lines {
                let cells = try splitHeader(line.text, line.number)
                if cells.first == marker { return (line.number, cells) }
            }
            throw V3DeferHeader(message: "no header row starting with \"\(marker)\" was found")
        }
    }

    /// Header lookup is case-insensitive, primary header first then alias
    /// fallback; ambiguous headers and two columns resolving to one source
    /// column fail closed. Both column and header supplied requires
    /// agreement; aliases require a header (validated at parse).
    static func resolveDataColumns(headers: [String]?, variant: ProfileVariantV3, relativePath: String) throws -> [(ProfileColumnV3, Int)] {
        let decodable = variant.rawStream.columns.filter { $0.role != .skip }
        guard !decodable.isEmpty else {
            throw ReaderError.invalidSource("\(relativePath): variant \"\(variant.id)\" declares no decodable columns.")
        }
        var resolved: [(ProfileColumnV3, Int)] = []
        if let headers {
            for column in decodable {
                var headerIndex: Int? = nil
                if let want = column.source.header {
                    let primary = headers.indices.filter { headers[$0].compare(want, options: .caseInsensitive) == .orderedSame }
                    if primary.count > 1 {
                        throw ReaderError.invalidSource("\(relativePath): header for column \"\(column.id)\" (\(want)) matches more than one cell in the header row [\(headers.joined(separator: ", "))].")
                    }
                    if let hit = primary.first {
                        headerIndex = hit
                    } else {
                        let fallback = headers.indices.filter { index in
                            column.source.aliases.contains { headers[index].compare($0, options: .caseInsensitive) == .orderedSame }
                        }
                        if fallback.count > 1 {
                            throw ReaderError.invalidSource("\(relativePath): header for column \"\(column.id)\" (\(want)) matches more than one cell via aliases [\(column.source.aliases.joined(separator: ", "))] in the header row [\(headers.joined(separator: ", "))].")
                        }
                        headerIndex = fallback.first
                    }
                }
                if let position = column.source.column {
                    if let headerIndex {
                        guard headerIndex == position - 1 else {
                            throw ReaderError.invalidSource("\(relativePath): column \"\(column.id)\" declares source column \(position) but header \"\(column.source.header ?? "")\" resolves to source column \(headerIndex + 1); position and header must agree.")
                        }
                    } else {
                        headerIndex = position - 1
                    }
                }
                guard let index = headerIndex else {
                    if !column.required { continue }
                    throw ReaderError.invalidSource("\(relativePath): header for column \"\(column.id)\" (\(column.source.header ?? "column \(column.source.column ?? 0)")) was not found in the header row [\(headers.joined(separator: ", "))].")
                }
                resolved.append((column, index))
            }
        } else {
            for column in decodable {
                guard let position = column.source.column else {
                    throw ReaderError.invalidSource("\(relativePath): column \"\(column.id)\" has no header row to resolve against and declares no source column position.")
                }
                resolved.append((column, position - 1))
            }
        }
        var seen: [Int: String] = [:]
        for (column, index) in resolved {
            if let other = seen[index] {
                throw ReaderError.invalidSource("\(relativePath): columns \"\(other)\" and \"\(column.id)\" resolve to the same source column \(index + 1).")
            }
            seen[index] = column.id
        }
        return resolved
    }

    /// Builds the normalized result with additive v3 provenance: profile and
    /// variant identity, document and grammar fingerprints, axis eligibility,
    /// and the default progression. Conflicting filename/header metadata is
    /// kept with source qualification plus a diagnostic, never precedence.
    static func measurement(relativePath: String, basename: String, match: V3Match, extracted: TabularExtraction) throws -> NormalizedMeasurement {
        let variant = match.variant
        let channels = zip(extracted.columns, extracted.reasons).map { column, reasons in
            MeasurementChannel(name: column.0.key, label: column.0.label, unit: column.0.unit,
                               quantity: column.0.quantity.isEmpty ? nil : column.0.quantity,
                               values: column.1, gapReasons: reasons)
        }
        let channelNames = Set(channels.map(\.name))
        let view: MeasurementView
        if let plot = variant.defaultPlot {
            guard channelNames.contains(plot.x), plot.y.allSatisfy({ channelNames.contains($0) }) else {
                throw ReaderError.invalidSource("\(relativePath): variant \"\(variant.id)\" default_plot references a column missing from this source.")
            }
            view = MeasurementView(kind: "xy", x: plot.x, y: plot.y, preserveOrder: true)
        } else {
            view = MeasurementView(kind: "metadata-only", x: nil, y: nil, preserveOrder: true)
        }
        var acquisition = extracted.headerFields
        var filenameFields = match.facts.extractedFields.sorted(by: { $0.key < $1.key }).map { (key: $0.key, value: $0.value) }
        var warnings = extracted.warnings
        for key in Set(acquisition.map(\.key)).intersection(filenameFields.map(\.key)) {
            let fileValue = filenameFields.first(where: { $0.key == key })!.value
            let streamValue = acquisition.first(where: { $0.key == key })!.value
            if fileValue != streamValue {
                acquisition.removeAll(where: { $0.key == key })
                filenameFields.removeAll(where: { $0.key == key })
                acquisition.append((key: "\(key) (filename)", value: fileValue))
                acquisition.append((key: "\(key) (header)", value: streamValue))
                warnings.append("\(relativePath): metadata \"\(key)\" differs between the filename (\(fileValue)) and the file header (\(streamValue)); both are kept with source qualification.")
            } else {
                filenameFields.removeAll(where: { $0.key == key })
            }
        }
        func field(_ key: String, _ value: String) -> MetadataField {
            MetadataField(key: key, label: key.replacingOccurrences(of: "_", with: " ").capitalized,
                          value: .string(value), unit: nil, kind: "string")
        }
        var sections: [MetadataSection] = []
        if !acquisition.isEmpty {
            sections.append(MetadataSection(title: "Acquisition", fields: acquisition.map { field($0.key, $0.value) }))
        }
        var identity = filenameFields
        identity.append((key: "filename", value: basename))
        sections.append(MetadataSection(title: "Identity", fields: identity.map { field($0.key, $0.value) }))
        let rowCount = channels.first?.values.count ?? 0
        let gapCount = channels.reduce(0) { $0 + $1.values.filter({ $0 == nil }).count }
        sections.append(MetadataSection(title: "Data", fields: [
            MetadataField(key: "channel_count", label: "Channel count", value: .number(Double(channels.count)), unit: nil, kind: "number"),
            MetadataField(key: "point_count", label: "Point count", value: .number(Double(rowCount)), unit: nil, kind: "number"),
            MetadataField(key: "gap_count", label: "Gap count", value: .number(Double(gapCount)), unit: nil, kind: "number"),
        ]))
        let eligibleX = variant.rawStream.columns
            .filter { $0.role != .skip && $0.axes.contains(.x) && channelNames.contains($0.id) }.map(\.id).sorted()
        let eligibleY = variant.rawStream.columns
            .filter { $0.role != .skip && $0.axes.contains(.y) && channelNames.contains($0.id) }.map(\.id).sorted()
        return NormalizedMeasurement(
            source: SourceIdentity(path: relativePath, sha256: extracted.sha256),
            instrument: InstrumentIdentity(id: match.document.instrumentID, name: match.document.instrumentName,
                                           vendor: match.document.vendor, model: match.document.model),
            applicationMode: variant.id,
            view: view, channels: channels, metadataSections: sections, warnings: warnings, supportStatus: "supported",
            provenance: [
                "reader_version": InstrumentReader.version,
                "profile_id": match.document.profileID,
                "variant_id": variant.id,
                "profile_hash": match.documentSHA256,
                "profile_schema_version": "3",
                "mode": match.facts.mode ?? variant.id,
                "grammar_id": match.document.grammarID,
                "grammar_sha256": match.grammarSHA256,
                "eligible_x": eligibleX.joined(separator: ","),
                "eligible_y": eligibleY.joined(separator: ","),
                "progression": variant.defaultPlot?.progression ?? "",
            ])
    }
}

/// Bounded secure streaming extraction for one resolved v3 variant. Lines
/// flow through the shared incremental puller (single encoding, running
/// SHA-256, 1 MiB line/header bounds, cancellation checks); only the rows
/// metadata needs are retained, so complete value arrays stay exact with no
/// file-size cap. Gap classification reuses the shared cell contract.
enum V3StreamExtractor {
    static func extractStreaming(relativePath: String, match: V3Match, encoding: String.Encoding,
                                 initialText: String, initialPending: Data,
                                 handle: FileHandle, hasher: SHA256) throws -> TabularExtraction {
        let variant = match.variant
        let stream = variant.rawStream
        guard let delimiter = stream.delimiter.first, stream.delimiter.count == 1,
              let decimal = stream.decimalSeparator.first, stream.decimalSeparator.count == 1 else {
            throw ReaderError.invalidSource("\(relativePath): variant \"\(variant.id)\" declares an unusable delimiter or decimal separator.")
        }
        func splitLine(_ text: String, _ number: Int) throws -> [String] {
            try TabularExtractor.split(text, delimiter: delimiter, context: "\(relativePath) line \(number)")
        }
        var puller = LinePuller(handle: handle, hasher: hasher, encoding: encoding,
                                relativePath: relativePath, pendingBytes: initialPending)
        try puller.stageText(initialText, final: false)
        let wantsPreHeader = variant.metadataCapture.contains(.preHeaderFields)
        let commentPrefix = stream.rows.commentPrefix
        let wantsComments: Bool = {
            guard commentPrefix != nil else { return false }
            return variant.metadataCapture.contains { if case .commentKeyValue = $0 { true } else { false } }
        }()
        var fixedRows: Set<Int> = []
        for meta in variant.metadata where meta.role != "ignore" {
            if let row = meta.row { fixedRows.insert(row) }
            if let row = meta.parameterRow { fixedRows.insert(row) }
        }
        let excluded = Set(stream.rows.excludedMetadata)
        let dataStartRow: Int? = {
            if case .row(let physical) = stream.rows.dataStart { return physical }
            return nil
        }()
        var lineNumber = 0
        var headerLine: Int? = nil
        var headerNames: [String]? = nil
        let isHeaderless: Bool = {
            if case .none = stream.rows.header { return true }
            return false
        }()
        var columns: [(ProfileColumnV3, Int)] = []
        var columnsResolved = false
        var preBuffer: [(number: Int, text: String)] = []
        var preBytes = 0
        var retained: [Int: String] = [:]
        var commentRecords: [(key: String, value: String)] = []
        var usedCommentKeys = Set<String>()
        var ledger = CellLedger(count: 0)
        var rowCount = 0
        // Headerless layouts resolve columns up front; every other layout
        // resolves them at the header row with full-stream (definitive) errors.
        if isHeaderless {
            columns = try V3Reader.resolveDataColumns(headers: nil, variant: variant, relativePath: relativePath)
            columnsResolved = true
            ledger = CellLedger(count: columns.count)
        }
        while let line = try puller.nextLine() {
            lineNumber += 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isHeaderless, headerLine == nil {
                if let prefix = commentPrefix, trimmed.hasPrefix(prefix) {
                    recordComment(lineNumber: lineNumber, trimmed: trimmed, prefix: prefix,
                                  excluded: excluded, wantsComments: wantsComments,
                                  records: &commentRecords, usedKeys: &usedCommentKeys)
                    continue
                }
                preBytes += line.utf8.count + 1
                guard preBytes <= InstrumentReader.maximumHeaderBytes else {
                    throw ReaderError.invalidSource("\(relativePath): header section exceeds the 1 MiB header limit.")
                }
                switch stream.rows.header {
                case .none:
                    break
                case .row(let physical):
                    preBuffer.append((lineNumber, line))
                    if lineNumber == physical {
                        headerLine = lineNumber
                        headerNames = try splitLine(line, lineNumber)
                    }
                case .firstNonBlank:
                    preBuffer.append((lineNumber, line))
                    if !trimmed.isEmpty {
                        headerLine = lineNumber
                        headerNames = try splitLine(line, lineNumber)
                    }
                case .prefix(let marker):
                    preBuffer.append((lineNumber, line))
                    if try splitLine(line, lineNumber).first == marker {
                        headerLine = lineNumber
                        headerNames = try splitLine(line, lineNumber)
                    }
                }
                if headerLine != nil {
                    if fixedRows.contains(lineNumber) { retained[lineNumber] = line }
                    columns = try V3Reader.resolveDataColumns(headers: headerNames, variant: variant, relativePath: relativePath)
                    columnsResolved = true
                    ledger = CellLedger(count: columns.count)
                }
                continue
            }
            guard columnsResolved else {
                throw ReaderError.invalidSource("\(relativePath): no header row was found.")
            }
            if let header = headerLine, lineNumber == header { continue }
            if trimmed.isEmpty { continue }
            if let prefix = commentPrefix, trimmed.hasPrefix(prefix) {
                recordComment(lineNumber: lineNumber, trimmed: trimmed, prefix: prefix,
                              excluded: excluded, wantsComments: wantsComments,
                              records: &commentRecords, usedKeys: &usedCommentKeys)
                continue
            }
            let startLine: Int = dataStartRow ?? (headerLine.map({ $0 + 1 }) ?? 1)
            if lineNumber < startLine {
                if fixedRows.contains(lineNumber) { retained[lineNumber] = line }
                continue
            }
            if fixedRows.contains(lineNumber), retained[lineNumber] == nil { retained[lineNumber] = line }
            if let dataPrefix = stream.rows.dataPrefix, !dataPrefix.isEmpty {
                guard try splitLine(line, lineNumber).first == dataPrefix else { continue }
            }
            let fields = try splitLine(line, lineNumber)
            for (columnIndex, column) in columns.enumerated() {
                if column.1 >= fields.count {
                    ledger.record(column: columnIndex, reason: .blank,
                                  message: "\(relativePath) line \(lineNumber): column \"\(column.0.id)\" has no cell \(column.1 + 1); shown as a gap.")
                } else {
                    try CellParser.append(raw: fields[column.1], column: columnIndex, key: column.0.id,
                                          lineNumber: lineNumber, relativePath: relativePath,
                                          decimal: decimal, ledger: &ledger)
                }
            }
            rowCount += 1
            if rowCount.isMultiple(of: 4096) { try Task.checkCancellation() }
        }
        if !isHeaderless, headerLine == nil {
            throw ReaderError.invalidSource("\(relativePath): no header row was found.")
        }
        guard columnsResolved else {
            throw ReaderError.invalidSource("\(relativePath): no header row was found.")
        }
        guard rowCount > 0 else {
            if let dataPrefix = stream.rows.dataPrefix, !dataPrefix.isEmpty {
                throw ReaderError.invalidSource("\(relativePath): no \"\(dataPrefix)\" data rows were found after the header.")
            }
            throw ReaderError.invalidSource("\(relativePath): no data rows were found after the header.")
        }
        let headerLimit = headerLine ?? lineNumber
        let preHeaderTexts = preBuffer.filter { $0.number < headerLimit && !excluded.contains($0.number) }.map(\.text)
        var headerFields = wantsPreHeader
            ? try TabularExtractor.headerMetadata(lines: preHeaderTexts, delimiter: delimiter, relativePath: relativePath)
            : []
        headerFields.append(contentsOf: commentRecords)
        for meta in variant.metadata where meta.role != "ignore" {
            guard let row = meta.row, let text = retained[row] ?? preBuffer.first(where: { $0.number == row })?.text else {
                if meta.row == nil {
                    throw ReaderError.invalidSource("\(relativePath): metadata \"\(meta.key)\" names no source row; a fixed row is required.")
                }
                throw ReaderError.invalidSource("\(relativePath): metadata \"\(meta.key)\" source row \(meta.row!) is past the end of the file.")
            }
            if excluded.contains(row) {
                throw ReaderError.invalidSource("\(relativePath): metadata \"\(meta.key)\" source row \(row) is excluded metadata.")
            }
            let cells = try splitLine(text, row)
            if let column = meta.column {
                guard column - 1 < cells.count, !cells[column - 1].isEmpty else { continue }
                headerFields.append((key: meta.key, value: cells[column - 1]))
            } else {
                let joined = cells.filter({ !$0.isEmpty }).joined(separator: ", ")
                guard !joined.isEmpty else { continue }
                headerFields.append((key: meta.key, value: joined))
            }
            if let parameterName = meta.parameterName {
                let parameterRow = meta.parameterRow ?? meta.row
                let parameterColumn = meta.parameterColumn ?? meta.column
                guard let parameterRow, let parameterColumn,
                      let parameterText = retained[parameterRow] ?? preBuffer.first(where: { $0.number == parameterRow })?.text else { continue }
                if excluded.contains(parameterRow) {
                    throw ReaderError.invalidSource("\(relativePath): metadata \"\(meta.key)\" parameter source row \(parameterRow) is excluded metadata.")
                }
                let parameterCells = try splitLine(parameterText, parameterRow)
                guard parameterColumn - 1 < parameterCells.count, !parameterCells[parameterColumn - 1].isEmpty else { continue }
                headerFields.append((key: "\(meta.key).\(parameterName)", value: parameterCells[parameterColumn - 1]))
            }
        }
        return TabularExtraction(
            columns: columns.enumerated().map { (index, column) in
                (ProfileColumn(key: column.0.id, header: column.0.source.header, aliases: column.0.source.aliases,
                               quantity: column.0.quantity, unit: column.0.unit ?? "", label: column.0.label,
                               index: nil, required: column.0.required), ledger.values[index])
            },
            reasons: ledger.reasons,
            warnings: ledger.summarize(relativePath: relativePath),
            headerFields: headerFields,
            sha256: puller.digestHex())
    }

    /// Declared comment lines are filtered before decoding; with a
    /// comment_key_value rule they also become ordered key=value records
    /// (repeated keys kept, legacy caps), mirroring the comment-tsv contract.
    private static func recordComment(lineNumber: Int, trimmed: String, prefix: String, excluded: Set<Int>,
                                      wantsComments: Bool, records: inout [(key: String, value: String)],
                                      usedKeys: inout Set<String>) {
        guard wantsComments, !excluded.contains(lineNumber), records.count < 256 else { return }
        let body = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard let separator = body.firstIndex(of: "=") else { return }
        let key = String(body[..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(body[body.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }
        var unique = key
        var suffix = 2
        while usedKeys.contains(unique) {
            unique = "\(key) #\(suffix)"
            suffix += 1
        }
        usedKeys.insert(unique)
        records.append((unique, value.count > 512 ? String(value.prefix(509)) + "..." : value))
    }
}
