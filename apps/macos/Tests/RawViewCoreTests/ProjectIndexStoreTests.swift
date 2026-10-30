import Darwin
import Foundation
import SQLite3
import Testing
@testable import RawViewCore

/// Task 3: safe SQLite namespace, relocation, advisory trust, and writer lease.
///
/// Synthetic fixtures only: every project root lives under the system
/// temporary directory and is removed after the test. The SQLite filesystem
/// proof gate did not pass for a project-local destination, so product code
/// performs NO project-local SQLite write in this task: `migrateLegacy()`
/// reports a withheld outcome, never publishes `.rawviewer/index.db`, and
/// never deletes or mutates legacy db/WAL/SHM. Backup mechanics are proven
/// against a staging database outside any project.
// MARK: - Fixtures

private func makeStoreProject(
    dataRootFiles: [String: String] = ["data/raw/seed.csv": "synthetic"]
) throws -> (project: ProjectContext, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pidx-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (relativePath, body) in dataRootFiles {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
    }
    let project = try ProjectContext.open(root, dataRootRelativePath: "data/raw")
    return (project, root)
}

private func digests(_ urls: [URL]) -> [String: String] {
    var result: [String: String] = [:]
    for url in urls where FileManager.default.fileExists(atPath: url.path) {
        result[url.path] = sha256Hex((try? Data(contentsOf: url)) ?? Data())
    }
    return result
}

/// Content snapshot of a whole tree, so "open resolves and creates nothing"
/// can be asserted byte-for-byte.
private func treeSnapshot(root: URL) -> [String: String] {
    var snapshot: [String: String] = [:]
    let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    while let entry = enumerator?.nextObject() as? URL {
        let relative = entry.path.hasPrefix(root.path + "/")
            ? String(entry.path.dropFirst(root.path.count + 1))
            : entry.lastPathComponent
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            snapshot[relative] = "symlink"
        } else if values?.isDirectory == true {
            snapshot[relative] = "dir"
        } else if let data = try? Data(contentsOf: entry) {
            snapshot[relative] = sha256Hex(data)
        }
    }
    return snapshot
}

/// Opens a real legacy WAL database at `url` and leaves the connection open,
/// so committed rows sit in `-wal` with `-shm` present — the exact state a
/// migration must back up without touching. The caller closes it.
private func openLegacyWALFixture(at url: URL, rows: Int) throws -> OpaquePointer {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
          let db else {
        throw NSError(domain: "ProjectIndexStoreTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot open legacy fixture"])
    }
    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        guard rc == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "sqlite error \(rc)"
            sqlite3_free(message)
            throw NSError(domain: "ProjectIndexStoreTests", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
    }
    try exec("PRAGMA journal_mode = WAL;")
    try exec("""
    CREATE TABLE sources (
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
        error TEXT
    );
    """)
    for index in 0..<rows {
        try exec("INSERT OR REPLACE INTO sources (relative_path, mtime, byte_size, support_status, validation_state, reader_version, profile_hash) "
            + "VALUES ('data/raw/f\(index).csv', \(index), 10, 'supported', 'valid', '1.3.0', 'abc');")
    }
    return db
}

/// Removes a synthetic index file plus its WAL/SHM siblings.
private func removeIndexedFile(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
}

