import Foundation
import Testing
@testable import RawViewCore

struct GrammarVectorTests {
    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private struct VectorCase {
        let id: String
        let filename: String
        let matched: Bool
        let tokens: [String: String]
    }

    private static func loadVectors() throws -> (FilenameGrammar, [VectorCase]) {
        let root = repoRoot()
        let vectorsURL = root.appendingPathComponent("fixtures/grammar/vectors.yaml")
        let text = try String(contentsOf: vectorsURL, encoding: .utf8)
        let node = try YAMLParser.parse(text)
        let grammarFile = node.value(for: "grammar_file")?.scalarValue ?? "standard-scientific.yaml"
        let grammarURL = root.appendingPathComponent("fixtures/grammar/\(grammarFile)")
        let grammarCatalog = try FilenameGrammarEngine.load(fileURL: grammarURL)
        guard let grammar = grammarCatalog.grammars.first else {
            throw GrammarCatalogError.parseFailed(path: grammarURL.path, message: "missing grammar")
        }
        guard let items = node.value(for: "vectors")?.listItems else {
            throw GrammarCatalogError.parseFailed(path: vectorsURL.path, message: "vectors list missing")
        }
        let cases: [VectorCase] = try items.map { item in
            guard let id = item.value(for: "id")?.scalarValue,
                  let filename = item.value(for: "filename")?.scalarValue else {
                throw GrammarCatalogError.parseFailed(path: vectorsURL.path, message: "vector entry incomplete")
            }
            let matched = item.value(for: "matched")?.scalarValue?.lowercased() == "true"
            var tokens: [String: String] = [:]
            if let entries = item.value(for: "tokens")?.mapEntries {
                for (key, value) in entries {
                    if let scalar = value.scalarValue {
                        tokens[key] = scalar
                    }
                }
            }
            return VectorCase(id: id, filename: filename, matched: matched, tokens: tokens)
        }
        return (grammar, cases)
    }

    @Test func sharedGrammarCompilePatternMatchesRustReference() throws {
        let root = Self.repoRoot()
        let grammarURL = root.appendingPathComponent("fixtures/grammar/standard-scientific.yaml")
        let grammar = try FilenameGrammarEngine.load(fileURL: grammarURL).grammars[0]
        let (regex, _) = try FilenameGrammarEngine.compile(template: grammar.template, fields: grammar.fields)
        let expected = #"^(\d{6}-\d{6})_([^._]+)\.([^._]+)_\[([^\]]+)\]_([^_]+(?:\.[^_]+)*)(?:_r\.\[([^\]]+)\])?(?:_f\.\[([^\]]+)\])?(?:_(\d{3}))?$"#
        #expect(regex.pattern == expected)
    }

    @Test func sharedGrammarVectorsMatchSwiftEngine() throws {
        let (grammar, cases) = try Self.loadVectors()
        #expect(!cases.isEmpty)
        for vector in cases {
            let facts = FilenameGrammarEngine.extract(from: vector.filename, grammar: grammar)
            #expect(facts.isMatched == vector.matched, "\(vector.id): is_matched")
            if vector.matched {
                for (key, expected) in vector.tokens {
                    #expect(facts.extractedFields[key] == expected, "\(vector.id): token \(key)")
                }
            }
        }
    }
}
