import Foundation
import CryptoKit

public struct GenericTableInspection: Sendable, Equatable {
    public let delimiter: Character
    public let decimalSeparator: Character
    public let headerLineIndex: Int?
    public let dataStartLineIndex: Int
    public let columnNames: [String]
    public let columnUnits: [String?]
    public let totalRows: Int
    public let sampleRows: [[Double]]

    public init(
        delimiter: Character,
        decimalSeparator: Character,
        headerLineIndex: Int?,
        dataStartLineIndex: Int,
        columnNames: [String],
        columnUnits: [String?],
        totalRows: Int,
        sampleRows: [[Double]]
    ) {
        self.delimiter = delimiter
        self.decimalSeparator = decimalSeparator
        self.headerLineIndex = headerLineIndex
        self.dataStartLineIndex = dataStartLineIndex
        self.columnNames = columnNames
        self.columnUnits = columnUnits
        self.totalRows = totalRows
        self.sampleRows = sampleRows
    }
}

public enum GenericTableReader {
    public static func inspect(url: URL, maxSampleLines: Int = 100) throws -> GenericTableInspection {
        let content = try readFileContent(at: url)
        let lines = splitLines(content)
        guard !lines.isEmpty else {
            throw ReaderError.emptyFile
        }

        let sampleLimit = min(lines.count, maxSampleLines)
        let sampleLines = Array(lines.prefix(sampleLimit))

        let candidateDelimiters: [Character] = ["\t", ",", ";"]
        var bestConfig: (delimiter: Character, decimal: Character, dataStart: Int, colCount: Int, headerIdx: Int?)?

        // 1. Try candidate character delimiters
        for delim in candidateDelimiters {
            if let config = findNumericBlock(lines: sampleLines, delimiter: delim) {
                bestConfig = config
                break
            }
        }

        // If no character delimiter matched, try whitespace delimiter
        if bestConfig == nil {
            if let config = findNumericBlock(lines: sampleLines, delimiter: " ") {
                bestConfig = config
            }
        }

        guard let config = bestConfig else {
            throw ReaderError.noNumericDataFound
        }

        // 2. Parse Column Headers
        var columnNames: [String] = []
        var columnUnits: [String?] = []

        if let hIdx = config.headerIdx, hIdx >= 0, hIdx < lines.count {
            let rawHeader = cleanLine(lines[hIdx])
            let tokens = splitLine(rawHeader, delimiter: config.delimiter)
            for i in 0..<config.colCount {
                if i < tokens.count {
                    let cleaned = tokens[i].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"\'#;")))
                    let parsed = parseHeaderAndUnit(cleaned)
                    columnNames.append(parsed.name.isEmpty ? "Column \(i + 1)" : parsed.name)
                    columnUnits.append(parsed.unit)
                } else {
                    columnNames.append("Column \(i + 1)")
                    columnUnits.append(nil)
                }
            }
        } else {
            for i in 0..<config.colCount {
                columnNames.append("Column \(i + 1)")
                columnUnits.append(nil)
            }
        }

        // 3. Count total rows and gather sample rows
        var totalRows = 0
        var sampleRows: [[Double]] = []

        for idx in config.dataStart..<lines.count {
            let line = cleanLine(lines[idx])
            guard !line.isEmpty, !isCommentLine(line) else { continue }
            let tokens = splitLine(line, delimiter: config.delimiter)
            guard tokens.count >= config.colCount else { continue }

            var rowValues: [Double] = []
            var valid = true
            for c in 0..<config.colCount {
                if let val = parseDouble(tokens[c], decimalSeparator: config.decimal) {
                    rowValues.append(val)
                } else {
                    valid = false
                    break
                }
            }

            if valid {
                totalRows += 1
                if sampleRows.count < 5 {
                    sampleRows.append(rowValues)
                }
            }
        }

        guard totalRows > 0 else {
            throw ReaderError.noNumericDataFound
        }

        return GenericTableInspection(
            delimiter: config.delimiter,
            decimalSeparator: config.decimal,
            headerLineIndex: config.headerIdx,
            dataStartLineIndex: config.dataStart,
            columnNames: columnNames,
            columnUnits: columnUnits,
            totalRows: totalRows,
            sampleRows: sampleRows
        )
    }

    public static func loadMeasurement(
        url: URL,
        sourceID: String,
        xColumnIndex: Int = 0,
        yColumnIndex: Int = 1,
        customXLabel: String? = nil,
        customYLabel: String? = nil
    ) throws -> NormalizedMeasurement {
        let inspection = try inspect(url: url)
        let content = try readFileContent(at: url)
        let lines = splitLines(content)

        let colCount = inspection.columnNames.count
        var columnValues: [[Double?]] = Array(repeating: [], count: colCount)
        for i in 0..<colCount {
            columnValues[i].reserveCapacity(inspection.totalRows)
        }

        for idx in inspection.dataStartLineIndex..<lines.count {
            let line = cleanLine(lines[idx])
            guard !line.isEmpty, !isCommentLine(line) else { continue }
            let tokens = splitLine(line, delimiter: inspection.delimiter)
            guard tokens.count >= colCount else { continue }

            var parsedAny = false
            for c in 0..<colCount {
                let val = parseDouble(tokens[c], decimalSeparator: inspection.decimalSeparator)
                columnValues[c].append(val)
                if val != nil { parsedAny = true }
            }
            if !parsedAny {
                // Drop empty row
                for c in 0..<colCount {
                    _ = columnValues[c].popLast()
                }
            }
        }

        let rowCount = columnValues.first?.count ?? 0
        guard rowCount > 0 else {
            throw ReaderError.noNumericDataFound
        }

        let xCol = max(0, min(xColumnIndex, colCount - 1))
        let yCol = max(0, min(yColumnIndex, colCount - 1))

        var channels: [MeasurementChannel] = []
        for i in 0..<colCount {
            let key = "col_\(i)"
            let originalName = inspection.columnNames[i]
            let label: String
            if i == xCol, let customX = customXLabel {
                label = customX
            } else if i == yCol, let customY = customYLabel {
                label = customY
            } else {
                label = originalName
            }
            let unit = inspection.columnUnits[i] ?? ""
            channels.append(MeasurementChannel(
                name: key,
                label: label,
                unit: unit,
                quantity: originalName,
                values: columnValues[i]
            ))
        }

        let xKey = "col_\(xCol)"
        let yKey = "col_\(yCol)"

        let fileData = (try? Data(contentsOf: url)) ?? Data()
        let sha = sha256Hex(fileData)

        return NormalizedMeasurement(
            source: SourceIdentity(path: sourceID, sha256: sha),
            instrument: InstrumentIdentity(
                id: "generic-table",
                name: "Generic Table (\(delimiterName(inspection.delimiter)))",
                vendor: "Generic",
                model: "Delimited Text"
            ),
            applicationMode: "table-view",
            view: MeasurementView(kind: "xy", x: xKey, y: [yKey], preserveOrder: true),
            channels: channels,
            metadataSections: [
                MetadataSection(
                    title: "File Format",
                    fields: [
                        MetadataField(key: "delimiter", label: "Delimiter", value: .string(delimiterName(inspection.delimiter)), unit: nil, kind: "string"),
                        MetadataField(key: "decimal", label: "Decimal Separator", value: .string(String(inspection.decimalSeparator)), unit: nil, kind: "string"),
                        MetadataField(key: "columns", label: "Columns", value: .number(Double(colCount)), unit: nil, kind: "number"),
                        MetadataField(key: "rows", label: "Rows", value: .number(Double(rowCount)), unit: nil, kind: "number")
                    ]
                )
            ],
            warnings: [],
            supportStatus: "supported",
            provenance: [
                "reader": "GenericTableReader",
                "delimiter": String(inspection.delimiter)
            ]
        )
    }

    // MARK: - Private Helpers

    public enum ReaderError: Error, LocalizedError {
        case emptyFile
        case noNumericDataFound
        case unreadableEncoding

        public var errorDescription: String? {
            switch self {
            case .emptyFile: return "The file is empty."
            case .noNumericDataFound: return "Could not detect a numeric data block in this file."
            case .unreadableEncoding: return "The file could not be read with text encoding."
            }
        }
    }

    private static func readFileContent(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) {
            if utf8.starts(with: "\u{FEFF}") {
                return String(utf8.dropFirst())
            }
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        throw ReaderError.unreadableEncoding
    }

    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    private static func cleanLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCommentLine(_ line: String) -> Bool {
        line.starts(with: "#") || line.starts(with: ";") || line.starts(with: "//")
    }

    private static func splitLine(_ line: String, delimiter: Character) -> [String] {
        if delimiter == " " {
            return line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        return line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
    }

    private static func parseDouble(_ raw: String, decimalSeparator: Character) -> Double? {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"\'")))
        if decimalSeparator == "," {
            str = str.replacingOccurrences(of: ",", with: ".")
        }
        return Double(str)
    }

    private static func findNumericBlock(
        lines: [String],
        delimiter: Character
    ) -> (delimiter: Character, decimal: Character, dataStart: Int, colCount: Int, headerIdx: Int?)? {
        let decimals: [Character] = (delimiter == ",") ? ["."] : [".", ","]

        for dec in decimals {
            for i in 0..<lines.count {
                let line = cleanLine(lines[i])
                guard !line.isEmpty, !isCommentLine(line) else { continue }
                let tokens = splitLine(line, delimiter: delimiter)
                guard tokens.count >= 2 else { continue }

                let numericCount = tokens.filter { parseDouble($0, decimalSeparator: dec) != nil }.count
                if Double(numericCount) / Double(tokens.count) >= 0.75 {
                    var consecutive = 1
                    var nextIdx = i + 1
                    while nextIdx < lines.count && consecutive < 3 {
                        let nextLine = cleanLine(lines[nextIdx])
                        if !nextLine.isEmpty && !isCommentLine(nextLine) {
                            let nextTokens = splitLine(nextLine, delimiter: delimiter)
                            if nextTokens.count == tokens.count {
                                let nextNumeric = nextTokens.filter { parseDouble($0, decimalSeparator: dec) != nil }.count
                                if Double(nextNumeric) / Double(nextTokens.count) >= 0.75 {
                                    consecutive += 1
                                } else {
                                    break
                                }
                            } else {
                                break
                            }
                        }
                        nextIdx += 1
                    }

                    if consecutive >= min(3, max(1, lines.count - i)) {
                        var headerIdx: Int?
                        for prev in stride(from: i - 1, through: 0, by: -1) {
                            let prevLine = cleanLine(lines[prev])
                            if !prevLine.isEmpty {
                                headerIdx = prev
                                break
                            }
                        }
                        return (delimiter, dec, i, tokens.count, headerIdx)
                    }
                }
            }
        }
        return nil
    }

    private static func parseHeaderAndUnit(_ raw: String) -> (name: String, unit: String?) {
        let pattern = #"^(.*?)\s*[\(\[]([^\)\]]+)[\)\]]$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            let nameRange = Range(match.range(at: 1), in: raw)
            let unitRange = Range(match.range(at: 2), in: raw)
            let name = nameRange.map { String(raw[$0]).trimmingCharacters(in: .whitespaces) } ?? raw
            let unit = unitRange.map { String(raw[$0]).trimmingCharacters(in: .whitespaces) }
            return (name, unit)
        }
        return (raw, nil)
    }

    private static func delimiterName(_ delim: Character) -> String {
        switch delim {
        case "\t": return "TSV"
        case ",": return "CSV"
        case ";": return "Semicolon"
        case " ": return "Whitespace"
        default: return String(delim)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
