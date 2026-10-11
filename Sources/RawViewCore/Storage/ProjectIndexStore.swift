import Foundation

/// Namespace identity of a project index database: `(schema version, project
/// identity, data root, reader version, catalog fingerprint)`. Stored rows
/// whose namespace differs from the active one are rebuilt, never restored.
public struct IndexNamespace: Sendable, Equatable {
    public let schemaVersion: Int
    public let projectIdentity: String
    public let dataRoot: String
    public let readerVersion: String
    public let catalogFingerprint: String

    public init(
        schemaVersion: Int,
        projectIdentity: String,
        dataRoot: String,
        readerVersion: String,
        catalogFingerprint: String
    ) {
        self.schemaVersion = schemaVersion
        self.projectIdentity = projectIdentity
        self.dataRoot = dataRoot
        self.readerVersion = readerVersion
        self.catalogFingerprint = catalogFingerprint
    }
}

/// Explicit advisory state persisted per index record. Every project-controlled
/// or migrated row is a hint: none of them ever carries scientific authority.
public enum IndexRecordState: String, Sendable, Codable, Equatable {
    case advisoryHint = "advisory_hint"
}

/// Trust decision for a stored record. There is deliberately no `trusted`
/// case: matching digest/catalog metadata proves freshness, never authorship
/// of an inspection result, so a row can at best be an unverified hint.
public enum IndexHintDisposition: String, Sendable, Equatable {
    /// Stored namespace differs from the active one: rebuild, never restore.
    case staleNamespace
    /// Secured prefix digest or descriptor size differs: content is not fresh.
    case staleContent
    /// Content matches but the row stays an unverified hint.
    case advisoryHint

    /// Fail-closed contract: no stored row grants successful `SourceInspection`
    /// authority. Consumers must recompute the inspection outcome from the
    /// secured prefix (or the private inspection cache) instead.
    public var grantsInspectionAuthority: Bool { false }
}

/// Storage resolution for a project index: where the store would read and
/// write, plus what exists right now. Reported as facts only — resolving or
/// asking for usage never creates a file, directory, or database.
public struct IndexUsage: Sendable, Equatable {
    public enum StorageMode: String, Sendable, Equatable, Codable {
        /// Project-local `.rawviewer/index.db` (existing or preferred).
        case destination
        /// Legacy `data/.rawview/index.db` still holds the index.
        case legacy
        /// Read-only project: owner-private app-local index location.
        case privateFallback
        /// Nothing exists and nothing can be created from here.
        case none
    }

    public let storageMode: StorageMode
    public let destinationURL: URL
    public let legacyURL: URL
    public let destinationExists: Bool
    public let legacyExists: Bool
    public let stagingExists: Bool
    public let projectWritable: Bool
}

/// Result of a migration attempt. Reports storage mode, warnings, and counts
/// only — never raw row values.
public struct IndexMigrationReport: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        /// An already-existing destination wins; both databases are preserved.
        case destinationExists
        /// No usable legacy index (absent or not readable SQLite); retained as is.
        case legacyUnavailable
        /// Valid legacy source, but the SQLite VFS proof gate failed, so no
        /// project-local destination write is performed pending a decision.
        case withheldPendingStorageDecision
    }

    public let outcome: Outcome
    public let storageMode: IndexUsage.StorageMode
    public let copiedRows: Int
    public let warnings: [String]
}

/// OS-managed advisory lock held for exactly one bounded writer/migration job.
/// The lock file's existence is never a mutex: only the kernel lock counts,
/// and the kernel releases it when the holder exits or crashes.
struct IndexWriterLease: Sendable {
    let fd: Int32

    static func acquire(path: String) throws -> IndexWriterLease {
        // O_NOFOLLOW: a lease file is RawView-owned private state; if anything
        // replaced it with a link, refuse instead of locking through it.
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw ProjectIndexStore.StoreError.storage(detail: "cannot open writer lease at \(path)")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw ProjectIndexStore.StoreError.busy
        }
        return IndexWriterLease(fd: fd)
    }

    func release() {
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}

