import Darwin
import Foundation
import SQLite3
import Testing
@testable import RawViewCore

/// Task 4: shared indexing coordinator, typed inspection dispositions, bounded
/// prefix-only generic inspection, validated store restoration, and the
/// app-local destination cutover.
///
/// Synthetic fixtures only: every project root lives under the system
/// temporary directory and is removed with its owner-private app-local index
/// state after the test. Raw fixture bytes and mtimes are asserted unchanged
/// where the test mutates nothing. A deterministic unprofiled (structural
/// candidate) result is never scientific acceptance.

// MARK: - Fixtures

private let indexerProfileYAML = """
schema_version: 1
instrument:
  id: keysight-b1500a
  name: Keysight B1500A
formats:
  - id: csv
    kind: tabular
    extensions: [".csv"]
    delimiter: ","
    rows:
      names_prefix: "DataName"
      data_prefix: "DataValue"
    columns:
      voltage:
        header: "V1"
        quantity: voltage
        unit: "V"
      current:
        header: "I2"
        aliases: ["I1"]
        quantity: current
        unit: "A"
modes:
  - id: dual-sweep
    format: csv
    detect: ["2-terminal dual Vsweep"]
    extract:
      x: voltage
      y: [current]
"""

private let profiledCSV = """
\u{FEFF}SetupTitle, 2-terminal dual Vsweep
DataName, V1, I1
DataValue, 0, 1E-12
DataValue, 0.1, 2E-12
DataValue, 0.2, 3E-12
"""

private let genericCSV = "time,voltage\n0.1,1\n0.2,2\n0.3,3\n"
private let unresolvableCSV = "notes\nplain prose without numbers\nmore prose without digits\n"

private func makeIndexerProject(
    files: [String: String],
    withProfile: Bool = false
) throws -> (project: ProjectContext, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pidxr-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if withProfile {
        try writeIndexerFixture(root, "data/instruments/keysight-b1500a.yaml", indexerProfileYAML)
    }
    for (relativePath, body) in files {
        try writeIndexerFixture(root, relativePath, body)
    }
    let project = try ProjectContext.open(root, dataRootRelativePath: "data/raw")
    return (project, root)
}

