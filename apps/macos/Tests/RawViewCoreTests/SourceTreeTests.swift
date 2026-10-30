import Foundation
import Testing
@testable import RawViewCore

// MARK: - Task 2 fixtures (synthetic only)

private func makeTempProject(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("rawview-t2-\(label)-\(UUID().uuidString)")
}

private func write(_ root: URL, _ relativePath: String, _ text: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func metadataIssuePaths(_ issues: [InventoryIssue]) -> [String] {
    issues.compactMap { issue in
        if case .metadata(let path, _) = issue { return path }
        return nil
    }
}

// MARK: - Required Task 2 tests

@Test func configuredRootWorksAcrossLoadInspectCacheAndManifest() async throws {
    let root = makeTempProject("configured")
    defer { try? FileManager.default.removeItem(at: root) }
    try ProjectSettingsStore.save(ProjectSettings(dataRoot: "measurements", defaultView: "tree"), projectRoot: root)
    try write(root, "measurements/batch/a.csv", Fixtures.dualSweepCSV)
    try write(root, "data/instruments/keysight-b1500a.yaml", Fixtures.keysightProfile)
    try write(root, "study/study.yaml", "study_id: configured-study\nsources:\n  - path: measurements/batch/a.csv\n")
    let csvURL = root.appendingPathComponent("measurements/batch/a.csv")
    let bytesBefore = try Data(contentsOf: csvURL)
    let mtimeBefore = try FileManager.default.attributesOfItem(atPath: csvURL.path)[.modificationDate] as? Date

    let project = try ProjectContext.open(root)
    #expect(project.dataRootRelativePath == "measurements")
    #expect(project.rawRoot.path.hasSuffix("/measurements"))

    // Discovery keeps project-relative identity under the configured root.
    let inventory = try await project.discoverInventoryAsync()
    #expect(inventory.issues.isEmpty)
    #expect(inventory.isComplete)
    #expect(inventory.sources.map(\.relativePath) == ["measurements/batch/a.csv"])
    #expect(inventory.directoryPaths == ["measurements/batch"])
    let source = try #require(inventory.sources.first)
    #expect(project.sourceRelativePath(of: source.url) == "measurements/batch/a.csv")

    // Load and inspection honor the configured root.
    let measurement = try await InstrumentReader.load(source.url, project: project)
    #expect(measurement.source.path == "measurements/batch/a.csv")
    #expect(measurement.instrument.id == "keysight-b1500a")
    let report = await InstrumentReader.inspectMany(inventory.sources, project: project)
    #expect(report.results.first?.inspection?.instrumentID == "keysight-b1500a")

    // Private cache works under the configured root and round-trips.
    let cache = MeasurementCache(project: project)
    let catalog = ProfileCatalog.load(project: project)
    _ = try await InstrumentReader.load(source.url, project: project, cache: cache)
    let cached = try #require(try cache.measurement(for: source, project: project, profileFingerprint: catalog.fingerprint))
    #expect(cached.source.path == "measurements/batch/a.csv")
    let producerCalls = VisitCounter()
    let producer: @Sendable (Data, Int64, URL) async throws -> MeasurementCache.CachedInspection = { _, _, _ in
        producerCalls.increment()
        return .blocked("synthetic")
    }
    let first = try await cache.inspection(for: source, project: project,
                                           catalogFingerprint: catalog.fingerprint, producer: producer)
    #expect(first.fromCache == false)
    let second = try await cache.inspection(for: source, project: project,
                                            catalogFingerprint: catalog.fingerprint, producer: producer)
    #expect(second.fromCache == true)
    #expect(producerCalls.count == 1)

    // Manifest discovery outside the configured root keeps exact membership.
    let index = ManifestIndex.load(project: project)
    #expect(index.issues.isEmpty)
    #expect(index.manifests.count == 1)
    #expect(index.manifests.first?.members == ["measurements/batch/a.csv"])

    // Raw fixture bytes and mtime are unchanged by the whole round trip.
    let bytesAfter = try Data(contentsOf: csvURL)
    let mtimeAfter = try FileManager.default.attributesOfItem(atPath: csvURL.path)[.modificationDate] as? Date
    #expect(bytesAfter == bytesBefore)
    #expect(mtimeAfter == mtimeBefore)
}

@Test func treePreservesIntermediateAndEmptyFolders() async throws {
    let root = makeTempProject("tree")
    defer { try? FileManager.default.removeItem(at: root) }
    try ProjectSettingsStore.save(ProjectSettings(dataRoot: "measurements", defaultView: "tree"), projectRoot: root)
    try write(root, "measurements/batch/nested/a.csv", "synthetic")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("measurements/empty"),
                                            withIntermediateDirectories: true)

    let project = try ProjectContext.open(root)
    let inventory = try await project.discoverInventoryAsync()
    #expect(inventory.issues.isEmpty)
    #expect(inventory.directoryPaths == [
        "measurements/batch", "measurements/batch/nested", "measurements/empty"
    ])
    let tree = SourceTree(inventory: inventory, project: project)
    #expect(tree.root.id == "directory:measurements")
    #expect(tree.root.name == "measurements")
    #expect(tree.root.sourceID == nil)
    let batch = try #require(tree.root.children.first { $0.name == "batch" })
    let nested = try #require(batch.children.first { $0.name == "nested" })
    #expect(nested.children.map(\.id) == ["source:measurements/batch/nested/a.csv"])
    let empty = try #require(tree.root.children.first { $0.name == "empty" })
    #expect(empty.id == "directory:measurements/empty")
    #expect(empty.children.isEmpty)
}

