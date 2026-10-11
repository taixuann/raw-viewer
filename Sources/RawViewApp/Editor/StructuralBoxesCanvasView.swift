import SwiftUI
import RawViewCore

struct StructuralBoxesCanvasView: View {
    let lines: [String]
    let delimiter: String
    @Binding var columns: [ColumnDefinition]
    let lineTags: [Int: LineRegionType]
    var metadataCellTags: [String: MetadataCellTag] = [:]
    var onTagMetadataCell: ((MetadataCellTag) -> Void)? = nil
    var onRemoveMetadataTag: ((Int, Int) -> Void)? = nil
    var onUpdateColumn: ((Int, ColumnDefinition) -> Void)?
    var onSelectDelimiter: ((String) -> Void)? = nil

    private var headerLineIndex: Int {
        var minHeader = Int.max
        for (idx, tag) in lineTags {
            if tag == .columnHeaders, idx < minHeader {
                minHeader = idx
            }
        }
        return minHeader == Int.max ? 0 : minHeader
    }

    private var metadataLines: [(index: Int, text: String)] {
        let headerIdx = headerLineIndex
        let scanLimit = min(lines.count, max(headerIdx + 1, 60))
        return lines.prefix(scanLimit).enumerated().compactMap { idx, text in
            (lineTags[idx] == .metadata || (idx < headerIdx && !text.isEmpty)) ? (idx, text) : nil
        }
    }

