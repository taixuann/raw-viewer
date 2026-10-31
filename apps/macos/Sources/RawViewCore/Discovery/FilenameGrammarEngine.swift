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
    /// Optional legacy role. Nil means variable-native: the template
    /// variable itself is the metadata identity (`{batch}` is `batch`).
    /// Old role-bearing catalogs load with their mapping preserved until
    /// explicitly edited; new saves omit nil roles. Compatible schema-1
    /// extension: no second display-name property exists.
    public var role: String?
    public var type: GrammarFieldType
    public var formatHint: String
    public var stripBrackets: Bool
    public var isOptional: Bool
    public var isFacet: Bool

    public init(
        name: String,
        role: String? = nil,
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
            id: "standard-scientific",
            name: "Standard Filename Pattern",
            template: "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]_f.[{flags}]_{batch}",
            description: "Default pattern for electrochemistry measurement series",
            fields: [
                GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "DDMMYY-HHmmSS"),
                GrammarField(name: "instrument", role: "Instrument", type: .string),
                GrammarField(name: "mode", role: "Mode", type: .string),
                GrammarField(name: "device-id", role: "Device ID", type: .string, stripBrackets: true),
                GrammarField(name: "study", role: "Study", type: .string),
                GrammarField(name: "remarks", role: "Remarks", type: .string, stripBrackets: true, isOptional: true),
                GrammarField(name: "flags", role: "flags", type: .string, stripBrackets: true, isOptional: true),
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

public enum GrammarCatalogError: Error, LocalizedError, Equatable {
    case fileNotFound(path: String)
    case parseFailed(path: String, message: String)
    case invalidSchemaVersion(found: String?)
    case duplicateGrammarID(String)
    case duplicateField(grammar: String, field: String)
    case duplicateVariable(grammar: String, variable: String)
    case missingFieldDefinition(grammar: String, variable: String)
    case undeclaredField(grammar: String, field: String)
    case unknownType(field: String, found: String?)
    case incompatibleFormat(field: String, format: String)
    case emptyRole(field: String)
    case referencedVariable(grammar: String, variable: String, references: [String])
    case unexpectedKey(scope: String, key: String)
    case invalidGrammar(grammar: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Grammar catalog not found: \(path)"
        case .parseFailed(let path, let message):
            return "Cannot parse grammar catalog \(path): \(message)"
        case .invalidSchemaVersion(let found):
            return "Unsupported grammar schema_version '\(found ?? "missing")'; expected 1"
        case .duplicateGrammarID(let id):
            return "Duplicate grammar id '\(id)'"
        case .duplicateField(let grammar, let field):
            return "Grammar '\(grammar)' declares field '\(field)' more than once"
        case .duplicateVariable(let grammar, let variable):
            return "Grammar '\(grammar)' template repeats variable '\(variable)'"
        case .missingFieldDefinition(let grammar, let variable):
            return "Grammar '\(grammar)' template variable '\(variable)' has no field definition"
        case .undeclaredField(let grammar, let field):
            return "Grammar '\(grammar)' field '\(field)' does not appear in its template"
        case .unknownType(let field, let found):
            return "Field '\(field)' has unknown type '\(found ?? "missing")'; expected string, number or datetime"
        case .incompatibleFormat(let field, let format):
            return "Field '\(field)' format '\(format)' is incompatible with string type"
        case .emptyRole(let field):
            return "Field '\(field)' role must be a nonempty metadata key"
        case .referencedVariable(let grammar, let variable, let references):
            return "Variable '\(variable)' in grammar '\(grammar)' is still referenced by \(references.joined(separator: ", ")); remove the references before renaming"
        case .unexpectedKey(let scope, let key):
            return "\(scope) contains unexpected key '\(key)'"
        case .invalidGrammar(let grammar, let reason):
            return "Grammar '\(grammar)' is invalid: \(reason)"
        }
    }
}

/// Fail-closed deletion guard: every case preserves the target file and
/// in-memory state; the caller reports the reason and changes nothing.
public enum SafeDeleteError: Error, LocalizedError, Equatable {
    case notProjectOwned(path: String)
    case symlinkRefused(path: String)
    case changedOnDisk(path: String)
    case unreadableTarget(path: String)
    case dependentsUnreadable(detail: String)

    public var errorDescription: String? {
        switch self {
        case .notProjectOwned(let path):
            return "'\(path)' is not a project-owned canonical file; only .rawviewer/instrument/ YAML files can be deleted"
        case .symlinkRefused(let path):
            return "'\(path)' is a symlink; symlinks are never followed for deletion"
        case .changedOnDisk(let path):
            return "'\(path)' was deleted, renamed, or changed on disk; reload before deleting"
        case .unreadableTarget(let path):
            return "'\(path)' could not be verified for deletion; nothing was deleted"
        case .dependentsUnreadable(let detail):
            return "references could not be fully inspected (\(detail)); deletion blocked"
        }
    }
}

public enum FilenameGrammarEngine {
    /// Canonical project-owned grammar catalog (schema v1).
    public static let relativePath = ".rawviewer/grammar.yaml"
    /// Previous storage location. Read only when the canonical file is absent;
    /// a malformed canonical file is an error, never a legacy fallback.
    public static let legacyRelativePath = ".rawviewer/view/grammar.yaml"
    /// Grammar catalog schema version written and accepted by this engine.
    public static let schemaVersion = 1