@Test func treeIDsSeparateDirectoryAndSource() async throws {
    let root = makeTempProject("ids")
    defer { try? FileManager.default.removeItem(at: root) }
    try ProjectSettingsStore.save(ProjectSettings(dataRoot: "measurements", defaultView: "tree"), projectRoot: root)
    try write(root, "measurements/batch/a.csv", "synthetic")

    let project = try ProjectContext.open(root)
    let inventory = try await project.discoverInventoryAsync()
    let tree = SourceTree(inventory: inventory, project: project)
    var directoryIDs: [String] = []
    var sourceIDs: [String] = []
    var fileNodes: [SourceTreeNode] = []
    func walk(_ node: SourceTreeNode) {
        if let sourceID = node.sourceID {
            sourceIDs.append(node.id)
            if sourceID == "measurements/batch/a.csv" { fileNodes.append(node) }
        } else {
            directoryIDs.append(node.id)
        }
        node.children.forEach(walk)
    }
    walk(tree.root)
    #expect(directoryIDs.allSatisfy { $0.hasPrefix("directory:") })
    #expect(sourceIDs.allSatisfy { $0.hasPrefix("source:") })
    #expect(Set(directoryIDs).isDisjoint(with: Set(sourceIDs)))
    #expect(directoryIDs.contains("directory:measurements"))
    #expect(directoryIDs.contains("directory:measurements/batch"))
    #expect(sourceIDs == ["source:measurements/batch/a.csv"])
    let file = try #require(fileNodes.first)
    #expect(file.name == "a.csv")
    #expect(file.sourceID == "measurements/batch/a.csv")
    #expect(file.children.isEmpty)
}

@Test func dotRootExcludesViewerMetadataAndSnapshots() async throws {
    let root = makeTempProject("dot")
    defer { try? FileManager.default.removeItem(at: root) }
    try ProjectSettingsStore.save(ProjectSettings(dataRoot: ".", defaultView: "tree"), projectRoot: root)
    try write(root, ".rawviewer/evil.csv", "viewer metadata")
    try write(root, "data/.rawview/legacy.csv", "legacy index")
    try write(root, "data/snapshot/export.csv", "snapshot export")
    try write(root, "data/raw/ok.csv", "synthetic")
    try write(root, "run.csv", "synthetic")
    try write(root, "notes/study.csv", "synthetic")

    let project = try ProjectContext.open(root)
    #expect(project.dataRootRelativePath == ".")
    let inventory = try await project.discoverInventoryAsync()
    #expect(inventory.issues.isEmpty)
    #expect(inventory.sources.map(\.relativePath) == ["data/raw/ok.csv", "notes/study.csv", "run.csv"])
    #expect(inventory.directoryPaths == ["data", "data/raw", "notes"])
    let tree = SourceTree(inventory: inventory, project: project)
    #expect(tree.root.id == "directory:.")
    #expect(tree.root.name == root.lastPathComponent)

    // Dot root has no metadata subtree outside raw data: no manifests, and an
    // explicit diagnostic instead of scanning every project YAML file.
    let index = ManifestIndex.load(project: project)
    #expect(index.manifests.isEmpty)
    #expect(index.issues.contains {
        $0.contains("data root \".\"") && $0.contains("no study manifests")
    })
}

