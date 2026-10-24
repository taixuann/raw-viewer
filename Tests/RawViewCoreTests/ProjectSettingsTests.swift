import Foundation
import Testing
@testable import RawViewCore

/// Task 1: portable project settings and the contained data-root contract.
/// Synthetic fixtures only; every project root lives under the system
/// temporary directory and is removed after the test.
private func makeSettingsProject(_ files: [String: String] = [:]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (relativePath, body) in files {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
    }
    return root
}

private let validSettingsYAML = "schema_version: 1\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\n"

@Test func settingsRoundTripIsProjectRelative() throws {
    let root = try makeSettingsProject(["measurements/batch/a.csv": "synthetic"])
    defer { try? FileManager.default.removeItem(at: root) }

    let settings = ProjectSettings(dataRoot: "measurements", defaultView: "tree")
    try ProjectSettingsStore.save(settings, projectRoot: root)

    let file = ProjectSettingsStore.settingsURL(projectRoot: root)
    #expect(file.path.hasSuffix(ProjectSettingsStore.relativePath))
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text == "schema_version: 3\ndata_root: \"measurements\"\ndefault_view: \"tree\"\ndefault_preset: \"nature-single\"\ndeveloper_mode: false\nexplorer_views: []\n",
            "exact schema v3 YAML changed: \(text)")
    #expect(!text.contains(root.path), "settings must never store the absolute project directory")
    #expect(try ProjectSettingsStore.load(projectRoot: root) == settings)

    // The project root itself is a valid data root and round-trips unchanged.
    let dot = ProjectSettings(dataRoot: ".", defaultView: "tree")
    try ProjectSettingsStore.save(dot, projectRoot: root)
    #expect(try ProjectSettingsStore.load(projectRoot: root) == dot)
}

@Test func missingSettingsIsNotMalformedSettings() throws {
    let fresh = try makeSettingsProject(["data/raw/a.csv": "synthetic"])
    defer { try? FileManager.default.removeItem(at: fresh) }

    // Proven absent (ENOENT) is nil, not an error, and the compatibility open
    // keeps its legacy data/raw default.
    #expect(try ProjectSettingsStore.load(projectRoot: fresh) == nil)
    let legacy = try ProjectContext.open(fresh)
    #expect(legacy.dataRootRelativePath == "data/raw")
    #expect(legacy.rawRoot.path.hasSuffix("/data/raw"))

    // Corrupt settings throw — never a silent legacy fallback, even in a
    // project that also lacks data/raw.
    let corrupt = try makeSettingsProject([".rawviewer/setting/setting.yaml":
        "schema_version: 99\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\n"])
    defer { try? FileManager.default.removeItem(at: corrupt) }
    #expect(throws: ProjectSettingsError.self) { try ProjectSettingsStore.load(projectRoot: corrupt) }
    #expect(throws: ProjectSettingsError.self) { try ProjectContext.open(corrupt) }
}