private func writeIndexerFixture(_ root: URL, _ relativePath: String, _ contents: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

/// Removes the synthetic project and its owner-private app-local state
/// (cache + index + lease), keyed by this project's digest.
private func removeIndexerProject(_ root: URL, _ project: ProjectContext) {
    let appLocal = MeasurementCache.appLocalRoot(project: project).deletingLastPathComponent()
    try? FileManager.default.removeItem(at: appLocal)
    try? FileManager.default.removeItem(at: root)
}

private func indexRows(_ project: ProjectContext) -> [String: IndexDatabase.Record] {
    guard let db = try? IndexDatabase.open(at: project.indexDatabaseURL) else { return [:] }
    defer { try? db.close() }
    return db.lookupAll()
}

private let defaultCohort: [String: String] = [
    "data/raw/matched-a.csv": profiledCSV,
    "data/raw/matched-b.csv": profiledCSV,
    "data/raw/generic-a.csv": genericCSV,
    "data/raw/generic-b.csv": genericCSV,
    "data/raw/notes.csv": unresolvableCSV
]

// MARK: - Bounded prefix-only generic inspection

/// Plan-mandated name. Generic inspection consumes only the secured 64 KiB
/// prefix that was pinned before the pathname became unavailable: deleting the
/// file after the prefix read must not change the preview or the disposition.
@Test func prefixOnlyInspectionNeverReopensSource() throws {
    let (project, root) = try makeIndexerProject(files: ["data/raw/table.csv": genericCSV])
    defer { removeIndexerProject(root, project) }
    let url = root.appendingPathComponent("data/raw/table.csv")
    let source = RawSource(relativePath: "data/raw/table.csv", url: url,
                            byteSize: Int64(genericCSV.utf8.count))

    let secured = try MeasurementCache.openSecuredPrefix(source: source, project: project)
    let prefix = secured.prefix
    try secured.handle.close()
    try FileManager.default.removeItem(at: url)

    let preview = try GenericTableReader.inspect(prefix: prefix)
    #expect(preview.delimiter == ",")
    #expect(preview.headerLineIndex == 0)
    #expect(preview.sampleRows.first == [0.1, 1.0])
    #expect(preview.sampleRows.count <= 5)

    let catalog = ProfileCatalog.load(project: project)
    let outcome = try InstrumentReader.inspectPinned(
        source: source, project: project, catalog: catalog,
        prefix: prefix, descriptorSize: Int64(genericCSV.utf8.count), actualURL: url)
    guard case .supported(let inspection, let disposition) = outcome else {
        Issue.record("pinned bytes must still produce a structural candidate")
        return
    }
    #expect(disposition == .structuralCandidate)
    #expect(inspection.instrumentID == "generic-table")
    #expect(inspection.validationState?.contains("structural candidate") == true)
}

/// A prefix cut before any resolvable numeric block stays unresolved: the
/// outcome is a deterministic block with the reader diagnostic, never a
/// structural candidate and never support.
@Test func truncatedSampleRemainsUnresolved() throws {
    let (project, root) = try makeIndexerProject(files: ["data/raw/cut.csv": genericCSV])
    defer { removeIndexerProject(root, project) }
    let url = root.appendingPathComponent("data/raw/cut.csv")
    let source = RawSource(relativePath: "data/raw/cut.csv", url: url, byteSize: 64)

    let truncated = Data("time,voltage,current\n0.1,1".utf8)
    var threw = false
    do {
        _ = try GenericTableReader.inspect(prefix: truncated)
    } catch {
        threw = true
    }
    #expect(threw, "an unresolvable prefix must not produce a preview")

    let catalog = ProfileCatalog.load(project: project)
    let outcome = try InstrumentReader.inspectPinned(
        source: source, project: project, catalog: catalog,
        prefix: truncated, descriptorSize: 64, actualURL: url)
    guard case .blocked(let message) = outcome else {
        Issue.record("an unresolvable prefix must resolve to a deterministic block")
        return
    }
    #expect(!message.isEmpty)
}

/// A source that cannot be opened is a transient failure, never a cached or
/// deterministic outcome: no inspection, no persisted row, incomplete report.
@Test func genericReadFailureRemainsTransient() async throws {
    let (project, root) = try makeIndexerProject(files: ["data/raw/present.csv": genericCSV])
    defer { removeIndexerProject(root, project) }
    let missing = root.appendingPathComponent("data/raw/gone.csv")
    let source = RawSource(relativePath: "data/raw/gone.csv", url: missing, byteSize: 64)

    let report = await InstrumentReader.inspectMany([source], project: project, cache: nil)
    let result = try #require(report.results.first)
    #expect(result.inspection == nil)
    #expect(result.disposition == .transientFailure)
    #expect(!(result.error?.isEmpty ?? true))
}

// MARK: - Coordinator reports

/// Plan-mandated name. The headless coordinator and the GUI restore seam are
/// the same store: whatever one persists, the other validates to the same
/// recomputed outcome — and a GUI-side focused record is visible to a
/// subsequent coordinator run.
@Test func CLIAndGUIShareIndexValidity() async throws {
    let (project, root) = try makeIndexerProject(files: defaultCohort, withProfile: true)
    defer { removeIndexerProject(root, project) }

    let cliReport = try await ProjectIndexer.run(project: project)
    #expect(cliReport.complete)
    #expect(cliReport.discovered == 5)
    #expect(cliReport.inspected == 5)
    #expect(cliReport.structuralCandidates == 2)
    #expect(cliReport.deterministicBlocked == 1)
    #expect(cliReport.inspected - cliReport.structuralCandidates - cliReport.deterministicBlocked == 2)
    #expect(cliReport.transientFailures == 0 && cliReport.cancelled == 0 && cliReport.inventoryFailures == 0)

    let store = try await ProjectIndexStore.open(project: project)
    let sources = try project.discoverSources()
    for source in sources {
        let restored = try await store.validatedInspection(for: source, project: project)
        let freshReport = await InstrumentReader.inspectMany([source], project: project, cache: nil)
        let fresh = try #require(freshReport.results.first)
        #expect(restored?.disposition == fresh.disposition,
                "\(source.relativePath): restored disposition diverged")
        #expect(restored?.inspection?.instrumentID == fresh.inspection?.instrumentID)
        #expect(restored?.inspection?.applicationMode == fresh.inspection?.applicationMode)
        #expect(restored?.error == fresh.error)
    }

    // GUI-side focused write: a fresh inspection recorded through the store
    // must be restorable by a later coordinator run with the same outcome.
    let focused = try #require(sources.first)
    let focusedResult = try #require(
        await InstrumentReader.inspectMany([focused], project: project, cache: nil).results.first)
    try await store.withWriterJob {
        try await store.record(focusedResult, source: focused, project: project)
    }
    let rerun = try await ProjectIndexer.run(project: project)
    #expect(rerun.complete && rerun.discovered == cliReport.discovered)
    #expect(rerun.inspected == cliReport.inspected)
    #expect(rerun.structuralCandidates == cliReport.structuralCandidates)
    #expect(rerun.deterministicBlocked == cliReport.deterministicBlocked)
}

