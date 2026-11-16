import Foundation
import Testing
@testable import RawViewCore

private let grammarPerfEnabled = ProcessInfo.processInfo.environment["RAWVIEW_PERF"] == "1"

private let defaultFilename = "010526-000001_autolab-usth.ca_[dev-1]_electrochem.study1_r.[clean]_f.[none]_001.txt"
private let defaultFilenameSecond = "010526-000002_autolab-usth.ca_[dev-1]_electrochem.study1_r.[clean]_f.[none]_002.txt"

struct GrammarCacheTests {

    @Test func repeatedExtractReturnsEqualFactsWithoutRecompiling() {
        let cache = GrammarCache()
        let grammar = FilenameGrammarCatalog.standardDefaults[0]

        let first = FilenameGrammarEngine.extract(from: defaultFilename, grammar: grammar, cache: cache)
        let second = FilenameGrammarEngine.extract(from: defaultFilename, grammar: grammar, cache: cache)

        #expect(first == second)
        #expect(first.isMatched == true)
        #expect(first.timestamp == "010526-000001")
        #expect(first.instrument == "autolab-usth")
        #expect(first.mode == "ca")
        #expect(first.deviceID == "dev-1")
        #expect(first.category == "electrochem.study1")
        #expect(first.batch == "001")
        #expect(cache.compilationCount == 1)

        let other = FilenameGrammarEngine.extract(from: defaultFilenameSecond, grammar: grammar, cache: cache)

        #expect(other.isMatched == true)
        #expect(other.timestamp == "010526-000002")
        #expect(other.batch == "002")
        #expect(cache.compilationCount == 1)
    }

    @Test func changedTemplateOrFieldFormatCompilesAgain() throws {
        let cache = GrammarCache()
        let twoDigitFields = [
            GrammarField(name: "code", type: .number, formatHint: "01"),
            GrammarField(name: "batch")
        ]
        let twoDigit = FilenameGrammar(name: "two", template: "{code}_{batch}", fields: twoDigitFields)
        let threeDigit = FilenameGrammar(
            name: "three",
            template: "{code}_{batch}",
            fields: [GrammarField(name: "code", type: .number, formatHint: "001"), GrammarField(name: "batch")]
        )
        let dashed = FilenameGrammar(name: "dashed", template: "{code}-{batch}", fields: twoDigitFields)

        let a = FilenameGrammarEngine.extract(from: "07_001", grammar: twoDigit, cache: cache)
        #expect(a.isMatched == true)
        #expect(a.extractedFields == ["code": "07", "batch": "001"])
        #expect(cache.compilationCount == 1)

        let b = FilenameGrammarEngine.extract(from: "07_001", grammar: threeDigit, cache: cache)
        #expect(b.isMatched == false)
        #expect(b.extractedFields.isEmpty)
        #expect(cache.compilationCount == 2)

        let c = FilenameGrammarEngine.extract(from: "07-001", grammar: dashed, cache: cache)
        #expect(c.isMatched == true)
        #expect(c.extractedFields == ["code": "07", "batch": "001"])
        #expect(cache.compilationCount == 3)

        let twoDigitPattern = try cache.compiled(template: twoDigit.template, fields: twoDigit.fields).regex.pattern
        let threeDigitPattern = try cache.compiled(template: threeDigit.template, fields: threeDigit.fields).regex.pattern
        #expect(twoDigitPattern != threeDigitPattern)
        #expect(cache.compilationCount == 3)

        let again = FilenameGrammarEngine.extract(from: "07_001", grammar: twoDigit, cache: cache)
        #expect(again == a)
        #expect(cache.compilationCount == 3)
    }