@Test func settingsRejectUnknownVersionKeysAndParentPaths() throws {
    func expectReject(_ yaml: String, _ comment: String) throws {
        let root = try makeSettingsProject([".rawviewer/setting/setting.yaml": yaml])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ProjectSettingsError.self, "\(comment) was accepted") {
            try ProjectSettingsStore.load(projectRoot: root)
        }
    }
    let head = "data_root: \"data/raw\"\ndefault_view: \"tree\"\n"
    try expectReject("schema_version: 4\n" + head, "schema_version 4")
    try expectReject("schema_version: 1\n" + head + "extra: 1\n", "unknown key")
    try expectReject("schema_version: 1\ndata_root: \"a\"\ndata_root: \"b\"\ndefault_view: \"tree\"\n", "duplicate key")
    for badRoot in ["/abs", "../outside", "data/../../x", "data/./raw", "data/raw/", "~", "data\"raw", "data\\raw"] {
        try expectReject("schema_version: 1\ndata_root: \"\(badRoot)\"\ndefault_view: \"tree\"\n", "data_root \(badRoot)")
    }
    try expectReject("schema_version: 1\ndata_root: \"data/raw\"\ndefault_view: \"list\"\n", "unknown default_view")

    // 64 KiB UTF-8 cap: a comment-padded file under the cap loads; over the
    // cap it is rejected even when its schema fields are valid.
    let root = try makeSettingsProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let pad = "# " + String(repeating: "p", count: 97) + "\n"
    let under = validSettingsYAML + String(repeating: pad, count: 600)
    #expect(Data(under.utf8).count <= ProjectSettingsStore.maximumFileBytes)
    try writeSettingsFile(root, under)
    #expect(try ProjectSettingsStore.load(projectRoot: root) == ProjectSettings(dataRoot: "data/raw", defaultView: "tree"))
    let over = validSettingsYAML + String(repeating: pad, count: 700)
    #expect(Data(over.utf8).count > ProjectSettingsStore.maximumFileBytes)
    try writeSettingsFile(root, over)
    #expect(throws: ProjectSettingsError.self) { try ProjectSettingsStore.load(projectRoot: root) }

    // Save validates before touching the project: an escaping data root is
    // rejected and no settings file appears.
    #expect(throws: ProjectSettingsError.self) {
        try ProjectSettingsStore.save(ProjectSettings(dataRoot: "../escape", defaultView: "tree"), projectRoot: root)
    }
    // A backslash would be re-read as a YAML escape sequence (a different
    // value than the one stored), so saving it must fail before any write.
    #expect(throws: ProjectSettingsError.self) {
        try ProjectSettingsStore.save(ProjectSettings(dataRoot: "data\\raw", defaultView: "tree"), projectRoot: root)
    }
}

@Test func settingsRejectSymlinkNamespaceAndRoot() throws {
    let fm = FileManager.default

    // Symlinked settings namespace: load and save both refuse, and the
    // refused save leaves the symlink target untouched.
    let namespace = try makeSettingsProject()
    defer { try? fm.removeItem(at: namespace) }
    let outside = try makeSettingsProject(["setting.yaml": validSettingsYAML, "setting/setting.yaml": validSettingsYAML])
    defer { try? fm.removeItem(at: outside) }
    try fm.createSymbolicLink(at: namespace.appendingPathComponent(".rawviewer"), withDestinationURL: outside)
    #expect(throws: ProjectSettingsError.self) { try ProjectSettingsStore.load(projectRoot: namespace) }
    #expect(throws: ProjectSettingsError.self) {
        try ProjectSettingsStore.save(ProjectSettings(dataRoot: "data/raw", defaultView: "tree"), projectRoot: namespace)
    }
    #expect(try String(contentsOf: outside.appendingPathComponent("setting.yaml"), encoding: .utf8) == validSettingsYAML)

    // Symlinked settings file: load refuses to follow it; save refuses to
    // replace it.
    let fileLink = try makeSettingsProject([".rawviewer/placeholder": "x", "real.yaml": validSettingsYAML])
    defer { try? fm.removeItem(at: fileLink) }
    try fm.createSymbolicLink(at: ProjectSettingsStore.settingsURL(projectRoot: fileLink),
                              withDestinationURL: fileLink.appendingPathComponent("real.yaml"))
    #expect(throws: ProjectSettingsError.self) { try ProjectSettingsStore.load(projectRoot: fileLink) }
    #expect(throws: ProjectSettingsError.self) {
        try ProjectSettingsStore.save(ProjectSettings(dataRoot: "data/raw", defaultView: "tree"), projectRoot: fileLink)
    }

    // Symlinked configured-root component: open rejects instead of following,
    // both with saved settings and with an explicit relative path.
    let rootLink = try makeSettingsProject([".rawviewer/setting/setting.yaml": validSettingsYAML,
                                            "real-raw/a.csv": "synthetic"])
    defer { try? fm.removeItem(at: rootLink) }
    try fm.createSymbolicLink(at: rootLink.appendingPathComponent("data"),
                              withDestinationURL: rootLink.appendingPathComponent("real-raw"))
    #expect(throws: ReaderError.self) { try ProjectContext.open(rootLink) }
    #expect(throws: ReaderError.self) { try ProjectContext.open(rootLink, dataRootRelativePath: "data/raw") }
}

