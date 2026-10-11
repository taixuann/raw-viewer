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
    #expect(text == "schema_version: 2\ndata_root: \"measurements\"\ndefault_view: \"tree\"\ndefault_preset: \"nature-single\"\n",
            "exact schema v2 YAML changed: \(text)")
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
    try expectReject("schema_version: 3\n" + head, "schema_version 3")
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
