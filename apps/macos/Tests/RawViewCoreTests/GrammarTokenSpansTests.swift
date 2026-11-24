import Foundation
import Testing
@testable import RawViewCore

// Issue #113: the Grammar tester splits a test filename into one colored segment per
// matched token. Synthetic filenames only; no file is read.

private let spanGrammar = FilenameGrammar(
    id: "span-grammar",
    name: "Span Grammar",
    template: "{date}_{instrument}.{mode}_[{device-id}]",
    fields: [
        GrammarField(name: "date", type: .datetime, formatHint: "DDMMYY-HHmmSS"),
        GrammarField(name: "instrument"),
        GrammarField(name: "mode"),
        GrammarField(name: "device-id", stripBrackets: true, isOptional: true),
    ]
)

private func substrings(_ filename: String, _ spans: [GrammarTokenSpan]) -> [(String, String)] {
    spans.map { span in
        let lower = filename.utf16.index(filename.utf16.startIndex, offsetBy: span.start)
        let upper = filename.utf16.index(filename.utf16.startIndex, offsetBy: span.end)
        return (span.name, String(filename[lower..<upper]))
    }
}

@Test(.globalConfigIsolated) func tokenSpansCoverEachCapturedValueInFilenameOrder() throws {
    let filename = "100826-102100_autolab-usth.ca_[dev-1].txt"
    let spans = try #require(FilenameGrammarEngine.tokenSpans(filename: filename, grammar: spanGrammar))

    let pairs = substrings(filename, spans)
    #expect(pairs.count == 4)
    #expect(pairs[0] == ("date", "100826-102100"))
    #expect(pairs[1] == ("instrument", "autolab-usth"))
    #expect(pairs[2] == ("mode", "ca"))
    #expect(pairs[3] == ("device-id", "dev-1"))
}

@Test(.globalConfigIsolated) func tokenSpansAreNilWhenTemplateDoesNotMatch() {
    #expect(FilenameGrammarEngine.tokenSpans(filename: "readme.txt", grammar: spanGrammar) == nil)
}

@Test(.globalConfigIsolated) func missingOptionalTokenHasNoSpan() throws {
    let optionalGrammar = FilenameGrammar(
        id: "optional-grammar",
        name: "Optional Grammar",
        template: "{instrument}.{mode}",
        fields: [
            GrammarField(name: "instrument"),
            GrammarField(name: "mode", isOptional: true),
        ]
    )
    let spans = try #require(FilenameGrammarEngine.tokenSpans(filename: "autolab.txt", grammar: optionalGrammar))
    #expect(spans.map(\.name) == ["instrument"])
}

@Test(.globalConfigIsolated) func filenamePiecesKeepLiteralTextBetweenTokens() throws {
    let filename = "100826-102100_autolab-usth.ca_[dev-1].txt"
    let spans = try #require(FilenameGrammarEngine.tokenSpans(filename: filename, grammar: spanGrammar))

    let pieces = FilenameGrammarEngine.filenamePieces(filename: filename, spans: spans)
    #expect(pieces.map(\.text) == [
        "100826-102100", "_", "autolab-usth", ".", "ca", "_[", "dev-1", "].txt",
    ])
    #expect(pieces.map(\.tokenName) == [
        "date", nil, "instrument", nil, "mode", nil, "device-id", nil,
    ])
}

@Test(.globalConfigIsolated) func filenamePiecesWithoutSpansReturnTheWholeName() {
    let pieces = FilenameGrammarEngine.filenamePieces(filename: "notes.csv", spans: [])
    #expect(pieces == [FilenamePiece(text: "notes.csv", tokenName: nil)])
}