@Test func nestedDataRawMarkerNoLongerPrunesSelectedData() async throws {
    let root = makeTempProject("marker")
    defer { try? FileManager.default.removeItem(at: root) }
    try write(root, "data/raw/top.csv", "synthetic")
    try write(root, "data/raw/inner/data/raw/deep.csv", "synthetic")

    let project = try ProjectContext.open(root)
    #expect(project.dataRootRelativePath == "data/raw")
    let inventory = try await project.discoverInventoryAsync()
    #expect(inventory.issues.isEmpty)
    // A real directory inside the selected data root is part of the tree, even
    // when it carries its own descendant data/raw marker.
    #expect(inventory.sources.map(\.relativePath) == [
        "data/raw/inner/data/raw/deep.csv", "data/raw/top.csv"
    ])
    #expect(inventory.directoryPaths.contains("data/raw/inner"))
    #expect(inventory.directoryPaths.contains("data/raw/inner/data/raw"))
    let tree = SourceTree(inventory: inventory, project: project)
    let inner = try #require(tree.root.children.first { $0.name == "inner" })
    let nestedData = try #require(inner.children.first { $0.name == "data" })
    let nestedRaw = try #require(nestedData.children.first { $0.name == "raw" })
    #expect(nestedRaw.children.map(\.sourceID) == ["data/raw/inner/data/raw/deep.csv"])
}

@Test func rootSwitchDoesNotReuseDerivedNamespace() async throws {
    let root = makeTempProject("switch")
    defer { try? FileManager.default.removeItem(at: root) }
    try write(root, "data/raw/a.csv", Fixtures.dualSweepCSV)
    let contained = try ProjectContext.open(root, dataRootRelativePath: "data/raw")
    let dot = try ProjectContext.open(root, dataRootRelativePath: ".")
    let url = root.resolvingSymlinksInPath().standardizedFileURL
        .appendingPathComponent("data/raw/a.csv")
    // Both roots claim the identical project-relative identity for the same
    // file, so only a root-aware derived namespace can tell them apart.
    #expect(contained.sourceRelativePath(of: url) == "data/raw/a.csv")
    #expect(dot.sourceRelativePath(of: url) == "data/raw/a.csv")
    let source = RawSource(relativePath: "data/raw/a.csv", url: url, byteSize: 64)

    let cache = MeasurementCache(project: contained)
    let calls = VisitCounter()
    let producer: @Sendable (Data, Int64, URL) async throws -> MeasurementCache.CachedInspection = { _, _, _ in
        calls.increment()
        return .blocked("synthetic")
    }
    let fingerprint = "fp-root-switch"
    let underContained = try await cache.inspection(for: source, project: contained,
                                                    catalogFingerprint: fingerprint, producer: producer)
    #expect(underContained.fromCache == false)
    let underDot = try await cache.inspection(for: source, project: dot,
                                              catalogFingerprint: fingerprint, producer: producer)
    #expect(underDot.fromCache == false, "a root switch reused the previous root's derived cache namespace")
    #expect(calls.count == 2)
    let again = try await cache.inspection(for: source, project: contained,
                                           catalogFingerprint: fingerprint, producer: producer)
    #expect(again.fromCache == true)
    #expect(calls.count == 2)
}

@Test func partialDirectoryFailureKeepsSiblingsAndFailsCLICompleteness() async throws {
    let root = makeTempProject("partial")
    let locked = root.appendingPathComponent("data/raw/locked")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: root)
    }
    try write(root, "data/raw/ok1.csv", "synthetic")
    try write(root, "data/raw/ok2.csv", "synthetic")
    try write(root, "data/raw/locked/hidden.csv", "synthetic")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

    let project = try ProjectContext.open(root)
    // Partial I/O is reported, not thrown: cancellation stays a distinct path.
    let inventory = try await project.discoverInventoryAsync()
    #expect(inventory.sources.map(\.relativePath) == ["data/raw/ok1.csv", "data/raw/ok2.csv"])
    #expect(inventory.directoryPaths.contains("data/raw/locked"))
    #expect(!inventory.isComplete, "an enumeration failure must fail CLI completeness")
    #expect(!inventory.issues.isEmpty)
    #expect(inventory.issues.allSatisfy { issue in
        if case .enumeration(let path, _) = issue { return path == "data/raw/locked" }
        return false
    })
}

