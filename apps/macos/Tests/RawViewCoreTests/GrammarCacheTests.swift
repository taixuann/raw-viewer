import Foundation
import Testing
@testable import RawViewCore

private let grammarPerfEnabled = ProcessInfo.processInfo.environment["RAWVIEW_PERF"] == "1"

struct GrammarCacheTests {

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
