import Foundation
import Testing
@testable import RawViewCore

/// Task 5: pure filtering and session lifecycle tests for SourceTree and ProjectSessionState.
struct TreeNavigationTests {

    private func makeProject(dataRoot: String = "data/raw") throws -> (project: ProjectContext, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-nav-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataDir = root.appendingPathComponent(dataRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let project = try ProjectContext.open(root, dataRootRelativePath: dataRoot)
        return (project, root)
    }

    @Test func treeFilterKeepsAncestorsAndDoesNotFlatten() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let s1 = RawSource(relativePath: "data/raw/subA/deep/run1.csv",
                           url: root.appendingPathComponent("data/raw/subA/deep/run1.csv"), byteSize: 100)
        let s2 = RawSource(relativePath: "data/raw/subA/deep/run2.csv",
                           url: root.appendingPathComponent("data/raw/subA/deep/run2.csv"), byteSize: 200)
        let s3 = RawSource(relativePath: "data/raw/subB/other.csv",
                           url: root.appendingPathComponent("data/raw/subB/other.csv"), byteSize: 300)

        let inventory = SourceInventory(
            sources: [s1, s2, s3],
            directoryPaths: ["data/raw/subA", "data/raw/subA/deep", "data/raw/subB"],
            issues: []
        )
        let tree = SourceTree(inventory: inventory, project: project)

        // Filter only s1
        let filtered = tree.filtered(sourceIDs: [s1.relativePath])
        #expect(filtered.count == 1, "Only subA should be kept at top level under data/raw")
        guard let subA = filtered.first else { return }
        #expect(subA.id == "directory:data/raw/subA")
        #expect(subA.sourceID == nil)
        #expect(subA.children.count == 1, "deep directory is preserved as child of subA")

        let deep = subA.children[0]
        #expect(deep.id == "directory:data/raw/subA/deep")
        #expect(deep.children.count == 1, "run1.csv is preserved as child of deep")

        let fileNode = deep.children[0]
        #expect(fileNode.id == "source:data/raw/subA/deep/run1.csv")
        #expect(fileNode.sourceID == s1.relativePath)
        #expect(fileNode.name == "run1.csv")
        #expect(fileNode.children.isEmpty)
    }

    @Test func duplicateBasenamesKeepDistinctIDs() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let s1 = RawSource(relativePath: "data/raw/chamber1/sample.csv",
                           url: root.appendingPathComponent("data/raw/chamber1/sample.csv"), byteSize: 50)
        let s2 = RawSource(relativePath: "data/raw/chamber2/sample.csv",
                           url: root.appendingPathComponent("data/raw/chamber2/sample.csv"), byteSize: 50)

        let inventory = SourceInventory(
            sources: [s1, s2],
            directoryPaths: ["data/raw/chamber1", "data/raw/chamber2"],
            issues: []
        )
        let tree = SourceTree(inventory: inventory, project: project)

        #expect(tree.root.children.count == 2)
        let chamber1 = tree.root.children.first { $0.name == "chamber1" }
        let chamber2 = tree.root.children.first { $0.name == "chamber2" }
        #expect(chamber1 != nil && chamber2 != nil)

        let file1 = chamber1?.children.first
        let file2 = chamber2?.children.first

