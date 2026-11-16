import Foundation
import Testing
@testable import RawViewCore

// Issue #113: the Grammar editor converts between stored '+'-joined levels and the
// editable [[String]] model. Pure logic only; no file is read.

@Test func storedLevelsSplitCombinedTokensIntoEditableLevels() {
    let levels = TreeLevels.levels(stored: ["instrument+application-mode", "date"])
    #expect(levels == [["instrument", "application-mode"], ["date"]])
}

@Test func storedFormRoundTripsThroughEditableLevels() {
    let stored = ["instrument+application-mode", "device", "date"]
    #expect(TreeLevels.stored(levels: TreeLevels.levels(stored: stored)) == stored)
}

@Test func blankTokensAreDroppedWhenWritingStoredForm() {
    let stored = TreeLevels.stored(levels: [["instrument", " "], [], ["  "], ["date"]])
    #expect(stored == ["instrument", "date"])
}

@Test func levelWithEmptyTokenIsSkippedWhenReading() {
    #expect(TreeLevels.levels(stored: ["instrument+", "date"]) == [["date"]])
}

@Test func movingTokenIntoExistingLevelAppendsIt() {
    let moved = TreeLevels.move("date", in: [["instrument"], ["mode"], ["date"]], to: .level(0))
    #expect(moved == [["instrument", "date"], ["mode"]])
}

@Test func movingTokenToNewLevelInsertsItAtIndex() {
    let moved = TreeLevels.move("mode", in: [["instrument", "mode"], ["date"]], to: .newLevel(at: 1))
    #expect(moved == [["instrument"], ["mode"], ["date"]])
}

@Test func movingLastTokenOutOfLevelDropsTheEmptyLevel() {
    let moved = TreeLevels.move("date", in: [["instrument"], ["date"]], to: .level(0))
    #expect(moved == [["instrument", "date"]])
}

@Test func removingTokenDropsLevelsItEmptied() {
    let removed = TreeLevels.remove("mode", from: [["instrument", "mode"], ["mode"], ["date"]])
    #expect(removed == [["instrument"], ["date"]])
}

@Test func previewPathsJoinCombinedLevelFoldersWithDots() {
    let grammar = FilenameGrammar(
        id: "preview-grammar",
        name: "Preview Grammar",
        template: "{date}_{instrument}.{mode}_[{device-id}]",
        fields: [
            GrammarField(name: "date", type: .datetime, formatHint: "DDMMYY-HHmmSS"),
            GrammarField(name: "instrument"),
            GrammarField(name: "mode"),
            GrammarField(name: "device-id", stripBrackets: true, isOptional: true),
        ]
    )
    let names = [
        "100826-102100_autolab-usth.ca_[dev-1]",
        "100826-102200_autolab-usth.cv_[dev-1]",
    ]
    let sources = names.map {
        RawSource(relativePath: $0, url: URL(fileURLWithPath: "/tmp/\($0)"), byteSize: 1)
    }

    let paths = TreeLevels.previewPaths(
        sources: sources,
        grammar: grammar,
        groupingFields: ["instrument+mode"],
        dateGranularity: .day,
        limit: 5
    )

    #expect(paths == [
        ["autolab-usth.ca", "100826-102100_autolab-usth.ca_[dev-1]"],
        ["autolab-usth.cv", "100826-102200_autolab-usth.cv_[dev-1]"],
    ])
}

@Test func savingKeepsCombinedLevelWhenBothTokensStayTicked() {
    let saved = TreeLevels.reconciled(
        stored: ["instrument+application-mode", "date"],
        ticked: ["instrument", "application-mode", "date"]
    )
    #expect(saved == ["instrument+application-mode", "date"])
}

@Test func savingDropsUntickedTokenFromItsCombinedLevel() {
    let saved = TreeLevels.reconciled(
        stored: ["instrument+application-mode", "date"],
        ticked: ["instrument", "date"]
    )
    #expect(saved == ["instrument", "date"])
}

@Test func savingAppendsNewlyTickedTokenAsItsOwnLevel() {
    let saved = TreeLevels.reconciled(stored: ["date"], ticked: ["date", "mode"])
    #expect(saved == ["date", "mode"])
}

@Test func previewPathsStopAtLimit() {
    let sources = (1...4).map { index in
        RawSource(relativePath: "file\(index).csv", url: URL(fileURLWithPath: "/tmp/file\(index).csv"), byteSize: 1)
    }
    let paths = TreeLevels.previewPaths(sources: sources, grammar: nil, groupingFields: [], dateGranularity: .day, limit: 2)
    #expect(paths == [["file1.csv"], ["file2.csv"]])
}
