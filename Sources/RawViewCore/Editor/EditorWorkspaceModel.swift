import Foundation

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
}