@Test func metadataReadFailureIsReported() async throws {
    let root = makeTempProject("metadata")
    defer { try? FileManager.default.removeItem(at: root) }
    try write(root, "data/raw/run.csv", "synthetic")
    try write(root, "data/raw/ghost-a.csv", "synthetic")
    try write(root, "data/raw/ghost-b.csv", "synthetic")
    let ghostA = root.appendingPathComponent("data/raw/ghost-a.csv")
    let ghostB = root.appendingPathComponent("data/raw/ghost-b.csv")
    let ghostPaths = ["data/raw/ghost-a.csv", "data/raw/ghost-b.csv"]

    let project = try ProjectContext.open(root)
    // The directory listing prefetches names; deleting the not-yet-visited
    // ghosts from the first file visit makes their metadata read fail while
    // enumeration itself succeeds.
    let visits = VisitCounter()
    let inventory = try await project.discoverInventoryAsync(onVisitFile: { _ in
        if visits.increment() == 1 {
            try? FileManager.default.removeItem(at: ghostA)
            try? FileManager.default.removeItem(at: ghostB)
        }
    })
    #expect(!inventory.isComplete)
    let metadataPaths = metadataIssuePaths(inventory.issues)
    #expect(!metadataPaths.isEmpty)
    #expect(metadataPaths.allSatisfy { ghostPaths.contains($0) })
    for path in metadataPaths {
        #expect(!inventory.sources.contains { $0.relativePath == path },
                "a source with failed metadata must not enter the inventory")
    }
    #expect(inventory.sources.contains { $0.relativePath == "data/raw/run.csv" })
}

@Test func customDataRootDataDoesNotInventorySnapshotOrLegacyIndex() async throws {
    let root = makeTempProject("customdata")
    defer { try? FileManager.default.removeItem(at: root) }
    try ProjectSettingsStore.save(ProjectSettings(dataRoot: "data", defaultView: "tree"), projectRoot: root)
    try write(root, "data/raw/a.csv", "synthetic")
    try write(root, "data/study/b.csv", "synthetic")
    try write(root, "data/snapshot/export.csv", "snapshot export")
    try write(root, "data/.rawview/legacy.csv", "legacy index")
    try write(root, "data/instruments/keysight-b1500a.yaml", Fixtures.keysightProfile)

    let project = try ProjectContext.open(root)
    #expect(project.dataRootRelativePath == "data")
    let inventory = try await project.discoverInventoryAsync()
    #expect(inventory.issues.isEmpty)
    #expect(inventory.sources.map(\.relativePath) == ["data/raw/a.csv", "data/study/b.csv"])
    #expect(inventory.directoryPaths == ["data/instruments", "data/raw", "data/study"])

    // Viewer metadata and snapshot namespaces can never be a configured root.
    for forbidden in ["data/snapshot", "data/snapshot/nested", "data/.rawview", ".rawviewer", ".rawviewer/setting"] {
        var saveRejected = false
        do {
            try ProjectSettingsStore.save(ProjectSettings(dataRoot: forbidden, defaultView: "tree"), projectRoot: root)
        } catch is ProjectSettingsError { saveRejected = true }
        #expect(saveRejected, "save accepted forbidden data root \(forbidden)")
        var openRejected = false
        do { _ = try ProjectContext.open(root, dataRootRelativePath: forbidden) } catch { openRejected = true }
        #expect(openRejected, "open accepted forbidden data root \(forbidden)")
    }
    let storedSettings = try ProjectSettingsStore.load(projectRoot: root)
    #expect(storedSettings?.dataRoot == "data")

    // A manifest inside the snapshot namespace is never discovered; a manifest
    // outside the configured data root keeps exact membership.
    try write(root, "data/snapshot/snap.yaml", "study_id: snapshot-study\nsources:\n  - path: data/raw/a.csv\n")
    try write(root, "study.yaml", "study_id: kept\nsources:\n  - path: data/raw/a.csv\n")
    let index = ManifestIndex.load(project: project)
    #expect(index.issues.isEmpty)
    #expect(index.manifests.map(\.relativePath) == ["study.yaml"])
    #expect(index.manifests.first?.members == ["data/raw/a.csv"])
}

@Test func fileMetadataFailureKeepsFollowingDirectorySources() async throws {
    let root = makeTempProject("filemeta")
    defer { try? FileManager.default.removeItem(at: root) }
    try write(root, "data/raw/trigger.csv", "synthetic")
    try write(root, "data/raw/zghost.csv", "synthetic")
    try write(root, "data/raw/kept/s1.csv", "synthetic")
    try write(root, "data/raw/kept/s2.csv", "synthetic")
    let ghost = root.appendingPathComponent("data/raw/zghost.csv")

    let project = try ProjectContext.open(root)
    // The first visited regular file deletes the not-yet-visited ghost, so its
    // metadata read fails while enumeration succeeds: a FILE metadata failure.
    let visits = VisitCounter()
    let inventory = try await project.discoverInventoryAsync(onVisitFile: { _ in
        if visits.increment() == 1 {
            try? FileManager.default.removeItem(at: ghost)
        }
    })
    #expect(inventory.issues.contains {
        if case .metadata(let path, _) = $0 { return path == "data/raw/zghost.csv" }
        return false
    }, "the file metadata failure was not recorded")
    #expect(!inventory.isComplete)
    // A file metadata failure must never prune traversal: the directory after
    // the failing FILE keeps its sources.
    #expect(inventory.sources.map(\.relativePath) == [
        "data/raw/kept/s1.csv", "data/raw/kept/s2.csv", "data/raw/trigger.csv"
    ], "a file metadata failure pruned the following directory: \(inventory.sources.map(\.relativePath))")
    #expect(inventory.directoryPaths.contains("data/raw/kept"))
}

