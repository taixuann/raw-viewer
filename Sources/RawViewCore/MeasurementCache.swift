import CryptoKit
import Darwin
import Foundation

/// Bounded content-verified cache for deterministic inspection outcomes and
/// complete normalized measurements (Issues 6–7). Entries live in a private
/// app-local directory keyed by a digest of the canonical project root, so a
/// project-writable cache cannot inject plotted arrays. Raw paths and project
/// identifiers do not appear in cache directory names or keys; payloads do
/// include the normalized measurement, including its relative source path.
///
/// Layout: one directory per entry with binary-plist `meta` and `payload`
/// files. Writes are atomic (temp + rename); a torn or corrupted entry is an
/// ordinary miss that the next store rebuilds. Storage size is bounded by an
/// LRU over entry directories; oversized entries stay usable for the current
/// request but are not stored.
public struct MeasurementCache: Sendable {
    /// Cache schema version; bumping it invalidates every existing entry.
    static let schema = 2
    /// Default per-project disk budget (the app exposes Off/larger presets).
    public static let defaultLimitBytes: Int64 = 512 * 1024 * 1024
    /// Keep one decoded entry below a bounded memory ceiling even when the
    /// project-wide cache limit is configured higher.
    static let maximumEntryBytes: Int64 = 128 * 1024 * 1024
    private static let maximumMetadataBytes: Int64 = 64 * 1024

    public struct Usage: Sendable, Equatable {
        public let usedBytes: Int64
        public let entryCount: Int
        public let limitBytes: Int64
        public let root: String

        public init(usedBytes: Int64, entryCount: Int, limitBytes: Int64, root: String) {
            self.usedBytes = usedBytes
            self.entryCount = entryCount
            self.limitBytes = limitBytes
            self.root = root
        }
    }

    public enum RootResolution: Sendable, Equatable {
        /// Private app-owned directory keyed by a digest of the project root.
        case appLocal(path: String, basePath: String)
    }

    let rootResolution: RootResolution
    let limitBytes: Int64
    /// Serializes all cache-root operations across inspection/focused/overlay tasks.
    private let lock = NSLock()
    /// Shared by value copies of this cache so ordinary stores do not rescan
    /// the entire entry tree. Reconciled on `usage()` and after eviction.
    private let accounting = CacheAccounting()

    private final class CacheAccounting: @unchecked Sendable {
        var usedBytes: Int64?
    }

    public init(project: ProjectContext, limitBytes: Int64 = MeasurementCache.defaultLimitBytes) {
        self.limitBytes = max(1, limitBytes)
        self.rootResolution = MeasurementCache.resolveRoot(project: project)
    }

    init(project: ProjectContext, limitBytes: Int64, rootResolution: RootResolution) {
        self.limitBytes = max(1, limitBytes)
        self.rootResolution = rootResolution
    }

    // MARK: root resolution and containment

    /// Cache files never live in the selected project: collaborators who can
    /// write project files must not be able to forge arrays the viewer plots.
    public static func resolveRoot(project: ProjectContext) -> RootResolution {
        let location = appLocalLocation(project: project)
        return .appLocal(path: location.root.path, basePath: location.base.path)
    }

    /// App-local cache directory keyed only by a digest of the canonical
    /// project root path: the raw path itself never appears in the tree.
    /// Application Support first; a writable temp app-local directory second
    /// (Application Support can be unavailable in sandboxes).
    static func appLocalRoot(project: ProjectContext) -> URL {
        appLocalLocation(project: project).root
    }