    private var dataRows: [[String]] {
        var startIdx = 1
        var minData = Int.max
        for (idx, tag) in lineTags where tag == .dataMatrix {
            if idx < minData { minData = idx }
        }
        if minData != Int.max { startIdx = minData }
        guard startIdx < lines.count else { return [] }
        let slice = lines[startIdx..<min(lines.count, startIdx + 30)]
        let sep = delimiter == "\\t" ? "\t" : delimiter
        return slice.map { line in
            line.components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    @State private var isMetadataExpanded: Bool = true
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    private func tokenizeMetadataLine(_ text: String) -> [String] {
        let sep = delimiter == "\\t" ? "\t" : delimiter
        var tokens = text.components(separatedBy: sep)
        if tokens.count == 1, let colonRange = text.range(of: ": ") {
            let key = String(text[..<colonRange.lowerBound]) + ":"
            let val = String(text[colonRange.upperBound...])
            tokens = [key, val]
        }
        return tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                // BOX 1: Metadata Region (Interactive Token Cells with Right-Click Entity Mapping)
                if !metadataLines.isEmpty {
                    metadataSection
                }

                // BOX 2: Tabular Data Matrix (Clean Raw Data Stream from Header down)
                matrixSection
            }
            .padding(.vertical, 6)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Metadata Region (Tokenized Cells)
    private var metadataSection: some View {
        DisclosureGroup(isExpanded: $isMetadataExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Right-click any cell to assign semantic metadata (Instrument, Date/Time, or Parameters).")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                ForEach(metadataLines.prefix(25), id: \.index) { item in
                    let tokens = tokenizeMetadataLine(item.text)
                    HStack(alignment: .center, spacing: 6) {
                        Text("L\(item.index + 1)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, alignment: .trailing)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(0..<tokens.count, id: \.self) { tIdx in
                                    let token = tokens[tIdx]
                                    let tagKey = "\(item.index):\(tIdx)"
                                    let currentTag = metadataCellTags[tagKey]
                                    metadataCellPill(lineIdx: item.index, tokenIdx: tIdx, token: token, tag: currentTag)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.purple)
                Text("Metadata Header & Tokens")
                    .font(.system(size: 11, weight: .bold))
                Text("(\(metadataLines.count) lines)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !metadataCellTags.isEmpty {
                    Text("• \(metadataCellTags.count) tagged")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.purple)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.06)))
        .padding(.horizontal, 8)
    }

    private func metadataCellPill(lineIdx: Int, tokenIdx: Int, token: String, tag: MetadataCellTag?) -> some View {
        MetadataCellPillView(
            token: token,
            tag: tag,
            style: .structuralBox
        )
        .contextMenu {
            Section("INSTRUMENT IDENTIFIER") {
                Button("Set as Instrument Name (\"\(token)\")") {
                    onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .instrumentName))
                }
                Button("Set as Instrument ID") {
                    onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .instrumentID))
                }
            }

            Section("DATE & TIME") {
                Menu("Date & Time (Combined)") {
                    Button("ISO 8601 (yyyy-MM-dd HH:mm:ss)") {
                        onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateTime, format: "yyyy-MM-dd HH:mm:ss"))
                    }
                    Button("Slash format (dd/MM/yyyy HH:mm:ss)") {
                        onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateTime, format: "dd/MM/yyyy HH:mm:ss"))
                    }
                    Button("US format (MM/dd/yyyy hh:mm:ss a)") {
                        onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateTime, format: "MM/dd/yyyy hh:mm:ss a"))
                    }
                }

                Menu("Date Only") {
                    Button("yyyy-MM-dd") {
                        onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateOnly, format: "yyyy-MM-dd"))
                    }
                    Button("dd/MM/yyyy") {
                        onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateOnly, format: "dd/MM/yyyy"))
                    }
                    Button("MM/dd/yyyy") {
                        onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateOnly, format: "MM/dd/yyyy"))
                    }
                }

                Menu("Time Only") {
                    Button("HH:mm:ss (24h)") {
                        onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .timeOnly, format: "HH:mm:ss"))
                    }
                    Button("HH:mm") {
                        onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .timeOnly, format: "HH:mm"))
                    }
                    Button("hh:mm:ss a (12h AM/PM)") {
                        onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .timeOnly, format: "hh:mm:ss a"))
                    }
                }
            }

            Section("EXPERIMENTAL PARAMETER") {
                Button("Scan Rate / Sweep Speed") {
                    onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .parameter, customKey: "Scan Rate"))
                }
                Button("Temperature") {
                    onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .parameter, customKey: "Temperature"))
                }
                Button("pH") {
                    onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .parameter, customKey: "pH"))
                }
            }

            Section("CONTEXT") {
                Button("Operator") {
                    onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .operatorName))
                }
                Button("Sample Name") {
                    onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .sampleName))
                }
                Button("Technique") {
                    onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .technique))
                }
            }

            if tag != nil {
                Divider()
                Button("Clear Tag", role: .destructive) {
                    onRemoveMetadataTag?(lineIdx, tokenIdx)
                }
            }
        }
    }

    // MARK: - Tabular Data Matrix Section (Clean Raw Data Stream)
    private var matrixSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.blue)
                Text("Data Matrix")
                    .font(.system(size: 11, weight: .bold))

                let activeCount = columns.filter { !$0.isSkipped }.count
                Text("(\(activeCount)/\(columns.count) channels active)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("⊘ Auto-Skip Empty") {
                    autoSkipEmptyColumns()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.accentColor)

                Button("Include All") {
                    includeAllColumns()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)

                Divider().frame(height: 12)

                // Inline quick delimiter picker
                Menu {
                    Button("Semicolon (;)") { onSelectDelimiter?(";") }
                    Button("Comma (,)") { onSelectDelimiter?(",") }
                    Button("Tab (\\t)") { onSelectDelimiter?("\t") }
                    Button("Space") { onSelectDelimiter?(" ") }
                } label: {
                    HStack(spacing: 3) {
                        Text("Delimiter: \(displayDelimiter(delimiter))")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 8)

            // Spreadsheet Grid
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    // Column Headers Row
                    HStack(spacing: 6) {
                        ForEach(0..<columns.count, id: \.self) { cIdx in
                            columnHeaderCard(index: cIdx, col: columns[cIdx])
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))

                    Divider()

                    // Raw Data Rows
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<dataRows.count, id: \.self) { rIdx in
                            let row = dataRows[rIdx]
                            HStack(spacing: 6) {
                                ForEach(0..<columns.count, id: \.self) { cIdx in
                                    let col = columns[cIdx]
                                    let cellText = cIdx < row.count ? row[cIdx] : ""
                                    Text(cellText.isEmpty ? "—" : cellText)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(col.isSkipped ? Color.secondary.opacity(0.35) : cellColor(cIdx: cIdx))
                                        .frame(width: 140, alignment: .leading)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2.5)
                            .background(rIdx % 2 == 0 ? Color.clear : Color.primary.opacity(0.02))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func autoSkipEmptyColumns() {
        for cIdx in 0..<columns.count {
            let allEmpty = dataRows.allSatisfy { row in
                guard cIdx < row.count else { return true }
                let val = row[cIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                return val.isEmpty || val == "—" || val == "-"
            }
            if allEmpty {
                var updated = columns[cIdx]
                updated.isSkipped = true
                onUpdateColumn?(cIdx, updated)
            }
        }
    }

    private func includeAllColumns() {
        for cIdx in 0..<columns.count {
            var updated = columns[cIdx]
            updated.isSkipped = false
            onUpdateColumn?(cIdx, updated)
        }
    }

    private func cellColor(cIdx: Int) -> Color {
        guard cIdx < columns.count else { return .secondary }
        let col = columns[cIdx]
        if col.isXAxis { return Color.blue }
        if col.isYAxis { return Color.green }
        return .primary
    }

    // Clean, compact column header card without bulky button bars
    private func columnHeaderCard(index: Int, col: ColumnDefinition) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                // Index badge
                Text("#\(index + 1)")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                // Compact Role / Skip Pill
                Menu {
                    Button("Set as X Axis") {
                        var updated = col
                        updated.isXAxis = true
                        updated.isYAxis = false
                        updated.isSkipped = false
                        onUpdateColumn?(index, updated)
                    }
                    Button("Set as Y Axis") {
                        var updated = col
                        updated.isXAxis = false
                        updated.isYAxis = true
                        updated.isSkipped = false
                        onUpdateColumn?(index, updated)
                    }
                    Button("Set as Data Channel (Aux)") {
                        var updated = col
                        updated.isXAxis = false
                        updated.isYAxis = false
                        updated.isSkipped = false
                        onUpdateColumn?(index, updated)
                    }
                    Divider()
                    if col.isSkipped {
                        Button("↩ Include / Use Column") {
                            var updated = col
                            updated.isSkipped = false
                            onUpdateColumn?(index, updated)
                        }
                    } else {
                        Button("⊘ Skip / Ignore Column", role: .destructive) {
                            var updated = col
                            updated.isSkipped = true
                            onUpdateColumn?(index, updated)
                        }
                    }
                } label: {
                    StudioRoleBadgeView(
                        text: rolePillText(col: col),
                        roleColor: StudioTokens.roleColor(col: col),
                        hasDropdown: true,
                        uiFontSize: uiFontSize
                    )
                }
                .menuStyle(.borderlessButton)
            }

            // Column Name (Clean, mono font)
            Text(col.name.isEmpty ? "Column \(index + 1)" : col.name)
                .font(StudioTokens.mono(size: 11, weight: .semibold, uiFontSize: uiFontSize))
                .foregroundStyle(col.isSkipped ? Color.secondary.opacity(0.6) : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: 140, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4.5)
                .fill(col.isSkipped ? Color.primary.opacity(0.02) : headerBackground(col: col))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4.5)
                .stroke(col.isSkipped ? Color.clear : headerBorder(col: col), lineWidth: 0.8)
        )
        .contextMenu {
            let xCount = columns.filter { ($0.isXAxis || $0.role == .x) && !$0.isSkipped }.count
            let yCount = columns.filter { ($0.isYAxis || $0.role == .y) && !$0.isSkipped }.count

            if col.isXAxis || col.role == .x {
                if xCount > 1 {
                    Button(isPrimaryX(col: col) ? "★ Default X (Active Plot)" : "★ Set as Default X (Live Plot)") {
                        var updated = col
                        updated.isDefaultX = true
                        onUpdateColumn?(index, updated)
                    }
                    Divider()
                }
            } else {
                Button("Set as X Axis") {
                    var updated = col
                    updated.isXAxis = true
                    updated.isYAxis = false
                    updated.isDefaultX = (xCount == 0)
                    updated.isSkipped = false
                    updated.role = .x
                    onUpdateColumn?(index, updated)
                }
            }

            if col.isYAxis || col.role == .y {
                if yCount > 1 {
                    Button(isPrimaryY(col: col) ? "★ Default Y (Active Plot)" : "★ Set as Default Y (Live Plot)") {
                        var updated = col
                        updated.isDefaultY = true
                        onUpdateColumn?(index, updated)
                    }
                    Divider()
                }
            } else {
                Button("Set as Y Axis") {
                    var updated = col
                    updated.isXAxis = false
                    updated.isYAxis = true
                    updated.isDefaultY = (yCount == 0)
                    updated.isSkipped = false
                    updated.role = .y
                    onUpdateColumn?(index, updated)
                }
            }

            Button("Set as Data Channel (Aux)") {
                var updated = col
                updated.isXAxis = false
                updated.isYAxis = false
                updated.isDefaultX = false
                updated.isDefaultY = false
                updated.isSkipped = false
                updated.role = .channel
                onUpdateColumn?(index, updated)
            }
            Divider()
            if col.isSkipped {
                Button("↩ Include / Use Column") {
                    var updated = col
                    updated.isSkipped = false
                    onUpdateColumn?(index, updated)
                }
            } else {
                Button("⊘ Skip / Ignore Column", role: .destructive) {
                    var updated = col
                    updated.isSkipped = true
                    updated.role = .skip
                    onUpdateColumn?(index, updated)
                }
            }
        }
    }

    private func isPrimaryX(col: ColumnDefinition) -> Bool {
        let xCols = columns.filter { ($0.isXAxis || $0.role == .x) && !$0.isSkipped }
        if col.isDefaultX { return true }
        if xCols.count == 1 && xCols.first?.name == col.name { return true }
        return false
    }

    private func isPrimaryY(col: ColumnDefinition) -> Bool {
        let yCols = columns.filter { ($0.isYAxis || $0.role == .y) && !$0.isSkipped }
        if col.isDefaultY { return true }
        if yCols.count == 1 && yCols.first?.name == col.name { return true }
        return false
    }

    private func rolePillText(col: ColumnDefinition) -> String {
        if col.isSkipped || col.role == .skip { return "⊘ Skip" }
        if col.role == .progression {
            switch col.progressionType {
            case .time: return "Time"
            case .index: return "Scan"
            case .custom: return col.customProgressionName?.isEmpty == false ? col.customProgressionName! : "Custom"
            case .none: return "Prog"
            }
        }
        if col.isXAxis || col.role == .x {
            return isPrimaryX(col: col) ? "X ★" : "X"
        }
        if col.isYAxis || col.role == .y {
            return isPrimaryY(col: col) ? "Y ★" : "Y"
        }
        return "Data"
    }

    private func headerBackground(col: ColumnDefinition) -> Color {
        if col.isXAxis { return Color.blue.opacity(0.10) }
        if col.isYAxis { return Color.green.opacity(0.10) }
        return Color(NSColor.controlBackgroundColor)
    }

    private func headerBorder(col: ColumnDefinition) -> Color {
        if col.isXAxis { return Color.blue.opacity(0.4) }
        if col.isYAxis { return Color.green.opacity(0.4) }
        return Color.secondary.opacity(0.18)
    }

    private func displayDelimiter(_ delim: String) -> String {
        switch delim {
        case "\t", "\\t": return "Tab (\\t)"
        case ";": return "Semicolon (;)"
        case ",": return "Comma (,)"
        case " ": return "Space"
        default: return "'\(delim)'"
        }
    }
}
