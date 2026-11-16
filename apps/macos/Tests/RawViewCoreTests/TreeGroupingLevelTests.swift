import Foundation
import Testing
@testable import RawViewCore

// Issue #112: one tree level may hold several grammar tokens joined with '+'.
// Synthetic filenames only; no file is read.

private let levelGrammar = FilenameGrammar(
    id: "level-grammar",
    name: "Level Grammar",
    template: "{date}_{instrument}.{mode}_[{device-id}]",
    fields: [
        GrammarField(name: "date", type: .datetime, formatHint: "DDMMYY-HHmmSS"),
        GrammarField(name: "instrument"),
        GrammarField(name: "mode"),
        GrammarField(name: "device-id", stripBrackets: true, isOptional: true),
    ]
)

private func levelSource(_ name: String) -> RawSource {
    RawSource(relativePath: name, url: URL(fileURLWithPath: "/tmp/\(name)"), byteSize: 1)
}

private let caFirst = "100826-102100_autolab-usth.ca_[dev-1]"
private let cvFirst = "100826-102200_autolab-usth.cv_[dev-1]"
private let caSecond = "100826-102300_autolab-usth.ca_[dev-2]"
private let caNoDevice = "100826-102400_autolab-usth.ca"
private let caNoDeviceLater = "100826-102500_autolab-usth.ca"

@Test func twoTokensInOneLevelProduceDotJoinedFolders() {
    let tree = SourceTree(
        sources: [levelSource(caFirst), levelSource(cvFirst), levelSource(caSecond)],
        grammar: levelGrammar,
        groupingFields: ["instrument+mode"]
    )

    #expect(tree.root.children.map(\.name) == ["autolab-usth.ca", "autolab-usth.cv"])
    #expect(tree.root.children.map(\.id) == [
        "group:grammar/instrument+mode:autolab-usth.ca",
        "group:grammar/instrument+mode:autolab-usth.cv",
    ])
    let caNode = tree.root.children[0]
    let cvNode = tree.root.children[1]
    #expect(caNode.children.compactMap(\.sourceID) == [caFirst, caSecond])
    #expect(cvNode.children.compactMap(\.sourceID) == [cvFirst])
}

@Test func oneTokenLevelKeepsCurrentFolderNamesAndIDs() {
    let sources = [levelSource(caFirst), levelSource(cvFirst)]

    let single = SourceTree(sources: sources, grammar: levelGrammar, groupingFields: ["instrument"])
    #expect(single.root.children.map(\.name) == ["autolab-usth"])
    #expect(single.root.children.map(\.id) == ["group:grammar/instrument:autolab-usth"])

    let twoLevels = SourceTree(sources: sources, grammar: levelGrammar, groupingFields: ["instrument", "mode"])
    let instrumentNode = twoLevels.root.children[0]
    #expect(instrumentNode.children.map(\.name) == ["ca", "cv"])
    #expect(instrumentNode.children.map(\.id) == [
        "group:grammar/instrument:autolab-usth/mode:ca",
        "group:grammar/instrument:autolab-usth/mode:cv",
    ])
}

@Test func missingTokenInsideLevelIsSkippedAndOtherValueKept() {
    let tree = SourceTree(
        sources: [levelSource(caFirst), levelSource(caNoDevice)],
        grammar: levelGrammar,
        groupingFields: ["device-id+mode"]
    )

    #expect(tree.root.children.map(\.name) == ["ca", "dev-1.ca"])
    #expect(tree.root.children.first { $0.name == "ca" }?.children.compactMap(\.sourceID) == [caNoDevice])
    #expect(tree.root.children.first { $0.name == "dev-1.ca" }?.children.compactMap(\.sourceID) == [caFirst])
}