@Test func projectMovePreservesDataRoot() throws {
    let fm = FileManager.default
    let a = try makeSettingsProject([
        ".rawviewer/setting/setting.yaml": "schema_version: 1\ndata_root: \"measurements\"\ndefault_view: \"tree\"\n",
        "measurements/batch/a.csv": "synthetic,measurement",
    ])
    defer { try? fm.removeItem(at: a) }
    let b = fm.temporaryDirectory.appendingPathComponent("rawview-settings-moved-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: b) }

    let original = a.appendingPathComponent("measurements/batch/a.csv")
    let bytesBefore = try Data(contentsOf: original)
    let mtimeBefore = try fm.attributesOfItem(atPath: original.path)[.modificationDate] as? Date

    let openedA = try ProjectContext.open(a)
    #expect(openedA.dataRootRelativePath == "measurements")
    #expect(openedA.rawRoot.path.hasSuffix("/measurements"))
    let sourcesA = try openedA.discoverSources()
    #expect(sourcesA.map(\.relativePath) == ["measurements/batch/a.csv"])
    #expect(openedA.sourceRelativePath(of: sourcesA[0].url) == "measurements/batch/a.csv")
    #expect(openedA.sourceRelativePath(of: a.appendingPathComponent("outside.csv")) == nil)

    // Move the whole project directory: settings, relative data root, and
    // source identities all survive; raw bytes and mtime are unchanged.
    try fm.moveItem(at: a, to: b)
    let openedB = try ProjectContext.open(b)
    #expect(openedB.dataRootRelativePath == "measurements")
    #expect(try ProjectSettingsStore.load(projectRoot: b) == ProjectSettings(dataRoot: "measurements", defaultView: "tree"))
    #expect(try openedB.discoverSources().map(\.relativePath) == ["measurements/batch/a.csv"])
    let moved = b.appendingPathComponent("measurements/batch/a.csv")
    #expect(try Data(contentsOf: moved) == bytesBefore)
    let mtimeAfter = try fm.attributesOfItem(atPath: moved.path)[.modificationDate] as? Date
    #expect(mtimeAfter == mtimeBefore)
}

private func writeSettingsFile(_ root: URL, _ yaml: String) throws {
    let url = root.appendingPathComponent(".rawviewer/setting/setting.yaml")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(yaml.utf8).write(to: url)
}

// MARK: - Task 6: schema v3 developer_mode + explorer_views preservation.

private let v3SettingsYAML = """
schema_version: 3
data_root: "data/raw"
default_view: "tree"
default_preset: "nature-single"
developer_mode: true
explorer_views:
  - grammar_id: "standard-scientific"
    variable: "study"
  - grammar_id: "standard-scientific"
    variable: "device-id"
"""

@Test func settingsV3RoundTripDeveloperModeAndExplorerViews() throws {
    let root = try makeSettingsProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = ProjectSettings(
        dataRoot: "data/raw", defaultView: "tree", defaultPreset: "nature-single",
        developerMode: true,
        explorerViews: [
            ExplorerViewDefinition(grammarID: "standard-scientific", variable: "study"),
            ExplorerViewDefinition(grammarID: "standard-scientific", variable: "device-id"),
        ])
    try ProjectSettingsStore.save(settings, projectRoot: root)
    let text = try String(contentsOf: ProjectSettingsStore.settingsURL(projectRoot: root), encoding: .utf8)
    #expect(text == v3SettingsYAML + "\n", "exact schema v3 YAML changed: \(text)")
    #expect(try ProjectSettingsStore.load(projectRoot: root) == settings)
}

@Test func settingsV3EmptyViewsRoundTrip() throws {
    let root = try makeSettingsProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = ProjectSettings(dataRoot: "data/raw")
    try ProjectSettingsStore.save(settings, projectRoot: root)
    let text = try String(contentsOf: ProjectSettingsStore.settingsURL(projectRoot: root), encoding: .utf8)
    #expect(text.contains("schema_version: 3\n"), "new settings must be schema v3: \(text)")
    #expect(text.contains("developer_mode: false\n"), "developer_mode must persist explicitly: \(text)")
    #expect(try ProjectSettingsStore.load(projectRoot: root) == settings)
}

@Test func legacySettingsDefaultToDeveloperOffAndNoViews() throws {
    for yaml in [
        "schema_version: 1\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\n",
        "schema_version: 2\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\ndefault_preset: \"nature-single\"\n",
    ] {
        let root = try makeSettingsProject([".rawviewer/setting/setting.yaml": yaml])
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try ProjectSettingsStore.load(projectRoot: root)
        #expect(loaded?.developerMode == false)
        #expect(loaded?.explorerViews == [])
    }
}

@Test func settingsRejectExplorerViewsOutsideV3AndBadReferences() throws {
    func expectReject(_ yaml: String, _ comment: String) throws {
        let root = try makeSettingsProject([".rawviewer/setting/setting.yaml": yaml])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ProjectSettingsError.self, "\(comment) was accepted") {
            try ProjectSettingsStore.load(projectRoot: root)
        }
    }
    let head = "data_root: \"data/raw\"\ndefault_view: \"tree\"\n"
    // New keys are unknown outside v3.
    try expectReject("schema_version: 1\n" + head + "developer_mode: true\n", "developer_mode in v1")
    try expectReject("schema_version: 2\n" + head + "explorer_views: []\n", "explorer_views in v2")
    // Malformed v3 references.
    let v3head = "schema_version: 3\n" + head + "default_preset: \"nature-single\"\ndeveloper_mode: false\n"
    try expectReject(v3head + "explorer_views:\n  - grammar_id: \"g\"\n    variable: \"v\"\n  - grammar_id: \"g\"\n    variable: \"v\"\n", "duplicate view reference")
    try expectReject(v3head + "explorer_views:\n  - grammar_id: \"\"\n    variable: \"v\"\n", "empty grammar_id")
    try expectReject(v3head + "explorer_views:\n  - grammar_id: \"g\"\n    variable: \"\"\n", "empty variable")
    try expectReject(v3head + "explorer_views:\n  - grammar_id: \"g\"\n    variable: \"v\"\n    label: \"Custom\"\n", "unknown nested key")
    try expectReject(v3head + "explorer_views: \"study\"\n", "scalar explorer_views")
    try expectReject(v3head + "explorer_views:\n  - \"study\"\n", "scalar view item")
    try expectReject("schema_version: 3\n" + head + "developer_mode: \"yes\"\n", "non-boolean developer_mode")
}

