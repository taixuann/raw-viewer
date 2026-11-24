import Foundation
import Testing
@testable import RawViewCore

private let facetPerfEnabled = ProcessInfo.processInfo.environment["RAWVIEW_PERF"] == "1"

/// Synthetic 5,000-name workload. Each run tag yields names the facts cache has
/// never seen, so the first pass over them is a cold extract per file.
private func perfSources(tag: String, count: Int = 5_000) -> [RawSource] {
    (1...count).map { index in
        let name = "010526-\(String(format: "%06d", index))_autolab-usth.ca_[\(tag)-\(index % 40)]"
            + "_electrochem.study\(tag)\(index)_r.[clean]_f.[none]_\(String(format: "%03d", index % 999)).txt"
        return RawSource(relativePath: name, url: URL(fileURLWithPath: "/perf/\(name)"), byteSize: 100)
    }
}

private func milliseconds(_ body: () -> Void) -> Double {
    let elapsed = ContinuousClock().measure(body)
    return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000
}

/// Before: the filter menu ran one extract per source for each field, and the tree
/// extracted each file while it was built. After: one facts index per source list,
/// then the menu and the tree read it. Each measured step uses names not seen before in
/// the process, so the first pass is cold. "Warm" repeats the old path on the same names.
struct FacetIndexPerformanceTests {
    @Test(.globalConfigIsolated, .enabled(if: facetPerfEnabled))
    func facetIndexBenchmarkFiveThousandFiles() {
        let grammar = FilenameGrammarCatalog.standardDefaults[0]
        let fields = grammar.fields.map(\.name)
        let treeFields = ["instrument", "mode", "device-id", "date"]

        for run in 1...3 {
            let menuSources = perfSources(tag: "m\(run)")
            let menuCold = milliseconds {
                for field in fields { _ = legacyDistinctValues(sources: menuSources, grammar: grammar, variable: field) }
            }
            let menuWarm = milliseconds {
                for field in fields { _ = legacyDistinctValues(sources: menuSources, grammar: grammar, variable: field) }
            }

            let treeSources = perfSources(tag: "t\(run)")
            let treeCold = milliseconds {
                _ = SourceTree(sources: treeSources, grammar: grammar, groupingFields: treeFields)
            }
            let treeWarm = milliseconds {
                _ = SourceTree(sources: treeSources, grammar: grammar, groupingFields: treeFields)
            }

            let indexSources = perfSources(tag: "i\(run)")
            var index = FacetIndex.empty
            let indexBuild = milliseconds {
                index = FacetIndex.build(sources: indexSources, grammar: grammar)
            }
            let menuLookup = milliseconds {
                for field in fields { _ = index.distinctValues(field: field, grammar: grammar) }
            }
            var indexedTree: SourceTree?
            let treeFromIndex = milliseconds {
                indexedTree = SourceTree(sources: indexSources, grammar: grammar, groupingFields: treeFields, index: index)
            }
            #expect(indexedTree?.root.children.isEmpty == false)
            #expect(index.indexedFileCount == indexSources.count)

            var filter = SourceFilter()
            filter.toggle(facet: "instrument", value: "autolab-usth")
            filter.toggle(facet: "mode", value: "ca")
            var extractedMatches = 0
            let filterBefore = milliseconds {
                for source in indexSources {
                    let facts = FilenameGrammarEngine.extract(from: source.url.lastPathComponent, grammar: grammar)
                    if FacetIndex.matches(filter, facts: facts, variable: { $0 }) { extractedMatches += 1 }
                }
            }
            var indexedMatches = 0
            let filterAfter = milliseconds {
                for source in indexSources {
                    let facts = index.facts(forFilename: source.url.lastPathComponent, grammar: grammar)
                    if FacetIndex.matches(filter, facts: facts, variable: { $0 }) { indexedMatches += 1 }
                }
            }
            #expect(extractedMatches == indexedMatches)
            #expect(indexedMatches == indexSources.count)

            func ms(_ value: Double) -> String { String(format: "%.1f", value) }
            print("FACET_BENCH run=\(run) before menu_cold_ms=\(ms(menuCold)) menu_warm_ms=\(ms(menuWarm)) tree_cold_ms=\(ms(treeCold)) tree_warm_ms=\(ms(treeWarm)) filter_ms=\(ms(filterBefore))")
            print("FACET_BENCH run=\(run) after index_build_ms=\(ms(indexBuild)) menu_lookup_ms=\(ms(menuLookup)) tree_from_index_ms=\(ms(treeFromIndex)) tree_pipeline_ms=\(ms(indexBuild + treeFromIndex)) filter_ms=\(ms(filterAfter))")
        }
    }
}
