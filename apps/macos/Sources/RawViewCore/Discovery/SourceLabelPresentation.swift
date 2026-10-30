public struct ResolvedSourceLabelRow: Sendable, Equatable {
    public let text: String
    public let style: SourceLabelRow

    public init(text: String, style: SourceLabelRow) {
        self.text = text
        self.style = style
    }
}

public enum SourceLabelPresentation {
    public static func resolve(
        filename: String,
        layout: SourceLabelLayout?,
        matchedGrammarID: String?,
        values: [String: String],
        availableVariables: Set<String>
    ) -> [ResolvedSourceLabelRow] {
        let fallback = [ResolvedSourceLabelRow(text: filename, style: SourceLabelRow(variables: []))]
        guard let layout, let matchedGrammarID, matchedGrammarID == layout.grammarID else { return fallback }
        for row in layout.rows where !row.variables.isEmpty {
            guard row.variables.allSatisfy({ availableVariables.contains($0) }) else { return fallback }
        }
        let resolved = layout.rows.compactMap { row -> ResolvedSourceLabelRow? in
            guard !row.variables.isEmpty else { return nil }
            let parts = row.variables.compactMap { name -> String? in
                guard let raw = values[name], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return raw
            }
            guard !parts.isEmpty else { return nil }
            return ResolvedSourceLabelRow(text: parts.joined(separator: " · "), style: row)
        }
        return resolved.isEmpty ? fallback : resolved
    }
}
