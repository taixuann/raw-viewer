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
    public static let version = "1.1.0"
    static let progressBatchSize = 64
    static let headerSampleBytes = 64 * 1024

    public static func inspectMany(
        _ sources: [RawSource],
        project: ProjectContext,
        onProgress: (@Sendable ([SourceInspectionResult], Int) async -> Void)? = nil
    ) async -> ReaderInspectionReport {
        let catalog = ProfileCatalog.load(project: project)
        var results: [SourceInspectionResult] = []
        results.reserveCapacity(sources.count)
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
            var batch: [SourceInspectionResult] = []
            for source in sources[index..<end] {
                if Task.isCancelled {
                    batch.append(SourceInspectionResult(source: source, inspection: nil, error: ReaderError.cancelled.localizedDescription))
                } else {
                    batch.append(inspect(source, project: project, catalog: catalog))
                }
            }
            results.append(contentsOf: batch)
            await onProgress?(batch, end)
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

    public static func load(_ source: URL, project: ProjectContext) async throws -> NormalizedMeasurement {
        // Excluded files are rejected from the claimed name alone, before any
        // path resolution or filesystem access touches them.
        guard !ProjectContext.skippedRawExtensions.contains(source.pathExtension.lowercased()) else {
            throw ReaderError.invalidSource("\(project.claimedPath(of: source)): RawView skips .spe and .affm files.")
        }
        // No-follow source-link check before any canonicalization: a symlink
        // source is rejected from its link text alone (readlink touches only
        // the link). Discovery omits every symlink entry, so a link here can
        // only come from a direct caller and must fail closed.
        if let linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: source.path) {
            throw sourceLinkRejection(source, project: project, linkTarget: linkTarget)
        }
        let canonical = source.resolvingSymlinksInPath().standardizedFileURL
        // Containment first, without any readability requirement: an escaped
        // path gets the source-local outside diagnostic, while a missing or
        // unreadable in-root file falls through to the open diagnostics.
        guard project.containsSource(source) else {
            throw ReaderError.sourceOutsideRaw(project.claimedPath(of: source))
        }
        let relativePath = String(canonical.path.dropFirst(project.root.path.count + 1))
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw ReaderError.sourceOutsideRaw(project.claimedPath(of: source))
        }
        // A supported claimed name that resolves to an excluded file stays
        // rejected as well.
        guard !ProjectContext.skippedRawExtensions.contains(canonical.pathExtension.lowercased()) else {
            throw ReaderError.invalidSource("\(relativePath): RawView skips .spe and .affm files.")
        }
        do {
            try Task.checkCancellation()
            let catalog = ProfileCatalog.load(project: project)
            let fileExtension = "." + canonical.pathExtension.lowercased()
            // The secured handle pins the exact object that path checks
            // validated. Prefix bytes select the encoding and detect sample;
            // hashing and row parsing stream the same handle afterwards.
            let handle: FileHandle
            do {
                handle = try SecureFile.openVerified(resolvedPath: canonical.path, beneath: project.rawRoot.path)
            } catch let error as SecureOpenError {
                throw error.readerError(display: relativePath)
            } catch {
                throw ReaderError.invalidSource("\(relativePath): could not open the source file: \(error.localizedDescription)")
            }
            let prefixData: Data
            do {
                prefixData = try handle.read(upToCount: headerSampleBytes) ?? Data()
            } catch {
                throw ReaderError.invalidSource("\(relativePath): could not read the source file: \(error.localizedDescription)")
            }
            var hasher = SHA256()
            hasher.update(data: prefixData)
            // Extension gate before decoding: unclaimed extensions report
            // "No instrument profile supports" without attempting a decode, so an
            // undecodable header never masks the actionable unsupported diagnostic.
            let sample: String
            var selectedEncoding: String.Encoding?
            var pending = Data()
            if catalog.hasValidClaim(for: fileExtension) {
                if let selection = selectEncoding(prefixData, catalog: catalog, extension: fileExtension) {
                    sample = selection.text
                    selectedEncoding = selection.encoding
                    pending = selection.pending
                } else if catalog.hasBrokenClaim(for: fileExtension) {
                    sample = ""
                } else {
                    throw ReaderError.invalidSource("\(relativePath): the file header could not be decoded with any accepted profile encoding.")
                }
            } else {
                sample = ""
            }
            let match: ProfileMatch
            switch catalog.resolve(extension: fileExtension, headerSample: sample) {
            case .failed(let message): throw ReaderError.invalidSource(message)
            case .matched(let value): match = value
            }
            guard let encoding = selectedEncoding else {
                // Unreachable: a valid match requires a successful selection above.
                throw ReaderError.invalidSource("\(relativePath): no decoding was selected for this source.")
            }
            let extracted: TabularExtraction
            if match.format.kind == "comment-tsv" {
                extracted = try CommentTsvExtractor.extractStreaming(
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
            let facts = parseFilename(canonical.lastPathComponent)
            return NormalizedMeasurement(
                source: SourceIdentity(path: relativePath, sha256: extracted.sha256),
                instrument: InstrumentIdentity(id: match.profile.instrumentID, name: match.profile.instrumentName,
                                               vendor: match.profile.vendor, model: match.profile.model),
                applicationMode: match.mode.id,
                view: MeasurementView(kind: "xy", x: match.mode.x, y: match.mode.y, preserveOrder: true),
                channels: channels,
                metadataSections: metadataSections(headerFields: extracted.headerFields, filename: canonical.lastPathComponent, facts: facts, channelCount: channels.count, rowCount: rowCount, gapCount: gapCount),
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
        } catch is CancellationError {
            throw ReaderError.cancelled
        } catch let error as ReaderError {
            throw error
        } catch {
            throw ReaderError.invalidSource("\(relativePath): could not read the source file: \(error.localizedDescription)")
        }
    }

    private static func inspect(_ source: RawSource, project: ProjectContext, catalog: ProfileCatalog) -> SourceInspectionResult {
        do {
            // Excluded files are rejected from the claimed name alone, before
            // any path resolution or filesystem access touches them.
            guard !ProjectContext.skippedRawExtensions.contains(source.url.pathExtension.lowercased()) else {
                throw ReaderError.invalidSource("\(project.claimedPath(of: source.url)): RawView skips .spe and .affm files.")
            }
            // No-follow source-link check before any canonicalization: a
            // symlink source is rejected from its link text alone (readlink
            // touches only the link). Discovery omits every symlink entry, so
            // a link here can only come from a forged caller and must fail
            // closed.
            if let linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: source.url.path) {
                throw sourceLinkRejection(source.url, project: project, linkTarget: linkTarget)
            }
            let canonical = source.url.resolvingSymlinksInPath().standardizedFileURL
            let relativePath = String(canonical.path.dropFirst(project.root.path.count + 1))
            guard project.containsSource(source.url), relativePath == source.relativePath else {
                throw ReaderError.sourceOutsideRaw(project.claimedPath(of: source.url))
            }
            // A supported claimed name that resolves to an excluded file stays
            // rejected as well.
            guard !ProjectContext.skippedRawExtensions.contains(canonical.pathExtension.lowercased()) else {
                throw ReaderError.invalidSource("\(relativePath): RawView skips .spe and .affm files.")
            }
            let fileExtension = "." + canonical.pathExtension.lowercased()
            let handle: FileHandle
            let prefixData: Data
            do {
                handle = try SecureFile.openVerified(resolvedPath: canonical.path, beneath: project.rawRoot.path)
                prefixData = try handle.read(upToCount: headerSampleBytes) ?? Data()
            } catch let error as SecureOpenError {
                throw error.readerError(display: relativePath)
            } catch {
                throw ReaderError.invalidSource("\(relativePath): could not read the source file: \(error.localizedDescription)")
            }
            let sample: String
            if !catalog.hasValidClaim(for: fileExtension) {
                sample = ""
            } else if let selection = selectEncoding(prefixData, catalog: catalog, extension: fileExtension) {
                sample = selection.text
            } else if catalog.hasBrokenClaim(for: fileExtension) {
                sample = ""
            } else {
                throw ReaderError.invalidSource("\(relativePath): the file header could not be decoded with any accepted profile encoding.")
            }
            switch catalog.resolve(extension: fileExtension, headerSample: sample) {
            case .failed(let message):
                return SourceInspectionResult(source: source, inspection: nil, error: message)
            case .matched(let match):
                let facts = parseFilename(canonical.lastPathComponent)
                let inspection = SourceInspection(
                    source: relativePath, size: source.byteSize,
                    instrumentID: match.profile.instrumentID, instrumentName: match.profile.instrumentName,
                    applicationMode: match.mode.id, timestamp: facts.timestamp, deviceID: facts.deviceID, category: facts.category,
                    supportStatus: "supported",
                    validationState: "profile valid; source not loaded",
                    readerVersion: version, profileID: match.profile.instrumentID, profileHash: match.profile.sha256, error: nil
                )
                return SourceInspectionResult(source: source, inspection: inspection, error: nil)
            }
        } catch {
            return SourceInspectionResult(source: source, inspection: nil, error: error.localizedDescription)
        }
    }

    private static func decodeOptions(catalog: ProfileCatalog, extension fileExtension: String) -> [String.Encoding] {
        // Only encodings from formats that declare the source extension: no
        // undeclared fallback may rescue bytes the profile cannot read.
        var options: [String.Encoding] = []
        for profile in catalog.profiles {
            for format in profile.formats where format.extensions.contains(fileExtension) {
                for encoding in format.encodings where !options.contains(where: { $0 == encoding }) {
                    options.append(encoding)
                }
            }
        }
        return options
    }

    /// Picks the stream encoding from a bounded header prefix, trying only
    /// declared encodings in profile order. A UTF-8 prefix cut mid-scalar
    /// backs off to the scalar boundary instead of misdecoding.
    private static func selectEncoding(_ prefix: Data, catalog: ProfileCatalog, extension fileExtension: String) -> (encoding: String.Encoding, text: String, pending: Data)? {
        for encoding in decodeOptions(catalog: catalog, extension: fileExtension) {
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
        } else if let value = Double(TabularExtractor.decimalNumber(raw, decimal: decimal)) {
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
    var eof = false
    var finalFlushed = false
    var linesEmitted = 0
    // A trailing carriage return is held back: it may complete a CRLF pair
    // with the next chunk's first byte. (Swift treats "\r\n" as one grapheme
    // Character, so line splitting must run on normalized text.)
    var pendingCR = false

    mutating func stageText(_ text: String, final: Bool) {
        textBuffer += normalizeChunk(text)
        drainLines(final: final)
    }

    mutating func nextLine() throws -> String? {
        while true {
            if !readyLines.isEmpty {
                linesEmitted += 1
                var line = readyLines.removeFirst()
                if linesEmitted == 1, line.hasPrefix("\u{FEFF}") {
                    line = String(line.dropFirst())
                }
                return line
            }
            if eof {
                guard !finalFlushed else { return nil }
                finalFlushed = true
                if pendingCR {
                    pendingCR = false
                    textBuffer += "\r"
                }
                if !pendingBytes.isEmpty {
                    guard let tail = String(data: pendingBytes, encoding: encoding) else {
                        throw ReaderError.invalidSource("\(relativePath): could not decode the file using the selected encoding.")
                    }
                    pendingBytes = Data()
                    stageText(tail, final: true)
                } else {
                    drainLines(final: true)
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
        stageText(try decodeChunk(chunk), final: false)
    }

    private mutating func drainLines(final: Bool) {
        var parts = textBuffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        textBuffer = final ? "" : (parts.popLast() ?? "")
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
        puller.stageText(initialText, final: false)
        guard let namesPrefix = format.namesPrefix, let dataPrefix = format.dataPrefix else {
            throw ReaderError.invalidSource("\(relativePath): format \"\(format.id)\" has no row-block markers for kind \"\(format.kind)\".")
        }
        // Phase 1: header rows up to the names row.
        var headerLineTexts: [String] = []
        var headers: [String]? = nil
        var lineNumber = 0
        while let line = try puller.nextLine() {
            lineNumber += 1
            let fields = try split(line, delimiter: format.delimiter, context: "\(relativePath) line \(lineNumber)")
            if fields.first == namesPrefix { headers = fields; break }
            headerLineTexts.append(line)
        }
        guard let headers else {
            throw ReaderError.invalidSource("\(relativePath): no \"\(namesPrefix)\" header row was found.")
        }

        // Every format-declared channel resolves by exact primary header first,
        // aliases only as fallback. The ordered table keeps all of them; only
        // the mode's x/y channels drive the plot.
        var columns: [(ProfileColumn, Int)] = []
        for column in format.columns {
            let want = column.header ?? column.key
            let primary = headers.indices.filter {
                headers[$0].compare(want, options: .caseInsensitive) == .orderedSame
            }
            if primary.count > 1 {
                throw ReaderError.invalidSource("\(relativePath): header for column \"\(column.key)\" (\(want)) matches more than one cell in the \(namesPrefix) row [\(headers.joined(separator: ", "))].")
            }
            if let hit = primary.first {
                columns.append((column, hit))
                continue
            }
            let fallback = headers.indices.filter { index in
                column.aliases.contains { headers[index].compare($0, options: .caseInsensitive) == .orderedSame }
            }
            if fallback.count > 1 {
                throw ReaderError.invalidSource("\(relativePath): header for column \"\(column.key)\" (\(want)) matches more than one cell via aliases [\(column.aliases.joined(separator: ", "))] in the \(namesPrefix) row [\(headers.joined(separator: ", "))].")
            }
            guard let hit = fallback.first else {
                // An optional channel resolves when its header is present and
                // is skipped when absent: no values are invented for it, and
                // the required channels load unchanged.
                if !column.required { continue }
                throw ReaderError.invalidSource("\(relativePath): header for column \"\(column.key)\" (\(want)) was not found in the \(namesPrefix) row [\(headers.joined(separator: ", "))].")
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
        puller.stageText(initialText, final: false)
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
        while let line = try puller.nextLine() {
            lineNumber += 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
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
