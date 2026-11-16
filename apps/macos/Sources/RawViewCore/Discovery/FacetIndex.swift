import Foundation

/// Grammar facts for every source basename, built once per source list and grammar.
/// The filter menu, filter matching and tree grouping read it instead of running the
/// grammar again for each view. Facts depend only on the basename and the grammar, so a
/// lookup for a name the index does not hold falls back to a direct extract.
public struct FacetIndex: Sendable {
    /// Distinct values kept per grammar field: the first seen in source order, then sorted.
    public static let distinctValueLimit = 250

    /// No grammar: every lookup falls back to a direct extract.
    public static let empty = FacetIndex(grammar: nil, facts: [:], distinctByField: [:])

    public let grammar: FilenameGrammar?
    private let facts: [String: ExtractedGrammarFacts]
    private let distinctByField: [String: [String]]

    private init(grammar: FilenameGrammar?, facts: [String: ExtractedGrammarFacts], distinctByField: [String: [String]]) {
        self.grammar = grammar
        self.facts = facts
        self.distinctByField = distinctByField
    }

    public var indexedFileCount: Int { facts.count }

    /// Runs the grammar once per distinct basename, then derives every field's distinct values in one pass.
    public static func build(sources: [RawSource], grammar: FilenameGrammar?) -> FacetIndex {
        guard let grammar else { return .empty }
        var facts: [String: ExtractedGrammarFacts] = [:]
        var names: [String] = []
        for source in sources {
            let name = source.url.lastPathComponent
            guard facts[name] == nil else { continue }
            facts[name] = FilenameGrammarEngine.extract(from: name, grammar: grammar)
            names.append(name)
        }

        // Walking first-seen names in order is the same as walking every source, because a
        // repeated basename adds nothing new. The cap depends on that order.
        let fieldNames = grammar.fields.map(\.name)
        var seen: [String: Set<String>] = [:]
        var capped = Set<String>()
        for name in names where capped.count < fieldNames.count {
            guard let extracted = facts[name], extracted.isMatched else { continue }
            for field in fieldNames where !capped.contains(field) {
                guard let value = extracted.extractedFields[field]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { continue }
                seen[field, default: []].insert(value)
                if seen[field, default: []].count >= distinctValueLimit { capped.insert(field) }
            }
        }
        return FacetIndex(
            grammar: grammar,
            facts: facts,
            distinctByField: seen.mapValues { $0.sorted() }
        )
    }

    /// Facts for one basename under `grammar`. The index answers only when it was built for that grammar.
    public func facts(forFilename name: String, grammar: FilenameGrammar) -> ExtractedGrammarFacts {
        if self.grammar == grammar, let hit = facts[name] { return hit }
        return FilenameGrammarEngine.extract(from: name, grammar: grammar)
    }

    /// Distinct values for one field, capped as the filter menu always was. Empty when the index was built for another grammar.
    public func distinctValues(field: String, grammar: FilenameGrammar) -> [String] {
        guard self.grammar == grammar else { return [] }
        return distinctByField[field] ?? []
    }

    /// Filter rule for one source's facts. AND across facets, OR within a facet. `variable` maps a facet key to its grammar variable.
    public static func matches(_ filter: SourceFilter, facts: ExtractedGrammarFacts, variable: (String) -> String) -> Bool {
        if filter.isEmpty { return true }
        for (facetKey, selected) in filter.selections where !selected.isEmpty {
            let variableName = variable(facetKey)
            if facts.isMatched {
                if let value = facts.extractedFields[variableName]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    guard selected.contains(value) else { return false }
                } else {
                    guard selected.contains(SourceGrouping.missingValueBucketLabel) else { return false }
                }
            } else {
                guard selected.contains(SourceGrouping.unmatchedBucketLabel) else { return false }
            }
        }
        return true
    }
}

/// Drops results from an older index or tree build. Each source or grammar change takes a new token, and only the newest token may install its result.
public struct FacetIndexGate: Sendable {
    public private(set) var generation = 0

    public init() {}

    public mutating func begin() -> Int {
        generation += 1
        return generation
    }

    public func accepts(_ token: Int) -> Bool {
        token == generation
    }
}