/// Per-project coordinator for the project index: resolves storage, owns the
/// job-scoped writer lease, reports usage, and performs (or withholds)
/// legacy migration. Store open only resolves state — it creates nothing, and
/// an idle GUI or a read never holds the writer lease.
public actor ProjectIndexStore {
    public enum StoreError: Error, Equatable {
        /// Another writer job (this process or another one) holds the lease.
        case busy
        /// A symlinked metadata namespace or destination leaf: security refusal.
        case unsafeNamespace(path: String)
        /// Lease/storage access failure that is not writer contention.
        case storage(detail: String)
    }

    /// Preferred destination, resolved by the store only (never by callers).
    public static let destinationRelativePath = ".rawviewer/index.db"
    /// Advisory writer-lease file, kept in private app-local state so it is
    /// keyed to the canonical project even for read-only projects.
    public static let writerLeaseFileName = "index-writer.lock"
    /// Prefix of sibling staging databases used during a future migration.
    public static let migrationStagingPrefix = "index.db.staging"

    public let project: ProjectContext
    /// Active namespace for this open store: resolved at open, so a data-root,
    /// reader, catalog, or schema change produces a different namespace.
    public let activeNamespace: IndexNamespace

    private init(project: ProjectContext, catalogFingerprint: String) {
        self.project = project
        self.activeNamespace = Self.makeNamespace(project: project, catalogFingerprint: catalogFingerprint)
    }

    /// Resolves store state for a project without creating anything: no
    /// directory, no file, no database, no lease. The first writer job
    /// acquires the lease and checks migration before any destination write.
    /// A symlinked metadata namespace or destination leaf fails closed.
    public static func open(
        project: ProjectContext,
        catalogFingerprint: String = ""
    ) async throws -> ProjectIndexStore {
        let components = destinationRelativePath.split(separator: "/").map(String.init)
        if let offender = SecureFile.firstSymlinkedComponent(components, beneath: project.root.path) {
            throw StoreError.unsafeNamespace(path: offender)
        }
        // The default fingerprint is the live catalog: a catalog change must
        // produce a different active namespace, so stored rows stop being
        // restorable until a coordinator run re-validates them.
        let fingerprint = catalogFingerprint.isEmpty
            ? ProfileCatalog.load(project: project).fingerprint
            : catalogFingerprint
        return ProjectIndexStore(project: project, catalogFingerprint: fingerprint)
    }

    /// Namespace factory: the identity tuple persisted in `index_metadata`.
    public static func makeNamespace(
        project: ProjectContext,
        catalogFingerprint: String
    ) -> IndexNamespace {
        let canonicalRoot = project.root.resolvingSymlinksInPath().standardizedFileURL.path
        return IndexNamespace(
            schemaVersion: IndexDatabase.namespaceSchemaVersion,
            projectIdentity: sha256Hex(Data(canonicalRoot.utf8)),
            dataRoot: project.dataRootRelativePath,
            readerVersion: InstrumentReader.version,
            catalogFingerprint: catalogFingerprint)
    }

    public static func preferredDestinationURL(project: ProjectContext) -> URL {
        project.root.appendingPathComponent(destinationRelativePath)
    }

    public static func legacyIndexURL(project: ProjectContext) -> URL {
        project.root.appendingPathComponent("data/.rawview/index.db")
    }

    /// Lease location in private app-local state (never inside the project,
    /// so read-only roots can still run bounded writer jobs).
    public static func writerLeaseURL(project: ProjectContext) -> URL {
        MeasurementCache.appLocalRoot(project: project)
            .appendingPathComponent(writerLeaseFileName)
    }

    /// Trust decision for a stored record against the active namespace and
    /// the content observed through the secured bounded-prefix read. No
    /// return value of this function authorizes an inspection.
    public static func disposition(
        record: IndexDatabase.Record,
        storedNamespace: IndexNamespace,
        activeNamespace: IndexNamespace,
        observedPrefixSHA256: String,
        observedDescriptorSize: Int64
    ) -> IndexHintDisposition {
        guard storedNamespace == activeNamespace else { return .staleNamespace }
        guard let storedDigest = record.prefixSHA256,
              let storedSize = record.descriptorSize,
              storedDigest == observedPrefixSHA256,
              storedSize == observedDescriptorSize else {
            return .staleContent
        }
        return .advisoryHint
    }

    public nonisolated func disposition(
        record: IndexDatabase.Record,
        storedNamespace: IndexNamespace,
        observedPrefixSHA256: String,
        observedDescriptorSize: Int64
    ) -> IndexHintDisposition {
        Self.disposition(
            record: record, storedNamespace: storedNamespace, activeNamespace: activeNamespace,
            observedPrefixSHA256: observedPrefixSHA256,
            observedDescriptorSize: observedDescriptorSize)
    }

    /// Resolves storage and reports what exists. Read-only with respect to
    /// the project: safe to call during UI state evaluation.
    public func usage() async throws -> IndexUsage {
        let projectWritable = FileManager.default.isWritableFile(atPath: project.root.path)
        let destination: URL
        if !projectWritable {
            destination = MeasurementCache.appLocalRoot(project: project).appendingPathComponent("index.db")
        } else {
            destination = Self.preferredDestinationURL(project: project)
        }
        let destinationExists = FileManager.default.fileExists(atPath: destination.path)
        let legacyURL = Self.legacyIndexURL(project: project)
        let legacyExists = FileManager.default.fileExists(atPath: legacyURL.path)
        let destinationDirectory = destination.deletingLastPathComponent()
        var stagingExists = false
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path) {
            stagingExists = entries.contains { $0.hasPrefix(Self.migrationStagingPrefix) }
        }
        let storageMode: IndexUsage.StorageMode
        if destinationExists {
            storageMode = .destination
        } else if !projectWritable {
            storageMode = .privateFallback
        } else if legacyExists {
            storageMode = .legacy
        } else {
            storageMode = .destination
        }
        return IndexUsage(
            storageMode: storageMode,
            destinationURL: destination,
            legacyURL: legacyURL,
            destinationExists: destinationExists,
            legacyExists: legacyExists,
            stagingExists: stagingExists,
            projectWritable: projectWritable)
    }

    /// Runs one bounded migration attempt under the OS writer lease. Never
    /// deletes or mutates legacy db/WAL/SHM, never overwrites an existing
    /// destination, and never stages a partial destination state.
    public func migrateLegacy() async throws -> IndexMigrationReport {
        try await withWriterJob {
            let usage = try await self.usage()
            if usage.destinationExists {
                return IndexMigrationReport(
                    outcome: .destinationExists,
                    storageMode: usage.storageMode,
                    copiedRows: 0,
                    warnings: ["An index destination already exists; it is preserved and the legacy index is retained."])
            }
            guard usage.legacyExists else {
                return IndexMigrationReport(
                    outcome: .legacyUnavailable,
                    storageMode: usage.storageMode,
                    copiedRows: 0,
                    warnings: ["No legacy index database was found; nothing to migrate."])
            }
            guard Self.legacyLooksLikeSQLite(usage.legacyURL) else {
                return IndexMigrationReport(
                    outcome: .legacyUnavailable,
                    storageMode: usage.storageMode,
                    copiedRows: 0,
                    warnings: ["Legacy index database is not readable SQLite; it is retained untouched."])
            }
            // SQLite filesystem proof gate: descriptor-relative/no-follow VFS
            // handling for db/WAL/SHM was tested and FAILED for the approved
            // project-local destination (ancestor-swap TOCTOU escape), so the
            // write half of migration is withheld rather than silently
            // weakened or moved. Decision owner: Tai.
            return IndexMigrationReport(
                outcome: .withheldPendingStorageDecision,
                storageMode: usage.storageMode,
                copiedRows: 0,
                warnings: ["Project-local SQLite VFS proof gate did not pass; migration publication to .rawviewer/index.db is withheld pending a storage decision. Legacy db/WAL/SHM are preserved."])
        }
    }

    private var isLeaseHeld = false

    /// Scope of exactly one bounded writer/migration job: acquire the OS
    /// advisory lock, run, release. A second writer (nested, concurrent, or
    /// from another process) gets `StoreError.busy` instead of racing.
    /// Reads (`usage()`) never acquire this lease.
    public func withWriterJob<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let leaseURL = Self.writerLeaseURL(project: project)
        let leaseDir = leaseURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: leaseDir.path) {
            try? FileManager.default.createDirectory(at: leaseDir, withIntermediateDirectories: true)
        }
        let lease = try IndexWriterLease.acquire(path: leaseURL.path)
        defer { lease.release() }
        isLeaseHeld = true
        defer { isLeaseHeld = false }
        return try await body()
    }

    /// Recomputes and validates the stored inspection against the active
    /// namespace, pinned prefix bytes, and current catalog. No SQLite row
    /// ever authenticates an outcome by itself.
    public func validatedInspection(
        for source: RawSource,
        project: ProjectContext
    ) async throws -> SourceInspectionResult? {
        let destination = Self.preferredDestinationURL(project: project)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return nil
        }
        guard let db = try? IndexDatabase.open(at: destination) else {
            return nil
        }
        defer { try? db.close() }

        guard let storedNamespace = try? db.readMetadata(),
              storedNamespace == activeNamespace else {
            return nil
        }

        guard let record = db.lookupAll()[source.relativePath] else {
            return nil
        }

        guard let storedSHA = record.prefixSHA256,
              let storedSize = record.descriptorSize else {
            return nil
        }

        let secured: (handle: FileHandle, prefix: Data, selectedURL: URL, descriptorSize: Int64)
        do {
            secured = try MeasurementCache.openSecuredPrefix(source: source, project: project)
        } catch {
            return nil
        }
        defer { try? secured.handle.close() }

        guard sha256Hex(secured.prefix) == storedSHA,
              secured.descriptorSize == storedSize else {
            return nil
        }

        let catalog = ProfileCatalog.load(project: project)
        do {
            let outcome = try InstrumentReader.inspectPinned(
                source: source,
                project: project,
                catalog: catalog,
                prefix: secured.prefix,
                descriptorSize: secured.descriptorSize,
                actualURL: secured.selectedURL
            )
            switch outcome {
            case .supported(let inspection, let disposition):
                return SourceInspectionResult(source: source, inspection: inspection, disposition: disposition, error: nil)
            case .blocked(let message):
                return SourceInspectionResult(source: source, inspection: nil, disposition: .deterministicBlocked, error: message)
            }
        } catch {
            return nil
        }
    }

    /// Persists a verified inspection outcome under the writer lease. Transient
    /// failures and cancelled outcomes are never persisted.
    public func record(
        _ result: SourceInspectionResult,
        source: RawSource,
        project: ProjectContext
    ) async throws {
        try await recordBatch([result], project: project)
    }

    /// Persists a batch of verified inspection outcomes under the writer lease.
    public func recordBatch(
        _ results: [SourceInspectionResult],
        project: ProjectContext
    ) async throws {
        guard isLeaseHeld else {
            throw StoreError.storage(detail: "destination creation must require the writer lease")
        }
        let toRecord = results.filter { $0.disposition != .transientFailure && $0.disposition != .cancelled }
        guard !toRecord.isEmpty else { return }

        let destination = Self.preferredDestinationURL(project: project)
        let legacyURL = Self.legacyIndexURL(project: project)

        var importedLegacy: [IndexDatabase.Record] = []
        if !FileManager.default.fileExists(atPath: destination.path) {
            if FileManager.default.fileExists(atPath: legacyURL.path) && Self.legacyLooksLikeSQLite(legacyURL) {
                if let legacyDB = try? IndexDatabase.openReadOnly(at: legacyURL) {
                    let legacyRows = legacyDB.lookupAll()
                    try? legacyDB.close()
                    for (path, row) in legacyRows {
                        importedLegacy.append(IndexDatabase.Record(
                            relativePath: path,
                            mtime: row.mtime,
                            byteSize: row.byteSize,
                            instrumentID: row.instrumentID,
                            instrumentName: row.instrumentName,
                            applicationMode: row.applicationMode,
                            deviceID: row.deviceID,
                            timestamp: row.timestamp,
                            category: row.category,
                            supportStatus: row.supportStatus,
                            validationState: row.validationState,
                            readerVersion: row.readerVersion,
                            profileID: row.profileID,
                            profileHash: row.profileHash,
                            error: row.error,
                            prefixSHA256: nil,
                            descriptorSize: nil,
                            recordState: .advisoryHint
                        ))
                    }
                }
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let db = try IndexDatabase.open(at: destination)
        defer { try? db.close() }

        if (try? db.readMetadata()) == nil {
            try? db.writeMetadata(activeNamespace)
        }
        if !importedLegacy.isEmpty {
            try db.upsertBatch(importedLegacy)
        }

        var dbRecords: [IndexDatabase.Record] = []
        dbRecords.reserveCapacity(toRecord.count)
        for res in toRecord {
            var prefixSHA256: String? = nil
            var descriptorSize: Int64? = nil
            if let secured = try? MeasurementCache.openSecuredPrefix(source: res.source, project: project) {
                prefixSHA256 = sha256Hex(secured.prefix)
                descriptorSize = secured.descriptorSize
                try? secured.handle.close()
            }
            let mtime: Int64 = res.source.mtime != 0 ? res.source.mtime : ((try? res.source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970).map { Int64($0) } ?? 0)
            dbRecords.append(IndexDatabase.Record(
                relativePath: res.source.relativePath,
                mtime: mtime,
                byteSize: res.source.byteSize,
                instrumentID: res.inspection?.instrumentID,
                instrumentName: res.inspection?.instrumentName,
                applicationMode: res.inspection?.applicationMode,
                deviceID: res.inspection?.deviceID,
                timestamp: res.inspection?.timestamp,
                category: res.inspection?.category,
                supportStatus: res.inspection?.supportStatus ?? "blocked",
                validationState: res.inspection?.validationState ?? "deterministic diagnostic",
                readerVersion: res.inspection?.readerVersion ?? InstrumentReader.version,
                profileID: res.inspection?.profileID,
                profileHash: res.inspection?.profileHash ?? "",
                error: res.error,
                prefixSHA256: prefixSHA256,
                descriptorSize: descriptorSize,
                recordState: .advisoryHint
            ))
        }
        try db.upsertBatch(dbRecords)
    }

    /// Prunes stale index records whose sources no longer exist in the discovered set.
    public func deleteStale(discoveredPaths: Set<String>, project: ProjectContext) async throws {
        guard isLeaseHeld else { return }
        let destination = Self.preferredDestinationURL(project: project)
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        guard let db = try? IndexDatabase.open(at: destination) else { return }
        defer { try? db.close() }
        let currentKeys = db.lookupAll().keys
        let stale = currentKeys.filter { !discoveredPaths.contains($0) }
        if !stale.isEmpty {
            try db.delete(relativePaths: Array(stale))
        }
    }

    /// Byte-level validity check of the legacy source (SQLite magic header).
    /// Deliberately no SQLite open here, so migration decisions can never
    /// modify legacy db/WAL/SHM. ponytail: header check only; full
    /// integrity/scope verification happens on the staging copy when the
    /// storage decision unblocks publication.
    private static func legacyLooksLikeSQLite(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 16) else { return false }
        try? handle.close()
        return header == Data("SQLite format 3\0".utf8)
    }
}