/// Cross-process lease probe: a flock belongs to the open file description,
/// not to a process. The holder descriptor (opened without O_CLOEXEC) is
/// inherited by a spawned child across posix_spawn, and this process then
/// drops its own reference, leaving the child as the sole holder. The parent
/// must observe busy while that holder lives and free once the holder is
/// SIGKILLed — crash release through OS locking, no stale marker consulted.
private func probeLeaseAcrossCrash(leasePath: String) -> (busyWhileHeld: Bool, acquiredAfterCrash: Bool) {
    let fd = Darwin.open(leasePath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return (false, false) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        Darwin.close(fd)
        return (false, false)
    }
    var holder: pid_t = 0
    var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("60"), nil]
    let spawnResult = arguments.withUnsafeMutableBufferPointer { buffer in
        posix_spawn(&holder, "/bin/sleep", nil, nil, buffer.baseAddress, nil)
    }
    for case let argument? in arguments { free(argument) }
    // Drop our reference: after a successful spawn the sleeping child holds
    // the lock alone.
    Darwin.close(fd)
    guard spawnResult == 0, holder > 0 else { return (false, false) }

    var busyWhileHeld = false
    let probe = Darwin.open(leasePath, O_CREAT | O_RDWR, 0o600)
    if probe >= 0 {
        busyWhileHeld = flock(probe, LOCK_EX | LOCK_NB) != 0
        Darwin.close(probe)
    }

    kill(holder, SIGKILL)
    var status: Int32 = 0
    _ = waitpid(holder, &status, 0)

    var acquiredAfterCrash = false
    let after = Darwin.open(leasePath, O_CREAT | O_RDWR, 0o600)
    if after >= 0 {
        acquiredAfterCrash = flock(after, LOCK_EX | LOCK_NB) == 0
        if acquiredAfterCrash { _ = flock(after, LOCK_UN) }
        Darwin.close(after)
    }
    return (busyWhileHeld, acquiredAfterCrash)
}

// MARK: - Tests

/// Store resolution performs no creation: no `.rawviewer`, no legacy access,
/// no destination, no staging — open and usage only resolve and stat.
@Test func openResolvesWithoutCreatingAnything() async throws {
    let (project, root) = try makeStoreProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = treeSnapshot(root: root)

    let store = try await ProjectIndexStore.open(project: project)
    let usage = try await store.usage()

    #expect(treeSnapshot(root: root) == before,
            "store open/usage must not create, write, or delete anything in the project")
    #expect(usage.storageMode == .destination)
    #expect(usage.destinationExists == false)
    #expect(usage.legacyExists == false)
    #expect(usage.stagingExists == false)
    #expect(usage.projectWritable)
    #expect(usage.destinationURL.path == ProjectIndexStore.preferredDestinationURL(project: project).path)
    #expect(usage.legacyURL.path == ProjectIndexStore.legacyIndexURL(project: project).path)
}

/// Plan-mandated name. The publication half of WAL migration is withheld by
/// the failed VFS proof gate, so this asserts: withheld report, zero copies,
/// legacy db/WAL/SHM byte-identical, no destination/staging, and the backup
/// mechanics still copy every row committed only to the WAL.
@Test func legacyWALBackupIncludesCommittedRows() async throws {
    let (project, root) = try makeStoreProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyURL = ProjectIndexStore.legacyIndexURL(project: project)
    let fixture = try openLegacyWALFixture(at: legacyURL, rows: 25)
    defer { sqlite3_close_v2(fixture) }
    let walURL = URL(fileURLWithPath: legacyURL.path + "-wal")
    let shmURL = URL(fileURLWithPath: legacyURL.path + "-shm")
    #expect(FileManager.default.fileExists(atPath: walURL.path),
            "fixture must keep committed rows in the WAL")
    // db and -wal (the data and the committed log) are byte-identity
    // asserted; the -shm wal-index is derived state, asserted by presence
    // and size (SQLite's reader may refresh it in place; nothing deletes it).
    let before = digests([legacyURL, walURL])
    let shmSizeBefore = (try? Data(contentsOf: shmURL))?.count
    #expect(before.count == 2 && shmSizeBefore != nil,
            "legacy db, WAL, and SHM must all exist")

    let store = try await ProjectIndexStore.open(project: project)
    let report = try await store.migrateLegacy()
    #expect(report.outcome == .withheldPendingStorageDecision)
    #expect(report.copiedRows == 0)
    #expect(report.warnings.contains { $0.contains("withheld") })
    let destination = ProjectIndexStore.preferredDestinationURL(project: project)
    #expect(!FileManager.default.fileExists(atPath: destination.path),
            "the gate forbids creating the project-local destination")
    #expect(digests([legacyURL, walURL]) == before,
            "migration must never touch legacy db/WAL bytes")
    #expect((try? Data(contentsOf: shmURL))?.count == shmSizeBefore,
            "migration must preserve the SHM file in place")

    // Backup mechanics, proven on a staging database outside any project:
    // read-only legacy connection → sibling staging copy → verified contents.
    let staging = FileManager.default.temporaryDirectory
        .appendingPathComponent("staging-" + UUID().uuidString + ".db")
    defer { removeIndexedFile(staging) }
    let source = try IndexDatabase.openReadOnly(at: legacyURL)
    try source.backup(to: staging)
    let copied = try IndexDatabase.open(at: staging)
    #expect(copied.lookupAll().count == 25,
            "backup must include rows committed only to the WAL")
    let integrityOK = try copied.integrityCheck()
    #expect(integrityOK)
    try copied.checkpoint()
    try copied.close()
    let reopened = try IndexDatabase.open(at: staging)
    #expect(reopened.lookupAll().count == 25)
    try reopened.close()
    try source.close()
    #expect(digests([legacyURL, walURL]) == before,
            "read-only backup must not modify legacy db/WAL bytes")
    #expect(FileManager.default.fileExists(atPath: shmURL.path)
                && (try? Data(contentsOf: shmURL))?.count == shmSizeBefore,
            "SHM must be preserved in place")
}