@Test func settingsReadModifyWritePreservesViewsAndDeveloperMode() throws {
    let root = try makeSettingsProject([".rawviewer/setting.yaml": v3SettingsYAML + "\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    guard var loaded = try ProjectSettingsStore.load(projectRoot: root) else {
        Issue.record("v3 settings did not load")
        return
    }
    // Simulate a project configure/data-root change: only the root moves.
    loaded = ProjectSettings(
        dataRoot: "measurements", defaultView: loaded.defaultView,
        defaultPreset: loaded.defaultPreset, developerMode: loaded.developerMode,
        explorerViews: loaded.explorerViews)
    try ProjectSettingsStore.save(loaded, projectRoot: root)
    let reloaded = try ProjectSettingsStore.load(projectRoot: root)
    #expect(reloaded?.dataRoot == "measurements")
    #expect(reloaded?.developerMode == true)
    #expect(reloaded?.explorerViews == [
        ExplorerViewDefinition(grammarID: "standard-scientific", variable: "study"),
        ExplorerViewDefinition(grammarID: "standard-scientific", variable: "device-id"),
    ])
}

// MARK: - Task 1: Explorer source labels persistence.

@Test func sourceLabelsRoundTripAndPreserveOtherSettings() throws {
    let root = try makeSettingsProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = ProjectSettings(
        dataRoot: "data/raw", defaultView: "tree", defaultPreset: "custom-preset",
        developerMode: true,
        explorerViews: [ExplorerViewDefinition(grammarID: "standard-scientific", variable: "study")],
        sourceLabels: [
            SourceLabelLayout(grammarID: "grammar-a", rows: [
                SourceLabelRow(variables: ["study", "device-id"], fontSize: 10, weight: "regular", font: "normal", emphasis: "primary"),
                SourceLabelRow(variables: ["date"], fontSize: 18, weight: "semibold", font: "monospace", emphasis: "secondary"),
            ]),
            SourceLabelLayout(grammarID: "grammar-b", rows: [
                SourceLabelRow(variables: ["study"], fontSize: 12, weight: "medium", font: "normal", emphasis: "primary"),
            ]),
        ])
    try ProjectSettingsStore.save(settings, projectRoot: root)
    let text = try String(contentsOf: ProjectSettingsStore.settingsURL(projectRoot: root), encoding: .utf8)
    #expect(text.contains("source_labels:"), "source_labels must persist: \(text)")
    guard let reloaded = try ProjectSettingsStore.load(projectRoot: root) else {
        Issue.record("source-label settings did not load")
        return
    }
    #expect(reloaded == settings)
    #expect(reloaded.dataRoot == "data/raw")
    #expect(reloaded.defaultPreset == "custom-preset")
    #expect(reloaded.developerMode == true)
    #expect(reloaded.explorerViews == [ExplorerViewDefinition(grammarID: "standard-scientific", variable: "study")])
    #expect(reloaded.sourceLabels.count == 2)
}