/// A catalog change produces a new index namespace: every previously recorded
/// hint stops being restorable, for every affected source.
@Test func catalogChangeInvalidatesAllAffectedHints() async throws {
    let (project, root) = try makeIndexerProject(files: defaultCohort, withProfile: true)
    defer { removeIndexerProject(root, project) }
    let first = try await ProjectIndexer.run(project: project)
    #expect(first.complete)
    let sources = try project.discoverSources()
    let before = try await ProjectIndexStore.open(project: project)
    #expect(try await before.validatedInspection(for: sources[0], project: project) != nil)

    // A new profile file changes ProfileCatalog.load's fingerprint, so the
    // active namespace differs from the stored one.
    try writeIndexerFixture(root, "data/instruments/extra.yaml", """
    schema_version: 1
    instrument:
      id: extra-instrument
      name: Extra Fixture
    formats: []
    modes: []
    """)
    let after = try await ProjectIndexStore.open(project: project)
    for source in sources {
        let restored = try await after.validatedInspection(for: source, project: project)
        #expect(restored == nil, "\(source.relativePath): stale-catalog hint was restored")
    }
}

/// Refresh drops entries whose source no longer exists: the row disappears
/// from the index and cannot be restored.
@Test func deletedFilesDisappear() async throws {
    let (project, root) = try makeIndexerProject(files: defaultCohort, withProfile: true)
    defer { removeIndexerProject(root, project) }
    _ = try await ProjectIndexer.run(project: project)
    #expect(indexRows(project).count == 5)

    let removed = root.appendingPathComponent("data/raw/matched-b.csv")
    try FileManager.default.removeItem(at: removed)
    let refresh = try await ProjectIndexer.run(project: project)
    #expect(refresh.complete)
    #expect(refresh.discovered == 4)
    #expect(indexRows(project).count == 4)
    #expect(indexRows(project)["data/raw/matched-b.csv"] == nil)

    let store = try await ProjectIndexStore.open(project: project)
    let ghost = RawSource(relativePath: "data/raw/matched-b.csv", url: removed, byteSize: 10)
    #expect(try await store.validatedInspection(for: ghost, project: project) == nil)
}

/// Deterministic blocks are persisted and restorable: the index keeps the
/// source visible with its recomputed diagnostic.
@Test func blockedSourcesRemainVisible() async throws {
    let (project, root) = try makeIndexerProject(
        files: ["data/raw/notes.csv": unresolvableCSV, "data/raw/table.csv": genericCSV])
    defer { removeIndexerProject(root, project) }
    let report = try await ProjectIndexer.run(project: project)
    #expect(report.complete)
    #expect(report.deterministicBlocked == 1)
    #expect(report.structuralCandidates == 1)

    let rows = indexRows(project)
    #expect(rows.count == 2)
    let blockedRow = try #require(rows["data/raw/notes.csv"])
    #expect(!(blockedRow.error?.isEmpty ?? true))

    let store = try await ProjectIndexStore.open(project: project)
    let blocked = try #require(try project.discoverSources().first { $0.relativePath == "data/raw/notes.csv" })
    let restored = try await store.validatedInspection(for: blocked, project: project)
    #expect(restored?.disposition == .deterministicBlocked)
    #expect(restored?.inspection == nil)
    #expect(restored?.error == blockedRow.error, "the diagnostic must be recomputed, not promoted")
}

