import Foundation
import SQLite3

/// Fast SQLite-backed metadata index for high-scale project discovery.
/// Stores source inspection facts (mtime, size, instrument, mode, device, timestamp, category, status, error).
/// Operates with WAL (Write-Ahead Logging) and transactions for instant lookups (<10ms across 10,000 files).
public final class IndexDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// Schema version carried in the `index_metadata` namespace tuple.
    public static let namespaceSchemaVersion = 1

    public struct Record: Sendable, Equatable {
        public let relativePath: String
        public let mtime: Int64
        public let byteSize: Int64
        public let instrumentID: String?
        public let instrumentName: String?
        public let applicationMode: String?
        public let deviceID: String?
        public let timestamp: String?
        public let category: String?
        public let supportStatus: String
        public let validationState: String
        public let readerVersion: String
        public let profileID: String?
        public let profileHash: String
        public let error: String?
        /// SHA-256 of the secured bounded prefix recorded with this row.
        /// Nil for rows imported from an older database: they fail closed as
        /// stale content instead of being restorable.
        public let prefixSHA256: String?
        /// Descriptor size recorded with this row; nil fails closed the same way.
        public let descriptorSize: Int64?
        /// Explicit advisory state: every project row is an unverified hint.
        public let recordState: IndexRecordState

        public init(
            relativePath: String,
            mtime: Int64,
            byteSize: Int64,
            instrumentID: String? = nil,
            instrumentName: String? = nil,
            applicationMode: String? = nil,
            deviceID: String? = nil,
            timestamp: String? = nil,
            category: String? = nil,
            supportStatus: String = "supported",
            validationState: String = "profile valid; source not loaded",
            readerVersion: String = "",
            profileID: String? = nil,
            profileHash: String = "",
            error: String? = nil,
            prefixSHA256: String? = nil,
            descriptorSize: Int64? = nil,
            recordState: IndexRecordState = .advisoryHint
        ) {
            self.relativePath = relativePath
            self.mtime = mtime
            self.byteSize = byteSize
            self.instrumentID = instrumentID
            self.instrumentName = instrumentName
            self.applicationMode = applicationMode
            self.deviceID = deviceID
            self.timestamp = timestamp
            self.category = category
            self.supportStatus = supportStatus
            self.validationState = validationState
            self.readerVersion = readerVersion
            self.profileID = profileID
            self.profileHash = profileHash
            self.error = error
            self.prefixSHA256 = prefixSHA256
            self.descriptorSize = descriptorSize
            self.recordState = recordState
        }

        public init(source: RawSource, inspection: SourceInspection, mtime: Int64) {
            self.init(
                relativePath: source.relativePath,
                mtime: mtime,
                byteSize: source.byteSize,
                instrumentID: inspection.instrumentID,
                instrumentName: inspection.instrumentName,
                applicationMode: inspection.applicationMode,
                deviceID: inspection.deviceID,
                timestamp: inspection.timestamp,
                category: inspection.category,
                supportStatus: inspection.supportStatus ?? "supported",
                validationState: inspection.validationState ?? "",
                readerVersion: inspection.readerVersion ?? "",
                profileID: inspection.profileID,
                profileHash: inspection.profileHash ?? "",
                error: inspection.error
            )
        }

        public var asInspection: SourceInspection {
            SourceInspection(
                source: relativePath,
                size: byteSize,
                instrumentID: instrumentID,
                instrumentName: instrumentName,
                applicationMode: applicationMode,
                timestamp: timestamp,
                deviceID: deviceID,
                category: category,
                supportStatus: supportStatus,
                validationState: validationState,
                readerVersion: readerVersion,
                profileID: profileID ?? instrumentID ?? "",
                profileHash: profileHash,
                error: error
            )
        }
    }

    private init(db: OpaquePointer) {
        self.db = db
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    public static func open(at url: URL) throws -> IndexDatabase {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let db { sqlite3_close_v2(db) }
            throw NSError(domain: "IndexDatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        // Every SQLite return is checked: WAL setup, synchronous setup,
        // schema, and column migrations all verify their result codes. On
        // failure `index` is released and its deinit closes the handle.
        let index = IndexDatabase(db: db)
        try index.execChecked("PRAGMA journal_mode = WAL;", operation: "WAL setup")
        try index.execChecked("PRAGMA synchronous = NORMAL;", operation: "synchronous setup")
        try index.execChecked(IndexDatabase.schemaSQL, operation: "schema creation")
        try index.ensureColumn("ALTER TABLE sources ADD COLUMN profile_id TEXT;", operation: "profile_id migration")
        try index.ensureColumn("ALTER TABLE sources ADD COLUMN prefix_sha256 TEXT;", operation: "prefix_sha256 migration")
        try index.ensureColumn("ALTER TABLE sources ADD COLUMN descriptor_size INTEGER;", operation: "descriptor_size migration")
        try index.ensureColumn("ALTER TABLE sources ADD COLUMN record_state TEXT DEFAULT 'advisory_hint';", operation: "record_state migration")
        return index
    }

    /// Opens an existing database for reading only: no schema creation, no
    /// PRAGMA writes — the migration backup source must never modify legacy
    /// db/WAL/SHM.
    public static func openReadOnly(at url: URL) throws -> IndexDatabase {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database read-only"
            if let db { sqlite3_close_v2(db) }
            throw NSError(domain: "IndexDatabase", code: 12, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return IndexDatabase(db: db)
    }

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS sources (
            relative_path TEXT PRIMARY KEY,
            mtime INTEGER NOT NULL,
            byte_size INTEGER NOT NULL,
            instrument_id TEXT,
            instrument_name TEXT,
            application_mode TEXT,
            device_id TEXT,
            timestamp TEXT,
            category TEXT,
            support_status TEXT NOT NULL,
            validation_state TEXT NOT NULL,
            reader_version TEXT NOT NULL,
            profile_id TEXT,
            profile_hash TEXT NOT NULL,
            error TEXT,
            prefix_sha256 TEXT,
            descriptor_size INTEGER,
            record_state TEXT NOT NULL DEFAULT 'advisory_hint'
        );
        CREATE INDEX IF NOT EXISTS idx_sources_path_mtime ON sources(relative_path, mtime, byte_size);
        CREATE TABLE IF NOT EXISTS index_metadata (
            id INTEGER PRIMARY KEY CHECK (id = 0),
            schema_version INTEGER NOT NULL,
            project_identity TEXT NOT NULL,
            data_root TEXT NOT NULL,
            reader_version TEXT NOT NULL,
            catalog_fingerprint TEXT NOT NULL
        );
        """

    // MARK: checked SQLite helpers

    private func indexError(_ message: String, code: Int) -> NSError {
        NSError(domain: "IndexDatabase", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Checked `sqlite3_exec`: PRAGMA setup, schema, and BEGIN/COMMIT/ROLLBACK
    /// results are verified instead of ignored.
    private func execChecked(_ sql: String, operation: String) throws {
        guard let db else { throw indexError("\(operation): database is closed", code: 6) }
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        guard rc == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw indexError("\(operation) failed: \(detail)", code: Int(rc))
        }
    }

    /// Column migration where "duplicate column name" is the expected outcome
    /// on databases that already carry the column; anything else propagates.
    private func ensureColumn(_ sql: String, operation: String) throws {
        guard let db else { throw indexError("\(operation): database is closed", code: 6) }
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        if rc == SQLITE_OK { return }
        let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
        sqlite3_free(message)
        if detail.lowercased().contains("duplicate column name") { return }
        throw indexError("\(operation) failed: \(detail)", code: Int(rc))
    }

    // MARK: index metadata and advisory records

    /// Persists the namespace tuple as the single `index_metadata` row inside
    /// one checked transaction.
    public func writeMetadata(_ namespace: IndexNamespace) throws {
        lock.lock()
        defer { lock.unlock() }
        try execChecked("BEGIN TRANSACTION;", operation: "metadata BEGIN")
        do {
            guard let db else { throw indexError("metadata write: database is closed", code: 6) }
            let sql = """
            REPLACE INTO index_metadata (id, schema_version, project_identity, data_root, reader_version, catalog_fingerprint)
            VALUES (0, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw indexError("metadata write prepare failed", code: 8)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(namespace.schemaVersion))
            sqlite3_bind_text(stmt, 2, (namespace.projectIdentity as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (namespace.dataRoot as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (namespace.readerVersion as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (namespace.catalogFingerprint as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw indexError("metadata write failed", code: 9)
            }
            try execChecked("COMMIT;", operation: "metadata COMMIT")
        } catch {
            do {
                try execChecked("ROLLBACK;", operation: "metadata ROLLBACK")
            } catch let rollbackError {
                throw indexError("metadata write failed (\(error)); rollback also failed (\(rollbackError))", code: 10)
            }
            throw error
        }
    }

    /// Reads the `index_metadata` namespace row: nil when absent, and a
    /// malformed row fails closed with an error instead of guessing.
    public func readMetadata() throws -> IndexNamespace? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw indexError("metadata read: database is closed", code: 6) }
        let sql = """
        SELECT schema_version, project_identity, data_root, reader_version, catalog_fingerprint
        FROM index_metadata WHERE id = 0;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw indexError("metadata read prepare failed: \(String(cString: sqlite3_errmsg(db)))", code: 11)
        }
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw indexError("metadata read failed: \(String(cString: sqlite3_errmsg(db)))", code: Int(step))
        }
        guard let projectIdentity = sqlite3_column_text(stmt, 1),
              let dataRoot = sqlite3_column_text(stmt, 2),
              let readerVersion = sqlite3_column_text(stmt, 3),
              let catalogFingerprint = sqlite3_column_text(stmt, 4) else {
            throw indexError("index_metadata row is malformed", code: 12)
        }
        let namespace = IndexNamespace(
            schemaVersion: Int(sqlite3_column_int64(stmt, 0)),
            projectIdentity: String(cString: projectIdentity),
            dataRoot: String(cString: dataRoot),
            readerVersion: String(cString: readerVersion),
            catalogFingerprint: String(cString: catalogFingerprint))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw indexError("index_metadata must hold exactly one row", code: 13)
        }
        return namespace
    }

    /// Online backup into a NEW database file at `destination` (parent must
    /// exist). The source is only read — committed WAL content is included —
    /// and the destination connection is closed before returning so callers
    /// can verify and then publish it atomically.
    public func backup(to destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let source = db else { throw indexError("backup: source database is closed", code: 6) }
        var target: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(destination.path, &target, flags, nil) == SQLITE_OK, let target else {
            let msg = target.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open backup destination"
            if let target { sqlite3_close_v2(target) }
            throw indexError("backup destination open failed: \(msg)", code: 14)
        }
        defer { sqlite3_close_v2(target) }
        guard let handle = sqlite3_backup_init(target, "main", source, "main") else {
            throw indexError("backup init failed: \(String(cString: sqlite3_errmsg(target)))", code: 15)
        }
        let step = sqlite3_backup_step(handle, -1)
        let finish = sqlite3_backup_finish(handle)
        guard step == SQLITE_DONE || step == SQLITE_OK else {
            throw indexError("backup step failed (code \(step))", code: Int(step))
        }
        guard finish == SQLITE_OK else {
            throw indexError("backup finish failed (code \(finish))", code: Int(finish))
        }
    }

    /// Checked WAL checkpoint (TRUNCATE) on this connection.
    public func checkpoint() throws {
        lock.lock()
        defer { lock.unlock() }
        try execChecked("PRAGMA wal_checkpoint(TRUNCATE);", operation: "WAL checkpoint")
    }

    /// Checked `PRAGMA integrity_check`: true only for a single "ok" row.
    public func integrityCheck() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw indexError("integrity check: database is closed", code: 6) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw indexError("integrity check prepare failed", code: 16)
        }
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return false }
        guard step == SQLITE_ROW else {
            throw indexError("integrity check failed: \(String(cString: sqlite3_errmsg(db)))", code: Int(step))
        }
        guard let value = sqlite3_column_text(stmt, 0) else { return false }
        let first = String(cString: value)
        let tail = sqlite3_step(stmt)
        guard tail == SQLITE_DONE || tail == SQLITE_ROW else {
            throw indexError("integrity check failed: \(String(cString: sqlite3_errmsg(db)))", code: Int(tail))
        }
        return first == "ok" && tail == SQLITE_DONE
    }

    /// Checked close: releases this connection exactly once; later reads fail
    /// closed (nil/empty) and later writes throw.
    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        self.db = nil
        let rc = sqlite3_close_v2(db)
        guard rc == SQLITE_OK else {
            throw indexError("close failed (code \(rc))", code: Int(rc))
        }
    }

    public func lookup(path: String, mtime: Int64, size: Int64) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        let sql = "SELECT relative_path, mtime, byte_size, instrument_id, instrument_name, application_mode, device_id, timestamp, category, support_status, validation_state, reader_version, profile_id, profile_hash, error, prefix_sha256, descriptor_size, record_state FROM sources WHERE relative_path = ? AND mtime = ? AND byte_size = ? LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let legacySQL = "SELECT relative_path, mtime, byte_size, instrument_id, instrument_name, application_mode, device_id, timestamp, category, support_status, validation_state, reader_version, profile_id, profile_hash, error FROM sources WHERE relative_path = ? AND mtime = ? AND byte_size = ? LIMIT 1;"
            guard sqlite3_prepare_v2(db, legacySQL, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, mtime)
            sqlite3_bind_int64(stmt, 3, size)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return extractRecord(stmt)
            }
            return nil
        }
        guard let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, mtime)
        sqlite3_bind_int64(stmt, 3, size)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return extractRecord(stmt)
        }
        return nil
    }

    public func lookupAll() -> [String: Record] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [:] }
        let sql = "SELECT relative_path, mtime, byte_size, instrument_id, instrument_name, application_mode, device_id, timestamp, category, support_status, validation_state, reader_version, profile_id, profile_hash, error, prefix_sha256, descriptor_size, record_state FROM sources;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let legacySQL = "SELECT relative_path, mtime, byte_size, instrument_id, instrument_name, application_mode, device_id, timestamp, category, support_status, validation_state, reader_version, profile_id, profile_hash, error FROM sources;"
            guard sqlite3_prepare_v2(db, legacySQL, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var result: [String: Record] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let record = extractRecord(stmt) {
                    result[record.relativePath] = record
                }
            }
            return result
        }
        guard let stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var result: [String: Record] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let record = extractRecord(stmt) {
                result[record.relativePath] = record
            }
        }
        return result
    }

    public func upsertBatch(_ records: [Record]) throws {
        guard !records.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw indexError("upsert: database is closed", code: 6) }
        try execChecked("BEGIN TRANSACTION;", operation: "batch BEGIN")
        let sql = """
        INSERT OR REPLACE INTO sources (
            relative_path, mtime, byte_size, instrument_id, instrument_name,
            application_mode, device_id, timestamp, category, support_status,
            validation_state, reader_version, profile_id, profile_hash, error,
            prefix_sha256, descriptor_size, record_state
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            try? execChecked("ROLLBACK;", operation: "batch ROLLBACK")
            throw indexError("Failed to prepare batch statement", code: 3)
        }
        defer { sqlite3_finalize(stmt) }
        for r in records {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (r.relativePath as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, r.mtime)
            sqlite3_bind_int64(stmt, 3, r.byteSize)
            bindOptionalText(stmt, index: 4, value: r.instrumentID)
            bindOptionalText(stmt, index: 5, value: r.instrumentName)
            bindOptionalText(stmt, index: 6, value: r.applicationMode)
            bindOptionalText(stmt, index: 7, value: r.deviceID)
            bindOptionalText(stmt, index: 8, value: r.timestamp)
            bindOptionalText(stmt, index: 9, value: r.category)
            sqlite3_bind_text(stmt, 10, (r.supportStatus as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 11, (r.validationState as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 12, (r.readerVersion as NSString).utf8String, -1, nil)
            bindOptionalText(stmt, index: 13, value: r.profileID)
            sqlite3_bind_text(stmt, 14, (r.profileHash as NSString).utf8String, -1, nil)
            bindOptionalText(stmt, index: 15, value: r.error)
            bindOptionalText(stmt, index: 16, value: r.prefixSHA256)
            if let descriptorSize = r.descriptorSize {
                sqlite3_bind_int64(stmt, 17, descriptorSize)
            } else {
                sqlite3_bind_null(stmt, 17)
            }
            sqlite3_bind_text(stmt, 18, r.recordState.rawValue, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                try? execChecked("ROLLBACK;", operation: "batch ROLLBACK")
                throw indexError("Failed to insert record", code: 4)
            }
        }
        try execChecked("COMMIT;", operation: "batch COMMIT")
    }

    private func extractRecord(_ stmt: OpaquePointer) -> Record? {
        guard let pathC = sqlite3_column_text(stmt, 0) else { return nil }
        let path = String(cString: pathC)
        let mtime = sqlite3_column_int64(stmt, 1)
        let size = sqlite3_column_int64(stmt, 2)
        let instID = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let instName = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let mode = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let device = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let ts = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let cat = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let status = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "supported"
        let valState = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? ""
        let version = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? ""
        let profID = sqlite3_column_text(stmt, 12).map { String(cString: $0) }
        let hash = sqlite3_column_text(stmt, 13).map { String(cString: $0) } ?? ""
        let err = sqlite3_column_text(stmt, 14).map { String(cString: $0) }
        let colCount = sqlite3_column_count(stmt)
        let prefix = colCount > 15 ? sqlite3_column_text(stmt, 15).map { String(cString: $0) } : nil
        let hasDescriptorSize = colCount > 16 && sqlite3_column_type(stmt, 16) != SQLITE_NULL
        let descriptorSize = hasDescriptorSize ? sqlite3_column_int64(stmt, 16) : nil
        let stateText = colCount > 17 ? sqlite3_column_text(stmt, 17).map { String(cString: $0) } : nil
        return Record(
            relativePath: path, mtime: mtime, byteSize: size, instrumentID: instID,
            instrumentName: instName, applicationMode: mode, deviceID: device,
            timestamp: ts, category: cat, supportStatus: status, validationState: valState,
            readerVersion: version, profileID: profID, profileHash: hash, error: err,
            prefixSHA256: prefix, descriptorSize: descriptorSize,
            // Unknown or NULL state fails closed to the advisory hint; no row
            // is ever decoded into an authoritative state.
            recordState: stateText.flatMap(IndexRecordState.init(rawValue:)) ?? .advisoryHint
        )
    }

    public func delete(relativePath: String) throws {
        try delete(relativePaths: [relativePath])
    }

    public func delete(relativePaths: [String]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db, !relativePaths.isEmpty else { return }
        try execChecked("BEGIN TRANSACTION;", operation: "delete BEGIN")
        do {
            let sql = "DELETE FROM sources WHERE relative_path = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw indexError("delete prepare failed", code: 14)
            }
            defer { sqlite3_finalize(stmt) }
            for path in relativePaths {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw indexError("delete failed", code: 15)
                }
            }
            try execChecked("COMMIT;", operation: "delete COMMIT")
        } catch {
            _ = try? execChecked("ROLLBACK;", operation: "delete ROLLBACK")
            throw error
        }
    }

    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { return }
        try execChecked("DELETE FROM sources;", operation: "clear sources")
    }

    private func bindOptionalText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
