import Foundation

public struct GrammarField: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var role: String
    public var formatHint: String
    public var stripBrackets: Bool

    public init(name: String, role: String = "Remarks", formatHint: String = "", stripBrackets: Bool = false) {
        self.name = name
        self.role = role
        self.formatHint = formatHint
        self.stripBrackets = stripBrackets
    }
}

public struct FilenameGrammar: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var template: String
    public var description: String
    public var fields: [GrammarField]
    public var isDefault: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        template: String,
        description: String = "",
        fields: [GrammarField] = [],
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.template = template
        self.description = description
        self.fields = fields
        self.isDefault = isDefault
    }
}

public struct FilenameGrammarCatalog: Sendable, Equatable {
    public var grammars: [FilenameGrammar]
    public var activeGrammarID: String?

    public var activeGrammar: FilenameGrammar? {
        if let activeGrammarID, let match = grammars.first(where: { $0.id == activeGrammarID }) {
            return match
        }
        return grammars.first(where: { $0.isDefault }) ?? grammars.first
    }

    public init(grammars: [FilenameGrammar] = [], activeGrammarID: String? = nil) {
        self.grammars = grammars
        self.activeGrammarID = activeGrammarID
    }

    public static let standardDefaults: [FilenameGrammar] = [
        FilenameGrammar(
            id: "autolab-scientific",
            name: "Autolab USTH Scientific Pattern",
            template: "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]",
            description: "Default pattern for electrochemistry measurement series",
            fields: [
                GrammarField(name: "date", role: "Date & Time", formatHint: "DDMMYY-HHmmSS"),
                GrammarField(name: "instrument", role: "Instrument"),
                GrammarField(name: "mode", role: "Mode"),
                GrammarField(name: "device-id", role: "Device ID", stripBrackets: true),
                GrammarField(name: "study", role: "Study"),
                GrammarField(name: "remarks", role: "Remarks", stripBrackets: true)
            ],
            isDefault: true
        ),
        FilenameGrammar(
            id: "standard-delimited",
            name: "Standard Delimited Pattern",
            template: "{date}_{study}_{device-id}_{remarks}",
            description: "Underscore-separated naming convention",
            fields: [
                GrammarField(name: "date", role: "Date & Time", formatHint: "YYYYMMDD"),
                GrammarField(name: "study", role: "Study"),
                GrammarField(name: "device-id", role: "Device ID"),
                GrammarField(name: "remarks", role: "Remarks")
            ],
            isDefault: false
        )
    ]
}

public struct ExtractedGrammarFacts: Sendable, Equatable {
    public let isMatched: Bool
    public let extractedFields: [String: String]
    public let timestamp: String?
    public let instrument: String?
    public let mode: String?
    public let deviceID: String?
    public let category: String?
    public let remarks: [String]
    public let unmatchedReason: String?

    public init(
        isMatched: Bool,
        extractedFields: [String: String] = [:],
        timestamp: String? = nil,
        instrument: String? = nil,
        mode: String? = nil,
        deviceID: String? = nil,
        category: String? = nil,
        remarks: [String] = [],
        unmatchedReason: String? = nil
    ) {
        self.isMatched = isMatched
        self.extractedFields = extractedFields
        self.timestamp = timestamp
        self.instrument = instrument
        self.mode = mode
        self.deviceID = deviceID
        self.category = category
        self.remarks = remarks
        self.unmatchedReason = unmatchedReason
    }
}

public enum GrammarCompileError: Error, LocalizedError {
    case emptyTemplate
    case unclosedToken(token: String)
    case invalidRegex(reason: String)

    public var errorDescription: String? {
        switch self {
        case .emptyTemplate:
            return "Grammar template cannot be empty"
        case .unclosedToken(let token):
            return "Unclosed token bracket in template near: '\(token)'"
        case .invalidRegex(let reason):
            return "Invalid regular expression: \(reason)"
        }
    }
}

