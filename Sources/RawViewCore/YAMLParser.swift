import Foundation

/// Ordered YAML subset used by instrument profiles. Unknown constructs fail closed
/// instead of being guessed, so a profile that the viewer cannot fully understand
/// becomes a visible per-source diagnostic rather than a silently misread mapping.
enum YAMLNode {
    case scalar(String)
    case map([(key: String, value: YAMLNode)])
    case list([YAMLNode])
}

struct YAMLParseError: Error, Equatable {
    let line: Int
    let message: String

    var localizedDescription: String { "line \(line): \(message)" }
}

enum YAMLParser {
    private static let maximumDepth = 32

    /// Backslash parity for an appended closing double quote (shared with the
    /// flow-list scanner): odd backslashes escape, even do not.
    static func isEscapedDoubleQuote(_ tokenWithQuote: String) -> Bool {
        var backslashes = 0
        for character in tokenWithQuote.dropLast().reversed() {
            guard character == "\\" else { break }
            backslashes += 1
        }
        return backslashes % 2 == 1
    }

    /// The StudyManifest reader keeps YAML's indentless-sequence form; instrument
    /// profiles disable it because their documented subset rejects parent-indent lists.
    static func parse(_ text: String, allowIndentlessSequences: Bool = true) throws -> YAMLNode {
        var lines: [Line] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (offset, raw) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = offset + 1
            let line = String(raw)
            var indent = 0
            var index = line.startIndex
            while index < line.endIndex, line[index] == " " {
                indent += 1
                index = line.index(after: index)
            }
            if index < line.endIndex, line[index] == "\t" {
                throw YAMLParseError(line: number, message: "tab characters are not allowed for indentation")
            }
            let body = String(line[index...])
            guard !body.isEmpty, !body.hasPrefix("#") else { continue }
            let content = stripComment(body, line: number).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            lines.append(Line(number: number, indent: indent, content: content))
        }
        var parser = Body(lines: lines, allowIndentlessSequences: allowIndentlessSequences)
        guard parser.peek != nil else { return .map([]) }
        let node = try parser.parse(depth: 0)
        if let trailing = parser.peek {
            throw YAMLParseError(line: trailing.number, message: "unexpected content")
        }
        return node
    }

    private struct Line {
        let number: Int
        let indent: Int
        let content: String
    }

    private struct Body {
        var lines: [Line]
        let allowIndentlessSequences: Bool
        var index = 0

        var peek: Line? { index < lines.count ? lines[index] : nil }

        mutating func parse(depth: Int) throws -> YAMLNode {
            guard depth < maximumDepth else {
                throw YAMLParseError(line: peek?.number ?? 0, message: "profile nesting is too deep")
            }
            guard let line = peek else { throw YAMLParseError(line: 0, message: "expected a value") }
            if line.content == "-" || line.content.hasPrefix("- ") {
                return try parseList(indent: line.indent, depth: depth)
            }
            return try parseMap(indent: line.indent, depth: depth)
        }

        mutating func parseList(indent: Int, depth: Int) throws -> YAMLNode {
            var items: [YAMLNode] = []
            while let line = peek, line.indent == indent, line.content == "-" || line.content.hasPrefix("- ") {
                index += 1
                let rest = String(line.content.dropFirst()).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    if let next = peek, next.indent > indent {
                        items.append(try parse(depth: depth + 1))
                    } else {
                        items.append(.scalar(""))
                    }
                } else if isMappingEntry(rest) {
                    lines.insert(Line(number: line.number, indent: indent + 2, content: rest), at: index)
                    items.append(try parseMap(indent: indent + 2, depth: depth + 1))
                } else {
                    items.append(try parseScalar(rest, line: line.number))
                }
            }
            return .list(items)
        }

        mutating func parseMap(indent: Int, depth: Int) throws -> YAMLNode {
            var entries: [(key: String, value: YAMLNode)] = []
            var seen = Set<String>()
            while let line = peek, line.indent == indent {
                if line.content == "-" || line.content.hasPrefix("- ") {
                    throw YAMLParseError(line: line.number, message: "unexpected list marker \"\(line.content.prefix(8))\"; list items must be indented beneath their parent key")
                }
                guard let (key, valueText) = splitKeyValue(line.content, line: line.number) else {
                    throw YAMLParseError(line: line.number, message: "expected \"key: value\"")
                }
                guard seen.insert(key).inserted else {
                    throw YAMLParseError(line: line.number, message: "duplicate key \"\(key)\"")
                }
                index += 1
                if valueText.isEmpty {
                    let nextIsIndentlessList = allowIndentlessSequences && (peek.map {
                        $0.indent == indent && ($0.content == "-" || $0.content.hasPrefix("- "))
                    } ?? false)
                    if let next = peek, next.indent > indent || nextIsIndentlessList {
                        entries.append((key, try parse(depth: depth + 1)))
                    } else {
                        entries.append((key, .scalar("")))
                    }
                } else {
                    entries.append((key, try parseScalar(valueText, line: line.number)))
                }
            }
            return .map(entries)
        }

        private func isMappingEntry(_ content: String) -> Bool {
            guard let colon = content.firstIndex(of: ":") else { return false }
            let next = content.index(after: colon)
            return next == content.endIndex || content[next] == " " || content[next] == "\t"
        }

        private func splitKeyValue(_ content: String, line: Int) -> (String, String)? {
            guard let colon = content.firstIndex(of: ":") else { return nil }
            let next = content.index(after: colon)
            guard next == content.endIndex || content[next] == " " || content[next] == "\t" else { return nil }
            let key = content[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains("\""), !key.contains("'") else { return nil }
            return (key, content[next...].trimmingCharacters(in: .whitespaces))
        }

        private func parseScalar(_ content: String, line: Int) throws -> YAMLNode {
            if content.hasPrefix("[") {
                return .list(try parseFlowList(content, line: line))
            }
            if content.hasPrefix("{") {
                throw YAMLParseError(line: line, message: "flow mappings are not supported; use indented keys")
            }
            if content.hasPrefix("\"") || content.hasPrefix("'") {
                return .scalar(try parseQuoted(content, line: line))
            }
            if content == "null" || content == "~" || content == "Null" || content == "NULL" {
                return .scalar("")
            }
            return .scalar(content)
        }

        private func parseFlowList(_ content: String, line: Int) throws -> [YAMLNode] {
            guard content.hasSuffix("]") else {
                throw YAMLParseError(line: line, message: "flow list is missing its closing \"]\"")
            }
            let inner = content.dropFirst().dropLast()
            let innerIsBlank = inner.trimmingCharacters(in: .whitespaces).isEmpty
            var items: [YAMLNode] = []
            var token = ""
            var quote: Character?
            var index = inner.startIndex
            func finishToken() throws {
                let trimmed = token.trimmingCharacters(in: .whitespaces)
                token = ""
                guard !trimmed.isEmpty else {
                    // Empty lists ("[]" / "[ ]") have no elements; any other
                    // empty element (consecutive, leading, or trailing comma)
                    // is malformed and fails closed.
                    if innerIsBlank { return }
                    throw YAMLParseError(line: line, message: "empty element in flow list")
                }
                if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
                    throw YAMLParseError(line: line, message: "nested flow collections are not supported")
                }
                if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") {
                    items.append(.scalar(try parseQuoted(trimmed, line: line)))
                } else {
                    items.append(.scalar(trimmed))
                }
            }
            while index < inner.endIndex {
                let character = inner[index]
                if let active = quote {
                    token.append(character)
                    if character == active && (active == "'" || !YAMLParser.isEscapedDoubleQuote(token)) { quote = nil }
                    if active == "'" && token.hasSuffix("''") { quote = "'" }
                } else if character == "\"" || character == "'" {
                    quote = character
                    token.append(character)
                } else if character == "," {
                    try finishToken()
                } else {
                    token.append(character)
                }
                index = inner.index(after: index)
            }
            guard quote == nil else { throw YAMLParseError(line: line, message: "unterminated quoted value") }
            try finishToken()
            return items
        }

        private func parseQuoted(_ content: String, line: Int) throws -> String {
            if content.hasPrefix("'") {
                guard content.count >= 2, content.hasSuffix("'") else {
                    throw YAMLParseError(line: line, message: "unterminated single-quoted value")
                }
                return String(content.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            guard content.count >= 2, content.hasSuffix("\"") else {
                throw YAMLParseError(line: line, message: "unterminated double-quoted value")
            }
            var result = ""
            var iterator = content.dropFirst().dropLast().makeIterator()
            while let character = iterator.next() {
                guard character == "\\" else { result.append(character); continue }
                guard let escape = iterator.next() else {
                    throw YAMLParseError(line: line, message: "unterminated escape sequence")
                }
                switch escape {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "u":
                    var hex = ""
                    for _ in 0..<4 { guard let digit = iterator.next() else { throw YAMLParseError(line: line, message: "truncated \\u escape") }; hex.append(digit) }
                    guard let scalar = UInt32(hex, radix: 16), let unicode = UnicodeScalar(scalar) else {
                        throw YAMLParseError(line: line, message: "invalid \\u escape")
                    }
                    result.unicodeScalars.append(unicode)
                default:
                    throw YAMLParseError(line: line, message: "unsupported escape \"\\\(escape)\"")
                }
            }
            return result
        }
    }

    private static func stripComment(_ body: String, line: Int) -> String {
        var quote: Character?
        var previous: Character = " "
        var result = ""
        for character in body {
            if let active = quote {
                result.append(character)
                if active == "'" {
                    if character == "'" { quote = nil }
                } else if character == "\"" && !Self.isEscapedDoubleQuote(result) {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
                result.append(character)
            } else if character == "#" && (previous == " " || previous == "\t" || result.isEmpty) {
                break
            } else {
                result.append(character)
            }
            previous = character
        }
        return result
    }
}

extension YAMLNode {
    var mapEntries: [(key: String, value: YAMLNode)]? {
        if case .map(let entries) = self { return entries }
        return nil
    }

    var listItems: [YAMLNode]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var scalarValue: String? {
        if case .scalar(let value) = self, !value.isEmpty { return value }
        return nil
    }

    func value(for key: String) -> YAMLNode? {
        mapEntries?.first { $0.key == key }?.value
    }
}