/// Transient failures are never persisted: no row, no restoration, and the
/// run reports itself incomplete.
@Test func transientErrorsAreNotCached() async throws {
    let (project, root) = try makeIndexerProject(
        files: ["data/raw/table.csv": genericCSV, "data/raw/locked.csv": genericCSV])
    defer {
        chmod(root.appendingPathComponent("data/raw/locked.csv").path, 0o644)
        removeIndexerProject(root, project)
    }
    let lockedURL = root.appendingPathComponent("data/raw/locked.csv")
    guard chmod(lockedURL.path, 0o000) == 0 else {
        Issue.record("chmod 000 failed on the synthetic fixture")
        return
    }
    let report = try await ProjectIndexer.run(project: project)
    #expect(report.transientFailures == 1)
    #expect(report.inspected == 1)
    #expect(report.complete == false, "a transient failure keeps the report incomplete")

    let rows = indexRows(project)
    #expect(rows["data/raw/locked.csv"] == nil, "a transient failure must not be persisted")
    #expect(rows["data/raw/table.csv"] != nil)

    let store = try await ProjectIndexStore.open(project: project)
    let locked = try #require(try project.discoverSources().first { $0.relativePath == "data/raw/locked.csv" })
    #expect(try await store.validatedInspection(for: locked, project: project) == nil)
}