/// An already-existing destination wins: it and the legacy index are both
/// preserved byte-for-byte, and no staging artifact appears beside them.
@Test func destinationConflictPreservesBoth() async throws {
    let (project, root) = try makeStoreProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = ProjectIndexStore.preferredDestinationURL(project: project)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let destinationBytes = Data("SQLite format 3\0".utf8) + Data(repeating: 0x5A, count: 4096)
    try destinationBytes.write(to: destination)

    let legacyURL = ProjectIndexStore.legacyIndexURL(project: project)
    let fixture = try openLegacyWALFixture(at: legacyURL, rows: 7)
    defer { sqlite3_close_v2(fixture) }
    let walURL = URL(fileURLWithPath: legacyURL.path + "-wal")
    let shmURL = URL(fileURLWithPath: legacyURL.path + "-shm")
    let before = digests([destination, legacyURL, walURL, shmURL])
    #expect(before.count == 4)

    let store = try await ProjectIndexStore.open(project: project)
    let report = try await store.migrateLegacy()
    #expect(report.outcome == .destinationExists)
    #expect(report.copiedRows == 0)
    #expect(digests([destination, legacyURL, walURL, shmURL]) == before,
            "existing destination and legacy index must both survive byte-for-byte")
    let entries = try FileManager.default.contentsOfDirectory(
        atPath: destination.deletingLastPathComponent().path)
        .filter { !$0.hasSuffix(".lock") }
    #expect(entries == ["index.db"], "no staging or replacement file may appear: \(entries)")
}

/// An unusable legacy index is reported and retained: nothing is created,
/// nothing is deleted, and the bytes stay identical.
@Test func migrationFailureLeavesLegacyIntact() async throws {
    let (project, root) = try makeStoreProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyURL = ProjectIndexStore.legacyIndexURL(project: project)
    try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let garbage = Data((0..<512).map { UInt8($0 % 251) })
    try garbage.write(to: legacyURL)
    let before = digests([legacyURL])
    #expect(before.count == 1)

    let store = try await ProjectIndexStore.open(project: project)
    let report = try await store.migrateLegacy()
    #expect(report.outcome == .legacyUnavailable)
    #expect(report.warnings.contains { $0.contains("retained") })
    #expect(digests([legacyURL]) == before, "an unusable legacy index is retained untouched")
    #expect(!FileManager.default.fileExists(
        atPath: ProjectIndexStore.preferredDestinationURL(project: project).path))
    let rootEntries = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(!rootEntries.contains(".rawviewer"),
            "no destination namespace may be created by a failed migration")
}