@Test func levelWithEveryTokenMissingGoesToMissingValue() {
    let tree = SourceTree(
        sources: [levelSource(caFirst), levelSource(caNoDevice), levelSource(caNoDeviceLater)],
        grammar: levelGrammar,
        groupingFields: ["device-id+remarks"]
    )

    #expect(tree.root.children.map(\.name) == ["dev-1", SourceGrouping.missingValueBucketLabel])
    let missing = tree.root.children.first { $0.name == SourceGrouping.missingValueBucketLabel }
    #expect(missing?.children.compactMap(\.sourceID) == [caNoDevice, caNoDeviceLater])
    #expect(tree.root.children.first { $0.name == "dev-1" }?.children.compactMap(\.sourceID) == [caFirst])
}

@Test func dateTokenInCombinedLevelHonoursGranularity() {
    let august = caFirst
    let september = "150926-140000_autolab-usth.ca_[dev-1]"
    let sources = [levelSource(august), levelSource(september)]

    let year = SourceTree(sources: sources, grammar: levelGrammar, groupingFields: ["instrument+date"], dateGranularity: .year)
    #expect(year.root.children.map(\.name) == ["autolab-usth.2026"])
    #expect(year.root.children[0].children.compactMap(\.sourceID) == [august, september])

    let month = SourceTree(sources: sources, grammar: levelGrammar, groupingFields: ["instrument+date"], dateGranularity: .month)
    #expect(month.root.children.map(\.name) == ["autolab-usth.2026-08", "autolab-usth.2026-09"])

    let day = SourceTree(sources: sources, grammar: levelGrammar, groupingFields: ["instrument+date"], dateGranularity: .day)
    #expect(day.root.children.map(\.name) == ["autolab-usth.2026-08-10", "autolab-usth.2026-09-15"])
}

@Test func legacyPlainStringSettingsLoadAsOneTokenLevels() throws {
    let settings = try ProjectSettingsStore.parse(text: "schema_version: 1\ntree_grouping:\n  - instrument\n  - mode\n")
    #expect(settings.treeGrouping == ["instrument", "mode"])

    let tree = SourceTree(
        sources: [levelSource(caFirst), levelSource(cvFirst)],
        grammar: levelGrammar,
        groupingFields: settings.treeGrouping ?? []
    )
    #expect(tree.root.children.map(\.name) == ["autolab-usth"])
    #expect(tree.root.children[0].children.map(\.name) == ["ca", "cv"])
    #expect(tree.root.children[0].children.map(\.id) == [
        "group:grammar/instrument:autolab-usth/mode:ca",
        "group:grammar/instrument:autolab-usth/mode:cv",
    ])
}

@Test func combinedLevelSurvivesSaveAndLoad() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tree-grouping-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let levels = ["instrument+application-mode", "device-id", "date"]

    try ProjectSettingsStore.save(ProjectSettings(dataRoot: "data/raw", defaultView: "tree", treeGrouping: levels), projectRoot: root)
    let loaded = try #require(try ProjectSettingsStore.load(projectRoot: root))

    #expect(loaded.treeGrouping == levels)
}

@Test func plusThatDoesNotJoinTwoNamesIsRejected() throws {
    // '+' is the separator, so a '+' inside a token name can only show up as an empty token.
    let rejected = ["+mode", "instrument+", "a++b", "+", " + "]
    for level in rejected {
        #expect(SourceTree.groupingTokens(level: level) == nil, "level \(level)")
        #expect(throws: ProjectSettingsError.self) {
            _ = try ProjectSettingsStore.parse(text: "schema_version: 1\ntree_grouping:\n  - \"\(level)\"\n")
        }
    }
    #expect(SourceTree.groupingTokens(level: "instrument+application-mode") == ["instrument", "application-mode"])
    #expect(SourceTree.groupingTokens(level: "instrument") == ["instrument"])
    let settings = try ProjectSettingsStore.parse(text: "schema_version: 1\ntree_grouping:\n  - \"instrument+application-mode\"\n  - \"device-id\"\n")
    #expect(settings.treeGrouping == ["instrument+application-mode", "device-id"])
}