/// Plan-mandated name. Cancellation after the first completed batch keeps
/// every completed batch durable, counts the unvisited sources as cancelled
/// (never inspected), and reports the run incomplete.
@Test func cancelledIndexKeepsCompletedBatches() async throws {
    var many: [String: String] = [:]
    for index in 0..<300 {
        many["data/raw/run-\(String(format: "%03d", index)).csv"] = genericCSV
    }
    let (project, root) = try makeIndexerProject(files: many, withProfile: true)
    defer { removeIndexerProject(root, project) }

    let report = try await ProjectIndexer.run(project: project, rebuild: false) { completed, _ in
        if completed >= 1 {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    #expect(report.discovered == 300)
    #expect(report.inspected == 256, "exactly the first batch was inspected")
    #expect(report.cancelled == 44, "unvisited sources are cancelled, not inspected")
    #expect(report.transientFailures == 0 && report.structuralCandidates == 256)
    #expect(report.complete == false, "a cancelled run is never complete")
    #expect(indexRows(project).count == 256, "completed batches stay durable")
}

/// One source that cannot be opened does not drop the other results: the run
/// isolates the failure, persists the verified outcomes, and stays incomplete.
@Test func sourceFailureDoesNotDropOtherResults() async throws {
    let (project, root) = try makeIndexerProject(
        files: ["data/raw/a.csv": genericCSV, "data/raw/b.csv": genericCSV,
                "data/raw/c.csv": unresolvableCSV, "data/raw/locked.csv": genericCSV],
        withProfile: true)
    defer {
        chmod(root.appendingPathComponent("data/raw/locked.csv").path, 0o644)
        removeIndexerProject(root, project)
    }
    guard chmod(root.appendingPathComponent("data/raw/locked.csv").path, 0o000) == 0 else {
        Issue.record("chmod 000 failed on the synthetic fixture")
        return
    }
    let report = try await ProjectIndexer.run(project: project)
    #expect(report.discovered == 4)
    #expect(report.inspected == 3)
    #expect(report.transientFailures == 1)
    #expect(report.deterministicBlocked == 1)
    #expect(report.structuralCandidates == 2)
    #expect(report.complete == false)
    #expect(report.inspected + report.transientFailures + report.cancelled == report.discovered)

    let rows = indexRows(project)
    #expect(rows.count == 3)
    #expect(rows["data/raw/a.csv"] != nil && rows["data/raw/b.csv"] != nil)
    #expect(rows["data/raw/c.csv"] != nil)
    #expect(rows["data/raw/locked.csv"] == nil)
}

// MARK: - Store validity

/// A forged record with correct validity metadata still cannot promote itself:
/// the store recomputes the outcome from the pinned prefix and current
/// catalog. A deterministic unprofiled result is not scientific acceptance.
@Test func forgedRecordCannotPromoteInspection() async throws {
    let (project, root) = try makeIndexerProject(files: ["data/raw/matched.csv": profiledCSV],
                                                  withProfile: true)
    defer { removeIndexerProject(root, project) }
    _ = try await ProjectIndexer.run(project: project)

    guard let db = try? IndexDatabase.open(at: project.indexDatabaseURL),
          let original = db.lookupAll()["data/raw/matched.csv"] else {
        Issue.record("the run must persist the matched source")
        return
    }
    let forged = IndexDatabase.Record(
        relativePath: original.relativePath, mtime: original.mtime, byteSize: original.byteSize,
        instrumentID: "forged-instrument", instrumentName: "Forged", applicationMode: "forged-mode",
        supportStatus: "supported", validationState: "profile valid; source not loaded",
        readerVersion: original.readerVersion, profileID: "forged-profile",
        profileHash: "forged-hash", error: nil,
        prefixSHA256: original.prefixSHA256, descriptorSize: original.descriptorSize,
        recordState: .advisoryHint)
    try db.upsertBatch([forged])
    try db.close()

    let store = try await ProjectIndexStore.open(project: project)
    let source = try #require(try project.discoverSources().first)
    let restored = try await store.validatedInspection(for: source, project: project)
    #expect(restored?.inspection?.instrumentID == "keysight-b1500a")
    #expect(restored?.inspection?.applicationMode == "dual-sweep")
    #expect(restored?.inspection?.profileID != "forged-profile")
    #expect(restored?.disposition == .profileMatched)
}

/// Same size, same mtime, different bytes: the pinned prefix digest changes,
/// so the stored hint stops being restorable even though every advisory field
/// still matches.
@Test func sameSizeSameTimeEditInvalidatesStoredInspection() async throws {
    let (project, root) = try makeIndexerProject(
        files: ["data/raw/edited.csv": String(repeating: "A", count: 2048) + "\n"])
    defer { removeIndexerProject(root, project) }
    _ = try await ProjectIndexer.run(project: project)
    let store = try await ProjectIndexStore.open(project: project)
    let url = root.appendingPathComponent("data/raw/edited.csv")
    let source = try #require(try project.discoverSources().first)
    #expect(try await store.validatedInspection(for: source, project: project) != nil)

    let attributesBefore = try FileManager.default.attributesOfItem(atPath: url.path)
    let mtimeBefore = (attributesBefore[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
    let sizeBefore = (attributesBefore[.size] as? NSNumber)?.int64Value ?? 0
    var bytes = try Data(contentsOf: url)
    #expect(Int64(bytes.count) == sizeBefore)
    bytes.replaceSubrange(0..<4, with: Data("EVIL".utf8))
    try bytes.write(to: url)
    try FileManager.default.setAttributes([.modificationDate: mtimeBefore], ofItemAtPath: url.path)
    let attributesAfter = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributesAfter[.size] as? NSNumber)?.int64Value == sizeBefore)
    #expect(abs(((attributesAfter[.modificationDate] as? Date)?.timeIntervalSince(mtimeBefore) ?? 999)) < 0.002)

    #expect(try await store.validatedInspection(for: source, project: project) == nil,
            "same-size/same-mtime edits must not restore")
}

// MARK: - Rebuild and migration cutover

/// Rebuild bypasses SQLite hints without deleting raw or cache data: poisoned
/// rows are rewritten from a fresh inspection, source bytes/mtimes and cache
/// entries survive, and outcomes match a non-rebuild run.
@Test func rebuildBypassesIndexWithoutDeletingRawOrCache() async throws {
    let (project, root) = try makeIndexerProject(files: defaultCohort, withProfile: true)
    defer { removeIndexerProject(root, project) }
    let cold = try await ProjectIndexer.run(project: project)
    #expect(cold.complete)

    let url = root.appendingPathComponent("data/raw/matched-a.csv")
    let bytesBefore = try Data(contentsOf: url)
    let mtimeBefore = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    let cache = MeasurementCache(project: project)
    let cacheBefore = try cache.usage().entryCount
    #expect(cacheBefore > 0, "the private cache holds verified entries after a run")

    // Poison one advisory row while keeping its validity fields correct.
    guard let db = try? IndexDatabase.open(at: project.indexDatabaseURL),
          let original = db.lookupAll()["data/raw/matched-a.csv"] else {
        Issue.record("the run must persist the matched source")
        return
    }
    try db.upsertBatch([IndexDatabase.Record(
        relativePath: original.relativePath, mtime: original.mtime, byteSize: original.byteSize,
        instrumentID: "poisoned", applicationMode: "poisoned-mode",
        prefixSHA256: original.prefixSHA256, descriptorSize: original.descriptorSize)])
    try db.close()

    let rebuilt = try await ProjectIndexer.run(project: project, rebuild: true)
    #expect(rebuilt == cold, "rebuild and ordinary run must report identical outcomes")
    let row = try #require(indexRows(project)["data/raw/matched-a.csv"])
    #expect(row.instrumentID == "keysight-b1500a", "rebuild rewrites poisoned rows")

    #expect(try Data(contentsOf: url) == bytesBefore, "rebuild never writes raw bytes")
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) == mtimeBefore,
            "rebuild never rewrites raw mtimes")
    let cacheAfter = try cache.usage().entryCount
    #expect(cacheAfter >= cacheBefore, "rebuild never deletes private cache data")
}