/// One OS-managed advisory lock per bounded writer job: a nested/concurrent
/// writer sees busy, an idle read never contends, and a crashed holder's
/// lock is released by the kernel (no stale marker is consulted).
@Test func busyWriterIsReportedAndCrashReleasesLease() async throws {
    let (project, root) = try makeStoreProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await ProjectIndexStore.open(project: project)

    try await store.withWriterJob {
        // Reads inside the writer job work and never try to re-take the lease.
        let usage = try await store.usage()
        #expect(usage.destinationExists == false)
        do {
            try await store.withWriterJob { }
            Issue.record("a second concurrent writer job must report busy")
        } catch ProjectIndexStore.StoreError.busy {
            // expected: the first job still holds the OS lock
        } catch {
            Issue.record("unexpected error instead of busy: \(error)")
        }
    }

    let probe = probeLeaseAcrossCrash(
        leasePath: ProjectIndexStore.writerLeaseURL(project: project).path)
    #expect(probe.busyWhileHeld, "a second writer process must observe the lease as busy")
    #expect(probe.acquiredAfterCrash, "a crashed holder's lease must be released by the OS")

    // After every holder is gone, an uncontended writer job succeeds.
    try await store.withWriterJob { }
}

/// The persisted namespace is `(project identity, data root, reader version,
/// catalog fingerprint, schema)`: any axis changing invalidates stored rows
/// (rebuild, never restore), while matching content stays advisory only.
@Test func indexNamespaceChangesWithRootCatalogReader() async throws {
    let (project, root) = try makeStoreProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await ProjectIndexStore.open(project: project, catalogFingerprint: "fp-current")
    let active = await store.activeNamespace
    #expect(active.schemaVersion == IndexDatabase.namespaceSchemaVersion)
    #expect(active.readerVersion == InstrumentReader.version)
    #expect(active.dataRoot == "data/raw")
    #expect(active.projectIdentity == sha256Hex(Data(project.root.path.utf8)))
    #expect(active.catalogFingerprint == "fp-current")

    let seed = project.root.appendingPathComponent("data/raw/seed.csv")
    let source = RawSource(relativePath: "data/raw/seed.csv", url: seed, byteSize: 8)
    let secured = try MeasurementCache.openSecuredPrefix(source: source, project: project)
    defer { try? secured.handle.close() }
    let digest = sha256Hex(secured.prefix)
    let record = IndexDatabase.Record(
        relativePath: "data/raw/seed.csv", mtime: 1, byteSize: secured.descriptorSize,
        prefixSHA256: digest, descriptorSize: secured.descriptorSize)

    #expect(store.disposition(
        record: record, storedNamespace: active,
        observedPrefixSHA256: digest, observedDescriptorSize: secured.descriptorSize
    ) == .advisoryHint)

    func namespace(
        projectIdentity: String = active.projectIdentity,
        dataRoot: String = active.dataRoot,
        readerVersion: String = active.readerVersion,
        catalogFingerprint: String = active.catalogFingerprint,
        schemaVersion: Int = active.schemaVersion
    ) -> IndexNamespace {
        IndexNamespace(schemaVersion: schemaVersion, projectIdentity: projectIdentity,
                       dataRoot: dataRoot, readerVersion: readerVersion,
                       catalogFingerprint: catalogFingerprint)
    }
    let axisChanges: [IndexNamespace] = [
        namespace(dataRoot: "measurements"),
        namespace(readerVersion: "0.9.0"),
        namespace(catalogFingerprint: "fp-older"),
        namespace(projectIdentity: String(repeating: "0", count: 64)),
        namespace(schemaVersion: active.schemaVersion + 1),
    ]
    for stored in axisChanges {
        #expect(ProjectIndexStore.disposition(
            record: record, storedNamespace: stored, activeNamespace: active,
            observedPrefixSHA256: digest, observedDescriptorSize: secured.descriptorSize
        ) == .staleNamespace, "namespace change must invalidate: \(stored)")
    }
    #expect(store.disposition(
        record: record, storedNamespace: active,
        observedPrefixSHA256: String(repeating: "a", count: 64),
        observedDescriptorSize: secured.descriptorSize
    ) == .staleContent, "content mismatch must invalidate even with a matching namespace")
}

