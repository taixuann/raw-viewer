import Foundation

/// Status-capsule honesty (Task 3 L5): error text must never render with a
/// success icon. Matches every failure message the workspace emits
/// ("Save error:", "… FAILED (…)", "Failed …", "… error: …"); legacy-import
/// and grammar-warning notes stay non-error.
public func isErrorStatusMessage(_ message: String?) -> Bool {
    guard let text = message, !text.isEmpty else { return false }
    let lower = text.lowercased()
    return lower.contains("error") || lower.contains("failed")
}

public enum LineRegionType: String, Sendable, CaseIterable, Equatable {
    case unassigned = "Unassigned"
    case metadata = "Key-Value Metadata"
    case columnHeaders = "Column Names"
    case dataMatrix = "Data Matrix"

    public var badgeColorName: String {
        switch self {
        case .unassigned: return "gray"
        case .metadata: return "purple"
        case .columnHeaders: return "blue"
        case .dataMatrix: return "green"
        }
    }
}

public struct MetadataCellTag: Sendable, Equatable, Codable {
    public enum EntityType: String, Sendable, Equatable, Codable, CaseIterable {
        case instrumentName = "Instrument Name / Model"
        case instrumentID = "Instrument ID"
        case dateTime = "Date & Time"
        case dateOnly = "Date"
        case timeOnly = "Time"
        case operatorName = "Operator"
        case sampleName = "Sample Name"
        case technique = "Technique"
        case parameter = "Parameter"
        case ignore = "Ignored"
    }

    public let lineIndex: Int
    public let tokenIndex: Int
    public var rawValue: String
    public var entityType: EntityType
    public var customKey: String?
    public var format: String?
    public var parameterKey: String?
    public var parameterLineIndex: Int?
    public var parameterTokenIndex: Int?

    public init(
        lineIndex: Int,
        tokenIndex: Int,
        rawValue: String,
        entityType: EntityType,
        customKey: String? = nil,
        format: String? = nil,
        parameterKey: String? = nil,
        parameterLineIndex: Int? = nil,
        parameterTokenIndex: Int? = nil
    ) {
        self.lineIndex = lineIndex
        self.tokenIndex = tokenIndex
        self.rawValue = rawValue
        self.entityType = entityType
        self.customKey = customKey
        self.format = format
        self.parameterKey = parameterKey
        self.parameterLineIndex = parameterLineIndex
        self.parameterTokenIndex = parameterTokenIndex
    }
}

public enum ColumnRole: String, Sendable, Codable, CaseIterable {
    case channel = "channel"
    case x = "x"
    case y = "y"
    case progression = "progression"
    case skip = "skip"
}

public enum ProgressionType: String, Sendable, Codable, CaseIterable {
    case index = "Index / Step"
    case time = "Time"
    case custom = "Custom"
}

public enum ProgressionBehavior: String, Sendable, Codable, CaseIterable {
    case continuous = "continuous"
    case discrete = "discrete"

    public var displayName: String {
        switch self {
        case .continuous: return "Continuous"
        case .discrete: return "Discrete"
        }
    }
}

public struct ColumnDefinition: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var label: String
    public var quantity: String
    public var unit: String
    public var isXAxis: Bool
    public var isYAxis: Bool
    public var isDefaultX: Bool
    public var isDefaultY: Bool
    public var isSkipped: Bool
    public var role: ColumnRole
    /// Schema v3 `required: false`: the channel resolves when present and
    /// stays absent otherwise. Never drives default axes.
    public var isOptional: Bool
    public var progressionType: ProgressionType?
    public var progressionBehavior: ProgressionBehavior?
    public var customProgressionName: String?

    public init(
        name: String,
        label: String = "",
        quantity: String = "generic",
        unit: String = "",
        isXAxis: Bool = false,
        isYAxis: Bool = false,
        isDefaultX: Bool = false,
        isDefaultY: Bool = false,
        isSkipped: Bool = false,
        isOptional: Bool = false,
        role: ColumnRole? = nil,
        progressionType: ProgressionType? = nil,
        progressionBehavior: ProgressionBehavior? = nil,
        customProgressionName: String? = nil
    ) {
        self.name = name
        self.label = label.isEmpty ? name : label
        self.quantity = quantity
        self.unit = unit
        self.isXAxis = isXAxis
        self.isYAxis = isYAxis
        self.isDefaultX = isDefaultX
        self.isDefaultY = isDefaultY
        self.isSkipped = isSkipped
        self.isOptional = isOptional
        if let explicitRole = role {
            self.role = explicitRole
        } else if isSkipped {
            self.role = .skip
        } else if isXAxis {
            self.role = .x
        } else if isYAxis {
            self.role = .y
        } else {
            self.role = .channel
        }
        self.progressionType = progressionType
        self.progressionBehavior = progressionBehavior
        self.customProgressionName = customProgressionName
    }
}

public struct DetectedStructure: Sendable, Equatable {
    public let columnSeparator: String
    public let decimalDelimiter: String
    public let metadataPairs: [MetadataPair]
    public let headerLineIndex: Int?
    public let dataStartLineIndex: Int
    public let suggestedChannels: [ColumnDefinition]

    public struct MetadataPair: Sendable, Equatable {
        public let key: String
        public let value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public init(
        columnSeparator: String,
        decimalDelimiter: String,
        metadataPairs: [MetadataPair],
        headerLineIndex: Int?,
        dataStartLineIndex: Int,
        suggestedChannels: [ColumnDefinition]
    ) {
        self.columnSeparator = columnSeparator
        self.decimalDelimiter = decimalDelimiter
        self.metadataPairs = metadataPairs
        self.headerLineIndex = headerLineIndex
        self.dataStartLineIndex = dataStartLineIndex
        self.suggestedChannels = suggestedChannels
    }
}

/// State machine backing the 3-panel Visual Profile & View Editor Workspace.
public final class EditorWorkspaceModel: @unchecked Sendable {
    public static let maxPreviewLines = 10_000

    public var sampleFileURL: URL?
    public var lines: [String] = []
    public var lineTags: [Int: LineRegionType] = [:]
    public var headerLineIndex: Int? = nil // 0-based header line index
    public var dataStartLineIndex: Int = 1 // 0-based data matrix start index
    public var skippedMetadataLines: Set<Int> = [] // 1-based skipped metadata rows

    // Profile metadata
    public var instrumentID: String = ""
    public var instrumentName: String = ""
    public var modeID: String = "default"
    public var modeName: String = "Default Mode"
    public var delimiter: String = ","
    public var decimalDelimiter: String = "."

    // Columns
    public var columns: [ColumnDefinition] = []

    // Semantic Metadata Cell Tags: key is "\(lineIndex):\(tokenIndex)"
    public var metadataCellTags: [String: MetadataCellTag] = [:]

    // Token Segmentation for View / Category
    public var tokenDelimiters: [String] = ["_"]
    public var tokens: [String] = []
    public var selectedCategoryTokenIndex: Int? = nil
    public var selectedDeviceTokenIndex: Int? = nil

    public init() {}

