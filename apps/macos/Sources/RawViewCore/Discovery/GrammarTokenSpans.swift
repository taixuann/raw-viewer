import Foundation

/// One captured token's position in a filename, as UTF-16 offsets. Offsets stay valid
/// for the full filename because the data extension is stripped only from the end.
public struct GrammarTokenSpan: Sendable, Equatable {
    public let name: String
    public let start: Int
    public let end: Int

    public init(name: String, start: Int, end: Int) {
        self.name = name
        self.start = start
        self.end = end
    }
}

/// One piece of a filename for the tester: a token's value, or literal text between tokens.
public struct FilenamePiece: Sendable, Equatable {
    public let text: String
    public let tokenName: String?

    public init(text: String, tokenName: String?) {
        self.text = text
        self.tokenName = tokenName
    }
}

extension FilenameGrammarEngine {
    /// Token spans in filename order. Nil when the whole template does not match, because
    /// a prefix-only match has no span for the tokens it skipped. Callers then show the
    /// extracted values without segments.
    public static func tokenSpans(filename: String, grammar: FilenameGrammar) -> [GrammarTokenSpan]? {
        guard let (regex, names) = try? compile(template: grammar.template, fields: grammar.fields) else { return nil }
        let target = stripDataExtension(filename, template: grammar.template)
        let range = NSRange(target.startIndex..<target.endIndex, in: target)
        guard let match = regex.firstMatch(in: target, options: [], range: range) else { return nil }

        var spans: [GrammarTokenSpan] = []
        for (index, name) in names.enumerated() where index + 1 < match.numberOfRanges {
            let group = match.range(at: index + 1)
            // An optional token that did not participate has no location.
            guard group.location != NSNotFound else { continue }
            spans.append(GrammarTokenSpan(name: name, start: group.location, end: group.location + group.length))
        }
        return spans.sorted { $0.start < $1.start }
    }

    /// Splits a filename into token and literal pieces, in order. Spans that overlap an
    /// earlier span are skipped.
    public static func filenamePieces(filename: String, spans: [GrammarTokenSpan]) -> [FilenamePiece] {
        func index(_ offset: Int) -> String.Index {
            String.Index(utf16Offset: min(max(offset, 0), filename.utf16.count), in: filename)
        }
        var pieces: [FilenamePiece] = []
        var cursor = 0
        for span in spans.sorted(by: { $0.start < $1.start }) where span.start >= cursor && span.end <= filename.utf16.count {
            if span.start > cursor {
                pieces.append(FilenamePiece(text: String(filename[index(cursor)..<index(span.start)]), tokenName: nil))
            }
            pieces.append(FilenamePiece(text: String(filename[index(span.start)..<index(span.end)]), tokenName: span.name))
            cursor = span.end
        }
        if cursor < filename.utf16.count {
            pieces.append(FilenamePiece(text: String(filename[index(cursor)...]), tokenName: nil))
        }
        return pieces
    }
}