/// Plan-mandated name. Opening the store, reading usage, and restoring from
/// the index create nothing; only the first writer job (under the OS lease)
/// migrates legacy hints and only then creates the app-local destination.
/// Legacy db/WAL stay byte-identical afterwards.
@Test func firstGUIOpenMigratesBeforeDestinationCreation() async throws {
    let (project, root) = try makeIndexerProject(files: ["data/raw/table.csv": genericCSV])
    defer { removeIndexerProject(root, project) }
    let legacyURL = ProjectIndexStore.legacyIndexURL(project: project)
    let fixture = try openLegacyIndexFixture(at: legacyURL, rows: 3)
    defer { sqlite3_close_v2(fixture) }
    let walURL = URL(fileURLWithPath: legacyURL.path + "-wal")
    let legacyBefore = indexerDigests([legacyURL, walURL])
    #expect(legacyBefore.count == 2)

    let destination = ProjectIndexStore.preferredDestinationURL(project: project)
    let store = try await ProjectIndexStore.open(project: project)
    let usage = try await store.usage()
    #expect(usage.legacyExists && !usage.destinationExists)
    #expect(usage.legacyURL.path == legacyURL.path)
    // Reads and restoration never create the destination.
    let source = try #require(try project.discoverSources().first)
    #expect(try await store.validatedInspection(for: source, project: project) == nil)
    #expect(!FileManager.default.fileExists(atPath: destination.path),
            "read-only seams must not create the destination")

    // The GUI's first focused index write outside a lease is refused: no
    // destination, no migration, no partial state.
    let first = try #require(
        await InstrumentReader.inspectMany([source], project: project, cache: nil).results.first)
    var refused = false
    do {
        try await store.record(first, source: source, project: project)
    } catch {
        refused = true
    }
    #expect(refused, "destination creation must require the writer lease")
    #expect(!FileManager.default.fileExists(atPath: destination.path))

    // First writer job under the lease: migration runs before creation.
    try await store.withWriterJob {
        try await store.record(first, source: source, project: project)
    }
    #expect(FileManager.default.fileExists(atPath: destination.path),
            "the writer job creates the destination after migration")
    let rows = indexRows(project)
    #expect(rows.count == 4, "3 imported legacy hints plus the recorded source: \(rows.keys.sorted())")
    guard let imported = rows["data/raw/legacy-hint-1.csv"] else {
        Issue.record("legacy hints must be imported into the app-local destination")
        return
    }
    #expect(imported.recordState == .advisoryHint, "imported rows stay advisory hints")
    #expect(imported.prefixSHA256 == nil, "imported hints carry no verified prefix")
    #expect(imported.readerVersion == "1.0.0", "the imported row keeps its legacy payload")
    #expect(rows["data/raw/table.csv"] != nil)
    let restored = try await store.validatedInspection(for: source, project: project)
    #expect(restored != nil, "post-migration restoration validates through the store")
    let legacyHintSource = RawSource(relativePath: "data/raw/legacy-hint-1.csv",
                                      url: root.appendingPathComponent("data/raw/legacy-hint-1.csv"),
                                      byteSize: 10)
    #expect(try await store.validatedInspection(for: legacyHintSource, project: project) == nil,
            "an unverifiable imported hint never restores an inspection")

    #expect(indexerDigests([legacyURL, walURL]) == legacyBefore,
            "legacy db/WAL must stay byte-identical after migration")
    #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: legacyURL.path + "-shm").path),
            "legacy SHM is preserved, never deleted")
}