    public func tagMetadataCell(
        lineIndex: Int,
        tokenIndex: Int,
        rawValue: String,
        entityType: MetadataCellTag.EntityType,
        customKey: String? = nil,
        format: String? = nil,
        parameterKey: String? = nil,
        parameterLineIndex: Int? = nil,
        parameterTokenIndex: Int? = nil
    ) {
        let key = "\(lineIndex):\(tokenIndex)"
        let tag = MetadataCellTag(
            lineIndex: lineIndex,
            tokenIndex: tokenIndex,
            rawValue: rawValue,
            entityType: entityType,
            customKey: customKey,
            format: format,
            parameterKey: parameterKey,
            parameterLineIndex: parameterLineIndex,
            parameterTokenIndex: parameterTokenIndex
        )
        metadataCellTags[key] = tag

        if entityType == .instrumentName {
            self.instrumentName = rawValue
            if self.instrumentID.isEmpty {
                self.instrumentID = rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            }
        } else if entityType == .instrumentID {
            self.instrumentID = rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }

    public func removeMetadataCellTag(lineIndex: Int, tokenIndex: Int) {
        let key = "\(lineIndex):\(tokenIndex)"
        metadataCellTags.removeValue(forKey: key)
    }

    /// Loads up to `maxPreviewLines` lines from a sample measurement file into memory.
    public func loadSample(url: URL) throws {
        self.sampleFileURL = url
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw NSError(domain: "EditorWorkspaceModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sample file is not readable text."])
        }

        var loadedLines: [String] = []
        text.enumerateLines { line, stop in
            loadedLines.append(line)
            if loadedLines.count >= Self.maxPreviewLines {
                stop = true
            }
        }
        self.lines = loadedLines
        self.lineTags = [:]

        // Update tokens from filename
        let filename = url.lastPathComponent
        self.tokens = CategoryRuleEngine.tokenize(filename: filename, delimiters: tokenDelimiters)
    }

    /// Tags a range of lines [startLine...endLine] with a specific region type.
    public func tagRange(from startLine: Int, to endLine: Int, as regionType: LineRegionType) {
        let low = max(0, min(startLine, endLine))
        let high = min(lines.count - 1, max(startLine, endLine))
        guard low <= high else { return }

        for line in low...high {
            lineTags[line] = regionType
        }

        if regionType == .columnHeaders {
            headerLineIndex = low
        } else if regionType == .dataMatrix {
            dataStartLineIndex = low
        }

        // If tagging column headers, attempt auto-extracting column names
        if regionType == .columnHeaders, low < lines.count {
            detectColumns(headerLine: lines[low])
        }
    }

    private func detectColumns(headerLine: String) {
        // Detect delimiter: tab, comma, semicolon
        let delim: String
        if headerLine.contains("\t") {
            delim = "\t"
        } else if headerLine.contains(";") {
            delim = ";"
        } else {
            delim = ","
        }
        self.delimiter = delim

        let parts = headerLine.components(separatedBy: delim).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var newCols: [ColumnDefinition] = []
        for (idx, col) in parts.enumerated() where !col.isEmpty {
            let isX = idx == 0
            let isY = idx > 0
            newCols.append(ColumnDefinition(name: col, label: col, isXAxis: isX, isYAxis: isY))
        }
        if !newCols.isEmpty {
            self.columns = newCols
        }
    }

    // MARK: - Primary / Default Channels for Plotting
    /// Resolves the primary default X channel for plotting:
    /// 1. Column explicitly marked `isDefaultX` (and not skipped)
    /// 2. If exactly one X column exists, that column is the default X
    /// 3. First non-skipped X column
    /// 4. Fallback to first non-skipped column
    public var primaryXColumn: ColumnDefinition? {
        let activeX = columns.filter { ($0.isXAxis || $0.role == .x) && !$0.isSkipped }
        if let explicit = activeX.first(where: { $0.isDefaultX }) {
            return explicit
        }
        if activeX.count == 1 {
            return activeX.first
        }
        return activeX.first ?? columns.first(where: { !$0.isSkipped })
    }

    /// Resolves the primary default Y channel for plotting:
    /// 1. Column explicitly marked `isDefaultY` (and not skipped)
    /// 2. If exactly one Y column exists, that column is the default Y
    /// 3. First non-skipped Y column
    /// 4. Fallback to second non-skipped column (or first)
    public var primaryYColumn: ColumnDefinition? {
        let activeY = columns.filter { ($0.isYAxis || $0.role == .y) && !$0.isSkipped }
        if let explicit = activeY.first(where: { $0.isDefaultY }) {
            return explicit
        }
        if activeY.count == 1 {
            return activeY.first
        }
        if let firstY = activeY.first {
            return firstY
        }
        let activeCols = columns.filter { !$0.isSkipped }
        return activeCols.count > 1 ? activeCols[1] : activeCols.first
    }

    /// Marks the specified column index as the primary default X channel for plotting.
    public func setDefaultX(at index: Int) {
        guard index < columns.count else { return }
        for i in 0..<columns.count {
            if i == index {
                columns[i].isDefaultX = true
                columns[i].isXAxis = true
                columns[i].role = .x
                columns[i].isSkipped = false
            } else {
                columns[i].isDefaultX = false
            }
        }
    }

    /// Marks the specified column index as the primary default Y channel for plotting.
    public func setDefaultY(at index: Int) {
        guard index < columns.count else { return }
        for i in 0..<columns.count {
            if i == index {
                columns[i].isDefaultY = true
                columns[i].isYAxis = true
                columns[i].role = .y
                columns[i].isSkipped = false
            } else {
                columns[i].isDefaultY = false
            }
        }
    }

