import Foundation

public enum GrammarFieldType: String, Sendable, Equatable, CaseIterable, Identifiable {
    case string = "string"
    case number = "number"
    case datetime = "datetime"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .string: return "String"
        case .number: return "Number"
        case .datetime: return "Date/Time"
        }
    }
}

public struct GrammarField: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var role: String
    public var type: GrammarFieldType
    public var formatHint: String
    public var stripBrackets: Bool
    public var isOptional: Bool
    public var isFacet: Bool

    public init(
        name: String,
        role: String = "Remarks",
        type: GrammarFieldType = .string,
        formatHint: String = "",
        stripBrackets: Bool = false,
        isOptional: Bool = false,
        isFacet: Bool = true
    ) {
        self.name = name
        self.role = role
        self.type = type
        self.formatHint = formatHint
        self.stripBrackets = stripBrackets
        self.isOptional = isOptional
        self.isFacet = isFacet
    }
}

public enum FilenameGrammarScope: String, Sendable, Equatable, CaseIterable, Identifiable {
    case project = "project"
    case global = "global"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .project: return "Project"
        case .global: return "Global"
        }
    }
}

public struct FilenameGrammar: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var template: String
    public var description: String
    public var fields: [GrammarField]
    public var isDefault: Bool
    public var scope: FilenameGrammarScope?

    public init(
        id: String = UUID().uuidString,
        name: String,
        template: String,
        description: String = "",
        fields: [GrammarField] = [],
        isDefault: Bool = false,
        scope: FilenameGrammarScope? = nil
    ) {
        self.id = id
        self.name = name
        self.template = template
        self.description = description
        self.fields = fields
        self.isDefault = isDefault
        self.scope = scope
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
            template: "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]_{batch}",
            description: "Default pattern for electrochemistry measurement series",
            fields: [
                GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "DDMMYY-HHmmSS"),
                GrammarField(name: "instrument", role: "Instrument", type: .string),
                GrammarField(name: "mode", role: "Mode", type: .string),
                GrammarField(name: "device-id", role: "Device ID", type: .string, stripBrackets: true),
                GrammarField(name: "study", role: "Study", type: .string),
                GrammarField(name: "remarks", role: "Remarks", type: .string, stripBrackets: true, isOptional: true),
                GrammarField(name: "batch", role: "Batch", type: .number, formatHint: "001", isOptional: true)
            ],
            isDefault: true
        ),
        FilenameGrammar(
            id: "standard-delimited",
            name: "Standard Delimited Pattern",
            template: "{date}_{study}_{device-id}_{remarks}",
            description: "Underscore-separated naming convention",
            fields: [
                GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "YYYYMMDD"),
                GrammarField(name: "study", role: "Study", type: .string),
                GrammarField(name: "device-id", role: "Device ID", type: .string),
                GrammarField(name: "remarks", role: "Remarks", type: .string)
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
    public let batch: String?
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
        batch: String? = nil,
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
        self.batch = batch
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

    public static var globalGrammarURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rawviewer/grammar.yaml")
    }

    private static func patternForField(_ field: GrammarField?, hasTrailing: Bool) -> String {
        guard let field = field else {
            return hasTrailing ? "(.+?)" : "(.+)"
        }
        switch field.type {
        case .number:
            let fmt = field.formatHint.trimmingCharacters(in: .whitespaces)
            if fmt == "01" || fmt.lowercased().contains("2-digit") {
                return "(\\d{2})"
            } else if fmt == "001" || fmt.lowercased().contains("3-digit") {
                return "(\\d{3})"
            } else if fmt == "0.0" || fmt.lowercased() == "decimal" {
                return "(\\d+(?:\\.\\d+)?)"
            } else {
                return "(\\d+)"
            }
        case .datetime:
            let fmt = field.formatHint.trimmingCharacters(in: .whitespaces)
            if fmt == "yyyyMMdd" {
                return "(\\d{8})"
            } else if fmt == "yyMMdd" {
                return "(\\d{6})"
            } else if fmt == "yyyy-MM-dd" {
                return "(\\d{4}-\\d{2}-\\d{2})"
            } else if fmt == "HHmmss" {
                return "(\\d{6})"
            } else if fmt == "HHmm" {
                return "(\\d{4})"
            } else if fmt == "DDMMYY-HHmmSS" || fmt == "yyMMdd-HHmmss" {
                return "(\\d{6}-\\d{6})"
            } else {
                return hasTrailing ? "(.+?)" : "(.+)"
            }
        case .string:
            return hasTrailing ? "(.+?)" : "(.+)"
        }
    }

    /// Compiles a human-readable template like `{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]`
    /// into a regular expression and an ordered list of variable names.
    public static func compile(template: String, fields: [GrammarField] = []) throws -> (regex: NSRegularExpression, fieldNames: [String]) {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GrammarCompileError.emptyTemplate
        }

        var pattern = "^"
        var fieldNames: [String] = []

        var scanIndex = trimmed.startIndex
        while scanIndex < trimmed.endIndex {
            if let openBrace = trimmed[scanIndex...].firstIndex(of: "{") {
                let leadingLiteral = openBrace > scanIndex ? String(trimmed[scanIndex..<openBrace]) : ""

                guard let closeBrace = trimmed[openBrace...].firstIndex(of: "}") else {
                    let unclosed = String(trimmed[openBrace...])
                    throw GrammarCompileError.unclosedToken(token: unclosed)
                }

                let varName = String(trimmed[trimmed.index(after: openBrace)..<closeBrace]).trimmingCharacters(in: .whitespaces)
                fieldNames.append(varName)

                let fieldConfig = fields.first(where: { $0.name == varName })
                let isOptional = fieldConfig?.isOptional ?? false

                var nextIndex = trimmed.index(after: closeBrace)
                var trailingEnclosure = ""
                if nextIndex < trimmed.endIndex && (trimmed[nextIndex] == "]" || trimmed[nextIndex] == ")") {
                    trailingEnclosure = String(trimmed[nextIndex])
                    nextIndex = trimmed.index(after: nextIndex)
                }

                let hasTrailing = (nextIndex < trimmed.endIndex)
                let captureGroup = patternForField(fieldConfig, hasTrailing: hasTrailing || !trailingEnclosure.isEmpty)

                if isOptional {
                    let escapedLeading = leadingLiteral.isEmpty ? "" : NSRegularExpression.escapedPattern(for: leadingLiteral)
                    let escapedTrailing = trailingEnclosure.isEmpty ? "" : NSRegularExpression.escapedPattern(for: trailingEnclosure)
                    pattern += "(?:\(escapedLeading)\(captureGroup)\(escapedTrailing))?"
                } else {
                    if !leadingLiteral.isEmpty {
                        pattern += NSRegularExpression.escapedPattern(for: leadingLiteral)
                    }
                    if !trailingEnclosure.isEmpty {
                        pattern += captureGroup + NSRegularExpression.escapedPattern(for: trailingEnclosure)
                    } else {
                        pattern += captureGroup
                    }
                }

                scanIndex = nextIndex
            } else {
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
        guard let (regex, fieldNames) = try? compile(template: grammar.template, fields: grammar.fields) else {
            return ExtractedGrammarFacts(isMatched: false, unmatchedReason: "Invalid template syntax")
        }

        // Normalize filename by stripping standard extension if template does not expect it
        var target = filename
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty && !grammar.template.hasSuffix(".\(ext)") {
            target = (filename as NSString).deletingPathExtension
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
                let fieldConfig = grammar.fields.first(where: { $0.name == name })
                if (fieldConfig?.stripBrackets == true || true) && value.hasPrefix("[") && value.hasSuffix("]") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                extracted[name] = value
            }
        }

        // Map extracted variables to semantic roles in declared template order
        var timestamp: String? = nil
        var instrument: String? = nil
        var mode: String? = nil
        var deviceID: String? = nil
        var category: String? = nil
        var batch: String? = nil
        var remarks: [String] = []

        for name in fieldNames {
            guard let val = extracted[name] else { continue }
            let fieldConfig = grammar.fields.first(where: { $0.name == name })
            let role = fieldConfig?.role.lowercased() ?? ""
            let lowerName = name.lowercased()

            if role.contains("date") || role.contains("time") || lowerName.contains("date") || lowerName.contains("time") {
                timestamp = val
            } else if role == "instrument" || lowerName == "instrument" {
                instrument = val
            } else if role == "mode" || lowerName == "mode" {
                mode = val
            } else if role.contains("device") || lowerName.contains("device") {
                deviceID = val
            } else if role == "study" || role == "category" || lowerName == "study" || lowerName == "category" {
                category = val
            } else if role == "batch" || lowerName == "batch" {
                batch = val
            } else if role == "remarks" || lowerName.contains("remark") {
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
            batch: batch,
            remarks: remarks,
            unmatchedReason: nil
        )
    }

    private static func yamlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Saves the grammar catalog to a YAML file at the specified file URL.
    public static func save(catalog: FilenameGrammarCatalog, fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var lines: [String] = []
        if let active = catalog.activeGrammarID {
            lines.append("active_grammar_id: \"\(yamlEscape(active))\"")
        }
        lines.append("grammars:")
        for g in catalog.grammars {
            lines.append("  - id: \"\(yamlEscape(g.id))\"")
            lines.append("    name: \"\(yamlEscape(g.name))\"")
            lines.append("    template: \"\(yamlEscape(g.template))\"")
            lines.append("    description: \"\(yamlEscape(g.description))\"")
            lines.append("    is_default: \(g.isDefault)")
            if let scope = g.scope {
                lines.append("    scope: \"\(yamlEscape(scope.rawValue))\"")
            }
            if !g.fields.isEmpty {
                lines.append("    fields:")
                for f in g.fields {
                    lines.append("      - name: \"\(yamlEscape(f.name))\"")
                    lines.append("        role: \"\(yamlEscape(f.role))\"")
                    lines.append("        type: \"\(yamlEscape(f.type.rawValue))\"")
                    lines.append("        format_hint: \"\(yamlEscape(f.formatHint))\"")
                    lines.append("        strip_brackets: \(f.stripBrackets)")
                    lines.append("        is_optional: \(f.isOptional)")
                    lines.append("        is_facet: \(f.isFacet)")
                }
            }
        }

        let yaml = lines.joined(separator: "\n") + "\n"
        try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Saves the grammar catalog to `.rawviewer/view/grammar.yaml` in the given project.
    public static func save(catalog: FilenameGrammarCatalog, project: ProjectContext) throws {
        let file = project.root.appendingPathComponent(relativePath)
        try save(catalog: catalog, fileURL: file)
    }

    /// Loads the grammar catalog from the specified file URL.
    public static func load(fileURL: URL) -> FilenameGrammarCatalog? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8),
              let node = try? YAMLParser.parse(text) else {
            return nil
        }
        return parse(node: node)
    }

    /// Loads the grammar catalog from `.rawviewer/view/grammar.yaml` in the given project.
    public static func load(project: ProjectContext) -> FilenameGrammarCatalog? {
        let file = project.root.appendingPathComponent(relativePath)
        return load(fileURL: file)
    }

    /// Loads combined project and global grammar catalogs.
    /// Returns tagged Project and Global grammars, along with the resolved active grammar ID.
    public static func loadCombined(
        project: ProjectContext?,
        globalURL: URL = globalGrammarURL
    ) -> (projectGrammars: [FilenameGrammar], globalGrammars: [FilenameGrammar], activeID: String?) {
        let projectCatalog = project.flatMap { load(project: $0) }
        let globalCatalog = load(fileURL: globalURL)

        let projectGrammars: [FilenameGrammar] = (projectCatalog?.grammars ?? []).map {
            var g = $0
            g.scope = .project
            return g
        }

        let baseGlobalGrammars = (globalCatalog?.grammars.isEmpty == false)
            ? globalCatalog!.grammars
            : FilenameGrammarCatalog.standardDefaults

        let globalGrammars: [FilenameGrammar] = baseGlobalGrammars.map {
            var g = $0
            g.scope = .global
            return g
        }

        let activeID = projectCatalog?.activeGrammarID
            ?? projectGrammars.first(where: { $0.isDefault })?.id
            ?? globalCatalog?.activeGrammarID
            ?? globalGrammars.first(where: { $0.isDefault })?.id
            ?? projectGrammars.first?.id
            ?? globalGrammars.first?.id

        return (projectGrammars, globalGrammars, activeID)
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
                let scopeRaw = item.value(for: "scope")?.scalarValue
                let scope = scopeRaw.flatMap { FilenameGrammarScope(rawValue: $0) }

                var fields: [GrammarField] = []
                if let fieldList = item.value(for: "fields")?.listItems {
                    for fNode in fieldList {
                        guard let fName = fNode.value(for: "name")?.scalarValue else { continue }
                        let fRole = fNode.value(for: "role")?.scalarValue ?? "Remarks"
                        let fTypeRaw = fNode.value(for: "type")?.scalarValue ?? ""
                        let fType = GrammarFieldType(rawValue: fTypeRaw) ?? .string
                        let fHint = fNode.value(for: "format_hint")?.scalarValue ?? ""
                        let fStrip = (fNode.value(for: "strip_brackets")?.scalarValue?.lowercased() == "true")
                        let fOpt = (fNode.value(for: "is_optional")?.scalarValue?.lowercased() == "true")
                        let fFacet = (fNode.value(for: "is_facet")?.scalarValue?.lowercased() != "false")
                        fields.append(GrammarField(
                            name: fName,
                            role: fRole,
                            type: fType,
                            formatHint: fHint,
                            stripBrackets: fStrip,
                            isOptional: fOpt,
                            isFacet: fFacet
                        ))
                    }
                }

                grammars.append(FilenameGrammar(
                    id: id,
                    name: name,
                    template: template,
                    description: desc,
                    fields: fields,
                    isDefault: isDef,
                    scope: scope
                ))
            }
        }

        guard !grammars.isEmpty else { return nil }
        return FilenameGrammarCatalog(grammars: grammars, activeGrammarID: activeID)
    }
}
