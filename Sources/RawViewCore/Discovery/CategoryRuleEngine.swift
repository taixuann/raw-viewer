import Foundation

public struct SemanticTokenElement: Sendable, Equatable, Identifiable {
    public static let standardRoles = [
        "Instrument",
        "Mode",
        "Study",
        "Library",
        "Device ID",
        "Date & Time",
        "Remarks"
    ]

    public static let standardDateFormats = [
        "DDMMYYYY-HHmmSS",
        "DDMMYY-HHmmSS",
        "YYYYMMDD-HHmmSS",
        "YYMMDD-HHmmSS",
        "DDMMYYYY",
        "DDMMYY",
        "YYYYMMDD"
    ]

    public var id = UUID()
    public var index: Int
    public var token: String
    public var tagName: String        // User-defined element name e.g. "Operator", "Cell", "Batch"
    public var role: String           // One of standardRoles
    public var formatHint: String     // e.g. "DDMMYY-HHmmSS"

    public init(id: UUID = UUID(), index: Int = 0, token: String, tagName: String = "", role: String = "Remarks", formatHint: String = "") {
        self.id = id
        self.index = index
        self.token = token
        self.tagName = tagName
        self.role = role
        self.formatHint = formatHint
    }
}

/// Declarative rules for extracting semantic facts (category, device, timestamp)
/// from measurement filenames based on configurable delimiters and token indexes.
public struct CategoryRule: Sendable, Equatable {
    public let delimiters: [String]
    public let categoryIndex: Int?
    public let deviceIndex: Int?
    public let dateIndex: Int?
    public let categoryMap: [String: String]
    public let elements: [SemanticTokenElement]

    public init(
        delimiters: [String] = ["_"],
        categoryIndex: Int? = nil,
        deviceIndex: Int? = nil,
        dateIndex: Int? = nil,
        categoryMap: [String: String] = [:],
        elements: [SemanticTokenElement] = []
    ) {
        self.delimiters = delimiters.isEmpty ? ["_"] : delimiters
        self.categoryIndex = categoryIndex
        self.deviceIndex = deviceIndex
        self.dateIndex = dateIndex
        self.categoryMap = categoryMap
        self.elements = elements
    }
}

public struct ExtractedFacts: Sendable, Equatable {
    public let timestamp: String?
    public let deviceID: String?
    public let category: String?

    public init(timestamp: String? = nil, deviceID: String? = nil, category: String? = nil) {
        self.timestamp = timestamp
        self.deviceID = deviceID
        self.category = category
    }
}

public enum CategoryRuleEngine {
    public static let relativePath = ".rawviewer/view/category.yaml"

    public static func save(rules: CategoryRule, project: ProjectContext) throws {
        let dir = project.root.appendingPathComponent(".rawviewer/view", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("category.yaml")

        var yaml = "delimiters:\n"
        for d in rules.delimiters {
            yaml += "  - \"\(d)\"\n"
        }
        if let catIdx = rules.categoryIndex {
            yaml += "category_index: \(catIdx)\n"
        }
        if let devIdx = rules.deviceIndex {
            yaml += "device_index: \(devIdx)\n"
        }
        if let dateIdx = rules.dateIndex {
            yaml += "date_index: \(dateIdx)\n"
        }
        if !rules.categoryMap.isEmpty {
            yaml += "category_map:\n"
            for (k, v) in rules.categoryMap.sorted(by: { $0.key < $1.key }) {
                yaml += "  \(k): \"\(v)\"\n"
            }
        }
        if !rules.elements.isEmpty {
            yaml += "elements:\n"
            for el in rules.elements {
                yaml += "  - index: \(el.index)\n"
                yaml += "    token: \"\(el.token)\"\n"
                yaml += "    tag_name: \"\(el.tagName)\"\n"
                yaml += "    role: \"\(el.role)\"\n"
                yaml += "    format_hint: \"\(el.formatHint)\"\n"
            }
        }
        try yaml.write(to: file, atomically: true, encoding: .utf8)
    }

    public static func load(project: ProjectContext) -> CategoryRule? {
        let file = project.root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8),
              let node = try? YAMLParser.parse(text) else {
            return nil
        }
        return parse(node: node)
    }