/// A symlinked metadata namespace or destination leaf is a security refusal:
/// open fails closed and nothing is created or followed.
@Test func unsafeMetadataNamespaceFailsClosed() async throws {
    let (project, root) = try makeStoreProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = root.appendingPathComponent(".rawviewer")
    let target = root.deletingLastPathComponent()
        .appendingPathComponent("elsewhere-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: target) }
    try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target)

    do {
        _ = try await ProjectIndexStore.open(project: project)
        Issue.record("a symlinked .rawviewer namespace must be refused")
    } catch ProjectIndexStore.StoreError.unsafeNamespace(let path) {
        #expect(path.contains(".rawviewer"))
    }
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("index.db").path),
            "the symlink target must never receive an index")

    // Symlinked destination leaf inside a real metadata directory: refused too.
    try FileManager.default.removeItem(at: metadata)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: metadata.appendingPathComponent("index.db").path,
        withDestinationPath: "/tmp/rawview-evil.db")
    do {
        _ = try await ProjectIndexStore.open(project: project)
        Issue.record("a symlinked index.db destination must be refused")
    } catch ProjectIndexStore.StoreError.unsafeNamespace(let path) {
        #expect(path.hasSuffix("index.db"))
    }
}

/// An ordinary read-only project root never becomes a write target: storage
/// resolves to the owner-private app-local index fallback and the project
/// gains no `.rawviewer` namespace.
@Test func readOnlyProjectUsesPrivateFallback() async throws {
    let (project, root) = try makeStoreProject()
    defer {
        chmod(root.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }
    guard chmod(root.path, 0o555) == 0 else {
        Issue.record("chmod 0555 failed on the synthetic project root")
        return
    }

    let store = try await ProjectIndexStore.open(project: project)
    let usage = try await store.usage()
    #expect(usage.projectWritable == false)
    #expect(usage.storageMode == .privateFallback)
    #expect(usage.destinationExists == false)
    let appLocal = MeasurementCache.appLocalRoot(project: project)
    #expect(usage.destinationURL.path.hasPrefix(appLocal.path),
            "read-only project must resolve to the private app-local index: \(usage.destinationURL.path)")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".rawviewer").path),
            "a read-only project must never gain a project-local index namespace")
}

/// Forged scientific fields with CORRECT digest/catalog metadata stay
/// advisory: matching content proves freshness, never authorship, so the row
/// can never be promoted to a trusted SourceInspection. Imported legacy rows
/// without validity fields are equally non-restorable.
@Test func forgedIndexCannotPromoteTrustedInspection() async throws {
    let (project, root) = try makeStoreProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = project.root.appendingPathComponent("data/raw/seed.csv")
    let source = RawSource(relativePath: "data/raw/seed.csv", url: file, byteSize: 8)
    let secured = try MeasurementCache.openSecuredPrefix(source: source, project: project)
    defer { try? secured.handle.close() }
    let digest = sha256Hex(secured.prefix)

    let namespace = ProjectIndexStore.makeNamespace(project: project, catalogFingerprint: "fp-forged")
    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("forged-" + UUID().uuidString + ".db")
    defer { removeIndexedFile(dbURL) }
    let db = try IndexDatabase.open(at: dbURL)
    try db.writeMetadata(namespace)
    #expect(try db.readMetadata() == namespace)
    #expect(try db.readMetadata() == namespace, "metadata row must read back stable")

    let forged = IndexDatabase.Record(
        relativePath: "data/raw/seed.csv", mtime: 1, byteSize: secured.descriptorSize,
        instrumentID: "keysight-b1500a", applicationMode: "forged-mode",
        supportStatus: "supported", validationState: "profile valid; source not loaded",
        readerVersion: InstrumentReader.version, profileID: "forged-profile",
        profileHash: "forged-profile-hash",
        prefixSHA256: digest, descriptorSize: secured.descriptorSize,
        recordState: .advisoryHint)
    try db.upsertBatch([forged])
    let stored = db.lookupAll()["data/raw/seed.csv"]
    #expect(stored != nil)
    #expect(stored?.prefixSHA256 == digest, "the forge keeps correct digest metadata")
    #expect(stored?.descriptorSize == secured.descriptorSize)
    #expect(stored?.recordState == .advisoryHint, "every project row is explicitly advisory")

    let storedNamespace = try #require(try db.readMetadata())
    let disposition = ProjectIndexStore.disposition(
        record: try #require(stored), storedNamespace: storedNamespace, activeNamespace: namespace,
        observedPrefixSHA256: digest, observedDescriptorSize: secured.descriptorSize)
    #expect(disposition == .advisoryHint)
    #expect(disposition.grantsInspectionAuthority == false,
            "correct digest metadata must never promote a forged row to trusted inspection authority")

    // Imported legacy row without content validity fields: never restorable.
    let legacyRow = IndexDatabase.Record(
        relativePath: "data/raw/legacy.csv", mtime: 2, byteSize: 4,
        applicationMode: "legacy-mode", supportStatus: "supported")
    #expect(ProjectIndexStore.disposition(
        record: legacyRow, storedNamespace: namespace, activeNamespace: namespace,
        observedPrefixSHA256: digest, observedDescriptorSize: 4
    ) == .staleContent, "legacy rows without a matching prefix digest are not restorable")
}