/// Cold and warm runs over one fixed synthetic cohort must report identical
/// outcomes and counts. Timings are recorded as evidence only — no threshold.
@Test func coldAndWarmRunsReportOutcomeParity() async throws {
    let (project, root) = try makeIndexerProject(files: defaultCohort, withProfile: true)
    defer { removeIndexerProject(root, project) }

    let coldStart = Date()
    let cold = try await ProjectIndexer.run(project: project)
    let coldSeconds = Date().timeIntervalSince(coldStart)

    let warmStart = Date()
    let warm = try await ProjectIndexer.run(project: project)
    let warmSeconds = Date().timeIntervalSince(warmStart)

    #expect(cold.complete && warm.complete)
    #expect(cold == warm, "cold and warm runs must report identical outcomes")
    #expect(cold.discovered == 5 && cold.inspected == 5)
    #expect(cold.structuralCandidates == 2 && cold.deterministicBlocked == 1)
    print(String(format: "index parity cohort: cold %.3fs, warm %.3fs (revalidation included; no threshold asserted)",
                 coldSeconds, warmSeconds))
}

// MARK: - Fixture helpers

private func indexerDigests(_ urls: [URL]) -> [String: String] {
    var result: [String: String] = [:]
    for url in urls where FileManager.default.fileExists(atPath: url.path) {
        result[url.path] = sha256Hex((try? Data(contentsOf: url)) ?? Data())
    }
    return result
}

/// Legacy `data/.rawview/index.db` in WAL mode with committed rows, mirroring
/// the Task 3 fixture shape.
private func openLegacyIndexFixture(at url: URL, rows: Int) throws -> OpaquePointer {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
        throw CocoaError(.fileWriteUnknown)
    }
    func exec(_ sql: String) {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            preconditionFailure("legacy fixture SQL failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    exec("PRAGMA journal_mode = WAL;")
    exec("CREATE TABLE sources (relative_path TEXT PRIMARY KEY, mtime INTEGER NOT NULL, byte_size INTEGER NOT NULL, instrument_id TEXT, instrument_name TEXT, application_mode TEXT, device_id TEXT, timestamp TEXT, category TEXT, support_status TEXT NOT NULL, validation_state TEXT NOT NULL, reader_version TEXT NOT NULL, profile_id TEXT, profile_hash TEXT NOT NULL, error TEXT, prefix_sha256 TEXT, descriptor_size INTEGER, record_state TEXT NOT NULL DEFAULT 'advisory_hint');")
    exec("CREATE TABLE index_metadata (id INTEGER PRIMARY KEY CHECK (id = 0), schema_version INTEGER NOT NULL, project_identity TEXT NOT NULL, data_root TEXT NOT NULL, reader_version TEXT NOT NULL, catalog_fingerprint TEXT NOT NULL);")
    exec("BEGIN TRANSACTION;")
    for index in 1...rows {
        exec("INSERT INTO sources (relative_path, mtime, byte_size, support_status, validation_state, reader_version, profile_hash) VALUES ('data/raw/legacy-hint-\(index).csv', \(index), 10, 'supported', 'profile valid; source not loaded', '1.0.0', 'legacy');")
    }
    exec("COMMIT;")
    return db
}