    static func parse(node: YAMLNode) -> CategoryRule? {
        var delimiters: [String] = ["_"]
        if let delimsNode = node.value(for: "delimiters") {
            if let seq = delimsNode.listItems {
                delimiters = seq.compactMap(\.scalarValue).filter { !$0.isEmpty }
            } else if let scalar = delimsNode.scalarValue {
                delimiters = [scalar]
            }
        }

        let catIdx = node.value(for: "category_index")?.scalarValue.flatMap(Int.init)
        let devIdx = node.value(for: "device_index")?.scalarValue.flatMap(Int.init)
        let dateIdx = node.value(for: "date_index")?.scalarValue.flatMap(Int.init)

        var map: [String: String] = [:]
        if let mapEntries = node.value(for: "category_map")?.mapEntries {
            for entry in mapEntries {
                if let val = entry.value.scalarValue {
                    map[entry.key] = val
                }
            }
        }

        var parsedElements: [SemanticTokenElement] = []
        if let elList = node.value(for: "elements")?.listItems {
            for elNode in elList {
                guard let idxStr = elNode.value(for: "index")?.scalarValue, let idx = Int(idxStr),
                      let tok = elNode.value(for: "token")?.scalarValue else { continue }
                let tagName = elNode.value(for: "tag_name")?.scalarValue ?? ""
                let role = elNode.value(for: "role")?.scalarValue ?? "metadata"
                let hint = elNode.value(for: "format_hint")?.scalarValue ?? ""
                parsedElements.append(SemanticTokenElement(index: idx, token: tok, tagName: tagName, role: role, formatHint: hint))
            }
        }

        return CategoryRule(
            delimiters: delimiters,
            categoryIndex: catIdx,
            deviceIndex: devIdx,
            dateIndex: dateIdx,
            categoryMap: map,
            elements: parsedElements
        )
    }

    /// Splits a filename into tokens using the specified delimiters, stripping the file extension.
    public static func tokenize(filename: String, delimiters: [String]) -> [String] {
        var base = filename
        if let dot = base.lastIndex(of: ".") {
            base = String(base[..<dot])
        }
        var tokens = [base]
        for delim in delimiters where !delim.isEmpty {
            tokens = tokens.flatMap { token in
                token.components(separatedBy: delim).filter { !$0.isEmpty }
            }
        }
        return tokens
    }

    /// Extracts facts from a filename using declarative rules, falling back to legacy heuristics if not configured.
    public static func extract(from filename: String, rules: CategoryRule? = nil) -> ExtractedFacts {
        let legacy = InstrumentReader.parseFilename(filename)
        guard let rules = rules else {
            return ExtractedFacts(timestamp: legacy.timestamp, deviceID: legacy.deviceID, category: legacy.category)
        }

        let tokens = tokenize(filename: filename, delimiters: rules.delimiters)

        var category: String? = nil
        let effectiveCatIdx = rules.categoryIndex ?? rules.elements.first(where: { $0.role == "category" })?.index
        if let idx = effectiveCatIdx, idx >= 0 && idx < tokens.count {
            let raw = tokens[idx]
            category = rules.categoryMap[raw] ?? raw
        } else {
            category = legacy.category
        }

        var deviceID: String? = nil
        let effectiveDevIdx = rules.deviceIndex ?? rules.elements.first(where: { $0.role == "legend" })?.index
        if let idx = effectiveDevIdx, idx >= 0 && idx < tokens.count {
            deviceID = tokens[idx]
        } else {
            deviceID = legacy.deviceID
        }

        var timestamp: String? = nil
        let effectiveDateIdx = rules.dateIndex ?? rules.elements.first(where: { $0.tagName.lowercased().contains("date") || $0.tagName.lowercased().contains("time") })?.index
        if let idx = effectiveDateIdx, idx >= 0 && idx < tokens.count {
            timestamp = tokens[idx]
        } else {
            timestamp = legacy.timestamp
        }

        return ExtractedFacts(timestamp: timestamp, deviceID: deviceID, category: category)
    }
}