    private static func appLocalLocation(project: ProjectContext) -> (root: URL, base: URL) {
        let canonicalRoot = project.root.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonicalRoot.utf8)).map { String(format: "%02x", $0) }.joined()
        func prepare(_ base: URL, components: [String]) -> URL? {
            let canonicalBase = URL(fileURLWithPath: SecureFile.kernelCanonical(base.standardizedFileURL.path), isDirectory: true)
            guard Self.isPrivateBase(canonicalBase) else { return nil }
            var appDir = canonicalBase
            for component in components {
                appDir.appendPathComponent(component, isDirectory: true)
                guard Self.makePrivateDirectory(appDir) else { return nil }
            }
            return appDir
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let prepared = prepare(support, components: ["RawView", "cache", "projects", digest, "rawview"]) {
            return (prepared, URL(fileURLWithPath: SecureFile.kernelCanonical(support.path), isDirectory: true))
        }
        let temporary = URL(fileURLWithPath: SecureFile.kernelCanonical(FileManager.default.temporaryDirectory.path), isDirectory: true)
        let components = ["RawViewCache", "RawView", "cache", "projects", digest, "rawview"]
        if let prepared = prepare(temporary, components: components) { return (prepared, temporary) }
        return (components.reduce(temporary) { $0.appendingPathComponent($1, isDirectory: true) }, temporary)
    }

    private static func isSymlink(at path: String) -> Bool {
        var stat = stat()
        guard lstat(path, &stat) == 0 else { return false }
        return (stat.st_mode & S_IFMT) == S_IFLNK
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isPrivateBase(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && (info.st_mode & 0o022) == 0
    }

    private static func makePrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { return false }
            if mkdir(url.path, 0o700) != 0 && errno != EEXIST { return false }
            guard lstat(url.path, &info) == 0 else { return false }
        }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && (info.st_mode & 0o022) == 0
            && lstat(url.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && (info.st_mode & 0o022) == 0
    }

    var rootPath: String {
        switch rootResolution {
        case .appLocal(let path, _): path
        }
    }

    /// Containment gate for every cache operation: the app-local namespace
    /// beneath its private base must be a chain of real, owner-only directories
    /// with no symlink swap. Failure becomes a miss/no-op, so no lookup,
    /// accounting, write, eviction, or clear can escape the verified root.
    private func namespaceIntact() -> Bool {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard case .appLocal(_, let basePath) = rootResolution else { return false }
        let base = URL(fileURLWithPath: basePath, isDirectory: true)
        guard Self.isPrivateBase(base), root.path.hasPrefix(base.path + "/") else { return false }
        var current = root
        while current.path != base.path {
            guard Self.isRealDirectory(current), !Self.isSymlink(at: current.path) else { return false }
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { return false }
            current.deleteLastPathComponent()
        }
        return true
    }

    // MARK: measurement payload codec (binary plist, full fidelity)

    /// Serializes the complete normalized measurement for storage. Binary
    /// property lists preserve every Double bit pattern exactly (packed IEEE-754
    /// via the Swift runtime's plist bridge) and every gap reason, metadata
    /// field, and provenance entry.
    static func encode(measurement: NormalizedMeasurement) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(MeasurementPayload(measurement: measurement))
    }

    static func decode(measurement data: Data) throws -> NormalizedMeasurement {
        let payload = try PropertyListDecoder().decode(MeasurementPayload.self, from: data)
        // Shape validation: a malformed payload is a corrupt cache entry (a
        // miss), never a reconstruction trap.
        guard let measurement = payload.measurement else {
            throw ContractError.invalid("Malformed cache payload: channel or metadata arrays are misshapen.")
        }
        return measurement
    }

    /// Property-list model of the full normalized payload. Everything is
    /// explicit: order, gaps, reasons, metadata, warnings, provenance.
    /// Internal (not private) so tests can exercise shape-malfunction misses.
    struct MeasurementPayload: Codable {
        var sourcePath: String
        var sourceSHA256: String
        var instrumentID: String
        var instrumentName: String
        var instrumentVendor: String?
        var instrumentModel: String?
        var applicationMode: String?
        var viewKind: String
        var viewX: String?
        var viewY: [String]?
        var viewPreserveOrder: Bool
        var channelNames: [String]
        var channelLabels: [String]
        var channelUnits: [String]
        var channelQuantities: [String]
        var channelHasQuantity: [Bool]
        var channelValueBits: [[String]]
        var channelGapReasons: [[String]]
        var sectionTitles: [String]
        var sectionFieldKeys: [[String]]
        var sectionFieldLabels: [[String]]
        /// Metadata field values flattened to their storage form: tagged
        /// arrays `[tag, payload]` where a string value is `["s", text]`,
        /// a number `["n", bits]` (exact Double bits), a boolean `["b", 0|1]`,
        /// and null `["z"]`. A plain plist String cannot hold JSONValue's
        /// four cases, so the tagged form is the codec.
        var sectionFieldValues: [[[String]]]
        var sectionFieldUnits: [[String]]
        var sectionFieldHasUnit: [[Bool]]
        var sectionFieldKinds: [[String]]
        var warnings: [String]
        var supportStatus: String
        var provenance: [String: String]

        init(measurement: NormalizedMeasurement) {
            sourcePath = measurement.source.path
            sourceSHA256 = measurement.source.sha256
            instrumentID = measurement.instrument.id
            instrumentName = measurement.instrument.name
            instrumentVendor = measurement.instrument.vendor
            instrumentModel = measurement.instrument.model
            applicationMode = measurement.applicationMode
            viewKind = measurement.view.kind
            viewX = measurement.view.x
            viewY = measurement.view.y
            viewPreserveOrder = measurement.view.preserveOrder
            channelNames = measurement.channels.map(\.name)
            channelLabels = measurement.channels.map(\.label)
            channelUnits = measurement.channels.map(\.unit)
            channelQuantities = measurement.channels.map { $0.quantity ?? "" }
            channelHasQuantity = measurement.channels.map { $0.quantity != nil }
            channelValueBits = measurement.channels.map { channel in
                channel.values.map { $0.map { String($0.bitPattern, radix: 16) } ?? "" }
            }
            channelGapReasons = measurement.channels.map { channel in
                channel.gapReasons.map { $0?.rawValue ?? "" }
            }
            sectionTitles = measurement.metadataSections.map(\.title)
            sectionFieldKeys = measurement.metadataSections.map { $0.fields.map(\.key) }
            sectionFieldLabels = measurement.metadataSections.map { $0.fields.map(\.label) }
            sectionFieldValues = measurement.metadataSections.map { $0.fields.map { MeasurementPayload.storage($0.value) } }
            sectionFieldUnits = measurement.metadataSections.map { $0.fields.map { $0.unit ?? "" } }
            sectionFieldHasUnit = measurement.metadataSections.map { $0.fields.map { $0.unit != nil } }
            sectionFieldKinds = measurement.metadataSections.map { $0.fields.map(\.kind) }
            warnings = measurement.warnings
            supportStatus = measurement.supportStatus
            provenance = measurement.provenance
        }

        static func storage(_ value: JSONValue) -> [String] {
            switch value {
            case .string(let text): return ["s", text]
            case .number(let number): return ["n", String(number.bitPattern)]
            case .boolean(let flag): return ["b", flag ? "1" : "0"]
            case .null: return ["z"]
            }
        }

        static func value(from storage: [String]) -> JSONValue? {
            guard let tag = storage.first else { return nil }
            switch tag {
            case "s":
                return storage.count > 1 ? .string(storage[1]) : nil
            case "n":
                guard storage.count > 1, let bits = UInt64(storage[1]) else { return nil }
                return .number(Double(bitPattern: bits))
            case "b":
                return storage.count > 1 ? .boolean(storage[1] == "1") : nil
            case "z":
                return .null
            default:
                return nil
            }
        }

        var measurement: NormalizedMeasurement? {
            // Shape validation before any indexing/zip reconstruction: a
            // malformed payload (corrupt but checksummed cache, or a foreign
            // writer) is a miss, never a trap.
            let channelsAligned = channelNames.count == channelLabels.count
                && channelLabels.count == channelUnits.count
                && channelUnits.count == channelQuantities.count
                && channelQuantities.count == channelHasQuantity.count
                && channelHasQuantity.count == channelValueBits.count
                && channelValueBits.count == channelGapReasons.count
            let sectionsAligned = sectionTitles.count == sectionFieldKeys.count
                && sectionFieldKeys.count == sectionFieldLabels.count
                && sectionFieldLabels.count == sectionFieldValues.count
                && sectionFieldValues.count == sectionFieldUnits.count
                && sectionFieldUnits.count == sectionFieldHasUnit.count
                && sectionFieldHasUnit.count == sectionFieldKinds.count
            guard channelsAligned, sectionsAligned else { return nil }
            var channels: [MeasurementChannel] = []
            channels.reserveCapacity(channelNames.count)
            for index in channelNames.indices {
                let bits = channelValueBits[index]
                let reasons = channelGapReasons[index]
                guard bits.count == reasons.count else { return nil }
                var values: [Double?] = []
                var gapReasons: [GapReason?] = []
                values.reserveCapacity(bits.count)
                gapReasons.reserveCapacity(bits.count)
                for sample in bits.indices {
                    if bits[sample].isEmpty {
                        values.append(nil)
                    } else if let value = UInt64(bits[sample], radix: 16) {
                        values.append(Double(bitPattern: value))
                    } else {
                        return nil
                    }
                    if reasons[sample].isEmpty {
                        gapReasons.append(nil)
                    } else if let reason = GapReason(rawValue: reasons[sample]) {
                        gapReasons.append(reason)
                    } else {
                        return nil
                    }
                }
                let quantity = channelHasQuantity[index] ? channelQuantities[index] : nil
                channels.append(MeasurementChannel(name: channelNames[index], label: channelLabels[index],
                                                   unit: channelUnits[index], quantity: quantity,
                                                   values: values, gapReasons: gapReasons))
            }
            var sections: [MetadataSection] = []
            sections.reserveCapacity(sectionTitles.count)
            for index in sectionTitles.indices {
                let keys = sectionFieldKeys[index]
                let labels = sectionFieldLabels[index]
                let values = sectionFieldValues[index]
                let units = sectionFieldUnits[index]
                let hasUnits = sectionFieldHasUnit[index]
                let kinds = sectionFieldKinds[index]
                guard keys.count == labels.count, labels.count == values.count,
                      values.count == units.count, units.count == hasUnits.count,
                      hasUnits.count == kinds.count else { return nil }
                var fields: [MetadataField] = []
                for fieldIndex in keys.indices {
                    guard let value = MeasurementPayload.value(from: values[fieldIndex]) else { return nil }
                    fields.append(MetadataField(key: keys[fieldIndex], label: labels[fieldIndex],
                                                value: value, unit: hasUnits[fieldIndex] ? units[fieldIndex] : nil,
                                                kind: kinds[fieldIndex]))
                }
                sections.append(MetadataSection(title: sectionTitles[index], fields: fields))
            }
            return NormalizedMeasurement(
                source: SourceIdentity(path: sourcePath, sha256: sourceSHA256),
                instrument: InstrumentIdentity(id: instrumentID, name: instrumentName, vendor: instrumentVendor, model: instrumentModel),
                applicationMode: applicationMode,
                view: MeasurementView(kind: viewKind, x: viewX, y: viewY, preserveOrder: viewPreserveOrder),
                channels: channels, metadataSections: sections, warnings: warnings,
                supportStatus: supportStatus, provenance: provenance
            )
        }
    }

    // MARK: identity keys

    struct EntryIdentity: Sendable {
        let key: String
    }

    /// Inspection identity: project-relative source identity, lowercase
    /// extension, descriptor size (already secured), the SHA-256 of the exact
    /// bounded 64 KiB prefix read from the no-follow handle, the complete
    /// profile-catalog fingerprint, reader version, and cache schema.
    static func inspectionIdentity(source: RawSource, prefixSHA256: String, catalogFingerprint: String) -> EntryIdentity {
        let extensionPart = source.url.pathExtension.lowercased()
        let text = "inspection|\(schema)|\(source.relativePath)|\(extensionPart)|\(source.byteSize)|\(prefixSHA256)|\(catalogFingerprint)|\(InstrumentReader.version)"
        return EntryIdentity(key: sha256Hex(Data(text.utf8)))
    }

    /// Measurement identity: hashed project-relative identity plus the exact
    /// bounded prefix digest, descriptor size, resolved profile/catalog
    /// fingerprint, reader version, and schema. The candidate key must be
    /// content-derived (size + prefix), so a same-size/same-mtime header edit
    /// never even finds an entry; the full-content digest recorded in the
    /// entry is verified separately before decode.
    static func measurementIdentity(source: RawSource, prefixSHA256: String, catalogFingerprint: String) -> EntryIdentity {
        let extensionPart = source.url.pathExtension.lowercased()
        let text = "measurement|\(schema)|\(source.relativePath)|\(extensionPart)|\(source.byteSize)|\(prefixSHA256)|\(catalogFingerprint)|\(InstrumentReader.version)"
        return EntryIdentity(key: sha256Hex(Data(text.utf8)))
    }

    // MARK: secured source access (shared by lookup and verification)

    /// No-follow open beneath `data/raw` plus the exact bounded prefix read.
    /// Reused by every cache path so identity and verification can never
    /// diverge from what the reader itself opens.
    static func openSecuredPrefix(source: RawSource, project: ProjectContext) throws -> (handle: FileHandle, prefix: Data) {
        let canonical = source.url.resolvingSymlinksInPath().standardizedFileURL
        let handle = try SecureFile.openVerified(resolvedPath: canonical.path, beneath: project.rawRoot.path)
        let prefix = try handle.read(upToCount: InstrumentReader.headerSampleBytes) ?? Data()
        return (handle, prefix)
    }

    // MARK: inspection cache

    /// Codable cache payload for one deterministic inspection outcome: either
    /// a supported inspection or the deterministic diagnostic (the exact
    /// reader diagnostic for profile/header/mode resolution failures).
    /// Typed cacheability — no message heuristics: only an outcome produced
    /// after the contained no-follow open and exact-prefix read may reach the
    /// cache, and access/open/read/cancellation failures throw instead.
    public enum CachedInspection: Codable, Sendable, Equatable {
        case supported(SourceInspection)
        case blocked(String)
    }

    /// Deterministic inspection cache. The caller supplies a typed producer
    /// that throws for cancellation and transient filesystem/security/open/
    /// read failures (never cached) and returns a `CachedInspection` for
    /// deterministic outcomes after the contained open and exact-prefix read.
    /// The seam performs the mandatory secured open + exact-prefix hash + size
    /// check first (identity), consults the entry, and only falls back to the
    /// producer on a miss.
    public func inspection(
        for source: RawSource,
        project: ProjectContext,
        catalogFingerprint: String,
        producer: @Sendable () async throws -> CachedInspection
    ) async throws -> (outcome: CachedInspection, fromCache: Bool) {
        // Excluded suffixes never reach any source access or cache key.
        guard !ProjectContext.skippedRawExtensions.contains(source.url.pathExtension.lowercased()) else {
            let outcome = try await producer()
            return (outcome, false)
        }
        guard let secured = try? MeasurementCache.openSecuredPrefix(source: source, project: project) else {
            // Unreadable/missing/symlinked/escaped source: the producer decides
            // (and throws for non-deterministic access failures); nothing is cached.
            let outcome = try await producer()
            return (outcome, false)
        }
        let size: Int64
        // stat the pinned descriptor instead of seekToEnd: seekToEnd would move
        // the read offset and truncate any subsequent stream reusing the handle.
        var fileStat = stat()
        if fstat(secured.handle.fileDescriptor, &fileStat) == 0 {
            size = Int64(fileStat.st_size)
        } else {
            size = source.byteSize
        }
        // The handle is not needed across the entry read and producer await:
        // close it now.
        try? secured.handle.close()
        let prefixDigest = sha256Hex(secured.prefix)
        let identity = MeasurementCache.inspectionIdentity(source: RawSource(relativePath: source.relativePath, url: source.url, byteSize: size), prefixSHA256: prefixDigest, catalogFingerprint: catalogFingerprint)
        if let (payload, _) = try? readEntry(key: identity.key, kind: "inspection"),
           let cached = try? PropertyListDecoder().decode(CachedInspection.self, from: payload) {
                        touch(key: identity.key)
            return (cached, true)
            // Corrupt entry falls through to the producer and is rebuilt.
        }
                let outcome = try await producer()
        // Check task cancellation immediately before store: cancelled tasks
        // must never create an entry.
        guard !Task.isCancelled else { return (outcome, false) }
                storeEntry(key: identity.key, kind: "inspection", payload: try PropertyListEncoder().encode(outcome),
                   fullSHA256: nil, sourceSize: size)
        return (outcome, false)
    }

    // MARK: measurement cache

    /// Candidate lookup by hashed identity + profile fingerprint, then full
    /// verification: a fresh full-content SHA-256 from the secured source must
    /// equal the digest recorded in the entry before decode. Size and mtime
    /// are never content proof.
    public func measurement(for source: RawSource, project: ProjectContext, profileFingerprint: String) throws -> NormalizedMeasurement? {
        guard !ProjectContext.skippedRawExtensions.contains(source.url.pathExtension.lowercased()) else { return nil }
        // Identity needs the secured descriptor: no-follow open under data/raw,
        // exact bounded prefix, descriptor size.
        let canonical = source.url.resolvingSymlinksInPath().standardizedFileURL
        let prefix: Data
        let size: Int64
        do {
            let handle = try SecureFile.openVerified(resolvedPath: canonical.path, beneath: project.rawRoot.path)
            prefix = try handle.read(upToCount: InstrumentReader.headerSampleBytes) ?? Data()
            var fileStat = stat()
            if fstat(handle.fileDescriptor, &fileStat) == 0 {
                size = Int64(fileStat.st_size)
            } else {
                size = source.byteSize
            }
            try? handle.close()
        } catch {
            return nil
        }
        let probe = RawSource(relativePath: source.relativePath, url: source.url, byteSize: size)
        let identity = MeasurementCache.measurementIdentity(source: probe, prefixSHA256: sha256Hex(prefix), catalogFingerprint: profileFingerprint)
        guard let (payload, meta) = try? readEntry(key: identity.key, kind: "measurement"),
              let recorded = meta?["full_sha256"] as? String else { return nil }
        // Full-content verification before decode/use: a fresh digest of the
        // whole source must equal the digest recorded in the entry.
        let freshDigest: String?
        do {
            let handle = try SecureFile.openVerified(resolvedPath: canonical.path, beneath: project.rawRoot.path)
            defer { try? handle.close() }
            let freshPrefix = try handle.read(upToCount: InstrumentReader.headerSampleBytes) ?? Data()
            freshDigest = try MeasurementCache.fullDigest(handle: handle, prefix: freshPrefix)
        } catch {
            return nil
        }
        guard let freshDigest, freshDigest == recorded else { return nil }
        touch(key: identity.key)
        return try? MeasurementCache.decode(measurement: payload)
    }

    /// Full-content digest over exactly the source bytes. `prefix` holds the
    /// first `headerSampleBytes` read from the secured handle; the digest
    /// feeds those bytes and then the remainder of the same handle (its read
    /// offset already sits after the prefix), so every byte is hashed once.
    static func fullDigest(handle: FileHandle, prefix: Data) throws -> String {
        var hasher = SHA256()
        hasher.update(data: prefix)
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stores a successful measurement. The entry's identity is derived from
    /// the source descriptor (size + exact prefix digest) exactly like the
    /// lookup path; the recorded full-content digest is the measurement's own
    /// `source.sha256` (the reader hashes exactly the bytes it parsed).
    public func store(measurement: NormalizedMeasurement, profileFingerprint: String, source: RawSource, prefixSHA256: String) throws {
        guard !ProjectContext.skippedRawExtensions.contains(source.url.pathExtension.lowercased()) else { return }
        let identity = MeasurementCache.measurementIdentity(source: source, prefixSHA256: prefixSHA256, catalogFingerprint: profileFingerprint)
        storeEntry(key: identity.key, kind: "measurement", payload: try MeasurementCache.encode(measurement: measurement),
                   fullSHA256: measurement.source.sha256, sourceSize: source.byteSize)
    }

    // MARK: entry storage (checksummed, atomic, size-bounded, LRU)

    private struct EntryMeta: Codable {
        var kind: String
        var schema: Int
        var payloadSHA256: String
        var payloadBytes: Int
        var fullSHA256: String?
        var sourceSize: Int64
        var storedAt: Date
    }

    private func entryDirectory(key: String) -> URL {
        // Two-level fan-out keeps any single directory small on huge inventories.
        let prefix = String(key.prefix(2))
        return URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    func storeEntry(key: String, kind: String, payload: Data, fullSHA256: String?, sourceSize: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard payload.count <= Self.maximumEntryBytes, namespaceIntact() else { accounting.usedBytes = nil; return }
        let directory = entryDirectory(key: key)
        let fm = FileManager.default
        // Neither the level-1 prefix directory nor the entry directory may be
        // a symlink: nothing is ever written through a link out of the root.
        let prefixURL = directory.deletingLastPathComponent()
        if Self.isSymlink(at: prefixURL.path) || Self.isSymlink(at: directory.path) { return }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return }
        let payloadURL = directory.appendingPathComponent("payload")
        let metaURL = directory.appendingPathComponent("meta")
        let oldSize = directorySize(directory)
        // A destination that has been swapped to a symlink is never replaced.
        if Self.isSymlink(at: payloadURL.path) || Self.isSymlink(at: metaURL.path) { return }
        let payloadDigest = sha256Hex(payload)
        let meta = EntryMeta(kind: kind, schema: MeasurementCache.schema, payloadSHA256: payloadDigest,
                             payloadBytes: payload.count,
                             fullSHA256: fullSHA256, sourceSize: sourceSize, storedAt: Date())
        guard let metaData = try? PropertyListEncoder().encode(meta) else { return }
        let total = Int64(payload.count + metaData.count)
        guard total <= limitBytes, total <= Self.maximumEntryBytes else { return } // oversized: not stored
        // Atomic replace: temp files inside the entry directory, then rename.
        let payloadTemp = directory.appendingPathComponent("payload.tmp-\(UUID().uuidString)")
        let metaTemp = directory.appendingPathComponent("meta.tmp-\(UUID().uuidString)")
        guard (try? payload.write(to: payloadTemp, options: .atomic)) != nil else { return }
        guard (try? metaData.write(to: metaTemp, options: .atomic)) != nil else {
            try? fm.removeItem(at: payloadTemp)
            return
        }
        do {
            try Self.replaceOrMove(payloadTemp, at: payloadURL)
            try Self.replaceOrMove(metaTemp, at: metaURL)
        } catch {
            try? fm.removeItem(at: payloadTemp)
            try? fm.removeItem(at: metaTemp)
            accounting.usedBytes = nil
            return
        }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
        if let used = accounting.usedBytes {
            accounting.usedBytes = max(0, used - oldSize + total)
        } else {
            accounting.usedBytes = cacheSize()
        }
        if let used = accounting.usedBytes, used > limitBytes {
            accounting.usedBytes = evictToFit(limit: limitBytes)
        }
    }

    private static func replaceOrMove(_ temporary: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard !Self.isSymlink(at: directory.path),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return files.reduce(Int64(0)) { total, file in
            let path = directory.appendingPathComponent(file).path
            guard !Self.isSymlink(at: path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let bytes = attributes[.size] as? NSNumber else { return total }
            return total + bytes.int64Value
        }
    }

    /// Computes the current on-disk size once per cache instance, then the
    /// write path maintains it in constant time until eviction is needed.
    private func cacheSize() -> Int64 {
        guard let prefixes = try? FileManager.default.contentsOfDirectory(atPath: rootPath) else { return 0 }
        return prefixes.reduce(Int64(0)) { total, prefix in
            let url = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(prefix)
            guard !Self.isSymlink(at: url.path),
                  let keys = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return total }
            return total + keys.reduce(Int64(0)) { subtotal, key in
                let entry = url.appendingPathComponent(key, isDirectory: true)
                guard !Self.isSymlink(at: entry.path), Self.isRealDirectory(entry) else { return subtotal }
                return subtotal + directorySize(entry)
            }
        }
    }

    /// Reads a regular, non-symlink file only after its opened descriptor size
    /// is checked. The descriptor pins the object across the bounded read.
    static func readBoundedFile(_ url: URL, maximumBytes: Int64) -> Data? {
        guard maximumBytes >= 0 else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= maximumBytes,
              info.st_size <= Int64(Int.max) else { return nil }
        let expected = Int(info.st_size)
        var data = Data()
        data.reserveCapacity(expected)
        while data.count < expected {
            let amount = min(64 * 1024, expected - data.count)
            guard let chunk = try? handle.read(upToCount: amount), !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        // Reject a file that grew after fstat rather than accepting a prefix.
        do {
            let extra = try handle.read(upToCount: 1)
            guard extra?.isEmpty != false else { return nil }
        } catch { return nil }
        return data
    }

    /// Returns the payload and meta when the entry is intact: both files
    /// present, payload digest matches the recorded checksum, schema current.
    func readEntry(key: String, kind: String) throws -> (payload: Data, meta: [String: Any]?) {
        lock.lock()
        defer { lock.unlock() }
        guard namespaceIntact() else { return (Data(), nil) }
        let directory = entryDirectory(key: key)
        let prefixURL = directory.deletingLastPathComponent()
        guard !Self.isSymlink(at: prefixURL.path), !Self.isSymlink(at: directory.path) else { return (Data(), nil) }
        let payloadURL = directory.appendingPathComponent("payload")
        let metaURL = directory.appendingPathComponent("meta")
        guard !Self.isSymlink(at: payloadURL.path), !Self.isSymlink(at: metaURL.path) else { return (Data(), nil) }
        guard let metaData = Self.readBoundedFile(metaURL, maximumBytes: Self.maximumMetadataBytes),
              let meta = try? PropertyListDecoder().decode(EntryMeta.self, from: metaData) else {
            return (Data(), nil)
        }
        guard meta.kind == kind, meta.schema == MeasurementCache.schema,
              meta.payloadBytes >= 0,
              Int64(meta.payloadBytes) <= Self.maximumEntryBytes,
              Int64(meta.payloadBytes) <= limitBytes,
              let payload = Self.readBoundedFile(payloadURL, maximumBytes: Int64(meta.payloadBytes)),
              meta.payloadSHA256 == sha256Hex(payload), meta.payloadBytes == payload.count else {
            return (Data(), nil) // torn, corrupt, or foreign entry: a miss
        }
        return (payload, ["full_sha256": meta.fullSHA256 as Any])
    }

    private func touch(key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard namespaceIntact(), !Self.isSymlink(at: entryDirectory(key: key).path) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: entryDirectory(key: key).path)
    }

    /// LRU eviction over entry directories ordered by modification date,
    /// contained to the cache root; never touches `data/raw` or profiles.
    /// Full-tree size work happens only when the configured limit is crossed.
    private func evictToFit(limit: Int64) -> Int64? {
        let fm = FileManager.default
        guard namespaceIntact() else { return nil }
        guard let levelOne = try? fm.contentsOfDirectory(atPath: rootPath) else { return nil }
        var entries: [(path: String, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for prefix in levelOne {
            let prefixURL = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(prefix)
            guard !Self.isSymlink(at: prefixURL.path),
                  let keys = try? fm.contentsOfDirectory(atPath: prefixURL.path) else { continue }
            for key in keys {
                let entry = prefixURL.appendingPathComponent(key)
                guard !Self.isSymlink(at: entry.path), Self.isRealDirectory(entry) else { continue }
                guard let attributes = try? fm.attributesOfItem(atPath: entry.path),
                      attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
                let size = directorySize(entry)
                let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
                entries.append((entry.path, size, modified))
                total += size
            }
        }
        guard total > limit else { return total }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard total > limit else { break }
            do {
                try fm.removeItem(atPath: entry.path)
                total = max(0, total - entry.size)
            } catch {
                // A failed delete cannot be counted as freed space.
            }
        }
        return total <= limit ? total : nil
    }

    // MARK: usage and clear

    public func usage() throws -> Usage {
        lock.lock()
        defer { lock.unlock() }
        guard namespaceIntact() else {
            accounting.usedBytes = nil
            return Usage(usedBytes: 0, entryCount: 0, limitBytes: limitBytes, root: rootPath)
        }
        let fm = FileManager.default
        var used: Int64 = 0
        var count = 0
        if let levelOne = try? fm.contentsOfDirectory(atPath: rootPath) {
            for prefix in levelOne {
                let prefixURL = URL(fileURLWithPath: rootPath, isDirectory: true)
                    .appendingPathComponent(prefix)
                guard !Self.isSymlink(at: prefixURL.path),
                      let keys = try? fm.contentsOfDirectory(atPath: prefixURL.path) else { continue }
                for key in keys {
                    let entry = prefixURL.appendingPathComponent(key)
                    guard !Self.isSymlink(at: entry.path), Self.isRealDirectory(entry) else { continue }
                    guard let attributes = try? fm.attributesOfItem(atPath: entry.path),
                          attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
                    count += 1
                    if let files = try? fm.contentsOfDirectory(atPath: entry.path) {
                        for file in files {
                            let fileURL = entry.appendingPathComponent(file)
                            if !Self.isSymlink(at: fileURL.path),
                               let fileAttributes = try? fm.attributesOfItem(atPath: fileURL.path),
                               let bytes = fileAttributes[.size] as? NSNumber {
                                used += bytes.int64Value
                            }
                        }
                    }
                }
            }
        }
        accounting.usedBytes = used
        return Usage(usedBytes: used, entryCount: count, limitBytes: limitBytes, root: rootPath)
    }

    /// Removes only contained cache entry files. `data/raw` and profile YAMLs
    /// are never touched. Stray temp files from interrupted atomic writes are
    /// removed as well.
    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        guard namespaceIntact() else { accounting.usedBytes = nil; return }
        let fm = FileManager.default
        guard let levelOne = try? fm.contentsOfDirectory(atPath: rootPath) else {
            accounting.usedBytes = nil
            return
        }
        for prefix in levelOne {
            let prefixURL = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(prefix)
            guard !Self.isSymlink(at: prefixURL.path),
                  let keys = try? fm.contentsOfDirectory(atPath: prefixURL.path) else { continue }
            for key in keys {
                let entry = prefixURL.appendingPathComponent(key)
                guard !Self.isSymlink(at: entry.path) else { continue }
                guard let attributes = try? fm.attributesOfItem(atPath: entry.path) else { continue }
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    // A leftover .tmp-… remnant from an interrupted atomic write.
                    try? fm.removeItem(atPath: entry.path)
                    continue
                }
                try? fm.removeItem(atPath: entry.path)
            }
        }
        accounting.usedBytes = 0
    }
}