@Test func oldSettingsDefaultToFilename() throws {
    for yaml in [
        "schema_version: 1\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\n",
        "schema_version: 2\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\ndefault_preset: \"nature-single\"\n",
        "schema_version: 3\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\ndefault_preset: \"nature-single\"\ndeveloper_mode: false\nexplorer_views: []\n",
    ] {
        let root = try makeSettingsProject([".rawviewer/setting/setting.yaml": yaml])
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try ProjectSettingsStore.load(projectRoot: root)
        #expect(loaded?.sourceLabels == [], "absent source_labels means no customization")
    }
    #expect(ProjectSettings(dataRoot: "data/raw").sourceLabels == [])
}

@Test func invalidLabelStyleAndDuplicateGrammarRejected() throws {
    func expectSaveReject(_ labels: [SourceLabelLayout], _ comment: String) throws {
        let root = try makeSettingsProject()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ProjectSettingsError.self, "\(comment) was saved") {
            try ProjectSettingsStore.save(ProjectSettings(dataRoot: "data/raw", sourceLabels: labels), projectRoot: root)
        }
        #expect(!FileManager.default.fileExists(atPath: ProjectSettingsStore.settingsURL(projectRoot: root).path),
                "\(comment) wrote a file before validation")
    }
    let goodRow = SourceLabelRow(variables: ["study"], fontSize: 12, weight: "regular", font: "normal", emphasis: "primary")
    func layout(_ rows: [SourceLabelRow], grammar: String = "g") -> [SourceLabelLayout] {
        [SourceLabelLayout(grammarID: grammar, rows: rows)]
    }
    try expectSaveReject(layout([SourceLabelRow(variables: ["s"], fontSize: 9, weight: "regular", font: "normal", emphasis: "primary")]), "fontSize 9")
    try expectSaveReject(layout([SourceLabelRow(variables: ["s"], fontSize: 19, weight: "regular", font: "normal", emphasis: "primary")]), "fontSize 19")
    try expectSaveReject(layout([SourceLabelRow(variables: ["s"], fontSize: 12, weight: "bold", font: "normal", emphasis: "primary")]), "bad weight")
    try expectSaveReject(layout([SourceLabelRow(variables: ["s"], fontSize: 12, weight: "regular", font: "serif", emphasis: "primary")]), "bad font")
    try expectSaveReject(layout([SourceLabelRow(variables: ["s"], fontSize: 12, weight: "regular", font: "normal", emphasis: "muted")]), "bad emphasis")
    try expectSaveReject(layout([SourceLabelRow(variables: [], fontSize: 12, weight: "regular", font: "normal", emphasis: "primary")]), "empty variables")
    try expectSaveReject(layout([SourceLabelRow(variables: [""], fontSize: 12, weight: "regular", font: "normal", emphasis: "primary")]), "empty variable name")
    try expectSaveReject(layout([SourceLabelRow(variables: ["   "], fontSize: 12, weight: "regular", font: "normal", emphasis: "primary")]), "blank variable name")
    try expectSaveReject([SourceLabelLayout(grammarID: "g", rows: [])], "empty rows inside layout")
    try expectSaveReject([
        SourceLabelLayout(grammarID: "g", rows: [goodRow]),
        SourceLabelLayout(grammarID: "g", rows: [goodRow]),
    ], "duplicate grammarID")

    func expectLoadReject(_ yaml: String, _ comment: String) throws {
        let root = try makeSettingsProject([".rawviewer/setting/setting.yaml": yaml])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ProjectSettingsError.self, "\(comment) was accepted") {
            try ProjectSettingsStore.load(projectRoot: root)
        }
    }
    let v3head = "schema_version: 3\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\ndefault_preset: \"nature-single\"\ndeveloper_mode: false\nexplorer_views: []\n"
    try expectLoadReject(v3head + "source_labels:\n  - grammar_id: \"g\"\n    rows:\n      - variables: [\"s\"]\n        font_size: 9\n        weight: \"regular\"\n        font: \"normal\"\n        emphasis: \"primary\"\n", "fontSize 9 YAML")
    try expectLoadReject(v3head + "source_labels:\n  - grammar_id: \"g\"\n    rows:\n      - variables: [\"s\"]\n        font_size: 19\n        weight: \"regular\"\n        font: \"normal\"\n        emphasis: \"primary\"\n", "fontSize 19 YAML")
    try expectLoadReject(v3head + "source_labels:\n  - grammar_id: \"g\"\n    rows:\n      - variables: [\"s\"]\n        font_size: 12\n        weight: \"bold\"\n        font: \"normal\"\n        emphasis: \"primary\"\n", "bad weight YAML")
    try expectLoadReject(v3head + "source_labels:\n  - grammar_id: \"g\"\n    rows:\n      - variables: []\n        font_size: 12\n        weight: \"regular\"\n        font: \"normal\"\n        emphasis: \"primary\"\n", "empty variables YAML")
    try expectLoadReject(v3head + "source_labels:\n  - grammar_id: \"g\"\n    rows:\n      - variables: [\"s\"]\n        font_size: 12\n        weight: \"regular\"\n        font: \"normal\"\n        emphasis: \"primary\"\n  - grammar_id: \"g\"\n    rows:\n      - variables: [\"t\"]\n        font_size: 12\n        weight: \"regular\"\n        font: \"normal\"\n        emphasis: \"primary\"\n", "duplicate grammar YAML")
    try expectLoadReject(v3head + "source_labels:\n  - grammar_id: \"g\"\n    rows: []\n", "empty rows YAML")
    try expectLoadReject("schema_version: 1\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\nsource_labels: []\n", "source_labels in v1")
}