// MARK: - Regressions under a configured root

@Test func configuredRootKeepsZeroOpenAndLinkRegressions() async throws {
    let root = makeTempProject("regress-links")
    defer { try? FileManager.default.removeItem(at: root) }
    try ProjectSettingsStore.save(ProjectSettings(dataRoot: "measurements", defaultView: "tree"), projectRoot: root)
    try write(root, "measurements/batch/a.csv", Fixtures.dualSweepCSV)
    try write(root, "measurements/skip.SPE", "prohibited")
    try write(root, "measurements/skip.affm", "prohibited")
    try write(root, "measurements/inside-target.csv", Fixtures.dualSweepCSV)
    try write(root, "outside.csv", "outside data")
    let rawRoot = root.appendingPathComponent("measurements")
    try FileManager.default.createSymbolicLink(at: rawRoot.appendingPathComponent("escape.csv"),
                                               withDestinationURL: root.appendingPathComponent("outside.csv"))
    let speURL = rawRoot.appendingPathComponent("skip.SPE")
    let speBytes = try Data(contentsOf: speURL)
    let speMtime = try FileManager.default.attributesOfItem(atPath: speURL.path)[.modificationDate] as? Date

    let project = try ProjectContext.open(root)
    let inventory = try await project.discoverInventoryAsync()
    #expect(inventory.sources.map(\.relativePath) == [
        "measurements/batch/a.csv", "measurements/escape.csv", "measurements/inside-target.csv"
    ])
    #expect(inventory.sources.first { $0.relativePath == "measurements/escape.csv" }?.byteSize == 0)

    // .spe/.affm zero-open: rejected from the claimed name alone; bytes and
    // mtime stay untouched.
    do {
        _ = try await InstrumentReader.load(speURL, project: project)
        Issue.record(".spe source was opened")
    } catch {
        #expect(error.localizedDescription.contains("skips .spe and .affm"))
    }
    let speBytesAfter = try Data(contentsOf: speURL)
    let speMtimeAfter = try FileManager.default.attributesOfItem(atPath: speURL.path)[.modificationDate] as? Date
    #expect(speBytesAfter == speBytes)
    #expect(speMtimeAfter == speMtime)

    // An outside link reports an outside diagnostic naming the configured root.
    let report = await InstrumentReader.inspectMany(inventory.sources, project: project)
    let escape = try #require(report.results.first { $0.id == "measurements/escape.csv" })
    #expect(escape.inspection == nil)
    #expect(escape.error?.contains("outside") == true)
    #expect(escape.error?.contains("data root (\"measurements\")") == true)

    // A link swapped in after discovery fails closed without reading the target.
    let swapped = rawRoot.appendingPathComponent("inside-target.csv")
    try FileManager.default.removeItem(at: swapped)
    try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: rawRoot.appendingPathComponent("batch/a.csv"))
    do {
        _ = try await InstrumentReader.load(swapped, project: project)
        Issue.record("swapped-in symlink was opened")
    } catch {
        #expect(error.localizedDescription.contains("symlink"))
        #expect(error.localizedDescription.contains("never followed"))
    }
    let outsideTarget = try Data(contentsOf: root.appendingPathComponent("outside.csv"))
    #expect(outsideTarget == Data("outside data".utf8))
}

@Test func sessionStateRejectsStaleWorkAfterRootChange() {
    var state = ProjectSessionState()
    let first = state.beginRootChange()
    #expect(state.accepts(generation: first))
    state.selectedSourceIDs.insert("measurements/batch/a.csv")
    state.expandedDirectoryIDs.insert("directory:measurements/batch")
    let second = state.beginRootChange()
    #expect(second == first + 1)
    #expect(state.selectedSourceIDs.isEmpty)
    #expect(state.expandedDirectoryIDs.isEmpty)
    #expect(!state.accepts(generation: first), "a superseded root generation must be rejected")
    #expect(state.accepts(generation: second))
}
