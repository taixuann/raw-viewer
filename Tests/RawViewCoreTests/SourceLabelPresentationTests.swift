import Testing
@testable import RawViewCore

struct SourceLabelPresentationTests {
    private func filenameStyle() -> SourceLabelRow {
        SourceLabelRow(variables: [], fontSize: 12, weight: "regular", font: "normal", emphasis: "primary")
    }

    @Test func exactFilenameFallback() {
        let names = ["DEV01_20240101.csv", "測定データ🔬 raw file (v2).CSV"]
        for name in names {
            let rows = SourceLabelPresentation.resolve(
                filename: name, layout: nil, matchedGrammarID: "g1",
                values: ["device": "D1"], availableVariables: ["device"])
            #expect(rows.count == 1)
            #expect(rows[0].text == name)
            #expect(rows[0].style == filenameStyle())
        }
    }

    @Test func optionalValuesJoinWithoutDanglingSeparator() {
        let layout = SourceLabelLayout(grammarID: "g1", rows: [
            SourceLabelRow(variables: ["device", "date", "mode"])
        ])
        let rows = SourceLabelPresentation.resolve(
            filename: "a.csv", layout: layout, matchedGrammarID: "g1",
            values: ["device": "D1", "date": "   ", "mode": "sweep"],
            availableVariables: ["device", "date", "mode"])
        #expect(rows.count == 1)
        #expect(rows[0].text == "D1 · sweep")

        let allMissing = SourceLabelPresentation.resolve(
            filename: "a.csv", layout: layout, matchedGrammarID: "g1",
            values: [:], availableVariables: ["device", "date", "mode"])
        #expect(allMissing.count == 1)
        #expect(allMissing[0].text == "a.csv")
        #expect(allMissing[0].style == filenameStyle())
    }

    @Test func emptyRowsDisappear() {
        let layout = SourceLabelLayout(grammarID: "g1", rows: [
            SourceLabelRow(variables: []),
            SourceLabelRow(variables: ["device"], fontSize: 14, weight: "medium", font: "monospace", emphasis: "secondary"),
            SourceLabelRow(variables: ["missing"], fontSize: 10)
        ])
        let rows = SourceLabelPresentation.resolve(
            filename: "a.csv", layout: layout, matchedGrammarID: "g1",
            values: ["device": "D1"], availableVariables: ["device", "missing"])
        #expect(rows.count == 1)
        #expect(rows[0].text == "D1")
        #expect(rows[0].style == SourceLabelRow(variables: ["device"], fontSize: 14, weight: "medium", font: "monospace", emphasis: "secondary"))

        let allEmpty = SourceLabelLayout(grammarID: "g1", rows: [
            SourceLabelRow(variables: []), SourceLabelRow(variables: [])
        ])
        let fallback = SourceLabelPresentation.resolve(
            filename: "b.csv", layout: allEmpty, matchedGrammarID: "g1",
            values: ["device": "D1"], availableVariables: ["device"])
        #expect(fallback.count == 1)
        #expect(fallback[0].text == "b.csv")
        #expect(fallback[0].style == filenameStyle())
    }

    @Test func staleOrUnmatchedGrammarFallsBack() {
        let layoutA = SourceLabelLayout(grammarID: "grammar-a", rows: [
            SourceLabelRow(variables: ["device"])
        ])
        // Nil matched grammar.
        let nilMatch = SourceLabelPresentation.resolve(
            filename: "a.csv", layout: layoutA, matchedGrammarID: nil,
            values: ["device": "D1"], availableVariables: ["device"])
        #expect(nilMatch.count == 1)
        #expect(nilMatch[0].text == "a.csv")
        #expect(nilMatch[0].style == filenameStyle())
        // Second grammar ID mismatch.
        let mismatch = SourceLabelPresentation.resolve(
            filename: "a.csv", layout: layoutA, matchedGrammarID: "grammar-b",
            values: ["device": "D1"], availableVariables: ["device"])
        #expect(mismatch.count == 1)
        #expect(mismatch[0].text == "a.csv")
        #expect(mismatch[0].style == filenameStyle())
        // Stale reference: configured variable not in availableVariables.
        let stale = SourceLabelPresentation.resolve(
            filename: "a.csv", layout: layoutA, matchedGrammarID: "grammar-a",
            values: ["device": "D1"], availableVariables: ["other"])
        #expect(stale.count == 1)
        #expect(stale[0].text == "a.csv")
        #expect(stale[0].style == filenameStyle())
    }

    @Test func customValuesRemainExact() {
        let layout = SourceLabelLayout(grammarID: "g1", rows: [
            SourceLabelRow(variables: ["device", "note"])
        ])
        let rows = SourceLabelPresentation.resolve(
            filename: "a.csv", layout: layout, matchedGrammarID: "g1",
            values: ["device": " dev1 ", "note": "MiXeD_UnDer-Score (v2)"],
            availableVariables: ["device", "note"])
        #expect(rows.count == 1)
        #expect(rows[0].text == " dev1  · MiXeD_UnDer-Score (v2)")
    }
}