    @Test func changedRoleGivesNewFactsWithoutRecompiling() {
        let cache = GrammarCache()
        let plain = FilenameGrammar(
            name: "plain",
            template: "{code}_{batch}",
            fields: [GrammarField(name: "code", type: .number, formatHint: "01"), GrammarField(name: "batch")]
        )
        let roled = FilenameGrammar(
            name: "roled",
            template: "{code}_{batch}",
            fields: [GrammarField(name: "code", role: "Instrument", type: .number, formatHint: "01"), GrammarField(name: "batch")]
        )

        let plainFacts = FilenameGrammarEngine.extract(from: "07_001", grammar: plain, cache: cache)
        #expect(plainFacts.instrument == nil)
        #expect(plainFacts.extractedFields == ["code": "07", "batch": "001"])

        let roledFacts = FilenameGrammarEngine.extract(from: "07_001", grammar: roled, cache: cache)
        #expect(roledFacts.instrument == "07")
        #expect(roledFacts.extractedFields == ["code": "07", "batch": "001"])
        #expect(cache.compilationCount == 1)
    }

    @Test func concurrentExtractReturnsCorrectFacts() async {
        let grammars = [FilenameGrammarCatalog.standardDefaults[0], FilenameGrammarCatalog.standardDefaults[1]]
        var names: [String] = []
        for index in 1...200 {
            names.append(String(format: "010526-%06d_autolab-usth.ca_[dev-1]_electrochem.study1_r.[clean]_f.[none]_%03d.txt", index, index % 1000))
            names.append("random_sample_\(index).csv")
        }

        // Each expected value comes from a fresh cache, so no shared state can leak into it.
        let expected: [[ExtractedGrammarFacts]] = grammars.map { grammar in
            names.map { FilenameGrammarEngine.extract(from: $0, grammar: grammar, cache: GrammarCache()) }
        }

        let shared = GrammarCache()
        await withTaskGroup(of: (Int, [ExtractedGrammarFacts]).self) { group in
            for task in 0..<8 {
                group.addTask {
                    let grammarIndex = task % grammars.count
                    let order = names.indices.map { ($0 + task * 37) % names.count }
                    let facts = order.map {
                        FilenameGrammarEngine.extract(from: names[$0], grammar: grammars[grammarIndex], cache: shared)
                    }
                    return (task, facts)
                }
            }
            for await (task, facts) in group {
                let grammarIndex = task % grammars.count
                let order = names.indices.map { ($0 + task * 37) % names.count }
                let wanted = order.map { expected[grammarIndex][$0] }
                #expect(facts == wanted)
            }
        }
    }

    @Test func factsCacheClearsWhenBoundIsReached() {
        let cache = GrammarCache(factsLimit: 3)
        let grammar = FilenameGrammar(
            name: "bounded",
            template: "{code}_{batch}",
            fields: [GrammarField(name: "code", type: .number, formatHint: "01"), GrammarField(name: "batch")]
        )

        for code in ["01", "02", "03"] {
            _ = FilenameGrammarEngine.extract(from: "\(code)_001", grammar: grammar, cache: cache)
        }
        #expect(cache.cachedFactsCount == 3)

        _ = FilenameGrammarEngine.extract(from: "04_001", grammar: grammar, cache: cache)
        #expect(cache.cachedFactsCount == 1)
    }

    @Test(.enabled(if: grammarPerfEnabled))
    func extractBenchmarkFiveThousandFiles() {
        let grammar = FilenameGrammarCatalog.standardDefaults[0]
        let names = (1...5_000).map { index in
            String(format: "010526-%06d_autolab-usth.ca_[dev-1]_electrochem.study1_r.[clean]_f.[none]_001.txt", index)
        }

        let clock = ContinuousClock()
        for label in ["cold", "warm"] {
            var matched = 0
            let elapsed = clock.measure {
                for name in names where FilenameGrammarEngine.extract(from: name, grammar: grammar).isMatched {
                    matched += 1
                }
            }
            let milliseconds = Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1_000
            print("GRAMMAR_BENCH \(label) extract 5000 files: \(String(format: "%.1f", milliseconds)) ms")
            #expect(matched == names.count)
        }
    }
}