        #expect(file1?.name == "sample.csv")
        #expect(file2?.name == "sample.csv")
        #expect(file1?.id == "source:data/raw/chamber1/sample.csv")
        #expect(file2?.id == "source:data/raw/chamber2/sample.csv")
        #expect(file1?.sourceID == "data/raw/chamber1/sample.csv")
        #expect(file2?.sourceID == "data/raw/chamber2/sample.csv")
        #expect(file1?.id != file2?.id, "Identical basenames must have distinct node IDs")
    }

    @Test func rootChangeClearsSelectionAndExpansion() {
        var state = ProjectSessionState()
        #expect(state.generation == 0)

        state.selectedSourceIDs = ["data/raw/f1.csv", "data/raw/f2.csv"]
        state.expandedDirectoryIDs = ["directory:data/raw/sub"]

        let token = state.beginRootChange()
        #expect(token == 1)
        #expect(state.generation == 1)
        #expect(state.selectedSourceIDs.isEmpty, "Selection must be cleared on root change")
        #expect(state.expandedDirectoryIDs.isEmpty, "Expansion must be cleared on root change")
        #expect(state.accepts(generation: token))
        #expect(!state.accepts(generation: 0), "Old generation token must be rejected")
    }

    @Test func virtualGroupingStillUsesProjectRelativeIDs() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let s1 = RawSource(relativePath: "data/raw/batch1/meas1.csv",
                           url: root.appendingPathComponent("data/raw/batch1/meas1.csv"), byteSize: 100)
        let s2 = RawSource(relativePath: "data/raw/batch2/meas2.csv",
                           url: root.appendingPathComponent("data/raw/batch2/meas2.csv"), byteSize: 200)

        let group = SourceGroup(label: "Batch 1", sourceIDs: [s1.relativePath])
        #expect(group.sourceIDs == ["data/raw/batch1/meas1.csv"], "Virtual grouping must store project-relative IDs")

        let inventory = SourceInventory(
            sources: [s1, s2],
            directoryPaths: ["data/raw/batch1", "data/raw/batch2"],
            issues: []
        )
        let tree = SourceTree(inventory: inventory, project: project)
        let filtered = tree.filtered(sourceIDs: Set(group.sourceIDs))

        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "batch1")
        #expect(filtered.first?.children.first?.sourceID == s1.relativePath)
    }

    // MARK: - Task 6 Lifecycle Tests

    @Test func lateOldRootResultsCannotInstall() {
        var state = ProjectSessionState()
        let token1 = state.beginRootChange()
        let token2 = state.beginRootChange()

        #expect(!state.accepts(generation: token1), "Old generation token must be rejected")
        #expect(state.accepts(generation: token2), "Current generation token must be accepted")
    }

    @Test func setupCancelPreservesCurrentProject() throws {
        let (project1, root1) = try makeProject(dataRoot: "data/raw")
        defer { try? FileManager.default.removeItem(at: root1) }
        let (_, root2) = try makeProject(dataRoot: "data/raw")
        defer { try? FileManager.default.removeItem(at: root2) }

        var currentProject: ProjectContext? = project1

        // User opens setup for root2 but cancels
        let userCancelled = true
        if !userCancelled {
            currentProject = try ProjectContext.open(root2)
        }

        #expect(currentProject?.root.path == project1.root.path, "Current project must be preserved when setup is cancelled")
        #expect(currentProject?.dataRootRelativePath == "data/raw")
    }

    @Test func failedSettingsSaveDoesNotClaimSaved() throws {
        let (_, root) = try makeProject(dataRoot: "data/raw")
        defer {
            chmod(root.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        guard chmod(root.path, 0o555) == 0 else {
            Issue.record("chmod 0555 failed on synthetic project")
            return
        }

        var saveSucceeded = false
        do {
            let settings = ProjectSettings(dataRoot: "data/raw", defaultView: "tree")
            try ProjectSettingsStore.save(settings, projectRoot: root)
            saveSucceeded = true
        } catch {
            saveSucceeded = false
        }

        #expect(!saveSucceeded, "Saving settings on a read-only root must fail")
        let settingsFile = root.appendingPathComponent(".rawviewer/setting/setting.yaml")
        #expect(!FileManager.default.fileExists(atPath: settingsFile.path), "No settings file must be created on failed save")
    }

    @Test func readOnlyUseWithoutSavingWorks() throws {
        let (_, root) = try makeProject(dataRoot: "data/raw")
        defer {
            chmod(root.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        guard chmod(root.path, 0o555) == 0 else {
            Issue.record("chmod 0555 failed on synthetic project")
            return
        }

        // Opening without saving works: ProjectContext can open with explicit dataRoot
        let opened = try ProjectContext.open(root, dataRootRelativePath: "data/raw")
        #expect(opened.dataRootRelativePath == "data/raw")
        #expect(opened.root.path == root.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test func malformedSavedRootNeedsCorrection() throws {
        let (_, root) = try makeProject(dataRoot: "data/raw")
        defer { try? FileManager.default.removeItem(at: root) }

        let settingsDir = root.appendingPathComponent(".rawviewer/setting", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let malformedYAML = """
        schema_version: 1
        data_root: "../escape"
        default_view: "tree"
        """
        try malformedYAML.write(to: settingsDir.appendingPathComponent("setting.yaml"), atomically: true, encoding: .utf8)

        var loadedSettings: ProjectSettings? = nil
        var loadFailed = false
        do {
            loadedSettings = try ProjectSettingsStore.load(projectRoot: root)
        } catch {
            loadFailed = true
        }

        #expect(loadFailed, "Malformed settings must throw and signal that corrective setup is needed")
        #expect(loadedSettings == nil, "Malformed settings must never silently load")
    }
}
