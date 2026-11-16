import Foundation

/// Where a grouping token moves in the editable level model.
public enum TreeLevelDestination: Equatable, Sendable {
    /// Append to an existing level (index into the levels before the move).
    case level(Int)
    /// Insert a new level holding only the token, at this index (before the move).
    case newLevel(at: Int)
}

/// Converts between the stored tree grouping (`["instrument+application-mode", "date"]`)
/// and the editable level model (`[["instrument", "application-mode"], ["date"]]`).
/// Stored settings keep `[String]`; the editor works on `[[String]]`.
public enum TreeLevels {
    /// Editable levels from the stored form. Malformed levels (an empty token) are skipped.
    public static func levels(stored: [String]) -> [[String]] {
        stored.compactMap { SourceTree.groupingTokens(level: $0) }
    }

    /// Stored form from editable levels. Blank tokens and empty levels are dropped.
    public static func stored(levels: [[String]]) -> [String] {
        levels.compactMap { tokens in
            let names = tokens
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return names.isEmpty ? nil : names.joined(separator: "+")
        }
    }

    /// Stored levels after the grammar is saved. The Tree flags decide membership: unticked or
    /// removed tokens leave their level, and newly ticked tokens become their own levels at the
    /// end. Existing combined levels keep their shape.
    public static func reconciled(stored: [String], ticked: [String]) -> [String] {
        let allowed = Set(ticked)
        var kept = levels(stored: stored)
            .map { $0.filter { allowed.contains($0) } }
            .filter { !$0.isEmpty }
        let placed = Set(kept.flatMap { $0 })
        kept += ticked.filter { !placed.contains($0) }.map { [$0] }
        return TreeLevels.stored(levels: kept)
    }

    /// Moves a token to one destination. A token sits in at most one level, so any
    /// earlier occurrence is removed first. Levels left empty are dropped.
    public static func move(_ token: String, in levels: [[String]], to destination: TreeLevelDestination) -> [[String]] {
        var result = levels.map { $0.filter { $0 != token } }
        switch destination {
        case .level(let index):
            if result.indices.contains(index) { result[index].append(token) } else { result.append([token]) }
        case .newLevel(let index):
            result.insert([token], at: min(max(index, 0), result.count))
        }
        return result.filter { !$0.isEmpty }
    }

    /// Removes a token from whichever level holds it. Levels left empty are dropped.
    public static func remove(_ token: String, from levels: [[String]]) -> [[String]] {
        levels.map { $0.filter { $0 != token } }.filter { !$0.isEmpty }
    }

    /// Folder paths for the first `limit` project files under the given grouping, as
    /// folder names followed by the file name. Uses the same tree the Explorer builds, so
    /// combined levels show their dot-joined folder names.
    public static func previewPaths(
        sources: [RawSource],
        grammar: FilenameGrammar?,
        groupingFields: [String],
        dateGranularity: DateGranularity,
        limit: Int
    ) -> [[String]] {
        guard limit > 0 else { return [] }
        let tree = SourceTree(
            sources: sources,
            grammar: grammar,
            groupingFields: groupingFields,
            dateGranularity: dateGranularity
        )
        var paths: [[String]] = []
        func walk(_ node: SourceTreeNode, folders: [String], isRoot: Bool) {
            if node.sourceID != nil {
                if paths.count < limit { paths.append(folders + [node.name]) }
                return
            }
            let next = isRoot ? folders : folders + [node.name]
            for child in node.children where paths.count < limit {
                walk(child, folders: next, isRoot: false)
            }
        }
        walk(tree.root, folders: [], isRoot: true)
        return paths
    }
}
