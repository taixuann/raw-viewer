import Foundation

/// Combined multi-facet filter: AND across facets, OR within a facet.
public struct SourceFilter: Sendable, Equatable {
    public var selections: [String: Set<String>] = [:]

    public init() {}

    public mutating func toggle(facet: String, value: String) {
        let selected = selections[facet, default: []]
        if selected.contains(value) {
            selections[facet] = selected.subtracting([value])
        } else {
            selections[facet] = selected.union([value])
        }
    }

    public mutating func remove(facet: String, value: String) {
        selections[facet, default: []].remove(value)
    }

    public mutating func clear() {
        selections = [:]
    }

    public var isEmpty: Bool { selections.values.allSatisfy(\.isEmpty) }

    /// A source matches when, for EVERY facet with a non-empty selection, its label set
    /// for that facet intersects the selection (AND across facets; OR within a facet).
    /// Sources lacking any label for a selected facet are excluded.
    public func matches(_ labelsByFacet: [String: Set<String>]) -> Bool {
        selections.allSatisfy { facet, selected in
            selected.isEmpty || !labelsByFacet[facet, default: []].isDisjoint(with: selected)
        }
    }
}