    /// Automatically sniffs delimiters, metadata blocks, and data matrix boundaries.
    @discardableResult
    public func smartAutoDetect() -> DetectedStructure {
        guard !lines.isEmpty else {
            return DetectedStructure(
                columnSeparator: ",",
                decimalDelimiter: ".",
                metadataPairs: [],
                headerLineIndex: nil,
                dataStartLineIndex: 0,
                suggestedChannels: []
            )
        }

        // 1. Detect column separator: scan tab, semicolon, comma
        var candidateCounts = ["\t": 0, ";": 0, ",": 0]
        let inspectCount = min(lines.count, 50)
        for i in 0..<inspectCount {
            let l = lines[i]
            for sep in ["\t", ";", ","] {
                if l.contains(sep) {
                    candidateCounts[sep, default: 0] += 1
                }
            }
        }
        let chosenSeparator: String
        let tabs = candidateCounts["\t"] ?? 0
        let semis = candidateCounts[";"] ?? 0
        let commas = candidateCounts[","] ?? 0
        if tabs > 0 && tabs >= max(semis, commas) {
            chosenSeparator = "\t"
        } else if semis > 0 && semis >= commas {
            chosenSeparator = ";"
        } else {
            chosenSeparator = ","
        }

        // 2. Scan metadata & find dataStartLineIndex
        var metadata: [DetectedStructure.MetadataPair] = []
        var headerIndex: Int? = nil
        var dataStartIndex: Int = 0
        var foundDataStart = false
        var periodNumericCount = 0
        var commaNumericCount = 0

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let tokens = trimmed.components(separatedBy: chosenSeparator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var linePeriodCount = 0
            var lineCommaCount = 0
            for t in tokens {
                if Double(t) != nil {
                    linePeriodCount += 1
                } else if Double(t.replacingOccurrences(of: ",", with: ".")) != nil {
                    lineCommaCount += 1
                }
            }
            let numericCount = linePeriodCount + lineCommaCount

            if !tokens.isEmpty && Double(numericCount) / Double(tokens.count) >= 0.8 {
                periodNumericCount += linePeriodCount
                commaNumericCount += lineCommaCount
                if !foundDataStart {
                    dataStartIndex = idx
                    foundDataStart = true
                    if idx > 0 {
                        let prev = lines[idx - 1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !prev.isEmpty && !prev.hasPrefix("#") {
                            headerIndex = idx - 1
                        }
                    }
                    break
                }
            } else {
                if trimmed.contains(":") || trimmed.contains("=") || trimmed.hasPrefix("#") {
                    let cleaned = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
                    if let colonIdx = cleaned.firstIndex(of: ":") {
                        let k = String(cleaned[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                        let v = String(cleaned[cleaned.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                        metadata.append(DetectedStructure.MetadataPair(key: k, value: v))
                    } else if let eqIdx = cleaned.firstIndex(of: "=") {
                        let k = String(cleaned[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                        let v = String(cleaned[cleaned.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                        metadata.append(DetectedStructure.MetadataPair(key: k, value: v))
                    }
                }
            }
        }

        if !foundDataStart {
            dataStartIndex = max(0, lines.count - 1)
        }
        if headerIndex == nil && dataStartIndex > 0 {
            headerIndex = dataStartIndex - 1
        }

        // 3. Extract channels from headerLine
        var suggested: [ColumnDefinition] = []
        if let hIdx = headerIndex, hIdx < lines.count {
            let headerLine = lines[hIdx]
            let tokens = headerLine.components(separatedBy: chosenSeparator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var hasX = false
            for (idx, token) in tokens.enumerated() {
                var name = token
                var unit = ""
                if let openParen = token.firstIndex(of: "("), let closeParen = token.firstIndex(of: ")"), openParen < closeParen {
                    unit = String(token[token.index(after: openParen)..<closeParen]).trimmingCharacters(in: .whitespaces)
                    name = String(token[..<openParen]).trimmingCharacters(in: .whitespaces)
                } else if let openBracket = token.firstIndex(of: "["), let closeBracket = token.firstIndex(of: "]"), openBracket < closeBracket {
                    unit = String(token[token.index(after: openBracket)..<closeBracket]).trimmingCharacters(in: .whitespaces)
                    name = String(token[..<openBracket]).trimmingCharacters(in: .whitespaces)
                }

                let cleanName = name.isEmpty ? token : name
                let lower = token.lowercased()
                let isX: Bool
                let isY: Bool
                if !hasX && (lower.contains("volt") || lower.contains("time") || lower.contains("wave") || lower == "x" || lower.hasPrefix("v ") || lower.hasSuffix(" v")) {
                    isX = true
                    isY = false
                    hasX = true
                } else if hasX && (lower.contains("curr") || lower.contains("amp") || lower.contains("intens") || lower.contains("count") || lower == "y" || lower.hasPrefix("i ") || lower.hasSuffix(" a")) {
                    isX = false
                    isY = true
                } else if !hasX && idx == 0 {
                    isX = true
                    isY = false
                    hasX = true
                } else {
                    isX = false
                    isY = true
                }

                suggested.append(ColumnDefinition(
                    name: cleanName,
                    label: cleanName,
                    quantity: isX ? "sweep" : "signal",
                    unit: unit,
                    isXAxis: isX,
                    isYAxis: isY
                ))
            }
        }

        // Set boundaries directly (O(1) instead of 41,000 dictionary allocations)
        self.headerLineIndex = headerIndex
        self.dataStartLineIndex = dataStartIndex
        self.lineTags.removeAll()
        if let hIdx = headerIndex {
            self.lineTags[hIdx] = .columnHeaders
        }
        self.lineTags[dataStartIndex] = .dataMatrix

        let detectedDecimal = (chosenSeparator != "," && commaNumericCount > periodNumericCount) ? "," : "."
        self.decimalDelimiter = detectedDecimal
        self.delimiter = chosenSeparator
        if !suggested.isEmpty {
            self.columns = suggested
        }

        return DetectedStructure(
            columnSeparator: chosenSeparator,
            decimalDelimiter: detectedDecimal,
            metadataPairs: metadata,
            headerLineIndex: headerIndex,
            dataStartLineIndex: dataStartIndex,
            suggestedChannels: suggested
        )
    }

    /// Compiles current tags and column mappings into a valid RawView instrument YAML profile string.
    public func compileProfile() throws -> String {
        let cleanID = instrumentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "custom-instrument"
            : instrumentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = instrumentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? cleanID.capitalized
            : instrumentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModeID = modeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "default"
            : modeID.trimmingCharacters(in: .whitespacesAndNewlines)

        let headerRow = (headerLineIndex ?? 0) + 1
        let dataStartRow = dataStartLineIndex + 1

        var yaml = """
        schema_version: 1
        instrument:
          id: "\(cleanID)"
          name: "\(cleanName)"
        modes:
          - id: "\(cleanModeID)"
            name: "\(modeName)"
            table:
              delimiter: "\(delimiter == "\t" ? "\\t" : delimiter)"
        """
        if decimalDelimiter == "," {
            yaml += "\n      decimal_separator: \",\""
        }
        yaml += """

              header_row: \(headerRow)
              data_start_row: \(dataStartRow)
            channels:

        """

        if columns.isEmpty {
            yaml += """
                  - name: "x"
                    label: "X"
                    quantity: "generic"
                    is_x: true
                  - name: "y"
                    label: "Y"
                    quantity: "generic"
                    is_y: true

            """
        } else {
            for col in columns {
                if col.isSkipped {
                    yaml += """
                          - name: "\(col.name)"
                            label: "\(col.label)"
                            role: skip
                    """
                    yaml += "\n"
                    continue
                }
                yaml += """
                      - name: "\(col.name)"
                        label: "\(col.label)"
                        quantity: "\(col.quantity)"
                """
                if !col.unit.isEmpty {
                    yaml += "\n        unit: \"\(col.unit)\""
                }
                if col.isXAxis {
                    yaml += "\n        is_x: true"
                    if col.isDefaultX {
                        yaml += "\n        is_default_x: true"
                    }
                }
                if col.isYAxis {
                    yaml += "\n        is_y: true"
                    if col.isDefaultY {
                        yaml += "\n        is_default_y: true"
                    }
                }
                if col.role == .progression {
                    yaml += "\n        role: progression"
                    let dim: String
                    switch col.progressionType {
                    case .time: dim = "Time"
                    case .index: dim = "Scan"
                    case .custom: dim = col.customProgressionName?.isEmpty == false ? col.customProgressionName! : "Custom"
                    case .none: dim = "Progression"
                    }
                    yaml += "\n        progression_dimension: \"\(dim)\""
                    let beh = col.progressionBehavior?.rawValue ?? (col.progressionType == .time ? "continuous" : "discrete")
                    yaml += "\n        progression_behavior: \"\(beh)\""
                }
                yaml += "\n"
            }
        }

        if !metadataCellTags.isEmpty {
            yaml += "\n    metadata:\n"
            for tag in metadataCellTags.values.sorted(by: { $0.lineIndex == $1.lineIndex ? $0.tokenIndex < $1.tokenIndex : $0.lineIndex < $1.lineIndex }) {
                yaml += "      - line: \(tag.lineIndex + 1)\n"
                yaml += "        token: \(tag.tokenIndex + 1)\n"
                yaml += "        entity: \"\(tag.entityType.rawValue)\"\n"
                yaml += "        raw: \"\(tag.rawValue)\"\n"
                if let param = tag.parameterKey, !param.isEmpty {
                    yaml += "        parameter: \"\(param)\"\n"
                }
                if let pLine = tag.parameterLineIndex, let pTok = tag.parameterTokenIndex {
                    yaml += "        parameter_line: \(pLine + 1)\n"
                    yaml += "        parameter_token: \(pTok + 1)\n"
                }
                if let k = tag.customKey, !k.isEmpty {
                    yaml += "        key: \"\(k)\"\n"
                }
                if let fmt = tag.format, !fmt.isEmpty {
                    yaml += "        format: \"\(fmt)\"\n"
                }
            }
        }

        return yaml
    }

    /// Saves the compiled profile to `<project>/.rawviewer/instrument/<instrument_id>.yaml`.
    public func saveProfile(project: ProjectContext) throws -> URL {
        let yaml = try compileProfile()
        let dir = project.root.appendingPathComponent(".rawviewer/instrument", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(instrumentID.isEmpty ? "custom" : instrumentID).yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Loads an existing YAML profile from disk into this editor session.
    /// Supports:
    /// - RawView Schema v2 (formats block, format-level columns mapping/list, mode extracts)
    /// - RawView Schema v1 (formats block, columns list, mode x/y)
    /// - Custom Editor Workspace YAML (modes with table and channels)
    /// - Flat YAML files (root delimiter, root columns/channels)
    /// - Lenient text scanner if strict YAML parsing fails
    public func loadSavedProfile(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .windowsCP1252) else {
            throw NSError(domain: "EditorWorkspaceModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Profile file is not readable text."])
        }

        // Try standard YAMLParser first
        if let rootNode = try? YAMLParser.parse(content, allowIndentlessSequences: true) {
            parseFromYAMLNode(rootNode)
            if !columns.isEmpty || !instrumentID.isEmpty {
                return
            }
        }

        // If YAMLParser didn't populate columns or threw, run lenient text scanner
        parseFromLenientText(content)
    }

    private func parseFromYAMLNode(_ rootNode: YAMLNode) {
        // Parse instrument identity
        if let instNode = rootNode.value(for: "instrument") {
            if let id = instNode.value(for: "id")?.scalarValue { self.instrumentID = id }
            if let name = instNode.value(for: "name")?.scalarValue { self.instrumentName = name }
        } else {
            if let id = rootNode.value(for: "id")?.scalarValue { self.instrumentID = id }
            if let name = rootNode.value(for: "name")?.scalarValue { self.instrumentName = name }
        }

        // Extract mode details and plot axis intentions
        var xChannelKey: String? = nil
        var yChannelKeys: [String] = []
        let modeNodes = rootNode.value(for: "modes")?.listItems ?? (rootNode.value(for: "mode").map { [$0] } ?? [])
        let firstMode = modeNodes.first
        if let firstMode = firstMode {
            if let mID = firstMode.value(for: "id")?.scalarValue { self.modeID = mID }
            if let mName = firstMode.value(for: "name")?.scalarValue { self.modeName = mName }
            if let extract = firstMode.value(for: "extract") {
                xChannelKey = extract.value(for: "x")?.scalarValue
                if let yList = extract.value(for: "y")?.listItems {
                    yChannelKeys = yList.compactMap { $0.scalarValue }
                } else if let singleY = extract.value(for: "y")?.scalarValue {
                    yChannelKeys = [singleY]
                }
            }
            if xChannelKey == nil {
                xChannelKey = firstMode.value(for: "x")?.scalarValue
            }
            if yChannelKeys.isEmpty {
                if let yList = firstMode.value(for: "y")?.listItems {
                    yChannelKeys = yList.compactMap { $0.scalarValue }
                } else if let singleY = firstMode.value(for: "y")?.scalarValue {
                    yChannelKeys = [singleY]
                }
            }
        }

        // Extract delimiter & decimal separator
        let formats = rootNode.value(for: "formats")?.listItems
        let firstFormat = formats?.first

        var foundDelim: String? = nil
        var foundDec: String? = nil

        if let fmt = firstFormat {
            foundDelim = fmt.value(for: "delimiter")?.scalarValue
            foundDec = fmt.value(for: "decimal_separator")?.scalarValue ?? fmt.value(for: "decimal")?.scalarValue
        }
        if foundDelim == nil, let table = firstMode?.value(for: "table") {
            foundDelim = table.value(for: "delimiter")?.scalarValue
            foundDec = foundDec ?? table.value(for: "decimal_separator")?.scalarValue ?? table.value(for: "decimal")?.scalarValue
        }
        if foundDelim == nil, let rootTable = rootNode.value(for: "table") {
            foundDelim = rootTable.value(for: "delimiter")?.scalarValue
            foundDec = foundDec ?? rootTable.value(for: "decimal_separator")?.scalarValue ?? rootTable.value(for: "decimal")?.scalarValue
        }
        if foundDelim == nil {
            foundDelim = rootNode.value(for: "delimiter")?.scalarValue
            foundDec = foundDec ?? rootNode.value(for: "decimal_separator")?.scalarValue ?? rootNode.value(for: "decimal")?.scalarValue
        }

        if let delim = foundDelim {
            self.delimiter = (delim == "\\t") ? "\t" : delim
        }
        if let dec = foundDec {
            self.decimalDelimiter = dec
        }

        // Extract columns from format, mode channels, or root columns
        var parsedColumns: [ColumnDefinition] = []

        // Source A: format columns
        if let colsNode = firstFormat?.value(for: "columns") {
            parsedColumns = parseColumnsNode(colsNode, xKey: xChannelKey, yKeys: yChannelKeys)
        }
        // Source B: mode channels
        if parsedColumns.isEmpty, let channelsNode = firstMode?.value(for: "channels") {
            parsedColumns = parseColumnsNode(channelsNode, xKey: xChannelKey, yKeys: yChannelKeys)
        }
        // Source C: mode columns
        if parsedColumns.isEmpty, let modeColsNode = firstMode?.value(for: "columns") {
            parsedColumns = parseColumnsNode(modeColsNode, xKey: xChannelKey, yKeys: yChannelKeys)
        }
        // Source D: root columns
        if parsedColumns.isEmpty, let rootColsNode = rootNode.value(for: "columns") {
            parsedColumns = parseColumnsNode(rootColsNode, xKey: xChannelKey, yKeys: yChannelKeys)
        }
        // Source E: root channels
        if parsedColumns.isEmpty, let rootChannelsNode = rootNode.value(for: "channels") {
            parsedColumns = parseColumnsNode(rootChannelsNode, xKey: xChannelKey, yKeys: yChannelKeys)
        }

        if !parsedColumns.isEmpty {
            // Guarantee at least one X and one Y if not already designated
            if !parsedColumns.contains(where: { $0.isXAxis }) {
                parsedColumns[0].isXAxis = true
            }
            if !parsedColumns.contains(where: { $0.isYAxis }) && parsedColumns.count > 1 {
                parsedColumns[1].isYAxis = true
            }
            self.columns = parsedColumns
        }
    }

    private func parseColumnsNode(_ node: YAMLNode, xKey: String?, yKeys: [String]) -> [ColumnDefinition] {
        var result: [ColumnDefinition] = []
        if let map = node.mapEntries {
            for (key, colVal) in map {
                let header = colVal.value(for: "header")?.scalarValue ?? key
                let label = colVal.value(for: "label")?.scalarValue ?? header
                let quantity = colVal.value(for: "quantity")?.scalarValue ?? "generic"
                let unit = colVal.value(for: "unit")?.scalarValue ?? ""
                let explicitX = colVal.value(for: "is_x")?.scalarValue?.lowercased() == "true"
                let explicitY = colVal.value(for: "is_y")?.scalarValue?.lowercased() == "true"
                let explicitDefaultX = colVal.value(for: "is_default_x")?.scalarValue?.lowercased() == "true"
                let explicitDefaultY = colVal.value(for: "is_default_y")?.scalarValue?.lowercased() == "true"
                let matchesX = (key == xKey) || (header == xKey) || explicitX
                let matchesY = yKeys.contains(key) || yKeys.contains(header) || explicitY
                result.append(ColumnDefinition(
                    name: header,
                    label: label,
                    quantity: quantity,
                    unit: unit,
                    isXAxis: matchesX,
                    isYAxis: matchesY,
                    isDefaultX: explicitDefaultX,
                    isDefaultY: explicitDefaultY
                ))
            }
        } else if let items = node.listItems {
            for item in items {
                let name = item.value(for: "name")?.scalarValue
                    ?? item.value(for: "header")?.scalarValue
                    ?? item.scalarValue
                    ?? ""
                guard !name.isEmpty else { continue }
                let label = item.value(for: "label")?.scalarValue ?? name
                let quantity = item.value(for: "quantity")?.scalarValue ?? "generic"
                let unit = item.value(for: "unit")?.scalarValue ?? ""
                let explicitX = item.value(for: "is_x")?.scalarValue?.lowercased() == "true"
                let explicitY = item.value(for: "is_y")?.scalarValue?.lowercased() == "true"
                let explicitDefaultX = item.value(for: "is_default_x")?.scalarValue?.lowercased() == "true"
                let explicitDefaultY = item.value(for: "is_default_y")?.scalarValue?.lowercased() == "true"
                let matchesX = (name == xKey) || explicitX
                let matchesY = yKeys.contains(name) || explicitY
                result.append(ColumnDefinition(
                    name: name,
                    label: label,
                    quantity: quantity,
                    unit: unit,
                    isXAxis: matchesX,
                    isYAxis: matchesY,
                    isDefaultX: explicitDefaultX,
                    isDefaultY: explicitDefaultY
                ))
            }
        }
        return result
    }

    private func parseFromLenientText(_ content: String) {
        let lines = content.components(separatedBy: .newlines)
        var parsedCols: [ColumnDefinition] = []
        var inColumnsBlock = false
        var currentColName: String? = nil
        var currentColUnit: String = ""
        var currentColLabel: String = ""

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if (line.hasPrefix("id:") || line.hasPrefix("- id:")) && self.instrumentID.isEmpty {
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !val.isEmpty { self.instrumentID = val }
            }
            if (line.hasPrefix("name:") || line.hasPrefix("- name:")) && self.instrumentName.isEmpty {
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !val.isEmpty { self.instrumentName = val }
            }
            if line.hasPrefix("delimiter:") {
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if val == "\\t" { self.delimiter = "\t" }
                else if !val.isEmpty { self.delimiter = val }
            }
            if line.hasPrefix("decimal:") || line.hasPrefix("decimal_separator:") {
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !val.isEmpty { self.decimalDelimiter = val }
            }

            if line.hasPrefix("columns:") || line.hasPrefix("channels:") {
                inColumnsBlock = true
                continue
            }
            if inColumnsBlock && !rawLine.hasPrefix(" ") && !rawLine.hasPrefix("\t") && !line.hasPrefix("-") {
                inColumnsBlock = false
            }

            if inColumnsBlock {
                if line.hasPrefix("- name:") || line.hasPrefix("- header:") || line.hasPrefix("header:") {
                    if let col = currentColName {
                        parsedCols.append(ColumnDefinition(name: col, label: currentColLabel.isEmpty ? col : currentColLabel, unit: currentColUnit))
                    }
                    let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    currentColName = val
                    currentColUnit = ""
                    currentColLabel = val
                } else if line.hasPrefix("unit:") {
                    currentColUnit = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } else if line.hasPrefix("label:") {
                    currentColLabel = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
        }

        if let col = currentColName {
            parsedCols.append(ColumnDefinition(name: col, label: currentColLabel.isEmpty ? col : currentColLabel, unit: currentColUnit))
        }

        if !parsedCols.isEmpty {
            if parsedCols.count > 0 { parsedCols[0].isXAxis = true }
            if parsedCols.count > 1 { parsedCols[1].isYAxis = true }
            self.columns = parsedCols
        }
    }

    // MARK: - Schema v3 document ownership

    /// Profile identity, kept split from the instrument identity below:
    /// one `.rawviewer/instrument/<profileID>.yaml` file owns one named
    /// profile plus its variants, independent of the instrument it reads.
    public var profileID: String = ""
    public var profileName: String = ""
    /// The full owned document. Variant switches never drop other variants;
    /// only whole-document replacement prompts Save/Discard/Cancel (Task 3).
    public var profileDocument: ProfileDocumentV3? = nil
    public var selectedVariantID: String? = nil
    /// Document-level dirty flag: true after any staged in-memory edit, false
    /// after apply or successful whole-document save.
    public private(set) var profileDirty: Bool = false
    /// Last serialized bytes written by `saveDocument` (or loaded by
    /// `applyProfileDocument`); used to detect external changes before save.
    private var lastSavedYAML: String? = nil

    public var selectedVariant: ProfileVariantV3? {
        guard let document = profileDocument else { return nil }
        if let id = selectedVariantID { return document.variants.first { $0.id == id } }
        return document.variants.first
    }

    /// Stores the whole document, resolves the selection, and projects the
    /// selected variant into the legacy editable fields above. Never invents
    /// fallback X/Y: columns without defaults stay default-free.
    public func applyProfileDocument(_ document: ProfileDocumentV3, selectedVariantID: String?) {
        profileDocument = document
        if let requested = selectedVariantID,
           document.variants.contains(where: { $0.id == requested }) {
            self.selectedVariantID = requested
        } else {
            self.selectedVariantID = document.variants.first?.id
        }
        profileID = document.profileID
        profileName = document.profileName
        instrumentID = document.instrumentID
        instrumentName = document.instrumentName
        projectCurrentVariant()
        lastSavedYAML = try? document.serializedYAML()
        profileDirty = false
    }

    /// Single baseline authority: records the exact bytes on disk after
    /// every successful profile-file write (byte-save, serialized save,
    /// import copy) or clears it (delete). Keeps the external-change
    /// guard honest across both write paths.
    public func rebaseSaveBaseline(to yaml: String?) {
        lastSavedYAML = yaml
    }

    /// Projects the selected variant into the legacy editable fields.
    /// Never traps: without a selection the fields stay untouched.
    private func projectCurrentVariant() {
        guard let variant = selectedVariant else { return }
        modeID = variant.id
        modeName = variant.name
        delimiter = variant.rawStream.delimiter
        decimalDelimiter = variant.rawStream.decimalSeparator
        let plot = variant.defaultPlot
        columns = variant.rawStream.columns.map { self.columnDefinition(for: $0, plot: plot) }
    }

    /// Explicitly marks the document dirty (for edits made directly to the
    /// legacy fields outside `stageCurrentVariantEdits`).
    public func markProfileDirty() {
        guard profileDocument != nil else { return }
        profileDirty = true
    }

    /// Stages legacy-field edits, then reports unsaved state. Guards that
    /// check only `profileDirty` miss direct binding writes to the legacy
    /// fields; call this before gating a document replacement on the flag.
    @discardableResult
    public func refreshDirtyFromStagedEdits() -> Bool {
        stageCurrentVariantEdits()
        return profileDirty
    }

    /// Folds identity plus the legacy editable fields back into the selected
    /// variant without validating, so incomplete visual drafts survive in
    /// memory across variant switches. Save validates all variants.
    public func stageCurrentVariantEdits() {
        guard var document = profileDocument,
              let selection = selectedVariantID,
              let index = document.variants.firstIndex(where: { $0.id == selection }) else { return }
        let before = document
        document.profileID = profileID
        document.profileName = profileName
        document.instrumentID = instrumentID
        document.instrumentName = instrumentName
        foldCurrentEdits(into: &document.variants[index])
        profileDocument = document
        if document != before { profileDirty = true }
    }

    /// Stages the current visual draft, then switches the selection and
    /// re-projects. Never validates, so navigation never traps on incomplete
    /// drafts; only whole-document replacement prompts Save/Discard/Cancel.
    @discardableResult
    public func selectVariant(id: String) -> Bool {
        guard let document = profileDocument,
              document.variants.contains(where: { $0.id == id }) else { return false }
        stageCurrentVariantEdits()
        selectedVariantID = id
        projectCurrentVariant()
        return true
    }

    /// Copies only the selected variant under a new ID. Key values are copied
    /// verbatim; resolving key/selector collisions with sibling variants is an
    /// explicit follow-up edit, never a silent rewrite here.
    public func duplicateCurrentVariant(newID: String, newName: String) throws {
        stageCurrentVariantEdits()
        guard var document = profileDocument,
              let selection = selectedVariantID,
              let source = document.variants.first(where: { $0.id == selection }) else {
            throw ProfileDocumentError.invalid(reason: "No variant is selected for duplication.")
        }
        guard !document.variants.contains(where: { $0.id == newID }) else {
            throw ProfileDocumentError.invalid(reason: "Variant id \"\(newID)\" already exists; resolve the collision first.")
        }
        var copy = source
        copy.id = newID
        copy.name = newName
        document.variants.append(copy)
        try document.validate()
        profileDocument = document
        selectedVariantID = newID
        projectCurrentVariant()
        profileDirty = true
    }

    /// Copies the whole document under a new profile ID. Instrument identity
    /// stays independent of the profile copy; every variant is preserved.
    public func duplicateProfile(newProfileID: String, newProfileName: String) throws {
        stageCurrentVariantEdits()
        guard var document = profileDocument else {
            throw ProfileDocumentError.invalid(reason: "No profile document is loaded; apply a v3 document first.")
        }
        document.profileID = newProfileID
        document.profileName = newProfileName
        try document.validate()
        profileID = newProfileID
        profileName = newProfileName
        profileDocument = document
        profileDirty = true
    }

    /// Task 6: one blank v3 variant from the live sample parse (delimiter,
    /// decimal, header/data-start rows, columns incl. skip/X/Y, the sample
    /// extension, caller match evidence) under a keyless key set. Loads it
    /// as the dirty unsaved document and returns it. Never touches disk.
    @discardableResult
    public func newDocumentFromSample(
        profileID: String, profileName: String,
        grammarID: String, match: VariantMatchV3? = nil,
        catalog: FilenameGrammarCatalog? = nil
    ) throws -> ProfileDocumentV3 {
        guard !columns.isEmpty else {
            throw ProfileDocumentError.invalid(reason: "Load a sample before creating a profile: no parsed columns are available.")
        }
        let ext = sampleFileURL.map { "." + $0.pathExtension.lowercased() } ?? ""
        guard ext.count > 1 else {
            throw ProfileDocumentError.invalid(reason: "Load a sample file before creating a profile: no sample filename is available.")
        }
        // ponytail: brand-new columns keep the fold's header-source mapping; no defaults guessed.
        let variantColumns: [ProfileColumnV3] = columns.map { definition in
            var axes: [AxisV3] = []
            if definition.isXAxis { axes.append(.x) }
            if definition.isYAxis { axes.append(.y) }
            return ProfileColumnV3(
                id: definition.name,
                source: ColumnSourceV3(header: definition.name),
                label: definition.label,
                quantity: definition.quantity,
                unit: definition.unit.isEmpty ? nil : definition.unit,
                required: !definition.isOptional,
                role: definition.isSkipped ? .skip : (definition.role == .progression ? .progression : .channel),
                axes: definition.isSkipped ? [] : axes,
                progression: definition.isSkipped ? nil : v3Progression(for: definition, stored: nil))
        }
        let cleanName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleanName.isEmpty ? profileID : cleanName
        let cleanInstrument = instrumentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstrumentName = instrumentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = ProfileDocumentV3(
            profileID: profileID, profileName: displayName,
            instrumentID: cleanInstrument.isEmpty ? profileID : cleanInstrument,
            instrumentName: cleanInstrumentName.isEmpty ? displayName : cleanInstrumentName,
            grammarID: grammarID, variantKeys: [],
            variants: [ProfileVariantV3(
                id: "variant-1", name: displayName, keyValues: [:], match: match,
                rawStream: RawStreamV3(
                    extensions: [ext], encodings: ["utf-8"],
                    delimiter: delimiter, decimalSeparator: decimalDelimiter,
                    rows: RowLocatorsV3(
                        header: headerLineIndex.map { HeaderLocatorV3.row($0 + 1) } ?? .none,
                        dataStart: .row(dataStartLineIndex + 1),
                        excludedMetadata: skippedMetadataLines.sorted()),
                    columns: variantColumns))])
        if let catalog { try document.validate(catalog: catalog) } else { try document.validate() }
        applyProfileDocument(document, selectedVariantID: nil)
        profileDirty = true
        return document
    }

    /// Explicit key-set change: every variant needs exactly the new keys.
    /// Throws on any missing variant or extra/missing key; incomplete drafts
    /// cannot apply, and therefore cannot save.
    public func setVariantKeys(_ keys: [String], valuesByVariantID: [String: [String: String]]) throws {
        guard var document = profileDocument else {
            throw ProfileDocumentError.invalid(reason: "No profile document is loaded; apply a v3 document first.")
        }
        let clean = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !clean.isEmpty, Set(clean).count == clean.count, clean.allSatisfy({ !$0.isEmpty }) else {
            throw ProfileDocumentError.invalid(reason: "Variant keys must be unique nonempty names.")
        }
        let keySet = Set(clean)
        for variant in document.variants {
            guard let values = valuesByVariantID[variant.id] else {
                throw ProfileDocumentError.invalid(reason: "Variant \"\(variant.id)\" needs explicit values for the new key set.")
            }
            guard Set(values.keys) == keySet else {
                throw ProfileDocumentError.invalid(reason: "Variant \"\(variant.id)\" must supply exactly the selected keys.")
            }
        }
        document.variantKeys = clean
        for index in document.variants.indices {
            document.variants[index].keyValues = valuesByVariantID[document.variants[index].id] ?? [:]
        }
        try document.validate()
        profileDocument = document
        profileDirty = true
    }

    /// Single-key toggle for the Variant Key checkbox. Deliberately
    /// unvalidated: enabling stages empty values that block Save (not
    /// navigation) until every variant carries a real value. Dirties the
    /// profile only; the grammar catalog is never touched here.
    public func setVariantKeyEnabled(_ key: String, enabled: Bool) throws {
        guard var document = profileDocument else {
            throw ProfileDocumentError.invalid(reason: "No profile document is loaded; apply a v3 document first.")
        }
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw ProfileDocumentError.invalid(reason: "Variant key names must be nonempty.")
        }
        if enabled {
            if !document.variantKeys.contains(clean) { document.variantKeys.append(clean) }
            for index in document.variants.indices where document.variants[index].keyValues[clean] == nil {
                document.variants[index].keyValues[clean] = ""
            }
        } else {
            document.variantKeys.removeAll { $0 == clean }
            for index in document.variants.indices {
                document.variants[index].keyValues.removeValue(forKey: clean)
            }
        }
        profileDocument = document
        profileDirty = true
    }

    /// Per-variant key-value edit on the selected variant only. Unvalidated
    /// so navigation never traps; Save validates all variants.
    /// Task 7 keeps this for programmatic staging; the Keys value-entry row
    /// is gone from the UI, so key values only change through autofill below.
    public func updateSelectedVariantKeyValue(key: String, value: String) throws {
        guard var document = profileDocument,
              let selection = selectedVariantID,
              let index = document.variants.firstIndex(where: { $0.id == selection }) else {
            throw ProfileDocumentError.invalid(reason: "No variant is selected.")
        }
        document.variants[index].keyValues[key] = value
        profileDocument = document
        profileDirty = true
    }

    /// Task 7: tick-only keys autofill read-only from the current sample's
    /// extracted fields. Fills only empty values on the selected
    /// (sample-matched) variant and dirties the profile; unmatched samples
    /// never autofill, and existing values are never overwritten. Missing
    /// extraction leaves the value empty, and Save then names the exact key.
    /// Only marks dirty when a value actually changes.
    public func autofillSelectedVariantKeyValues(from extractedFields: [String: String], isMatched: Bool) {
        guard isMatched,
              var document = profileDocument,
              let selection = selectedVariantID,
              let index = document.variants.firstIndex(where: { $0.id == selection }),
              !document.variantKeys.isEmpty else { return }
        var changed = false
        for key in document.variantKeys {
            let current = document.variants[index].keyValues[key] ?? ""
            guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let filled = extractedFields[key], !filled.isEmpty else { continue }
            document.variants[index].keyValues[key] = filled
            changed = true
        }
        if changed {
            profileDocument = document
            profileDirty = true
        }
    }

    /// Explicit Use as Profile Defaults: replaces the complete default X/Y
    /// list on the selected variant's projection only. Sandbox axis pickers
    /// stay preview-only until this is called.
    public func usePreviewAsDefaults(x xID: String, y yIDs: [String]) throws {
        guard profileDocument != nil, selectedVariantID != nil else {
            throw ProfileDocumentError.invalid(reason: "No variant is selected.")
        }
        let names = Set(columns.map(\.name))
        for id in [xID] + yIDs {
            guard names.contains(id) else {
                throw ProfileDocumentError.invalid(reason: "Column \"\(id)\" is not part of the selected variant.")
            }
        }
        for index in columns.indices {
            columns[index].isDefaultX = (columns[index].name == xID)
            columns[index].isDefaultY = yIDs.contains(columns[index].name)
        }
        stageCurrentVariantEdits()
    }

    /// Generic selected-variant edit for Matching & Layout controls.
    /// Stages first, applies without validation, marks dirty.
    public func updateSelectedVariant(_ apply: (inout ProfileVariantV3) -> Void) throws {
        stageCurrentVariantEdits()
        guard var document = profileDocument,
              let selection = selectedVariantID,
              let index = document.variants.firstIndex(where: { $0.id == selection }) else {
            throw ProfileDocumentError.invalid(reason: "No variant is selected.")
        }
        apply(&document.variants[index])
        profileDocument = document
        profileDirty = true
    }

    /// Rebinds the profile to another grammar and clears keys/values for
    /// explicit review. Unvalidated in memory; Save blocks until keys resolve.
    public func rebindProfile(grammarID: String) {
        stageCurrentVariantEdits()
        guard var document = profileDocument else { return }
        document.grammarID = grammarID
        document.variantKeys = []
        for index in document.variants.indices { document.variants[index].keyValues = [:] }
        profileDocument = document
        profileDirty = true
    }

    /// Called after a non-v3 (legacy) profile load: the workspace matches
    /// disk, so no document draft is pending.
    public func didLoadExternalProfile() {
        lastSavedYAML = nil
        profileDirty = false
    }
    /// Writes the whole validated document to
    /// `.rawviewer/instrument/<profileID>.yaml`. Validates every variant
    /// before touching disk, so a failed save never replaces a valid file;
    /// aborts on external changes instead of overwriting them.
    @discardableResult
    public func saveDocument(project: ProjectContext, catalog: FilenameGrammarCatalog? = nil) throws -> URL {
        let document = try makeProfileDocument()
        if let catalog { try document.validate(catalog: catalog) }
        let text = try document.serializedYAML()
        let dir = project.root.appendingPathComponent(".rawviewer/instrument", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(document.profileID).yaml")
        if let baseline = lastSavedYAML,
           let existing = try? String(contentsOf: file, encoding: .utf8),
           existing != baseline {
            throw ProfileDocumentError.invalid(reason: "The profile file changed on disk; reconcile the external change before saving.")
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        rebaseSaveBaseline(to: text)
        profileDirty = false
        return file
    }

    private func columnDefinition(for column: ProfileColumnV3, plot: DefaultPlotV3?) -> ColumnDefinition {
        let role: ColumnRole?
        if column.role == .skip {
            role = .skip
        } else if column.role == .progression {
            role = .progression
        } else {
            role = nil
        }
        let progressionType: ProgressionType?
        let progressionBehavior: ProgressionBehavior?
        switch column.progression?.type {
        case .index: progressionType = .index
        case .time: progressionType = .time
        case .custom: progressionType = .custom
        case .none: progressionType = nil
        }
        switch column.progression?.behavior {
        case .continuous: progressionBehavior = .continuous
        case .discrete: progressionBehavior = .discrete
        case .none: progressionBehavior = nil
        }
        return ColumnDefinition(
            name: column.id,
            label: column.label,
            quantity: column.quantity,
            unit: column.unit ?? "",
            isXAxis: column.axes.contains(.x),
            isYAxis: column.axes.contains(.y),
            isDefaultX: plot?.x == column.id,
            isDefaultY: plot?.y.contains(column.id) ?? false,
            isSkipped: column.role == .skip,
            isOptional: !column.required,
            role: role,
            progressionType: progressionType,
            progressionBehavior: progressionBehavior,
            customProgressionName: column.progression?.name)
    }

    /// Editor-explicit progression fields win; silent fields keep the stored
    /// value so apply/make round-trips untouched. Fully silent keeps stored
    /// as-is; brand-new columns fall back to type-appropriate defaults.
    private func v3Progression(for definition: ColumnDefinition, stored: ColumnProgressionV3?) -> ColumnProgressionV3? {
        guard definition.role == .progression else { return nil }
        if definition.progressionType == nil && definition.progressionBehavior == nil
            && (definition.customProgressionName?.isEmpty ?? true) {
            return stored
        }
        let type: ProgressionTypeV3
        switch definition.progressionType {
        case .time: type = .time
        case .custom: type = .custom
        case .index: type = .index
        case .none: type = stored?.type ?? .index
        }
        let behavior: ProgressionBehaviorV3?
        switch definition.progressionBehavior {
        case .continuous: behavior = .continuous
        case .discrete: behavior = .discrete
        // ponytail: silent editor keeps stored (even none); brand-new columns get type defaults.
        case .none: behavior = stored?.behavior ?? (stored == nil ? (type == .time ? .continuous : .discrete) : nil)
        }
        let name = definition.customProgressionName?.isEmpty == false
            ? definition.customProgressionName : stored?.name
        return ColumnProgressionV3(type: type, name: name, behavior: behavior)
    }

    /// Folds the legacy editable fields back into the selected variant and
    /// returns the whole validated document. Unaffected variants round-trip
    /// untouched; variant columns missing from the workspace are preserved,
    /// never dropped here. Variant IDs stay stable (renames are Task 3).
    public func makeProfileDocument() throws -> ProfileDocumentV3 {
        guard var document = profileDocument else {
            throw ProfileDocumentError.invalid(reason: "No profile document is loaded; apply a v3 document first.")
        }
        document.profileID = profileID
        document.profileName = profileName
        document.instrumentID = instrumentID
        document.instrumentName = instrumentName
        guard let selection = selectedVariantID,
              let index = document.variants.firstIndex(where: { $0.id == selection }) else {
            throw ProfileDocumentError.invalid(reason: "The selected variant is not part of the profile document.")
        }
        foldCurrentEdits(into: &document.variants[index])
        try document.validate()
        profileDocument = document
        return document
    }

    /// Shared fold for staging (unvalidated) and make/save (validated).
    private func foldCurrentEdits(into variant: inout ProfileVariantV3) {
        variant.name = modeName
        variant.rawStream.delimiter = delimiter
        variant.rawStream.decimalSeparator = decimalDelimiter
        var merged: [ProfileColumnV3] = []
        merged.reserveCapacity(columns.count)
        for definition in columns {
            if let existing = variant.rawStream.columns.first(where: { $0.id == definition.name }) {
                var updated = existing
                updated.label = definition.label
                updated.quantity = definition.quantity
                updated.unit = definition.unit.isEmpty ? nil : definition.unit
                updated.required = !definition.isOptional
                if definition.isSkipped {
                    updated.role = .skip
                    updated.axes = []
                    updated.progression = nil
                } else {
                    updated.role = definition.role == .progression ? .progression : .channel
                    var axes: [AxisV3] = []
                    if definition.isXAxis { axes.append(.x) }
                    if definition.isYAxis { axes.append(.y) }
                    updated.axes = axes
                    // Task 3(a): a role away from progression clears the
                    // mapping; stale progression metadata must not survive.
                    updated.progression = definition.role == .progression
                        ? v3Progression(for: definition, stored: existing.progression)
                        : nil
                }
                merged.append(updated)
            } else {
                var axes: [AxisV3] = []
                if definition.isXAxis { axes.append(.x) }
                if definition.isYAxis { axes.append(.y) }
                merged.append(ProfileColumnV3(
                    id: definition.name,
                    source: ColumnSourceV3(header: definition.name),
                    label: definition.label,
                    quantity: definition.quantity,
                    unit: definition.unit.isEmpty ? nil : definition.unit,
                    required: !definition.isOptional,
                    role: definition.isSkipped ? .skip : (definition.role == .progression ? .progression : .channel),
                    axes: definition.isSkipped ? [] : axes,
                    progression: definition.isSkipped ? nil : v3Progression(for: definition, stored: nil)))
            }
        }
        // ponytail: workspace-absent variant columns are preserved, never dropped here.
        for existing in variant.rawStream.columns where !columns.contains(where: { $0.name == existing.id }) {
            merged.append(existing)
        }
        variant.rawStream.columns = merged
        let defaultX = columns.first { $0.isDefaultX && !$0.isSkipped }?.name
        let defaultY = columns.filter { $0.isDefaultY && !$0.isSkipped }.map(\.name)
        if let defaultX, !defaultY.isEmpty {
            variant.defaultPlot = DefaultPlotV3(x: defaultX, y: defaultY,
                                                progression: variant.defaultPlot?.progression)
        } else if defaultX == nil && defaultY.isEmpty {
            variant.defaultPlot = nil
        }
        // ponytail: partial defaults keep the stored plot; never guess the missing half.
    }

    // MARK: - Task 5: legacy upgrade draft lifecycle (unsaved until finalize + save)

    /// Pending strict-loaded legacy source for mode selection. Internal: views
    /// see only `upgradeModeOptions`/`upgradeNeedsModeSelection` (the legacy
    /// profile type stays module-internal).
    var upgradeSourceProfile: InstrumentProfile? = nil
    var upgradeSourcePath: String? = nil
    var upgradeSourceSHA256: String? = nil
    /// Unsaved conversion draft; originals and the live document are untouched
    /// until `finalizeUpgrade`.
    public var upgradeDraft: ProfileUpgradeDraft? = nil
    /// Declared legacy mode IDs offered for selection (multi-mode only).
    public var upgradeModeOptions: [String] = []

    public var hasUpgradeDraft: Bool { upgradeDraft != nil }

    public var upgradeNeedsModeSelection: Bool {
        upgradeSourceProfile != nil && upgradeDraft == nil && !upgradeModeOptions.isEmpty
    }

    public var upgradeSourceLabel: String {
        if let profile = upgradeSourceProfile {
            return profile.instrumentName.isEmpty ? profile.instrumentID : profile.instrumentName
        }
        return upgradeSourcePath ?? ""
    }

    /// Stages visual edits, then strict-loads one legacy file and stages it
    /// for upgrade. Single-mode profiles yield a draft immediately; multi-mode
    /// profiles only offer `upgradeModeOptions` until explicit selection. The
    /// live document is never touched here, so repeated preparation only
    /// replaces upgrade state and preserves every draft.
    public func prepareUpgradeFromLegacyFile(at url: URL, relativePath: String) throws {
        stageCurrentVariantEdits()
        let data = try Data(contentsOf: url)
        guard data.count <= ProfileCatalog.maximumProfileBytes else {
            throw ProfileDocumentError.invalid(reason: "\(relativePath): legacy profile exceeds the size limit.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProfileDocumentError.invalid(reason: "\(relativePath): legacy profile is not readable text.")
        }
        let digest = sha256Hex(data)
        let outcome = ProfileSchema.load(text: text, relativePath: relativePath, sha256: digest)
        guard let profile = outcome.profile else {
            throw ProfileDocumentError.invalid(reason: outcome.issues.first ?? "\(relativePath): legacy profile is not a supported v1/v2 document.")
        }
        upgradeSourceProfile = profile
        upgradeSourcePath = relativePath
        upgradeSourceSHA256 = digest
        if profile.modes.count == 1 {
            upgradeDraft = try LegacyProfileUpgrader.draft(
                from: profile, modeIDs: nil, legacyPath: relativePath, sha256: digest)
            upgradeModeOptions = []
        } else {
            upgradeDraft = nil
            upgradeModeOptions = profile.modes.map(\.id)
        }
    }

    /// Builds the single draft from explicitly selected modes. Empty or
    /// unknown selections throw before assigning anything, so prior drafts
    /// and the live document survive.
    public func applyUpgradeModeSelection(_ modeIDs: [String]) throws {
        guard let profile = upgradeSourceProfile,
              let path = upgradeSourcePath,
              let digest = upgradeSourceSHA256 else {
            throw ProfileDocumentError.invalid(reason: "No legacy profile is staged for upgrade; choose Upgrade first.")
        }
        let draft = try LegacyProfileUpgrader.draft(
            from: profile, modeIDs: modeIDs, legacyPath: path, sha256: digest)
        upgradeDraft = draft
        upgradeModeOptions = profile.modes.map(\.id)
    }

    /// Drops upgrade state; the live document and originals are untouched.
    public func cancelUpgrade() {
        upgradeSourceProfile = nil
        upgradeSourcePath = nil
        upgradeSourceSHA256 = nil
        upgradeDraft = nil
        upgradeModeOptions = []
    }

    /// Explicit Needs-definition review on the pending draft. Unvalidated by
    /// design: incomplete drafts stay editable and navigable; Save validates.
    public func resolveUpgrade(
        grammarID: String,
        variantKeys: [String],
        valuesByVariantID: [String: [String: String]]
    ) {
        guard var draft = upgradeDraft else { return }
        draft.resolve(grammarID: grammarID, variantKeys: variantKeys, valuesByVariantID: valuesByVariantID)
        upgradeDraft = draft
    }

    /// Finalizes the draft into the live document WITHOUT saving: the result
    /// is an unsaved v3 draft (dirty) that still needs an explicit Save.
    /// A colliding canonical file aborts later at `saveDocument` via the
    /// external-change guard, preserving the file and this draft.
    @discardableResult
    public func finalizeUpgrade(catalog: FilenameGrammarCatalog) throws -> ProfileDocumentV3 {
        guard let draft = upgradeDraft else {
            throw ProfileDocumentError.invalid(reason: "No upgrade draft is pending; choose Upgrade first.")
        }
        let document = try draft.finalize(catalog: catalog)
        applyProfileDocument(document, selectedVariantID: nil)
        profileDirty = true
        upgradeDraft = nil
        upgradeSourceProfile = nil
        upgradeSourcePath = nil
        upgradeSourceSHA256 = nil
        upgradeModeOptions = []
        return document
    }
}