@Test func sourceLabelsResetToEmptyPersists() throws {
    let root = try makeSettingsProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let row = SourceLabelRow(variables: ["study"], fontSize: 12, weight: "regular", font: "normal", emphasis: "primary")
    let first = ProjectSettings(
        dataRoot: "data/raw", defaultView: "tree", defaultPreset: "custom-preset",
        developerMode: true,
        explorerViews: [ExplorerViewDefinition(grammarID: "standard-scientific", variable: "study")],
        sourceLabels: [SourceLabelLayout(grammarID: "g", rows: [row])])
    try ProjectSettingsStore.save(first, projectRoot: root)
    #expect(try ProjectSettingsStore.load(projectRoot: root)?.sourceLabels == [SourceLabelLayout(grammarID: "g", rows: [row])])
    guard let loaded = try ProjectSettingsStore.load(projectRoot: root) else {
        Issue.record("settings did not load")
        return
    }
    let reset = ProjectSettings(
        dataRoot: loaded.dataRoot, defaultView: loaded.defaultView,
        defaultPreset: loaded.defaultPreset, developerMode: loaded.developerMode,
        explorerViews: loaded.explorerViews, sourceLabels: [])
    try ProjectSettingsStore.save(reset, projectRoot: root)
    guard let reloaded = try ProjectSettingsStore.load(projectRoot: root) else {
        Issue.record("reset settings did not load")
        return
    }
    #expect(reloaded.sourceLabels == [])
    #expect(reloaded.dataRoot == "data/raw")
    #expect(reloaded.defaultPreset == "custom-preset")
    #expect(reloaded.developerMode == true)
    #expect(reloaded.explorerViews == [ExplorerViewDefinition(grammarID: "standard-scientific", variable: "study")])
}

