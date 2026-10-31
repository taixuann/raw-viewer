import Foundation

/// Case-insensitive content matching applies to the first 64 KiB of the source.
enum ProfileWhenMatcher {
    static let contentMatchByteLimit = 64 * 1024
    private static func tokenizeFragment(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in text {
            if ch == "_" || ch == "." || ch == "-" || ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    struct WhenClause: Sendable, Equatable {
        var grammarTokens: [String: String] = [:]
        var contentContainsAny: [String] = []
        var contentStartsWith: [String] = []
        var filenameTokens: [String] = []

        var isContentOnly: Bool {
            grammarTokens.isEmpty && filenameTokens.isEmpty
                && (!contentContainsAny.isEmpty || !contentStartsWith.isEmpty)
        }

        var hasSelectors: Bool {
            !grammarTokens.isEmpty || !filenameTokens.isEmpty || !contentContainsAny.isEmpty
                || !contentStartsWith.isEmpty
        }
    }

    struct GrammarMatchContext: Sendable, Equatable {
        var catalogLoaded: Bool
        var matchedFields: [String: String]?

        static func withoutCatalog() -> GrammarMatchContext {
            GrammarMatchContext(catalogLoaded: false, matchedFields: nil)
        }

        var grammarMatched: Bool { matchedFields != nil }
    }

    enum ProfileResolveCode: String, Sendable {
        case ambiguousProfile = "ambiguous_profile"
        case grammarMatchedNoProfile = "grammar_matched_no_profile"
    }

    static func splitLegacyFilenameTokens(_ entries: [String]) -> [String] {
        entries.flatMap { tokenizeFragment($0) }
    }

    static func tokenizeBasename(_ basename: String) -> [String] {
        let stem: String
        if let dot = basename.lastIndex(of: ".") {
            stem = String(basename[..<dot])
        } else {
            stem = basename
        }
        return tokenizeFragment(stem)
    }

    static func mergeWhen(profile: WhenClause?, variant: WhenClause?) -> WhenClause {
        var merged = WhenClause()
        if let profile {
            merged.grammarTokens.merge(profile.grammarTokens) { _, new in new }
            merged.contentContainsAny.append(contentsOf: profile.contentContainsAny)
            merged.contentStartsWith.append(contentsOf: profile.contentStartsWith)
            merged.filenameTokens.append(contentsOf: profile.filenameTokens)
        }
        if let variant {
            merged.grammarTokens.merge(variant.grammarTokens) { _, new in new }
            merged.contentContainsAny.append(contentsOf: variant.contentContainsAny)
            merged.contentStartsWith.append(contentsOf: variant.contentStartsWith)
            merged.filenameTokens.append(contentsOf: variant.filenameTokens)
        }
        return merged
    }

    static func whenFromLegacy(detect: [String], filenameContainsAll: [String]?) -> WhenClause {
        WhenClause(
            contentContainsAny: detect,
            filenameTokens: filenameContainsAll.map { splitLegacyFilenameTokens($0) } ?? [])
    }

    static func whenFromV4Clause(_ clause: WhenClauseV4) -> WhenClause {
        WhenClause(
            grammarTokens: clause.tokens,
            contentContainsAny: clause.contentContainsAny ?? [],
            contentStartsWith: clause.contentStartsWith ?? [],
            filenameTokens: clause.filenameContainsAll.map { splitLegacyFilenameTokens($0) } ?? [])
    }

    static func grammarContextFromCatalog(_ catalog: FilenameGrammarCatalog?, basename: String) -> GrammarMatchContext {
        guard let catalog else { return .withoutCatalog() }
        for grammar in catalog.grammars {
            let facts = FilenameGrammarEngine.extract(from: basename, grammar: grammar)
            if facts.isMatched {
                return GrammarMatchContext(catalogLoaded: true, matchedFields: facts.extractedFields)
            }
        }
        return GrammarMatchContext(catalogLoaded: true, matchedFields: nil)
    }

    static func modeIsCandidate(_ merged: WhenClause, grammar: GrammarMatchContext) -> Bool {
        if !grammar.catalogLoaded { return true }
        if grammar.grammarMatched { return true }
        return merged.isContentOnly
    }

    static func matchesWhen(
        _ merged: WhenClause,
        grammarFields: [String: String]?,
        basenameTokens: [String],
        headerSample: String,
        basenameForContent: String
    ) -> Bool {
        guard merged.hasSelectors else { return false }
        let tokenSet = Set(basenameTokens)
        for required in merged.filenameTokens where !tokenSet.contains(required) {
            return false
        }
        for (key, expected) in merged.grammarTokens {
            guard let actual = grammarFields?[key], actual == expected else { return false }
        }
        let sample = truncateForContent(headerSample)
        let sampleLower = sample.lowercased()
        let basenameLower = basenameForContent.lowercased()
        let contentAnyOK = merged.contentContainsAny.isEmpty
            || merged.contentContainsAny.contains { sig in
                let needle = sig.lowercased()
                return sampleLower.contains(needle) || basenameLower.contains(needle)
            }
        guard contentAnyOK else { return false }
        return merged.contentStartsWith.isEmpty
            || merged.contentStartsWith.contains { sig in
                let needle = sig.lowercased()
                return sampleLower.hasPrefix(needle) || basenameLower.hasPrefix(needle)
            }
    }

    static func formatAmbiguous(_ candidateIDs: [String]) -> String {
        "ambiguous_profile: \(candidateIDs.count) candidate profile(s): \(candidateIDs.joined(separator: ", "))."
    }

    static func candidateProfileID(_ profile: InstrumentProfile) -> String {
        profile.profileID.isEmpty ? profile.relativePath : profile.profileID
    }

    static func describeFilenameMiss(tokens: [String], basename: String) -> String {
        let have = Set(tokenizeBasename(basename))
        let missing = tokens.filter { !have.contains($0) }
        if missing.isEmpty {
            return "filename_contains_all matched basename \"\(basename)\""
        }
        return "filename_contains_all tokens \(missing.map { "\"\($0)\"" }.joined(separator: ", ")) not in basename \"\(basename)\""
    }

    static func describeContentMiss(_ when: WhenClause, sample: String) -> String {
        let sampleLower = sample.lowercased()
        if when.contentContainsAny.contains(where: { sampleLower.contains($0.lowercased()) }) {
            return "detect matched header sample"
        }
        return "detect \(when.contentContainsAny.map { "\"\($0)\"" }.joined(separator: ", ")) not in header sample"
    }

    private static func truncateForContent(_ headerSample: String) -> String {
        if headerSample.utf8.count <= contentMatchByteLimit { return headerSample }
        var end = headerSample.endIndex
        var size = 0
        for idx in headerSample.utf8.indices {
            size += 1
            if size > contentMatchByteLimit {
                end = idx
                break
            }
        }
        return String(headerSample[..<end])
    }
}