    public static var globalGrammarURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rawviewer/grammar.yaml")
    }

    // MARK: - Stable role keys

    /// Explicit legacy-label to stable-key mapping. Custom nonempty roles pass
    /// through unchanged. There is deliberately no variable-name inference here.
    private static let canonicalRoleKeys: [String: String] = [
        "date & time": "datetime",
        "datetime": "datetime",
        "instrument": "instrument",
        "mode": "mode",
        "study": "study",
        "category": "category",
        "device id": "device",
        "device": "device",
        "remarks": "remarks",
        "batch": "batch",
        "library": "library",
    ]

    /// Stable-key to UI-label mapping for in-memory display.
    private static let roleDisplayNames: [String: String] = [
        "datetime": "Date & Time",
        "instrument": "Instrument",
        "mode": "Mode",
        "study": "Study",
        "device": "Device ID",
        "remarks": "Remarks",
        "batch": "Batch",
        "library": "Library",
    ]

    /// Stable metadata key for a stored or in-memory role value.
    public static func canonicalRoleKey(for role: String) -> String {
        canonicalRoleKeys[role.lowercased()] ?? role
    }

    /// UI label for a stored stable role key; custom keys display as-is.
    public static func displayRole(for role: String) -> String {
        roleDisplayNames[role] ?? role
    }

    /// Ordered variable names declared in a template, e.g. ["date", "study"].
    public static func templateVariables(in template: String) -> [String] {
        var names: [String] = []
        var scan = template.startIndex
        while scan < template.endIndex {
            guard let open = template[scan...].firstIndex(of: "{"),
                  let close = template[open...].firstIndex(of: "}") else { break }
            let name = String(template[template.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
            scan = template.index(after: close)
        }
        return names
    }

    private static let dataExtensions: Set<String> = [
        "csv", "txt", "tsv", "dat", "asc", "log", "json", "yaml", "yml", "xlsx", "xls",
    ]

    static func stripDataExtension(_ filename: String, template: String) -> String {
        let lower = filename.lowercased()
        for ext in dataExtensions {
            let suffix = ".\(ext)"
            if lower.hasSuffix(suffix) {
                if template.hasSuffix(suffix) { return filename }
                return String(filename.dropLast(suffix.count))
            }
        }
        return filename
    }

    private static func tailIsOptionalOnly(_ template: String, from start: String.Index, fields: [GrammarField]) -> Bool {
        var scan = start
        while scan < template.endIndex {
            guard let open = template[scan...].firstIndex(of: "{"),
                  let close = template[open...].firstIndex(of: "}") else { break }
            let name = String(template[template.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            guard fields.first(where: { $0.name == name })?.isOptional == true else { return false }
            scan = template.index(after: close)
            if scan < template.endIndex && template[scan] == "]" {
                scan = template.index(after: scan)
            }
        }
        return true
    }

    private static func patternForField(
        _ field: GrammarField?,
        nextLeading: String,
        categoryStyle: Bool
    ) -> String {
        guard let field = field else {
            return nextLeading.isEmpty ? "(.+)" : (nextLeading.count == 1 ? "(.+?)" : "(.+?)")
        }
        switch field.type {
        case .number:
            let fmt = field.formatHint.trimmingCharacters(in: .whitespaces)
            if fmt == "01" || fmt.lowercased().contains("2-digit") { return "(\\d{2})" }
            if fmt == "001" || fmt.lowercased().contains("3-digit") { return "(\\d{3})" }
            if fmt == "0.0" || fmt.lowercased() == "decimal" { return "(\\d+(?:\\.\\d+)?)" }
            return "(\\d+)"
        case .datetime:
            let fmt = field.formatHint.trimmingCharacters(in: .whitespaces)
            if fmt == "yyyyMMdd" { return "(\\d{8})" }
            if fmt == "yyMMdd" { return "(\\d{6})" }
            if fmt == "yyyy-MM-dd" { return "(\\d{4}-\\d{2}-\\d{2})" }
            if fmt == "HHmmss" { return "(\\d{6})" }
            if fmt == "HHmm" { return "(\\d{4})" }
            if fmt == "DDMMYY-HHmmSS" || fmt == "yyMMdd-HHmmss" { return "(\\d{6}-\\d{6})" }
            return nextLeading.isEmpty ? "(.+)" : "(.+?)"
        case .string:
            if categoryStyle { return "([^_]+(?:\\.[^_]+)*)" }
            if nextLeading.isEmpty { return "(.+)" }
            if nextLeading.count == 1 {
                let ch = nextLeading[nextLeading.startIndex]
                if ch == "." || ch == "_" { return "([^._]+)" }
                return "([^" + NSRegularExpression.escapedPattern(for: String(ch)) + "]+?)"
            }
            return "(.+?)"
        }
    }

    /// Compiles a human-readable template like `{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]`
    /// into a regular expression and an ordered list of variable names.
    public static func compile(template: String, fields: [GrammarField] = []) throws -> (regex: NSRegularExpression, fieldNames: [String]) {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GrammarCompileError.emptyTemplate }

        var pattern = "^"
        var fieldNames: [String] = []
        var scanIndex = trimmed.startIndex
        while scanIndex < trimmed.endIndex {
            guard let openBrace = trimmed[scanIndex...].firstIndex(of: "{") else {
                pattern += NSRegularExpression.escapedPattern(for: String(trimmed[scanIndex...]))
                break
            }
            var leading = openBrace > scanIndex ? String(trimmed[scanIndex..<openBrace]) : ""
            let bracketed = leading.hasSuffix("[")
            if bracketed { leading.removeLast() }

            guard let closeBrace = trimmed[openBrace...].firstIndex(of: "}") else {
                throw GrammarCompileError.unclosedToken(token: String(trimmed[openBrace...]))
            }
            let varName = String(trimmed[trimmed.index(after: openBrace)..<closeBrace]).trimmingCharacters(in: .whitespaces)
            fieldNames.append(varName)
            let fieldConfig = fields.first(where: { $0.name == varName })
            let isOptional = fieldConfig?.isOptional ?? false

            var afterVar = trimmed.index(after: closeBrace)
            if bracketed {
                guard afterVar < trimmed.endIndex, trimmed[afterVar] == "]" else {
                    throw GrammarCompileError.invalidRegex(reason: "Bracketed variable '\(varName)' must close with ']'")
                }
                afterVar = trimmed.index(after: afterVar)
            }

            var nextLeadingRaw = ""
            if afterVar < trimmed.endIndex, let nextOpen = trimmed[afterVar...].firstIndex(of: "{") {
                nextLeadingRaw = String(trimmed[afterVar..<nextOpen])
            }
            var nextLeading = nextLeadingRaw
            if nextLeading.hasSuffix("[") { nextLeading.removeLast() }
            let categoryStyle = fieldConfig?.type == .string
                && tailIsOptionalOnly(trimmed, from: afterVar, fields: fields)
                && (nextLeading.isEmpty || nextLeading.hasPrefix("_r."))
            let captureGroup = patternForField(fieldConfig, nextLeading: nextLeading, categoryStyle: categoryStyle)

            var body = ""
            if !leading.isEmpty { body += NSRegularExpression.escapedPattern(for: leading) }
            if bracketed {
                body += "\\[" + captureGroup + "\\]"
            } else {
                body += captureGroup
            }
            if isOptional {
                pattern += "(?:\(body))?"
            } else {
                pattern += body
            }
            scanIndex = afterVar
        }
        pattern += "$"

        do {
            return (try NSRegularExpression(pattern: pattern, options: []), fieldNames)
        } catch {
            throw GrammarCompileError.invalidRegex(reason: error.localizedDescription)
        }
    }

    /// Extracts semantic facts from a filename according to the given grammar.
    public static func extract(from filename: String, grammar: FilenameGrammar) -> ExtractedGrammarFacts {
        guard let (regex, fieldNames) = try? compile(template: grammar.template, fields: grammar.fields) else {
            return ExtractedGrammarFacts(isMatched: false, unmatchedReason: "Invalid template syntax")
        }

        var target = stripDataExtension(filename, template: grammar.template)
        let trimmed = grammar.template.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(target.startIndex..<target.endIndex, in: target)
        var match = regex.firstMatch(in: target, options: [], range: range)
        var activeFieldNames = fieldNames
        let isFullMatch = (match != nil)

        // If full string regex match fails, perform progressive prefix matching from N-1 down to 1 token
        if match == nil && fieldNames.count > 1 {
            for count in stride(from: fieldNames.count - 1, through: 2, by: -1) {
                // Build a prefix template up through the close brace of the count-th token plus the following literal/delimiter
                var matchedClose = trimmed.startIndex
                var foundCount = 0
                var sIdx = trimmed.startIndex
                while sIdx < trimmed.endIndex && foundCount < count {
                    if let ob = trimmed[sIdx...].firstIndex(of: "{"), let cb = trimmed[ob...].firstIndex(of: "}") {
                        matchedClose = trimmed.index(after: cb)
                        if matchedClose < trimmed.endIndex && (trimmed[matchedClose] == "]" || trimmed[matchedClose] == ")") {
                            matchedClose = trimmed.index(after: matchedClose)
                        }
                        foundCount += 1
                        sIdx = matchedClose
                        // Include subsequent delimiter literal up to next {
                        if foundCount == count {
                            if let nextOb = trimmed[matchedClose...].firstIndex(of: "{") {
                                matchedClose = nextOb
                            }
                        }
                    } else {
                        break
                    }
                }

                if foundCount == count {
                    let subTemplate = String(trimmed[..<matchedClose])
                    if let (subRegex, subFieldNames) = try? compile(template: subTemplate, fields: grammar.fields) {
                        let subPattern = subRegex.pattern.hasSuffix("$") ? String(subRegex.pattern.dropLast()) : subRegex.pattern
                        if let prefixRegex = try? NSRegularExpression(pattern: subPattern, options: []) {
                            if let subMatch = prefixRegex.firstMatch(in: target, options: [], range: range) {
                                match = subMatch
                                activeFieldNames = subFieldNames
                                break
                            }
                        }
                    }
                }
            }
        }

        guard let effectiveMatch = match else {
            return ExtractedGrammarFacts(isMatched: false, unmatchedReason: "Filename does not match template pattern")
        }

        var extracted: [String: String] = [:]
        for (idx, name) in activeFieldNames.enumerated() {
            let groupIdx = idx + 1
            guard groupIdx < effectiveMatch.numberOfRanges else { continue }
            let groupRange = effectiveMatch.range(at: groupIdx)
            if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: target) {
                var value = String(target[swiftRange])
                let fieldConfig = grammar.fields.first(where: { $0.name == name })
                if fieldConfig?.stripBrackets == true,
                   value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                extracted[name] = value
            }
        }

        // Map extracted variables to semantic keys: explicit stable roles
        // keep the legacy mapping; variable-native fields use their own
        // identifier. No substring inference: undeclared roles stay available
        // as raw extracted fields (editor feedback) without routing semantics.
        var timestamp: String? = nil
        var instrument: String? = nil
        var mode: String? = nil
        var deviceID: String? = nil
        var category: String? = nil
        var batch: String? = nil
        var remarks: [String] = []

        for name in fieldNames {
            guard let val = extracted[name] else { continue }
            guard let fieldConfig = grammar.fields.first(where: { $0.name == name }) else { continue }
            // Variable-native fields (role == nil) are keyed by their own
            // identifier: {batch} is batch. Explicit roles keep the legacy
            // mapping. Undeclared variables stay raw-only; never inferred.
            let key: String
            if let role = fieldConfig.role, !role.isEmpty {
                key = canonicalRoleKey(for: role)
            } else {
                key = canonicalRoleKey(for: fieldConfig.name)
            }
            switch key {
            case "datetime":
                timestamp = val
            case "instrument":
                instrument = val
            case "mode":
                mode = val
            case "device":
                deviceID = val
            case "study", "category":
                category = val
            case "batch":
                batch = val
            case "remarks":
                remarks.append(val)
            default:
                break
            }
        }

        return ExtractedGrammarFacts(
            isMatched: isFullMatch,
            extractedFields: extracted,
            timestamp: timestamp,
            instrument: instrument,
            mode: mode,
            deviceID: deviceID,
            category: category,
            batch: batch,
            remarks: remarks,
            unmatchedReason: isFullMatch ? nil : "Partial match: trailing tokens differ"
        )
    }

    private static func yamlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Serializes a validated catalog to canonical schema-v1 YAML.
    /// Validation runs first, so serialization never emits an invalid document.
    /// Variable-native fields (nil role) omit the role line; explicit legacy
    /// roles are written back unchanged.
    public static func serializedYAML(catalog: FilenameGrammarCatalog) throws -> String {
        try validate(catalog: catalog)
        var lines: [String] = []
        lines.append("schema_version: 1")
        // An empty catalog persists as an explicit empty list (the state
        // left by deleting the final grammar), never as a missing key.
        guard !catalog.grammars.isEmpty else {
            lines.append("grammars: []")
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append("grammars:")
        for g in catalog.grammars {
            lines.append("  - id: \"\(yamlEscape(g.id))\"")
            lines.append("    name: \"\(yamlEscape(g.name))\"")
            lines.append("    template: \"\(yamlEscape(g.template))\"")
            if !g.description.isEmpty {
                lines.append("    description: \"\(yamlEscape(g.description))\"")
            }
            lines.append("    fields:")
            for f in g.fields {
                lines.append("      - name: \"\(yamlEscape(f.name))\"")
                if let role = f.role {
                    lines.append("        role: \"\(yamlEscape(canonicalRoleKey(for: role)))\"")
                }
                lines.append("        type: \"\(f.type.rawValue)\"")
                if !f.formatHint.isEmpty {
                    lines.append("        format: \"\(yamlEscape(f.formatHint))\"")
                }
                lines.append("        optional: \(f.isOptional)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Validates a catalog against the schema-v1 contract: unique grammar and
    /// field IDs, exact template-field correspondence, known types and
    /// type-compatible formats, and compilable templates.
    public static func validate(catalog: FilenameGrammarCatalog) throws {
        var seenIDs = Set<String>()
        for g in catalog.grammars {
            let label = g.id.isEmpty ? "grammars[?]" : g.id
            guard !g.id.isEmpty, !g.id.contains("\n") else {
                throw GrammarCatalogError.invalidGrammar(grammar: label, reason: "id must be nonempty single-line text")
            }
            guard seenIDs.insert(g.id).inserted else {
                throw GrammarCatalogError.duplicateGrammarID(g.id)
            }
            guard !g.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GrammarCatalogError.invalidGrammar(grammar: label, reason: "name must be nonempty")
            }
            let trimmed = g.template.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw GrammarCatalogError.invalidGrammar(grammar: label, reason: "template must be nonempty")
            }
            do {
                _ = try compile(template: g.template, fields: g.fields)
            } catch {
                throw GrammarCatalogError.invalidGrammar(grammar: label, reason: error.localizedDescription)
            }
            let variables = templateVariables(in: trimmed)
            var seenVariables = Set<String>()
            for v in variables {
                guard seenVariables.insert(v).inserted else {
                    throw GrammarCatalogError.duplicateVariable(grammar: label, variable: v)
                }
            }
            var seenFields = Set<String>()
            for f in g.fields {
                guard seenFields.insert(f.name).inserted else {
                    throw GrammarCatalogError.duplicateField(grammar: label, field: f.name)
                }
            }
            for v in variables {
                guard seenFields.contains(v) else {
                    throw GrammarCatalogError.missingFieldDefinition(grammar: label, variable: v)
                }
            }
            for f in g.fields {
                guard seenVariables.contains(f.name) else {
                    throw GrammarCatalogError.undeclaredField(grammar: label, field: f.name)
                }
                // Nil role means variable-native (identity is the variable
                // name). An explicit role must stay nonempty.
                if let role = f.role {
                    guard !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw GrammarCatalogError.emptyRole(field: f.name)
                    }
                }
                if f.type == .string, !f.formatHint.isEmpty {
                    throw GrammarCatalogError.incompatibleFormat(field: f.name, format: f.formatHint)
                }
            }
        }
    }

    /// A variable identifier is valid when it is nonempty, contains no
    /// whitespace, and contains none of {}[] — the characters that would
    /// break the existing template parser. Names are used verbatim: never
    /// title-cased or otherwise transformed.
    public static func isValidVariableName(_ name: String) -> Bool {
        !name.isEmpty
            && name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "{}[]")) == nil
    }

    /// Atomically renames a template variable: the `{old}` placeholder and
    /// the field definition change together; the role is untouched, so a
    /// legacy mapping survives renames until explicitly edited. Throws
    /// without mutating on unknown, invalid, duplicate, or referenced names.
    /// A name is referenced when a profile variant key, an Explorer view, or
    /// a source-label row for the same grammar still uses it — the error
    /// lists every affected reference and no cascade rewrite is performed.
    public static func renameVariable(
        in grammar: inout FilenameGrammar,
        from oldName: String,
        to newName: String,
        variantKeys: [String] = [],
        explorerViews: [ExplorerViewDefinition] = [],
        sourceLabels: [SourceLabelLayout] = []
    ) throws {
        let label = grammar.id.isEmpty ? "grammars[?]" : grammar.id
        guard grammar.fields.contains(where: { $0.name == oldName }) else {
            throw GrammarCatalogError.invalidGrammar(grammar: label, reason: "unknown variable '\(oldName)'")
        }
        guard newName != oldName else { return }
        guard isValidVariableName(newName) else {
            throw GrammarCatalogError.invalidGrammar(grammar: label, reason: "variable name '\(newName)' must be nonempty with no whitespace or {}[]")
        }
        let siblings = Set(templateVariables(in: grammar.template))
            .union(grammar.fields.map(\.name))
            .subtracting([oldName])
        guard !siblings.contains(newName) else {
            throw GrammarCatalogError.duplicateVariable(grammar: label, variable: newName)
        }
        var references: [String] = []
        if variantKeys.contains(oldName) {
            references.append("variant key '\(oldName)'")
        }
        for view in explorerViews where view.grammarID == grammar.id && view.variable == oldName {
            references.append("Explorer view '\(view.variable)'")
        }
        for layout in sourceLabels where layout.grammarID == grammar.id {
            for (index, row) in layout.rows.enumerated() where row.variables.contains(oldName) {
                references.append("source label row \(index + 1) ('\(oldName)')")
            }
        }
        guard references.isEmpty else {
            throw GrammarCatalogError.referencedVariable(grammar: label, variable: oldName, references: references)
        }
        var renamed = grammar
        renamed.template = templateReplacingVariable(in: grammar.template, from: oldName, to: newName)
        if let fIdx = renamed.fields.firstIndex(where: { $0.name == oldName }) {
            renamed.fields[fIdx].name = newName
        }
        grammar = renamed
    }

    /// Replaces `{old}` placeholders (inner whitespace tolerated) with
    /// `{new}`; all other template text passes through byte-identical.
    static func templateReplacingVariable(in template: String, from oldName: String, to newName: String) -> String {
        var out = ""
        var scan = template.startIndex
        while scan < template.endIndex {
            guard let open = template[scan...].firstIndex(of: "{"),
                  let close = template[open...].firstIndex(of: "}") else {
                out += template[scan...]
                break
            }
            let inner = String(template[template.index(after: open)..<close])
            out += template[scan...open]
            out += inner.trimmingCharacters(in: .whitespaces) == oldName ? newName : inner
            out += "}"
            scan = template.index(after: close)
        }
        return out
    }

    /// Saves the grammar catalog to a YAML file at the specified file URL.
    /// The catalog is validated before any write, so a failed save preserves
    /// the existing document. Output contains only schema-v1 keys: no
    /// variant-key flags, is_facet, scope, or active_grammar_id.
    public static func save(catalog: FilenameGrammarCatalog, fileURL: URL) throws {
        let yaml = try serializedYAML(catalog: catalog)
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Saves the grammar catalog to `.rawviewer/grammar.yaml` in the given project.
    public static func save(catalog: FilenameGrammarCatalog, project: ProjectContext) throws {
        let file = project.root.appendingPathComponent(relativePath)
        try save(catalog: catalog, fileURL: file)
    }

    /// Loads and strictly validates the canonical schema-v1 catalog from a file.
    /// A missing file throws fileNotFound; malformed content throws a
    /// validation error. The two are never conflated into a silent default.
    public static func load(fileURL: URL) throws -> FilenameGrammarCatalog {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GrammarCatalogError.fileNotFound(path: fileURL.path)
        }
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw GrammarCatalogError.parseFailed(path: fileURL.path, message: error.localizedDescription)
        }
        let node: YAMLNode
        do {
            node = try YAMLParser.parse(text)
        } catch let parseError as YAMLParseError {
            throw GrammarCatalogError.parseFailed(path: fileURL.path, message: parseError.localizedDescription)
        }
        do {
            return try parseCanonical(node: node)
        } catch let catalogError as GrammarCatalogError {
            throw catalogError
        } catch {
            throw GrammarCatalogError.parseFailed(path: fileURL.path, message: error.localizedDescription)
        }
    }

    /// Loads the canonical `.rawviewer/grammar.yaml` catalog in the project.
    /// Never falls back to the legacy path: a malformed canonical file is an
    /// error even when legacy definitions exist.
    public static func load(project: ProjectContext) throws -> FilenameGrammarCatalog {
        let file = project.root.appendingPathComponent(relativePath)
        return try load(fileURL: file)
    }

    /// Result of a legacy import: the migrated catalog plus human-reviewable
    /// diagnostics describing every guessed or dropped legacy semantic.
    public struct LegacyGrammarImport: Sendable, Equatable {
        public var catalog: FilenameGrammarCatalog
        public var diagnostics: [String]
    }

    /// Reads a legacy `.rawviewer/view/grammar.yaml` file without changing it.
    /// Missing types default to string and recognized display roles map to
    /// stable keys; each such decision is recorded in diagnostics for review.
    /// Legacy-only state (is_facet, is_default, scope, active_grammar_id) is
    /// kept in memory as compatibility state and never written to new output.
    public static func importLegacy(fileURL: URL) throws -> LegacyGrammarImport {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GrammarCatalogError.fileNotFound(path: fileURL.path)
        }
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw GrammarCatalogError.parseFailed(path: fileURL.path, message: error.localizedDescription)
        }
        let node: YAMLNode
        do {
            node = try YAMLParser.parse(text)
        } catch let parseError as YAMLParseError {
            throw GrammarCatalogError.parseFailed(path: fileURL.path, message: parseError.localizedDescription)
        }
        return parseLegacy(node: node)
    }

    /// Imports the legacy project grammar file. Throws fileNotFound when no
    /// legacy file exists.
    public static func importLegacy(project: ProjectContext) throws -> LegacyGrammarImport {
        let file = project.root.appendingPathComponent(legacyRelativePath)
        return try importLegacy(fileURL: file)
    }

    /// Best-effort display/menu helper. It never throws and never masks a
    /// malformed canonical file: when the canonical file exists but fails
    /// strict validation, that side resolves to empty (project) or the
    /// built-in defaults (global) instead of a silent legacy substitution.
    /// Legacy import runs only when the canonical file is absent. For the
    /// enforced save/load path, use throwing `load(project:)` instead.
    public static func loadCombined(
        project: ProjectContext?,
        globalURL: URL = globalGrammarURL
    ) -> (projectGrammars: [FilenameGrammar], globalGrammars: [FilenameGrammar], activeID: String?) {
        let projectCatalog: FilenameGrammarCatalog? = project.flatMap { ctx in
            let canonicalURL = ctx.root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: canonicalURL.path) {
                // Canonical present: strict read only. Malformed content
                // yields nil (empty project grammars), never legacy fallback.
                return try? load(fileURL: canonicalURL)
            }
            return try? importLegacy(project: ctx).catalog
        }
        // Global side is strict-only too: a malformed global file falls back
        // to the built-in defaults, never a lenient re-parse of its content.
        let globalCatalog: FilenameGrammarCatalog? = try? load(fileURL: globalURL)

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

    /// Strict schema-v1 parse: schema_version must be 1, only documented keys
    /// are accepted, and the result must validate. The role key is optional:
    /// absent means variable-native; present roles map to display labels
    /// exactly as before (legacy mapping is never reinterpreted on load).
    static func parseCanonical(node: YAMLNode) throws -> FilenameGrammarCatalog {
        guard let entries = node.mapEntries else {
            throw GrammarCatalogError.parseFailed(path: "", message: "catalog root must be a mapping")
        }
        for (key, _) in entries {
            guard key == "schema_version" || key == "grammars" else {
                throw GrammarCatalogError.unexpectedKey(scope: "grammar catalog", key: key)
            }
        }
        guard node.value(for: "schema_version")?.scalarValue == "1" else {
            throw GrammarCatalogError.invalidSchemaVersion(found: node.value(for: "schema_version")?.scalarValue)
        }
        guard let list = node.value(for: "grammars")?.listItems else {
            throw GrammarCatalogError.parseFailed(path: "", message: "grammars must be a YAML list")
        }
        var grammars: [FilenameGrammar] = []
        for (index, item) in list.enumerated() {
            let label = item.value(for: "id")?.scalarValue ?? "grammars[\(index)]"
            guard let itemEntries = item.mapEntries else {
                throw GrammarCatalogError.invalidGrammar(grammar: label, reason: "grammar must be a mapping")
            }
            for (key, _) in itemEntries {
                guard key == "id" || key == "name" || key == "template" || key == "description" || key == "fields" else {
                    throw GrammarCatalogError.unexpectedKey(scope: "grammar '\(label)'", key: key)
                }
            }
            guard let id = item.value(for: "id")?.scalarValue,
                  let name = item.value(for: "name")?.scalarValue,
                  let template = item.value(for: "template")?.scalarValue else {
                throw GrammarCatalogError.invalidGrammar(grammar: label, reason: "id, name and template are required")
            }
            let description = item.value(for: "description")?.scalarValue ?? ""
            var fields: [GrammarField] = []
            if let fieldList = item.value(for: "fields")?.listItems {
                for fNode in fieldList {
                    guard let fEntries = fNode.mapEntries else {
                        throw GrammarCatalogError.invalidGrammar(grammar: label, reason: "field must be a mapping")
                    }
                    for (key, _) in fEntries {
                        guard key == "name" || key == "role" || key == "type" || key == "format" || key == "optional" else {
                            throw GrammarCatalogError.unexpectedKey(scope: "field in grammar '\(label)'", key: key)
                        }
                    }
                    guard let fName = fNode.value(for: "name")?.scalarValue, !fName.isEmpty else {
                        throw GrammarCatalogError.invalidGrammar(grammar: label, reason: "field name is required")
                    }
                    // Absent role means variable-native; a present role must
                    // be nonempty and maps to its display label (legacy kept).
                    let fRoleRaw = fNode.value(for: "role")?.scalarValue
                    if let raw = fRoleRaw, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw GrammarCatalogError.emptyRole(field: fName)
                    }
                    let mappedRole: String? = fRoleRaw.map { displayRole(for: $0) }
                    guard let fTypeRaw = fNode.value(for: "type")?.scalarValue,
                          let fType = GrammarFieldType(rawValue: fTypeRaw) else {
                        throw GrammarCatalogError.unknownType(field: fName, found: fNode.value(for: "type")?.scalarValue)
                    }
                    let fFormat = fNode.value(for: "format")?.scalarValue ?? ""
                    if let optRaw = fNode.value(for: "optional")?.scalarValue?.lowercased() {
                        guard optRaw == "true" || optRaw == "false" else {
                            throw GrammarCatalogError.invalidGrammar(grammar: label, reason: "field '\(fName)' optional must be true or false")
                        }
                        fields.append(GrammarField(
                            name: fName,
                            role: mappedRole,
                            type: fType,
                            formatHint: fFormat,
                            isOptional: optRaw == "true"
                        ))
                    } else {
                        fields.append(GrammarField(
                            name: fName,
                            role: mappedRole,
                            type: fType,
                            formatHint: fFormat
                        ))
                    }
                }
            }
            grammars.append(FilenameGrammar(
                id: id,
                name: name,
                template: template,
                description: description,
                fields: fields
            ))
        }
        let catalog = FilenameGrammarCatalog(grammars: grammars)
        try validate(catalog: catalog)
        return catalog
    }

    /// Lenient legacy parse: tolerates absent files keys and legacy-only keys,
    /// records every normalization as a diagnostic for human review.
    static func parseLegacy(node: YAMLNode) -> LegacyGrammarImport {
        var diagnostics: [String] = ["Imported from legacy grammar definitions; review migrated semantics."]
        var activeID = node.value(for: "active_grammar_id")?.scalarValue
        if activeID != nil {
            diagnostics.append("Legacy active_grammar_id '\(activeID!)' is compatibility state only; not written to schema-v1 output.")
        }
        if activeID == "autolab-scientific" {
            activeID = "standard-scientific"
            diagnostics.append("Normalized legacy grammar id 'autolab-scientific' to 'standard-scientific'.")
        }

        var grammars: [FilenameGrammar] = []
        if let list = node.value(for: "grammars")?.listItems {
            for item in list {
                guard var id = item.value(for: "id")?.scalarValue,
                      var name = item.value(for: "name")?.scalarValue,
                      let template = item.value(for: "template")?.scalarValue else {
                    diagnostics.append("Skipped a legacy grammar entry missing id, name or template.")
                    continue
                }
                if id == "autolab-scientific" {
                    id = "standard-scientific"
                    diagnostics.append("Normalized legacy grammar id 'autolab-scientific' to 'standard-scientific'.")
                }
                if name.contains("Autolab USTH") {
                    name = "Standard Filename Pattern"
                    diagnostics.append("Normalized legacy grammar name to 'Standard Filename Pattern'.")
                }
                let desc = item.value(for: "description")?.scalarValue ?? ""
                let isDef = (item.value(for: "is_default")?.scalarValue?.lowercased() == "true")
                if item.value(for: "is_default") != nil {
                    diagnostics.append("Grammar '\(id)': legacy is_default is compatibility state only; not written to schema-v1 output.")
                }
                if item.value(for: "is_facet") != nil || item.value(for: "fields")?.listItems?.contains(where: { $0.value(for: "is_facet") != nil }) == true {
                    diagnostics.append("Grammar '\(id)': legacy is_facet is compatibility state only; not written to schema-v1 output.")
                }
                let scopeRaw = item.value(for: "scope")?.scalarValue
                let scope = scopeRaw.flatMap { FilenameGrammarScope(rawValue: $0) }

                var fields: [GrammarField] = []
                if let fieldList = item.value(for: "fields")?.listItems {
                    for fNode in fieldList {
                        guard let fName = fNode.value(for: "name")?.scalarValue else { continue }
                        let fRoleRaw = fNode.value(for: "role")?.scalarValue ?? "Remarks"
                        if fNode.value(for: "role") == nil {
                            diagnostics.append("Field '\(fName)': no legacy role; defaulted to Remarks for review.")
                        }
                        let mappedRole = displayRole(for: canonicalRoleKey(for: fRoleRaw))
                        if mappedRole != fRoleRaw {
                            diagnostics.append("Field '\(fName)': mapped legacy role '\(fRoleRaw)' to stable key '\(canonicalRoleKey(for: fRoleRaw))'.")
                        }
                        let fTypeRaw = fNode.value(for: "type")?.scalarValue
                        let fType: GrammarFieldType
                        if let raw = fTypeRaw, let known = GrammarFieldType(rawValue: raw) {
                            fType = known
                        } else {
                            fType = .string
                            diagnostics.append("Field '\(fName)': legacy type '\(fTypeRaw ?? "missing")' needs review; defaulted to string.")
                        }
                        var fHint = fNode.value(for: "format")?.scalarValue ?? fNode.value(for: "format_hint")?.scalarValue ?? ""
                        if fNode.value(for: "format_hint") != nil {
                            diagnostics.append("Field '\(fName)': mapped legacy format_hint to format.")
                        }
                        if fType == .string, !fHint.isEmpty {
                            diagnostics.append("Field '\(fName)': format '\(fHint)' is incompatible with string type; dropped for review.")
                            fHint = ""
                        }
                        let fStrip = (fNode.value(for: "strip_brackets")?.scalarValue?.lowercased() == "true")
                        let optRaw = fNode.value(for: "optional")?.scalarValue ?? fNode.value(for: "is_optional")?.scalarValue
                        if fNode.value(for: "is_optional") != nil {
                            diagnostics.append("Field '\(fName)': mapped legacy is_optional to optional.")
                        }
                        let fOpt = (optRaw?.lowercased() == "true")
                        let fFacet = (fNode.value(for: "is_facet")?.scalarValue?.lowercased() != "false")
                        fields.append(GrammarField(
                            name: fName,
                            role: mappedRole,
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
        } else {
            diagnostics.append("Legacy file defines no grammars list.")
        }

        return LegacyGrammarImport(
            catalog: FilenameGrammarCatalog(grammars: grammars, activeGrammarID: activeID),
            diagnostics: diagnostics
        )
    }

    // MARK: - Task 4: safe deletion guards

    /// Project-owned profile directories inspected for grammar references,
    /// including excluded/invalid files. Bundled examples are never project
    /// configuration and are not inspected.
    private static let grammarReferenceScanDirs = [
        ".rawviewer/instrument",
        "data/.rawview/instrument",
        "data/instruments/rawview",
        "data/instruments",
    ]

    /// Best-effort grammar_id for one profile file's text, found even in
    /// excluded files that fail full validation. Nil when no plausible
    /// key/value pair exists. Comment lines never count as references.
    static func referencedGrammarID(in text: String) -> String? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let keyRange = line.range(of: "grammar_id") else { continue }
            // The key must start the content or follow whitespace/list markup.
            let prefix = line[..<keyRange.lowerBound]
            guard prefix.allSatisfy({ $0.isWhitespace || $0 == "-" }) else { continue }
            let afterKey = line[keyRange.upperBound...]
            guard let colon = afterKey.firstIndex(of: ":") else { continue }
            var value = afterKey[afterKey.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    /// Human-readable dependents blocking deletion of one grammar entry:
    /// project profiles (valid and excluded alike), settings explorerViews,
    /// and settings sourceLabels. Empty means deletable. Throws fail-closed
    /// when any inspection fails, so an unreadable file never silently
    /// passes. Never mutates anything.
    public static func grammarDeleteBlockers(grammarID: String, projectRoot: URL) throws -> [String] {
        var blockers: [String] = []
        let settings: ProjectSettings?
        do {
            settings = try ProjectSettingsStore.load(projectRoot: projectRoot)
        } catch {
            throw SafeDeleteError.dependentsUnreadable(
                detail: "settings could not be inspected: \(error.localizedDescription)")
        }
        if let settings {
            for view in settings.explorerViews where view.grammarID == grammarID {
                blockers.append("Explorer view '\(view.variable)' uses grammar '\(grammarID)'")
            }
            for layout in settings.sourceLabels where layout.grammarID == grammarID {
                for (index, row) in layout.rows.enumerated() {
                    blockers.append(
                        "source label row \(index + 1) (\(row.variables.joined(separator: ", "))) uses grammar '\(grammarID)'")
                }
            }
        }
        for dir in grammarReferenceScanDirs {
            let dirURL = projectRoot.appendingPathComponent(dir, isDirectory: true)
            var dirStat = stat()
            guard lstat(dirURL.path, &dirStat) == 0 else {
                guard errno == ENOENT else {
                    throw SafeDeleteError.dependentsUnreadable(
                        detail: "\(dir) could not be examined (\(String(cString: strerror(errno)))).")
                }
                continue
            }
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: dirURL, includingPropertiesForKeys: nil)
            } catch {
                throw SafeDeleteError.dependentsUnreadable(
                    detail: "\(dir) could not be listed: \(error.localizedDescription)")
            }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let ext = entry.pathExtension.lowercased()
                guard ext == "yaml" || ext == "yml" else { continue }
                var entryStat = stat()
                guard lstat(entry.path, &entryStat) == 0 else {
                    throw SafeDeleteError.dependentsUnreadable(
                        detail: "\(entry.lastPathComponent) could not be examined; references unknown.")
                }
                guard (entryStat.st_mode & S_IFMT) == S_IFREG
                    || (entryStat.st_mode & S_IFMT) == S_IFLNK else {
                    throw SafeDeleteError.dependentsUnreadable(
                        detail: "\(entry.lastPathComponent) is not a readable file; references unknown.")
                }
                let text: String
                do {
                    text = try String(contentsOf: entry, encoding: .utf8)
                } catch {
                    throw SafeDeleteError.dependentsUnreadable(
                        detail: "\(entry.lastPathComponent) could not be read: \(error.localizedDescription)")
                }
                if referencedGrammarID(in: text) == grammarID {
                    blockers.append("profile '\(entry.lastPathComponent)' references grammar '\(grammarID)'")
                }
            }
        }
        return blockers.sorted()
    }

    /// Verifies a profile file may be deleted: it must be a regular,
    /// non-symlink file whose opened object still sits in the project-owned
    /// canonical `.rawviewer/instrument/` directory, and — when a baseline
    /// is known — byte-identical to it (external change/rename rejected).
    public static func verifyProfileDeleteTarget(
        at fileURL: URL, projectRoot: URL, expectedBytes: Data?
    ) throws {
        let name = fileURL.lastPathComponent
        let canonicalDir = SecureFile.kernelCanonical(
            projectRoot.appendingPathComponent(".rawviewer/instrument", isDirectory: true).path)
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else {
            throw SafeDeleteError.changedOnDisk(path: name)
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw SafeDeleteError.symlinkRefused(path: name)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw SafeDeleteError.notProjectOwned(path: name)
        }
        let handle: FileHandle
        do {
            handle = try SecureFile.openVerified(resolvedPath: fileURL.path, beneath: projectRoot.path)
        } catch let error as SecureOpenError {
            switch error {
            case .symlink: throw SafeDeleteError.symlinkRefused(path: name)
            case .missing: throw SafeDeleteError.changedOnDisk(path: name)
            case .unreadable: throw SafeDeleteError.unreadableTarget(path: name)
            case .escaped: throw SafeDeleteError.notProjectOwned(path: name)
            }
        }
        defer { try? handle.close() }
        guard let actual = SecureFile.canonicalPath(of: handle) else {
            throw SafeDeleteError.unreadableTarget(path: name)
        }
        let actualParent = URL(fileURLWithPath: actual).deletingLastPathComponent().path
        guard actualParent == canonicalDir else {
            throw SafeDeleteError.notProjectOwned(path: name)
        }
        // ponytail: bounded single read; profiles are capped at 1 MiB elsewhere,
        // so truncation can only mismatch (fail closed), never false-pass.
        let current: Data
        do {
            current = try handle.read(upToCount: 2 * 1024 * 1024) ?? Data()
        } catch {
            throw SafeDeleteError.unreadableTarget(path: name)
        }
        if let expected = expectedBytes, current != expected {
            throw SafeDeleteError.changedOnDisk(path: name)
        }
    }

    /// Verifies then removes exactly one project-owned profile file. Any
    /// failure throws with the file untouched.
    public static func deleteVerifiedProfile(
        at fileURL: URL, projectRoot: URL, expectedBytes: Data?
    ) throws {
        try verifyProfileDeleteTarget(at: fileURL, projectRoot: projectRoot, expectedBytes: expectedBytes)
        try FileManager.default.removeItem(at: fileURL)
    }
}
