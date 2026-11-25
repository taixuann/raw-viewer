import Foundation
import Testing
@testable import RawViewCore

// Issue #116: one facts index per source list and grammar. Synthetic names only.

private let facetGrammar = FilenameGrammarCatalog.standardDefaults[0]

private let facetNames = [
    "010526-000001_autolab-usth.ca_[dev-1]_electrochem.study1_r.[clean]_f.[none]_001.txt",
    "010526-000002_keithley-2400.cv_[dev-9]_electrochem.study9_r.[clean]_f.[none]_002.txt",
    "010526-000003_autolab-usth.ca_[dev-1]_electrochem.study3_f.[none]_003.txt",
    "random_unmatched_file.txt",
]

func facetSource(_ name: String) -> RawSource {
    RawSource(relativePath: name, url: URL(fileURLWithPath: "/facets/\(name)"), byteSize: 1)
}

/// The filter menu before the index: one extract per source for one field.
func legacyDistinctValues(sources: [RawSource], grammar: FilenameGrammar, variable: String) -> [String] {
    var vals = Set<String>()
    for source in sources {
        let facts = FilenameGrammarEngine.extract(from: source.url.lastPathComponent, grammar: grammar)
        if facts.isMatched, let val = facts.extractedFields[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
            vals.insert(val)
            if vals.count >= 250 { break }
        }
    }
    return vals.sorted()
}

@Test func indexHoldsTheSameFieldsAsExtractPerFile() {
    let index = FacetIndex.build(sources: facetNames.map(facetSource), grammar: facetGrammar)

    #expect(index.indexedFileCount == facetNames.count)
    for name in facetNames {
        let expected = FilenameGrammarEngine.extract(from: name, grammar: facetGrammar, cache: GrammarCache())
        #expect(index.facts(forFilename: name, grammar: facetGrammar) == expected, "\(name)")
    }

    let first = index.facts(forFilename: facetNames[0], grammar: facetGrammar)
    #expect(first.isMatched == true)
    #expect(first.extractedFields["instrument"] == "autolab-usth")
    #expect(first.extractedFields["mode"] == "ca")
    #expect(first.extractedFields["device-id"] == "dev-1")
    #expect(first.extractedFields["batch"] == "001")
}

@Test func distinctValuesMatchThePerFieldMenuIncludingTheCap() {
    // 7 and 300 are coprime, so the 300 studies come in scrambled order. The first 250 seen
    // differ from the first 250 when sorted, which is what the cap has to keep.
    let scrambled = (0..<300).map { index in
        "010526-\(String(format: "%06d", index + 1))_autolab-usth.ca_[dev-1]_electrochem.study\((index * 7) % 300)_r.[clean]_f.[none]_001.txt"
    }
    let sources = scrambled.map(facetSource) + facetNames.map(facetSource)
    let index = FacetIndex.build(sources: sources, grammar: facetGrammar)

    let study = index.distinctValues(field: "study", grammar: facetGrammar)
    #expect(study.count == 250)
    #expect(study == legacyDistinctValues(sources: sources, grammar: facetGrammar, variable: "study"))
    for field in facetGrammar.fields.map(\.name) {
        #expect(index.distinctValues(field: field, grammar: facetGrammar)
            == legacyDistinctValues(sources: sources, grammar: facetGrammar, variable: field), "field \(field)")
    }
}

@Test func matchesFilterGivesTheSameResultForMatchedUnmatchedAndMissingFiles() {
    let sources = facetNames.map(facetSource)
    let index = FacetIndex.build(sources: sources, grammar: facetGrammar)
    let variableName: (String) -> String = { key in
        key.hasPrefix("view\0") ? String(key.split(separator: "\0").last ?? "") : key
    }
    let remarksMissing = facetNames[2]
    #expect(index.facts(forFilename: remarksMissing, grammar: facetGrammar).isMatched == true)
    #expect(index.facts(forFilename: remarksMissing, grammar: facetGrammar).extractedFields["remarks"] == nil)

    func results(_ filter: SourceFilter) -> [Bool] {
        facetNames.map { name in
            FacetIndex.matches(filter, facts: index.facts(forFilename: name, grammar: facetGrammar), variable: variableName)
        }
    }
    func filter(_ pairs: [(String, String)]) -> SourceFilter {
        var filter = SourceFilter()
        for (facet, value) in pairs { filter.toggle(facet: facet, value: value) }
        return filter
    }

    #expect(results(SourceFilter()) == [true, true, true, true])
    #expect(results(filter([("instrument", "autolab-usth")])) == [true, false, true, false])
    #expect(results(filter([("remarks", SourceGrouping.missingValueBucketLabel)])) == [false, false, true, false])
    #expect(results(filter([("instrument", SourceGrouping.unmatchedBucketLabel)])) == [false, false, false, true])
    #expect(results(filter([("view\0standard-scientific\0mode", "cv")])) == [false, true, false, false])
    #expect(results(filter([("instrument", "autolab-usth"), ("view\0standard-scientific\0mode", "ca")])) == [true, false, true, false])
}

@Test func indexBuiltForAnotherGrammarIsNotUsed() {
    let index = FacetIndex.build(sources: facetNames.map(facetSource), grammar: facetGrammar)
    let other = FilenameGrammar(name: "other", template: "{instrument}", fields: [GrammarField(name: "instrument")])

    #expect(index.facts(forFilename: facetNames[1], grammar: other) == FilenameGrammarEngine.extract(from: facetNames[1], grammar: other))
    #expect(index.distinctValues(field: "instrument", grammar: other) == [])
    #expect(FacetIndex.empty.facts(forFilename: facetNames[0], grammar: facetGrammar).isMatched == true)
}

@Test func buildStartedBeforeAGrammarOrSourceChangeIsDropped() {
    var gate = FacetIndexGate()
    let grammarBuild = gate.begin()
    let sourceBuild = gate.begin()
    #expect(gate.accepts(grammarBuild) == false)
    #expect(gate.accepts(sourceBuild) == true)

    let laterBuild = gate.begin()
    #expect(gate.accepts(sourceBuild) == false)
    #expect(gate.accepts(laterBuild) == true)
}