/// Same size and same recorded mtime prove nothing: a header edit that keeps
/// both still invalidates the index row through the secured prefix digest.
@Test func sameSizeSameTimeHeaderEditInvalidatesIndex() async throws {
    let (project, root) = try makeStoreProject(
        dataRootFiles: ["data/raw/edited.csv": String(repeating: "A", count: 2048)])
    defer { try? FileManager.default.removeItem(at: root) }
    let file = project.root.appendingPathComponent("data/raw/edited.csv")
    let attributesBefore = try FileManager.default.attributesOfItem(atPath: file.path)
    let mtimeBefore = (attributesBefore[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
    let sizeBefore = (attributesBefore[.size] as? NSNumber)?.int64Value ?? 0

    let source = RawSource(relativePath: "data/raw/edited.csv", url: file, byteSize: sizeBefore)
    let securedBefore = try MeasurementCache.openSecuredPrefix(source: source, project: project)
    let digestBefore = sha256Hex(securedBefore.prefix)
    try securedBefore.handle.close()

    let namespace = ProjectIndexStore.makeNamespace(project: project, catalogFingerprint: "fp-edit")
    let record = IndexDatabase.Record(
        relativePath: "data/raw/edited.csv", mtime: Int64(mtimeBefore.timeIntervalSince1970),
        byteSize: sizeBefore, instrumentID: "keysight-b1500a",
        applicationMode: "list-sweep", supportStatus: "supported",
        readerVersion: InstrumentReader.version,
        prefixSHA256: digestBefore, descriptorSize: sizeBefore, recordState: .advisoryHint)
    #expect(ProjectIndexStore.disposition(
        record: record, storedNamespace: namespace, activeNamespace: namespace,
        observedPrefixSHA256: digestBefore, observedDescriptorSize: sizeBefore
    ) == .advisoryHint, "fresh content matches its recorded digest")

    // Same-size, same-mtime header edit.
    var bytes = try Data(contentsOf: file)
    #expect(bytes.count == Int(sizeBefore))
    bytes.replaceSubrange(0..<4, with: Data("EVIL".utf8))
    try bytes.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: mtimeBefore], ofItemAtPath: file.path)
    let attributesAfter = try FileManager.default.attributesOfItem(atPath: file.path)
    let mtimeAfter = (attributesAfter[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
    let sizeAfter = (attributesAfter[.size] as? NSNumber)?.int64Value ?? 0
    #expect(sizeAfter == sizeBefore, "the edit must keep the same size")
    #expect(Int64(mtimeAfter.timeIntervalSince1970) == Int64(mtimeBefore.timeIntervalSince1970),
            "the edit must keep the same recorded mtime — size/mtime lookup still matches")

    let securedAfter = try MeasurementCache.openSecuredPrefix(source: source, project: project)
    let digestAfter = sha256Hex(securedAfter.prefix)
    try securedAfter.handle.close()
    #expect(digestAfter != digestBefore, "the secured prefix digest must notice the edit")

    #expect(ProjectIndexStore.disposition(
        record: record, storedNamespace: namespace, activeNamespace: namespace,
        observedPrefixSHA256: digestAfter, observedDescriptorSize: sizeAfter
    ) == .staleContent, "a same-size/same-time header edit must invalidate the index row")
}