// MARK: - Task 7: Explorer add/remove view read-modify-write.

@Test func settingsAddViewPreservesUnrelatedFields() throws {
    let root = try makeSettingsProject([".rawviewer/setting.yaml": v3SettingsYAML + "\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    // Explorer Add View from Filename…: load, append one reference, save.
    guard let loaded = try ProjectSettingsStore.load(projectRoot: root) else {
        Issue.record("v3 settings did not load")
        return
    }
    let updated = ProjectSettings(
        dataRoot: loaded.dataRoot, defaultView: loaded.defaultView,
        defaultPreset: "custom-preset", developerMode: loaded.developerMode,
        explorerViews: loaded.explorerViews
            + [ExplorerViewDefinition(grammarID: "legacy-grammar", variable: "study")])
    try ProjectSettingsStore.save(updated, projectRoot: root)
    let reloaded = try ProjectSettingsStore.load(projectRoot: root)
    #expect(reloaded?.dataRoot == "data/raw")
    #expect(reloaded?.defaultView == "tree")
    #expect(reloaded?.defaultPreset == "custom-preset")
    #expect(reloaded?.developerMode == true)
    // Identical variable names in different grammars stay distinct.
    #expect(reloaded?.explorerViews == [
        ExplorerViewDefinition(grammarID: "standard-scientific", variable: "study"),
        ExplorerViewDefinition(grammarID: "standard-scientific", variable: "device-id"),
        ExplorerViewDefinition(grammarID: "legacy-grammar", variable: "study"),
    ])
}

@Test func settingsRemoveViewPreservesRemainingViews() throws {
    let root = try makeSettingsProject([".rawviewer/setting.yaml": v3SettingsYAML + "\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    // Explorer Remove View: load, drop one reference, save.
    guard let loaded = try ProjectSettingsStore.load(projectRoot: root) else {
        Issue.record("v3 settings did not load")
        return
    }
    let removed = ExplorerViewDefinition(grammarID: "standard-scientific", variable: "study")
    let updated = ProjectSettings(
        dataRoot: loaded.dataRoot, defaultView: loaded.defaultView,
        defaultPreset: loaded.defaultPreset, developerMode: loaded.developerMode,
        explorerViews: loaded.explorerViews.filter { $0 != removed })
    try ProjectSettingsStore.save(updated, projectRoot: root)
    let reloaded = try ProjectSettingsStore.load(projectRoot: root)
    #expect(reloaded?.explorerViews == [
        ExplorerViewDefinition(grammarID: "standard-scientific", variable: "device-id"),
    ])
    #expect(reloaded?.developerMode == true)
    #expect(reloaded?.dataRoot == "data/raw")
}