public enum FilenameGrammarEngine {
    public static let relativePath = ".rawviewer/view/grammar.yaml"

    /// Compiles a human-readable template like `{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]`
    /// into a regular expression and an ordered list of variable names.
    public static func compile(template: String) throws -> (regex: NSRegularExpression, fieldNames: [String]) {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GrammarCompileError.emptyTemplate
        }

        var pattern = "^"
        var fieldNames: [String] = []

        var scanIndex = trimmed.startIndex
        while scanIndex < trimmed.endIndex {
            if let openBrace = trimmed[scanIndex...].firstIndex(of: "{") {
                // Literal part before the open brace
                if openBrace > scanIndex {
                    let literal = String(trimmed[scanIndex..<openBrace])
                    pattern += NSRegularExpression.escapedPattern(for: literal)
                }

                guard let closeBrace = trimmed[openBrace...].firstIndex(of: "}") else {
                    let unclosed = String(trimmed[openBrace...])
                    throw GrammarCompileError.unclosedToken(token: unclosed)
                }

                let varName = String(trimmed[trimmed.index(after: openBrace)..<closeBrace]).trimmingCharacters(in: .whitespaces)
                fieldNames.append(varName)

                // Lookahead to see if there is a trailing literal or delimiter right after this token
                let nextIndex = trimmed.index(after: closeBrace)
                if nextIndex < trimmed.endIndex {
                    pattern += "(.+?)"
                } else {
                    pattern += "(.+)"
                }

                scanIndex = nextIndex
            } else {
                // Trailing literal part
                let trailingLiteral = String(trimmed[scanIndex...])
                pattern += NSRegularExpression.escapedPattern(for: trailingLiteral)
                scanIndex = trimmed.endIndex
            }
        }
        pattern += "$"

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            return (regex, fieldNames)
        } catch {
            throw GrammarCompileError.invalidRegex(reason: error.localizedDescription)
        }
    }

    /// Extracts semantic facts from a filename according to the given grammar.
    public static func extract(from filename: String, grammar: FilenameGrammar) -> ExtractedGrammarFacts {
        guard let (regex, fieldNames) = try? compile(template: grammar.template) else {
            return ExtractedGrammarFacts(isMatched: false, unmatchedReason: "Invalid template syntax")
        }

        // Normalize filename by stripping standard extension if template does not expect it
        var target = filename
        if let dotIndex = target.lastIndex(of: "."), !grammar.template.contains(target[dotIndex...]) {
            target = String(target[..<dotIndex])
        }

        let range = NSRange(target.startIndex..<target.endIndex, in: target)
        guard let match = regex.firstMatch(in: target, options: [], range: range) else {
            return ExtractedGrammarFacts(isMatched: false, unmatchedReason: "Filename does not match template pattern")
        }

        var extracted: [String: String] = [:]
        for (idx, name) in fieldNames.enumerated() {
            let groupIdx = idx + 1
            guard groupIdx < match.numberOfRanges else { continue }
            let groupRange = match.range(at: groupIdx)
            if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: target) {
                var value = String(target[swiftRange])
                // Check if field config specifies stripBrackets or if it has matching brackets
                let fieldConfig = grammar.fields.first(where: { $0.name == name })
                if fieldConfig?.stripBrackets == true || (value.hasPrefix("[") && value.hasSuffix("]") && value.count >= 2) {
                    if value.hasPrefix("[") && value.hasSuffix("]") && value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                }
                extracted[name] = value
            }
        }

        // Map extracted variables to semantic roles
        var timestamp: String? = nil
        var instrument: String? = nil
        var mode: String? = nil
        var deviceID: String? = nil
        var category: String? = nil
        var remarks: [String] = []

        for (name, val) in extracted {
            let fieldConfig = grammar.fields.first(where: { $0.name == name })
            let role = fieldConfig?.role.lowercased() ?? ""

            if role.contains("date") || role.contains("time") || name.lowercased() == "date" || name.lowercased() == "timestamp" {
                timestamp = val
            } else if role == "instrument" || name.lowercased() == "instrument" {
                instrument = val
            } else if role == "mode" || name.lowercased() == "mode" {
                mode = val
            } else if role.contains("device") || name.lowercased() == "device-id" || name.lowercased() == "device" {
                deviceID = val
            } else if role == "study" || role == "category" || name.lowercased() == "study" || name.lowercased() == "category" {
                category = val
            } else if role == "remarks" || name.lowercased().contains("remark") {
                remarks.append(val)
            }
        }

        return ExtractedGrammarFacts(
            isMatched: true,
            extractedFields: extracted,
            timestamp: timestamp,
            instrument: instrument,
            mode: mode,
            deviceID: deviceID,
            category: category,
            remarks: remarks,
            unmatchedReason: nil
        )
    }

    /// Saves the grammar catalog to `.rawviewer/view/grammar.yaml`.
    public static func save(catalog: FilenameGrammarCatalog, project: ProjectContext) throws {
        let dir = project.root.appendingPathComponent(".rawviewer/view", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("grammar.yaml")

        var yaml = ""
        if let active = catalog.activeGrammarID {
            yaml += "active_grammar_id: \"\(active)\"\n"
        }
        yaml += "grammars:\n"
        for g in catalog.grammars {
            yaml += "  - id: \"\(g.id)\"\n"
            yaml += "    name: \"\(g.name)\"\n"
            yaml += "    template: \"\(g.template)\"\n"
            yaml += "    description: \"\(g.description)\"\n"
            yaml += "    is_default: \(g.isDefault)\n"
            if !g.fields.isEmpty {
                yaml += "    fields:\n"
                for f in g.fields {
                    yaml += "      - name: \"\(f.name)\"\n"
                    yaml += "        role: \"\(f.role)\"\n"
                    yaml += "        format_hint: \"\(f.formatHint)\"\n"
                    yaml += "        strip_brackets: \(f.stripBrackets)\n"
                }
            }
        }

        try yaml.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Loads the grammar catalog from `.rawviewer/view/grammar.yaml`, falling back to standard defaults if absent.
    public static func load(project: ProjectContext) -> FilenameGrammarCatalog? {
        let file = project.root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8),
              let node = try? YAMLParser.parse(text) else {
            return nil
        }
        return parse(node: node)
    }

    static func parse(node: YAMLNode) -> FilenameGrammarCatalog? {
        let activeID = node.value(for: "active_grammar_id")?.scalarValue

        var grammars: [FilenameGrammar] = []
        if let list = node.value(for: "grammars")?.listItems {
            for item in list {
                guard let id = item.value(for: "id")?.scalarValue,
                      let name = item.value(for: "name")?.scalarValue,
                      let template = item.value(for: "template")?.scalarValue else {
                    continue
                }
                let desc = item.value(for: "description")?.scalarValue ?? ""
                let isDef = (item.value(for: "is_default")?.scalarValue?.lowercased() == "true")

                var fields: [GrammarField] = []
                if let fieldList = item.value(for: "fields")?.listItems {
                    for fNode in fieldList {
                        guard let fName = fNode.value(for: "name")?.scalarValue else { continue }
                        let fRole = fNode.value(for: "role")?.scalarValue ?? "Remarks"
                        let fHint = fNode.value(for: "format_hint")?.scalarValue ?? ""
                        let fStrip = (fNode.value(for: "strip_brackets")?.scalarValue?.lowercased() == "true")
                        fields.append(GrammarField(name: fName, role: fRole, formatHint: fHint, stripBrackets: fStrip))
                    }
                }

                grammars.append(FilenameGrammar(
                    id: id,
                    name: name,
                    template: template,
                    description: desc,
                    fields: fields,
                    isDefault: isDef
                ))
            }
        }

        guard !grammars.isEmpty else { return nil }
        return FilenameGrammarCatalog(grammars: grammars, activeGrammarID: activeID)
    }
}
