import SwiftUI
import RawViewCore

public enum CanvasMode: String, CaseIterable, Identifiable {
    case matrix = "Data Matrix"
    case stream = "Raw Stream & Parser"
    public var id: String { rawValue }
}

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
        HStack(spacing: 4) {
            if let tag = tag {
                tagIcon(for: tag.entityType)
                    .font(.system(size: 8.5))
                    .foregroundStyle(tagColor(for: tag.entityType))
            }

            Text(token)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(tag != nil ? tagColor(for: tag!.entityType) : Color.primary)
                .lineLimit(1)

            if let tag = tag {
                Text(tagBadgeText(tag))
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(tagColor(for: tag.entityType).opacity(0.15))
                    .foregroundStyle(tagColor(for: tag.entityType))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 4.5)
                .fill(tag != nil ? tagColor(for: tag!.entityType).opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4.5)
                .stroke(tag != nil ? tagColor(for: tag!.entityType).opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 0.8)
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

    private func tagIcon(for type: MetadataCellTag.EntityType) -> Image {
        switch type {
        case .instrumentName, .instrumentID:
            return Image(systemName: "cpu")
        case .dateTime, .dateOnly, .timeOnly:
            return Image(systemName: "clock")
        case .parameter:
            return Image(systemName: "slider.horizontal.3")
        case .operatorName, .sampleName, .technique:
            return Image(systemName: "person.crop.circle")
        case .ignore:
            return Image(systemName: "slash.circle")
        }
    }

    private func tagColor(for type: MetadataCellTag.EntityType) -> Color {
        switch type {
        case .instrumentName, .instrumentID:
            return Color.purple
        case .dateTime, .dateOnly, .timeOnly:
            return Color.blue
        case .parameter:
            return Color.orange
        case .operatorName, .sampleName, .technique:
            return Color.teal
        case .ignore:
            return Color.secondary
        }
    }

    private func tagBadgeText(_ tag: MetadataCellTag) -> String {
        if let param = tag.parameterKey, !param.isEmpty {
            return param
        }
        switch tag.entityType {
        case .instrumentName: return "Model"
        case .instrumentID: return "ID"
        case .dateTime: return "DateTime"
        case .dateOnly: return "Date"
        case .timeOnly: return "Time"
        case .operatorName: return "Operator"
        case .sampleName: return "Sample"
        case .technique: return "Technique"
        case .parameter: return tag.customKey ?? "Param"
        case .ignore: return "Skip"
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

/// Live Sandbox Preview mini-plot: real-time curve rendering of parsed X/Y data.
enum ProgressionColorMode: String, CaseIterable {
    case multiColor = "Palette"
    case sweep = "Sweep"
}

struct SandboxSegment: Identifiable {
    var id: String { name }
    let name: String
    let points: [(x: Double, y: Double)]
}

struct LiveSandboxPlotView: View {
    let lines: [String]
    let delimiter: String
    let columns: [ColumnDefinition]
    var lineTags: [Int: LineRegionType] = [:]
    @Binding var selectedXCol: String?
    @Binding var selectedYCol: String?

    private var activeXIndex: Int {
        let plottable = columns.indices.filter { idx in
            let c = columns[idx]
            return !c.isSkipped && c.role != .progression && c.progressionType == nil
        }
        if let selX = selectedXCol, let idx = plottable.first(where: { columns[$0].name == selX }) {
            return idx
        }
        if let defX = plottable.first(where: { columns[$0].isDefaultX && (columns[$0].isXAxis || columns[$0].role == .x) }) {
            return defX
        }
        return plottable.first(where: { columns[$0].isXAxis || columns[$0].role == .x })
            ?? plottable.first ?? 0
    }

    private var activeYIndex: Int {
        let plottable = columns.indices.filter { idx in
            let c = columns[idx]
            return !c.isSkipped && c.role != .progression && c.progressionType == nil
        }
        if let selY = selectedYCol, let idx = plottable.first(where: { columns[$0].name == selY }) {
            return idx
        }
        if let defY = plottable.first(where: { columns[$0].isDefaultY && (columns[$0].isYAxis || columns[$0].role == .y) }) {
            return defY
        }
        let activeY = plottable.filter { columns[$0].isYAxis || columns[$0].role == .y }
        if let firstY = activeY.first {
            return firstY
        }
        return plottable.count > 1 ? plottable[1] : (plottable.first ?? 0)
    }

    @State private var customProgressionColIndex: Int? = nil
    @State private var cachedSegments: [SandboxSegment] = []
    @State private var availableProgressionValues: [String] = []
    @State private var selectedProgressionValues: Set<String> = []
    @State private var continuousMinTime: Double = 0.0
    @State private var continuousMaxTime: Double = 1.0
    @State private var timeStartText: String = ""
    @State private var timeStopText: String = ""
    @State private var isContinuousMode: Bool = false
    @State private var discreteColorMode: ProgressionColorMode = .multiColor
    @State private var cachedBounds: (minX: Double, maxX: Double, minY: Double, maxY: Double) = (0, 1, 0, 1)
    @State private var legendOffset: CGSize = .zero
    @State private var legendDragBase: CGSize = .zero
    @State private var highlightedCycle: String? = nil
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    private var activeProgressionIndex: Int? {
        if let custom = customProgressionColIndex {
            return custom >= 0 ? custom : nil
        }
        if let explicit = columns.firstIndex(where: { $0.role == .progression && !$0.isSkipped }) {
            return explicit
        }
        return columns.firstIndex(where: {
            let n = $0.name.lowercased()
            let l = $0.label.lowercased()
            return !$0.isSkipped && (
                n.contains("scan") || n.contains("cycle") || n.contains("segment") ||
                l.contains("scan") || l.contains("cycle") || l.contains("segment")
            )
        })
    }

    private var activeProgressionColumn: ColumnDefinition? {
        guard let idx = activeProgressionIndex, idx < columns.count else { return nil }
        return columns[idx]
    }

    private var dataStartIndex: Int {
        var minData = Int.max
        for (idx, tag) in lineTags {
            if tag == .dataMatrix, idx < minData {
                minData = idx
            } else if tag == .columnHeaders, (idx + 1) < minData {
                minData = idx + 1
            }
        }
        return minData == Int.max ? 0 : minData
    }

    private var totalPointCount: Int {
        cachedSegments.reduce(0) { $0 + $1.points.count }
    }

    private var activeXLabel: String {
        guard activeXIndex < columns.count else { return "X Axis" }
        let c = columns[activeXIndex]
        let label = c.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? c.name : c.label
        let unit = c.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = unit.isEmpty ? label : "\(label) (\(unit))"
        return ScientificTypography.format(raw)
    }

    private var activeYLabel: String {
        guard activeYIndex < columns.count else { return "Y Axis" }
        let c = columns[activeYIndex]
        let label = c.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? c.name : c.label
        let unit = c.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = unit.isEmpty ? label : "\(label) (\(unit))"
        return ScientificTypography.format(raw)
    }

    private var progressionFilterSummary: String {
        if isContinuousMode {
            if let s = Double(timeStartText), let e = Double(timeStopText) {
                return String(format: "%.1f–%.1fs", s, e)
            }
            return "Time Window"
        }
        if selectedProgressionValues.isEmpty || selectedProgressionValues.count == availableProgressionValues.count {
            return "All (\(availableProgressionValues.count))"
        } else if selectedProgressionValues.count == 1, let first = selectedProgressionValues.first {
            return "Cycle \(first)"
        } else {
            return "\(selectedProgressionValues.count) Cycles"
        }
    }

    private var progressionButtonLabel: String {
        if let col = activeProgressionColumn, let idx = activeProgressionIndex {
            let name = col.label.isEmpty ? col.name : col.label
            return "#\(idx + 1) \(name)"
        }
        return "Prog: None"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Live Sandbox Studio", systemImage: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .bold))

                Spacer()

                // 1. Progression Dimension Selector & Filtering Controls
                let progColumns = columns.enumerated().filter { !$0.element.isSkipped && ($0.element.role == .progression || $0.element.name.lowercased().contains("scan") || $0.element.name.lowercased().contains("cycle") || $0.element.name.lowercased().contains("time") || $0.element.label.lowercased().contains("scan") || $0.element.label.lowercased().contains("cycle") || $0.element.label.lowercased().contains("time")) }
                if !progColumns.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: isContinuousMode ? "timer" : "clock.arrow.circlepath")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.purple)

                        // Dimension Picker: [None | Scan | Time ...]
                        Menu {
                            Button {
                                customProgressionColIndex = -1
                                recomputePlotPoints()
                            } label: {
                                HStack {
                                    Text("Progression: None")
                                    if customProgressionColIndex == -1 {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            Divider()
                            ForEach(progColumns, id: \.offset) { item in
                                let idx = item.offset
                                let c = item.element
                                Button {
                                    customProgressionColIndex = idx
                                    selectedProgressionValues.removeAll()
                                    timeStartText = ""
                                    timeStopText = ""
                                    if let beh = c.progressionBehavior {
                                        isContinuousMode = (beh == .continuous)
                                    }
                                    recomputePlotPoints()
                                } label: {
                                    HStack {
                                        Text("#\(idx + 1) \(c.label.isEmpty ? c.name : c.label)\(c.unit.isEmpty ? "" : " (\(c.unit))")")
                                        if activeProgressionIndex == idx {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(progressionButtonLabel)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(Color.purple)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 6.5))
                                    .foregroundStyle(Color.purple.opacity(0.8))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(Color.purple.opacity(0.10)))
                            .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 0.8))
                        }
                        .menuStyle(.borderlessButton)

                        // 2. Behavior Switcher & Dual Filtering Controls
                        if activeProgressionColumn != nil {
                            // Behavior Switcher (Continuous vs Discrete)
                            Picker("", selection: Binding(
                                get: { isContinuousMode },
                                set: { newContinuous in
                                    isContinuousMode = newContinuous
                                    recomputePlotPoints(forceContinuous: newContinuous)
                                }
                            )) {
                                Text("Continuous").tag(true)
                                Text("Discrete").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.mini)
                            .frame(width: 140)

                            if isContinuousMode {
                                // CONTINUOUS TIME RANGE MODE: Start & Stop Inputs + Presets
                                HStack(spacing: 3) {
                                    Text("From:")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    TextField("0", text: $timeStartText)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .textFieldStyle(.plain)
                                        .frame(width: 36)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1.5)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(NSColor.textBackgroundColor)))
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.purple.opacity(0.3), lineWidth: 0.8))
                                        .onSubmit { recomputePlotPoints() }

                                    Text("to:")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    TextField("End", text: $timeStopText)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .textFieldStyle(.plain)
                                        .frame(width: 36)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1.5)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(NSColor.textBackgroundColor)))
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.purple.opacity(0.3), lineWidth: 0.8))
                                        .onSubmit { recomputePlotPoints() }

                                    Menu {
                                        Button("Full Range (\(String(format: "%.1f", continuousMinTime))–\(String(format: "%.1f", continuousMaxTime))s)") {
                                            timeStartText = String(format: "%.1f", continuousMinTime)
                                            timeStopText = String(format: "%.1f", continuousMaxTime)
                                            recomputePlotPoints()
                                        }
                                        Button("First 20% (0–\(String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.2))s)") {
                                            timeStartText = String(format: "%.1f", continuousMinTime)
                                            timeStopText = String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.2)
                                            recomputePlotPoints()
                                        }
                                        Button("First 50% (0–\(String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.5))s)") {
                                            timeStartText = String(format: "%.1f", continuousMinTime)
                                            timeStopText = String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.5)
                                            recomputePlotPoints()
                                        }
                                        Button("Last 50% (\(String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.5))–\(String(format: "%.1f", continuousMaxTime))s)") {
                                            timeStartText = String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.5)
                                            timeStopText = String(format: "%.1f", continuousMaxTime)
                                            recomputePlotPoints()
                                        }
                                    } label: {
                                        Image(systemName: "slider.horizontal.2.square")
                                            .font(.system(size: 8))
                                            .foregroundStyle(Color.purple)
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                            } else {
                                // DISCRETE CYCLE / SCAN MODE: Multi-Select Pill Menu + Palette/Sweep Toggle
                                if !availableProgressionValues.isEmpty {
                                    Menu {
                                        Button {
                                            selectedProgressionValues.removeAll()
                                            recomputePlotPoints()
                                        } label: {
                                            HStack {
                                                Text("Select All (\(availableProgressionValues.count))")
                                                if selectedProgressionValues.isEmpty || selectedProgressionValues.count == availableProgressionValues.count {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }

                                        if let first = availableProgressionValues.first {
                                            Button {
                                                selectedProgressionValues = [first]
                                                recomputePlotPoints()
                                            } label: {
                                                HStack {
                                                    Text("First Only (Cycle \(first))")
                                                    if selectedProgressionValues == [first] {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }

                                        if let last = availableProgressionValues.last, availableProgressionValues.count > 1 {
                                            Button {
                                                selectedProgressionValues = [last]
                                                recomputePlotPoints()
                                            } label: {
                                                HStack {
                                                    Text("Last Only (Cycle \(last))")
                                                    if selectedProgressionValues == [last] {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }

                                            if let first = availableProgressionValues.first {
                                                Button {
                                                    selectedProgressionValues = [first, last]
                                                    recomputePlotPoints()
                                                } label: {
                                                    HStack {
                                                        Text("First & Last Overlay (\(first), \(last))")
                                                        if selectedProgressionValues == [first, last] {
                                                            Image(systemName: "checkmark")
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        Divider()

                                        ForEach(availableProgressionValues, id: \.self) { val in
                                            Button {
                                                if selectedProgressionValues.isEmpty {
                                                    var all = Set(availableProgressionValues)
                                                    all.remove(val)
                                                    selectedProgressionValues = all
                                                } else if selectedProgressionValues.contains(val) {
                                                    selectedProgressionValues.remove(val)
                                                } else {
                                                    selectedProgressionValues.insert(val)
                                                    if selectedProgressionValues.count == availableProgressionValues.count {
                                                        selectedProgressionValues.removeAll()
                                                    }
                                                }
                                                recomputePlotPoints()
                                            } label: {
                                                HStack {
                                                    Text("Cycle \(val)")
                                                    if selectedProgressionValues.isEmpty || selectedProgressionValues.contains(val) {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 3) {
                                            Text(progressionFilterSummary)
                                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 6.5))
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                                        .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 0.8))
                                    }
                                    .menuStyle(.borderlessButton)
                                }

                                // Discrete Color Palette vs Sweep Toggle
                                Picker("", selection: $discreteColorMode) {
                                    Label("Palette", systemImage: "paintpalette").tag(ProgressionColorMode.multiColor)
                                    Label("Sweep", systemImage: "swatchpalette").tag(ProgressionColorMode.sweep)
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.mini)
                                .frame(width: 130)
                            }
                        }
                    }
                }

                let plottableCols = columns.filter { !$0.isSkipped && $0.role != .progression && $0.progressionType == nil }
                if !plottableCols.isEmpty {
                    let activeXCount = plottableCols.filter { $0.isXAxis || $0.role == .x }.count
                    let activeYCount = plottableCols.filter { $0.isYAxis || $0.role == .y }.count

                    HStack(spacing: 6) {
                        Text("X:")
                            .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                            .foregroundStyle(.blue)
                        Picker("", selection: Binding(
                            get: { selectedXCol ?? (columns.indices.contains(activeXIndex) ? columns[activeXIndex].name : "") },
                            set: { selectedXCol = $0 }
                        )) {
                            ForEach(plottableCols) { col in
                                let isDef = col.isDefaultX || (activeXCount == 1 && (col.isXAxis || col.role == .x))
                                Text("\(col.unit.isEmpty ? col.label : "\(col.label) (\(col.unit))")\(isDef ? " ★" : "")").tag(col.name)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.mini)
                        .frame(maxWidth: 140)

                        Text("Y:")
                            .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                            .foregroundStyle(.green)
                        Picker("", selection: Binding(
                            get: { selectedYCol ?? (columns.indices.contains(activeYIndex) ? columns[activeYIndex].name : "") },
                            set: { selectedYCol = $0 }
                        )) {
                            ForEach(plottableCols) { col in
                                let isDef = col.isDefaultY || (activeYCount == 1 && (col.isYAxis || col.role == .y))
                                Text("\(col.unit.isEmpty ? col.label : "\(col.label) (\(col.unit))")\(isDef ? " ★" : "")").tag(col.name)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.mini)
                        .frame(maxWidth: 140)
                    }
                }

                Text("\(totalPointCount) pts")
                    .font(StudioTokens.mono(size: 9.5, uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Divider()

            if cachedSegments.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("No numeric curve detected for selected X/Y.\nPick different channels or progression cycles above.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            } else {
                GeometryReader { containerGeo in
                    let layout = computePlotLayout(for: containerGeo.size)
                    let plot = layout.plot
                    let fontScale = layout.fontScale

                    ZStack(alignment: .topLeading) {
                        // 1. Publication GraphicsContext Canvas - Nature Single Spine, Outward Ticks, Scaled Typography
                        Canvas { context, _ in
                            // Nature spine frame
                            PlotRenderingEngine.drawSpineFrame(plot: plot, preset: .natureSingle, in: &context)

                            let tickLen = PlotRenderingEngine.tickLength(fontScale: fontScale, preset: .natureSingle)
                            let tickLabelSize = PlotRenderingEngine.tickLabelFontSize(preset: .natureSingle, fontScale: fontScale)
                            let spineWidth = PlotRenderingEngine.spineThickness(preset: .natureSingle)
                            let axisLabelSize = PlotRenderingEngine.axisLabelFontSize(preset: .natureSingle, fontScale: fontScale)

                            // Outward ticks & tick values
                            for index in 0...4 {
                                let t = Double(index) / 4.0
                                let x = cachedBounds.minX + t * (cachedBounds.maxX - cachedBounds.minX)
                                let y = cachedBounds.minY + t * (cachedBounds.maxY - cachedBounds.minY)
                                let px = plot.minX + CGFloat(t) * plot.width
                                let py = plot.maxY - CGFloat(t) * plot.height

                                var xTick = Path(); xTick.move(to: CGPoint(x: px, y: plot.maxY)); xTick.addLine(to: CGPoint(x: px, y: plot.maxY + tickLen))
                                var yTick = Path(); yTick.move(to: CGPoint(x: plot.minX, y: py)); yTick.addLine(to: CGPoint(x: plot.minX - tickLen, y: py))
                                context.stroke(xTick, with: .color(.primary), lineWidth: spineWidth)
                                context.stroke(yTick, with: .color(.primary), lineWidth: spineWidth)

                                context.draw(
                                    Text(formatTick(x)).font(PlotRenderingEngine.plotFont(preset: .natureSingle, size: tickLabelSize)),
                                    at: CGPoint(x: px, y: plot.maxY + tickLen + 3.0),
                                    anchor: .top
                                )
                                context.draw(
                                    Text(formatTick(y)).font(PlotRenderingEngine.plotFont(preset: .natureSingle, size: tickLabelSize)),
                                    at: CGPoint(x: plot.minX - tickLen - 3.0, y: py),
                                    anchor: .trailing
                                )
                            }

                            // Dynamic Axis Titles formatted as <Title> (<Unit>) via ScientificTypography
                            context.draw(
                                Text(activeXLabel).font(PlotRenderingEngine.plotFont(preset: .natureSingle, size: axisLabelSize, bold: false)),
                                at: CGPoint(x: plot.midX, y: plot.maxY + tickLen + 3.0 + tickLabelSize + 6.0),
                                anchor: .top
                            )

                            let yTitleX = max(14 * fontScale, plot.minX - tickLen - 3.0 - layout.maxLabelWidth - (12 * fontScale))
                            var yLabelContext = context
                            yLabelContext.translateBy(x: yTitleX, y: plot.midY)
                            yLabelContext.rotate(by: .degrees(-90))
                            yLabelContext.draw(
                                Text(activeYLabel).font(PlotRenderingEngine.plotFont(preset: .natureSingle, size: axisLabelSize, bold: false)),
                                at: .zero,
                                anchor: .center
                            )

                            // Clipped Data Curves
                            var plotContext = context
                            plotContext.clip(to: Path(plot))

                            let spanX = max(1e-12, cachedBounds.maxX - cachedBounds.minX)
                            let spanY = max(1e-12, cachedBounds.maxY - cachedBounds.minY)
                            let totalSegs = cachedSegments.count

                            for (sIdx, seg) in cachedSegments.enumerated() {
                                let pts = seg.points
                                guard !pts.isEmpty else { continue }
                                let isHl = (highlightedCycle == seg.name)
                                let isDim = (highlightedCycle != nil && !isHl)
                                let cWidth: CGFloat = isHl ? 2.8 : (isDim ? 1.0 : 1.5)
                                let cAlpha: Double = isHl ? 1.0 : (isDim ? 0.22 : 0.9)

                                let strideStep = max(1, pts.count / 2000)
                                var canvasPoints: [CGPoint] = []
                                for i in stride(from: 0, to: pts.count, by: strideStep) {
                                    let p = pts[i]
                                    let dx: Double = p.x - cachedBounds.minX
                                    let dy: Double = p.y - cachedBounds.minY
                                    let normX = CGFloat(dx / spanX)
                                    let normY = CGFloat(dy / spanY)
                                    let px = plot.minX + normX * plot.width
                                    let py = plot.maxY - normY * plot.height
                                    canvasPoints.append(CGPoint(x: px, y: py))
                                }
                                if let last = pts.last, (pts.count - 1) % strideStep != 0 {
                                    let dx: Double = last.x - cachedBounds.minX
                                    let dy: Double = last.y - cachedBounds.minY
                                    let normX = CGFloat(dx / spanX)
                                    let normY = CGFloat(dy / spanY)
                                    let px = plot.minX + normX * plot.width
                                    let py = plot.maxY - normY * plot.height
                                    canvasPoints.append(CGPoint(x: px, y: py))
                                }

                                if isContinuousMode {
                                    PlotRenderingEngine.renderRun(
                                        points: canvasPoints,
                                        mark: .line,
                                        interpolation: .spline,
                                        color: .blue.opacity(cAlpha),
                                        lineWidth: cWidth,
                                        markerSize: 3.5,
                                        colorBySweepProgress: true,
                                        in: &plotContext
                                    )
                                } else if discreteColorMode == .sweep {
                                    let frac = Double(sIdx) / Double(max(1, totalSegs - 1))
                                    let sweepColor = PlotRenderingEngine.sweepColor(at: frac).opacity(cAlpha)
                                    PlotRenderingEngine.renderRun(
                                        points: canvasPoints,
                                        mark: .line,
                                        interpolation: .spline,
                                        color: sweepColor,
                                        lineWidth: cWidth,
                                        markerSize: 3.5,
                                        colorBySweepProgress: false,
                                        in: &plotContext
                                    )
                                } else {
                                    let paletteColor = NativeOverlayPalette.color(sIdx).opacity(cAlpha)
                                    PlotRenderingEngine.renderRun(
                                        points: canvasPoints,
                                        mark: .line,
                                        interpolation: .spline,
                                        color: paletteColor,
                                        lineWidth: cWidth,
                                        markerSize: 3.5,
                                        colorBySweepProgress: false,
                                        in: &plotContext
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // 2. Twin Overlays: Sweep Colorbar or Discrete Multi-Color Legend
                        if isContinuousMode {
                            continuousSweepOverlay(plot: plot)
                        } else if discreteColorMode == .sweep {
                            discreteSweepOverlay(plot: plot)
                        } else if cachedSegments.count > 1 {
                            discretePaletteOverlay(plot: plot)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    )
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .task(id: "\(lines.count):\(delimiter):\(activeXIndex):\(activeYIndex):\(activeProgressionIndex ?? -1):\(selectedProgressionValues.sorted().joined(separator: ",")):\(timeStartText):\(timeStopText)") {
            recomputePlotPoints()
        }
        .onAppear {
            recomputePlotPoints()
        }
    }

    private func recomputePlotPoints(forceContinuous: Bool? = nil) {
        let xIdx = activeXIndex
        let yIdx = activeYIndex
        let progIdx = activeProgressionIndex
        let sep = delimiter == "\\t" ? "\t" : delimiter
        let start = dataStartIndex
        let linesSnapshot = lines
        let tagsSnapshot = lineTags
        let currentSelectedProg = selectedProgressionValues
        let currentProgCol = activeProgressionColumn
        let startTimeFilter = Double(timeStartText)
        let stopTimeFilter = Double(timeStopText)
        let manualOverride = forceContinuous

        Task.detached(priority: .userInitiated) {
            var orderedProgressionKeys: [String] = []
            var progressionSegments: [String: [(Double, Double)]] = [:]
            var allDiscoveredProgVals: [String] = []
            var seenProgVals: Set<String> = []
            var continuousVals: [Double] = []

            for (lineIdx, line) in linesSnapshot.enumerated() {
                guard lineIdx >= start else { continue }
                if let tag = tagsSnapshot[lineIdx], tag == .metadata || tag == .columnHeaders { continue }

                let tokens = line.components(separatedBy: sep)
                guard xIdx < tokens.count && yIdx < tokens.count else { continue }

                let xStr = tokens[xIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
                let yStr = tokens[yIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")

                guard let xVal = Double(xStr), let yVal = Double(yStr), xVal.isFinite, yVal.isFinite else {
                    continue
                }

                let progVal: String
                if let pIdx = progIdx, pIdx < tokens.count {
                    let rawP = tokens[pIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedP = rawP.replacingOccurrences(of: ",", with: ".")
                    if let d = Double(normalizedP) {
                        continuousVals.append(d)
                        if d.truncatingRemainder(dividingBy: 1) == 0 {
                            progVal = "\(Int(d))"
                        } else {
                            progVal = String(format: "%.3f", d)
                        }
                    } else {
                        progVal = rawP.isEmpty ? "1" : rawP
                    }
                } else {
                    progVal = "default"
                }

                if !seenProgVals.contains(progVal) {
                    seenProgVals.insert(progVal)
                    allDiscoveredProgVals.append(progVal)
                    orderedProgressionKeys.append(progVal)
                }

                progressionSegments[progVal, default: []].append((xVal, yVal))
            }

            // Determine if column behaves as Continuous Time or Discrete Cycles
            let isTimeOrContinuous: Bool
            let minTime: Double
            let maxTime: Double
            if let override = manualOverride {
                isTimeOrContinuous = override
            } else if let pCol = currentProgCol {
                if let beh = pCol.progressionBehavior {
                    isTimeOrContinuous = (beh == .continuous)
                } else {
                    let nameLower = pCol.name.lowercased()
                    let labelLower = pCol.label.lowercased()
                    let isTimeNamed = pCol.progressionType == .time || nameLower.contains("time") || labelLower.contains("time")
                    let hasHighCardinality = seenProgVals.count > 50
                    isTimeOrContinuous = isTimeNamed || hasHighCardinality
                }
            } else {
                isTimeOrContinuous = false
            }

            if !continuousVals.isEmpty {
                minTime = continuousVals.min() ?? 0.0
                maxTime = continuousVals.max() ?? 1.0
            } else {
                minTime = 0.0
                maxTime = 1.0
            }

            var activeSegments: [SandboxSegment] = []
            var localMinX: Double = .greatestFiniteMagnitude
            var localMaxX: Double = -.greatestFiniteMagnitude
            var localMinY: Double = .greatestFiniteMagnitude
            var localMaxY: Double = -.greatestFiniteMagnitude

            if isTimeOrContinuous {
                // Continuous time slicing: filter points based on range [start, stop]
                let startLimit = startTimeFilter ?? minTime
                let stopLimit = stopTimeFilter ?? maxTime
                var slicePts: [(Double, Double)] = []

                for (lineIdx, line) in linesSnapshot.enumerated() {
                    guard lineIdx >= start else { continue }
                    if let tag = tagsSnapshot[lineIdx], tag == .metadata || tag == .columnHeaders { continue }

                    let tokens = line.components(separatedBy: sep)
                    guard xIdx < tokens.count && yIdx < tokens.count else { continue }

                    let xStr = tokens[xIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
                    let yStr = tokens[yIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")

                    guard let xVal = Double(xStr), let yVal = Double(yStr), xVal.isFinite, yVal.isFinite else {
                        continue
                    }

                    if let pIdx = progIdx, pIdx < tokens.count {
                        let rawP = tokens[pIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
                        if let tVal = Double(rawP) {
                            if tVal < startLimit || tVal > stopLimit {
                                continue
                            }
                        }
                    }

                    slicePts.append((xVal, yVal))
                    if xVal < localMinX { localMinX = xVal }
                    if xVal > localMaxX { localMaxX = xVal }
                    if yVal < localMinY { localMinY = yVal }
                    if yVal > localMaxY { localMaxY = yVal }
                }

                if !slicePts.isEmpty {
                    activeSegments.append(SandboxSegment(name: "Time Window", points: slicePts))
                }
            } else {
                // Discrete Cycles: Filter segments based on selectedProgressionValues
                for key in orderedProgressionKeys {
                    if !currentSelectedProg.isEmpty && !currentSelectedProg.contains(key) {
                        continue
                    }

                    if let pts = progressionSegments[key], !pts.isEmpty {
                        activeSegments.append(SandboxSegment(name: key == "default" ? "Data" : key, points: pts))
                        for p in pts {
                            if p.0 < localMinX { localMinX = p.0 }
                            if p.0 > localMaxX { localMaxX = p.0 }
                            if p.1 < localMinY { localMinY = p.1 }
                            if p.1 > localMaxY { localMaxY = p.1 }
                        }
                    }
                }
            }

            let bounds: (Double, Double, Double, Double) = activeSegments.isEmpty ? (0, 1, 0, 1) : (localMinX, localMaxX, localMinY, localMaxY)
            let finalSegments = activeSegments
            let finalDiscovered = (progIdx != nil && !isTimeOrContinuous) ? allDiscoveredProgVals : []

            await MainActor.run {
                self.isContinuousMode = isTimeOrContinuous
                self.continuousMinTime = minTime
                self.continuousMaxTime = maxTime
                if isTimeOrContinuous && self.timeStartText.isEmpty && self.timeStopText.isEmpty {
                    self.timeStartText = String(format: "%.1f", minTime)
                    self.timeStopText = String(format: "%.1f", maxTime)
                }
                self.availableProgressionValues = finalDiscovered
                self.cachedSegments = finalSegments
                self.cachedBounds = bounds
            }
        }
    }

    @ViewBuilder
    private func continuousSweepOverlay(plot: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progCol = activeProgressionColumn {
                let dimLabel = progCol.label.isEmpty ? progCol.name : progCol.label
                let unitPart = progCol.unit.isEmpty ? "" : " (\(progCol.unit))"
                let rangePart: String = {
                    if let s = Double(timeStartText), let e = Double(timeStopText) {
                        return String(format: "%.1f–%.1fs (Full: %.1f–%.1fs)", s, e, continuousMinTime, continuousMaxTime)
                    } else {
                        return String(format: "%.1f–%.1fs", continuousMinTime, continuousMaxTime)
                    }
                }()
                Text("\(dimLabel)\(unitPart): \(rangePart)")
                    .font(StudioTokens.captionBold(uiFontSize: uiFontSize))
                    .foregroundStyle(Color.purple)
            }
            SweepColorbarView()
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.purple.opacity(0.25), lineWidth: 0.8)
        )
        .offset(x: plot.minX + 8, y: plot.minY + 8)
    }

    @ViewBuilder
    private func discreteSweepOverlay(plot: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let firstVal = availableProgressionValues.first ?? "1"
            let lastVal = availableProgressionValues.last ?? "\(availableProgressionValues.count)"
            Text("Progression: Cycle \(firstVal) (Start) → Cycle \(lastVal) (End)")
                .font(StudioTokens.captionBold(uiFontSize: uiFontSize))
                .foregroundStyle(Color.purple)
            SweepColorbarView()
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.purple.opacity(0.25), lineWidth: 0.8)
        )
        .offset(x: plot.minX + 8, y: plot.minY + 8)
    }

    @ViewBuilder
    private func discretePaletteOverlay(plot: CGRect) -> some View {
        let legendItems = cachedSegments.enumerated().map { sIdx, seg in
            (color: NativeOverlayPalette.color(sIdx), label: seg.name)
        }
        let totalCount = cachedSegments.count
        let cardWidth: CGFloat = totalCount <= 6 ? 140 : 155
        let baseX = max(10, plot.maxX - cardWidth - 12)
        let baseY = plot.minY + 8

        VStack(alignment: .leading, spacing: 5) {
            // Header with cycle count, drag handle & optional Reset button
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 7.5))
                    .foregroundStyle(.tertiary)
                Text("Cycles (\(totalCount)):")
                    .font(StudioTokens.captionBold(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
                Spacer()
                if highlightedCycle != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            highlightedCycle = nil
                        }
                    } label: {
                        Text("Reset")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if totalCount <= 6 {
                VStack(alignment: .leading, spacing: 2.5) {
                    ForEach(Array(legendItems.enumerated()), id: \.offset) { _, item in
                        cycleLegendRow(item: item)
                    }
                }
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        ForEach(Array(legendItems.enumerated()), id: \.offset) { _, item in
                            cycleLegendRow(item: item)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 130)
            }
        }
        .padding(7)
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.ultraThinMaterial.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(highlightedCycle != nil ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .offset(x: baseX + legendOffset.width, y: baseY + legendOffset.height)
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    legendOffset = CGSize(
                        width: legendDragBase.width + gesture.translation.width,
                        height: legendDragBase.height + gesture.translation.height
                    )
                }
                .onEnded { _ in
                    legendDragBase = legendOffset
                }
        )
    }

    @ViewBuilder
    private func cycleLegendRow(item: (color: Color, label: String)) -> some View {
        let isHl = (highlightedCycle == item.label)
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if highlightedCycle == item.label {
                    highlightedCycle = nil
                } else {
                    highlightedCycle = item.label
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(item.color)
                    .frame(width: isHl ? 8.5 : 7, height: isHl ? 8.5 : 7)
                    .overlay(
                        Circle().stroke(Color.primary.opacity(isHl ? 0.6 : 0), lineWidth: 1)
                    )
                Text(item.label)
                    .font(isHl ? StudioTokens.captionBold(uiFontSize: uiFontSize) : StudioTokens.caption(uiFontSize: uiFontSize))
                    .foregroundStyle(isHl ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
                if isHl {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(item.color)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHl ? item.color.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isHl ? item.color.opacity(0.4) : Color.clear, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private func formatTick(_ val: Double) -> String {
        if abs(val) >= 1000 || (abs(val) > 0 && abs(val) < 0.01) {
            return String(format: "%.1e", val)
        }
        return String(format: "%.2f", val)
    }

    private func computePlotLayout(for size: CGSize) -> (plot: CGRect, fontScale: CGFloat, maxLabelWidth: CGFloat, yLabels: [String]) {
        let minY = cachedBounds.minY
        let maxY = cachedBounds.maxY
        let yLabels: [String] = (0...4).map { idx in
            let t = Double(idx) / 4.0
            return formatTick(minY + t * (maxY - minY))
        }
        let targetRatio: CGFloat = 59.1 / 50.0 // Nature single column
        let approxPlotWidth = max(200, size.width - 120)
        let fontScale = PlotRenderingEngine.fontScale(plotWidth: approxPlotWidth, uiFontSize: uiFontSize)
        let maxChars = yLabels.map(\.count).max() ?? 1
        let maxLabelWidth = max(34 * fontScale, CGFloat(maxChars) * 8.0 * fontScale)
        let leftGutter = max(84 * fontScale, maxLabelWidth + 30 * fontScale)
        let topGutter: CGFloat = 20 * fontScale
        let bottomGutter: CGFloat = 54 * fontScale
        let rightGutter: CGFloat = 22 * fontScale

        let availWidth = max(10, size.width - leftGutter - rightGutter)
        let availHeight = max(10, size.height - topGutter - bottomGutter)
        var plotW = availWidth
        var plotH = plotW / targetRatio
        if plotH > availHeight {
            plotH = availHeight
            plotW = plotH * targetRatio
        }
        let plotX = leftGutter + (availWidth - plotW) / 2
        let plotY = topGutter + (availHeight - plotH) / 2
        let plot = CGRect(x: plotX, y: plotY, width: max(1, plotW), height: max(1, plotH))
        return (plot, fontScale, maxLabelWidth, yLabels)
    }
}

struct EditorCanvasView: View {
    let lines: [String]
    let lineTags: [Int: LineRegionType]
    @Binding var selectedLineRange: ClosedRange<Int>?
    var onTagRange: ((ClosedRange<Int>, LineRegionType) -> Void)?

    @State private var anchorLine: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Tag Selected:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button { applyTag(.metadata) } label: {
                    Label("Metadata", systemImage: "tag.fill")
                        .font(.caption2).foregroundStyle(.purple)
                }
                .disabled(selectedLineRange == nil)

                Button { applyTag(.columnHeaders) } label: {
                    Label("Column Names", systemImage: "tablecells")
                        .font(.caption2).foregroundStyle(.blue)
                }
                .disabled(selectedLineRange == nil)

                Button { applyTag(.dataMatrix) } label: {
                    Label("Data Matrix", systemImage: "chart.xyaxis.line")
                        .font(.caption2).foregroundStyle(.green)
                }
                .disabled(selectedLineRange == nil)

                Button("Clear") { applyTag(.unassigned) }
                    .font(.caption2)
                    .disabled(selectedLineRange == nil)

                Spacer()

                if let range = selectedLineRange {
                    Text("Lines \(range.lowerBound + 1)–\(range.upperBound + 1) selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            if lines.count > 2000 {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Showing first 2,000 lines of \(lines.count) for tagging.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
            }

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(0..<min(lines.count, 2000), id: \.self) { idx in
                        LineRowView(
                            lineNumber: idx + 1,
                            text: lines[idx],
                            tag: lineTags[idx] ?? .unassigned,
                            isSelected: selectedLineRange?.contains(idx) == true
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { handleLineClick(idx) }
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    private func handleLineClick(_ lineIndex: Int) {
        if NSEvent.modifierFlags.contains(.shift), let anchor = anchorLine {
            let start = min(anchor, lineIndex)
            let end = max(anchor, lineIndex)
            selectedLineRange = start...end
        } else {
            anchorLine = lineIndex
            selectedLineRange = lineIndex...lineIndex
        }
    }

    private func applyTag(_ tag: LineRegionType) {
        guard let range = selectedLineRange else { return }
        onTagRange?(range, tag)
    }
}

struct LineRowView: View {
    let lineNumber: Int
    let text: String
    let tag: LineRegionType
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(lineNumber)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Circle()
                .fill(tagColor)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(text.isEmpty ? " " : text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(rowBackground)
    }

    private var tagColor: Color {
        switch tag {
        case .unassigned: return .clear
        case .metadata: return .purple
        case .columnHeaders: return .blue
        case .dataMatrix: return .green
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor }
        switch tag {
        case .unassigned: return .clear
        case .metadata: return Color.purple.opacity(0.12)
        case .columnHeaders: return Color.blue.opacity(0.12)
        case .dataMatrix: return Color.green.opacity(0.08)
        }
    }
}

/// Custom Parser Override & Color-Coded Tokenized Raw Stream View
struct ParserSettingsCanvasView: View {
    let lines: [String]
    @Binding var delimiter: String
    @Binding var decimalSeparator: String
    @Binding var columns: [ColumnDefinition]
    let lineTags: [Int: LineRegionType]
    var metadataCellTags: [String: MetadataCellTag] = [:]
    var onTagMetadataCell: ((MetadataCellTag) -> Void)? = nil
    var onRemoveMetadataTag: ((Int, Int) -> Void)? = nil
    var onUpdateColumn: ((Int, ColumnDefinition) -> Void)? = nil
    var onRunAutoDetect: (() -> Void)?
    var onApplyCustomStructure: ((String, String, Int?, Int, Set<Int>) -> Void)?

    @State private var selectedDelimiter: String = ","
    @State private var customDelimiterText: String = ""
    @State private var selectedDecimal: String = "."
    @State private var headerLineChoice: Int = 0 // 0 = Auto/Current, -1 = None, 1...N = Line number
    @State private var headerLineText: String = ""
    @State private var dataStartLineChoice: Int = 2 // 1-based line number
    @State private var dataStartLineText: String = "2"
    @State private var skippedMetadataLines: Set<Int> = [] // 1-based line numbers to exclude
    @State private var showMetadataPopover: Bool = false

    // New Impeccable Stream Controls
    @State private var selectedLines: Set<Int> = [] // 1-based line numbers for Shift/Cmd selection
    @State private var lastClickedLine: Int? = nil // Selection anchor for Shift+Click range
    @State private var isDataExpanded: Bool = false // Toggle between head+tail inspection and full stream
    @State private var previewRowCount: Int = 50 // Number of data preview rows before folding

    struct CellTarget: Identifiable {
        let id = UUID()
        let lineIdx: Int
        let tokenIdx: Int
        let token: String
    }
    @State private var activeCellPopover: CellTarget? = nil

    @State private var selectedColumns: Set<Int> = [] // 0-based column indices
    @State private var lastClickedColumn: Int? = nil // Selection anchor for Shift+Click range
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0
    @State private var hoveredColumn: Int? = nil
    @State private var hoveredToolbarRole: ColumnRole? = nil

    private var focusedToolbarRole: ColumnRole? {
        if let hRole = hoveredToolbarRole {
            return hRole
        }
        let targetColIdx: Int? = hoveredColumn ?? (selectedColumns.count == 1 ? selectedColumns.first : nil)
        guard let idx = targetColIdx, idx < columns.count else { return nil }
        let col = columns[idx]
        if col.isSkipped || col.role == .skip { return .skip }
        if col.role == .progression || col.progressionType != nil { return .progression }
        if col.isXAxis || col.role == .x { return .x }
        if col.isYAxis || col.role == .y { return .y }
        return .channel
    }

    enum HeaderRowMode: String, CaseIterable, Identifiable {
        case raw = "Raw Stream"
        case configured = "Column Cards"
        var id: String { rawValue }
    }
    @State private var headerRowMode: HeaderRowMode = .configured

    // 12 Harmonious pastel colors for distinguishing columns
    private static let columnPalette: [Color] = [
        Color.blue,
        Color.green,
        Color.orange,
        Color.purple,
        Color.teal,
        Color.pink,
        Color.indigo,
        Color.mint,
        Color.cyan,
        Color.brown,
        Color.yellow,
        Color.red
    ]

    private var currentHeaderLine: Int? {
        var minH = Int.max
        for (idx, tag) in lineTags where tag == .columnHeaders {
            if idx < minH { minH = idx }
        }
        return minH == Int.max ? nil : (minH + 1)
    }

    private var currentDataStartLine: Int {
        var minD = Int.max
        for (idx, tag) in lineTags where tag == .dataMatrix {
            if idx < minD { minD = idx }
        }
        return minD == Int.max ? 2 : (minD + 1)
    }

    private var effectiveDelimiter: String {
        if selectedDelimiter == "CUSTOM" {
            return customDelimiterText.isEmpty ? "," : customDelimiterText
        }
        return selectedDelimiter == "\\t" ? "\t" : selectedDelimiter
    }

    private var effectiveHeaderLine: Int? {
        headerLineChoice == 0 ? currentHeaderLine : (headerLineChoice == -1 ? nil : headerLineChoice)
    }

    private var effectiveDataStartLine: Int {
        dataStartLineChoice > 0 ? dataStartLineChoice : currentDataStartLine
    }

    struct MetadataEntry: Identifiable {
        let lineIndex: Int
        var lineNum: Int { lineIndex + 1 }
        let rawText: String
        let key: String
        let value: String
        var id: Int { lineNum }
    }

    private var metadataEntries: [MetadataEntry] {
        var entries: [MetadataEntry] = []
        let dataStartIdx = min(lines.count, max(0, effectiveDataStartLine - 1))
        let headerIdx = effectiveHeaderLine.map { $0 - 1 }
        let limit = min(dataStartIdx, 50)
        for i in 0..<limit {
            if let h = headerIdx, i == h { continue }
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let clean = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            if let colonIdx = clean.firstIndex(of: ":") {
                let k = String(clean[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let v = String(clean[clean.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                entries.append(MetadataEntry(lineIndex: i, rawText: trimmed, key: k, value: v))
            } else if let eqIdx = clean.firstIndex(of: "=") {
                let k = String(clean[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                let v = String(clean[clean.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                entries.append(MetadataEntry(lineIndex: i, rawText: trimmed, key: k, value: v))
            } else {
                entries.append(MetadataEntry(lineIndex: i, rawText: trimmed, key: clean, value: ""))
            }
        }
        return entries
    }

    private var activeMetadataCount: Int {
        metadataEntries.filter { !skippedMetadataLines.contains($0.lineNum) }.count
    }

    private var streamColumnCount: Int {
        var count = 0
        if let h = effectiveHeaderLine, h > 0, h <= lines.count {
            let hTokens = lines[h - 1].components(separatedBy: effectiveDelimiter)
            count = max(count, hTokens.count)
        }
        let dataStart = max(1, min(lines.count, effectiveDataStartLine))
        let sampleLimit = min(lines.count + 1, dataStart + 15)
        for idx in dataStart..<sampleLimit {
            let dTokens = lines[idx - 1].components(separatedBy: effectiveDelimiter)
            count = max(count, dTokens.count)
        }
        return max(1, count)
    }

    /// Computes token array for a line, strictly preserving column coordinates without bias
    private func tokensForLine(rawLine: String) -> [String] {
        rawLine.components(separatedBy: effectiveDelimiter)
    }

    /// Lines to display: ALL pre-data lines (metadata header 100% visible, never clipped) + (Head [previewRowCount] data rows + marker -1 + Tail 10 data rows)
    private var linesToDisplay: [Int] {
        let dataStart = max(1, min(lines.count, effectiveDataStartLine))
        let total = lines.count

        var result: [Int] = []
        // 1. All lines before data start (metadata, header, comments) are 100% displayed without folding
        if dataStart > 1 {
            for lineNum in 1..<dataStart {
                result.append(lineNum)
            }
        }

        // 2. Data rows with Head & Tail folding based on previewRowCount
        if dataStart <= total {
            let dataCount = total - dataStart + 1
            if dataCount <= (previewRowCount + 15) || isDataExpanded {
                let limit = isDataExpanded ? dataCount : min(dataCount, previewRowCount * 2)
                for offset in 0..<limit {
                    result.append(dataStart + offset)
                }
            } else {
                // Head preview rows
                let headCount = min(previewRowCount, dataCount)
                for offset in 0..<headCount {
                    result.append(dataStart + offset)
                }
                // Marker for collapsed divider
                result.append(-1)
                // Tail 10 data rows
                let tailStart = max(dataStart + headCount, total - 9)
                if tailStart <= total {
                    for lineNum in tailStart...total {
                        result.append(lineNum)
                    }
                }
            }
        }
        return result
    }

    private func handleRowClick(lineNum: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            let anchor = lastClickedLine ?? lineNum
            let low = min(anchor, lineNum)
            let high = max(anchor, lineNum)
            selectedLines.formUnion(low...high)
        } else if flags.contains(.command) {
            if selectedLines.contains(lineNum) {
                selectedLines.remove(lineNum)
            } else {
                selectedLines.insert(lineNum)
            }
            lastClickedLine = lineNum
        } else {
            selectedLines = [lineNum]
            lastClickedLine = lineNum
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Impeccable Control Toolbar (4 Grouped macOS Studio Cards)
            HStack(alignment: .center, spacing: 10) {
                // CARD 1: Delimiter & Decimal Delimiters Block
                VStack(alignment: .leading, spacing: 5) {
                    // Row 1: Delimiter
                    HStack(spacing: 4) {
                        Text("Delimiter:")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)
                        Picker("", selection: $selectedDelimiter) {
                            Text("Semicolon (;)").tag(";")
                            Text("Comma (,)").tag(",")
                            Text("Tab (\\t)").tag("\t")
                            Text("Space").tag(" ")
                            Text("Custom…").tag("CUSTOM")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 115)

                        if selectedDelimiter == "CUSTOM" {
                            TextField("|", text: $customDelimiterText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 32)
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                    }

                    // Row 2: Decimal (Dropdown menu select, perfectly aligned with Delimiter)
                    HStack(spacing: 4) {
                        Text("Decimal:")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)
                        Picker("", selection: $selectedDecimal) {
                            Text("Period (.)").tag(".")
                            Text("Comma (,)").tag(",")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 115)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(NSColor.windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.8))

                // CARD 2: Row Bounds (Header L# & Data Start L#)
                VStack(alignment: .leading, spacing: 5) {
                    // Row 1: Header Line
                    HStack(spacing: 4) {
                        Text("Header L#:")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        TextField("None", text: $headerLineText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .frame(width: 42)
                            .onChange(of: headerLineText) { _, newValue in
                                if let val = Int(newValue.trimmingCharacters(in: .whitespaces)) {
                                    headerLineChoice = max(0, val)
                                } else if newValue.isEmpty {
                                    headerLineChoice = 0
                                }
                            }
                        Stepper("", value: Binding(
                            get: { headerLineChoice },
                            set: { newVal in
                                headerLineChoice = max(0, newVal)
                                headerLineText = newVal <= 0 ? "" : "\(newVal)"
                            }
                        ), in: 0...max(lines.count, 1))
                        .labelsHidden()
                    }

                    // Row 2: Data Start Line
                    HStack(spacing: 4) {
                        Text("Data Start L#:")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        TextField("1", text: $dataStartLineText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .frame(width: 42)
                            .onChange(of: dataStartLineText) { _, newValue in
                                if let val = Int(newValue.trimmingCharacters(in: .whitespaces)) {
                                    dataStartLineChoice = max(1, val)
                                }
                            }
                        Stepper("", value: Binding(
                            get: { dataStartLineChoice },
                            set: { newVal in
                                dataStartLineChoice = max(1, newVal)
                                dataStartLineText = "\(dataStartLineChoice)"
                            }
                        ), in: 1...max(lines.count, 1))
                        .labelsHidden()
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(NSColor.windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.8))

                // CARD 2: Metadata & Columns Status & Preview Controls
                VStack(alignment: .leading, spacing: 5) {
                    // Row 1: Metadata Items Popover Button & Preview Row Control
                    HStack(spacing: 6) {
                        Button {
                            showMetadataPopover.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "tag.fill")
                                    .foregroundStyle(Color.purple)
                                Text("Metadata Tags (\(activeMetadataCount)/\(metadataEntries.count))")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7.5))
                            }
                            .font(.system(size: 10.5))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .popover(isPresented: $showMetadataPopover, arrowEdge: .bottom) {
                            metadataPopoverContent
                        }

                        // Preview row count selector & Expand All
                        HStack(spacing: 4) {
                            Text("Preview:")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)

                            Picker("", selection: $previewRowCount) {
                                Text("25").tag(25)
                                Text("50").tag(50)
                                Text("100").tag(100)
                                Text("200").tag(200)
                                Text("500").tag(500)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 58)

                            Button {
                                isDataExpanded.toggle()
                            } label: {
                                Image(systemName: isDataExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help(isDataExpanded ? "Collapse to preview rows" : "Expand all rows")
                        }
                    }

                    // Row 2: Columns Summary & Quick Actions
                    HStack(spacing: 5) {
                        let activeCols = columns.filter { !$0.isSkipped }.count
                        Text("Cols: \(activeCols)/\(columns.count)")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(activeCols < columns.count ? Color.orange : Color.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.secondary.opacity(0.1)))

                        Button("Include All") {
                            includeAllColumns()
                        }
                        .font(.system(size: 9.5))
                        .buttonStyle(.borderless)
                        .controlSize(.mini)

                        Button("⊘ Auto-Skip Empty") {
                            autoSkipEmptyColumns()
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Automatically marks completely empty data columns as skipped")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(NSColor.windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.8))

                // CARD 3: Header View Mode & Selection Batch Actions
                VStack(alignment: .leading, spacing: 5) {
                    // Row 1: Header Mode Segmented Switch (Raw Header vs Column Cards)
                    HStack(spacing: 6) {
                        Text("Header View:")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.secondary)

                        Picker("", selection: $headerRowMode) {
                            Label("Raw Stream", systemImage: "doc.text")
                                .tag(HeaderRowMode.raw)
                            Label("Column Cards", systemImage: "rectangle.split.3x1.fill")
                                .tag(HeaderRowMode.configured)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                    }

                    // Row 2: Contextual Selection Actions OR Instruction Hint
                    if !selectedColumns.isEmpty {
                        let allSelectedSkipped = selectedColumns.allSatisfy { $0 < columns.count && columns[$0].isSkipped }

                        HStack(spacing: 6) {
                            Text("\(selectedColumns.count) selected")
                                .font(StudioTokens.captionBold(uiFontSize: uiFontSize))
                                .foregroundStyle(Color.accentColor)

                            // 1. Skip / Include Button (Uniform 24pt, dynamic illumination)
                            let isSkipLit = (focusedToolbarRole == (allSelectedSkipped ? .channel : .skip))
                            let skipColor = allSelectedSkipped ? Color.blue : Color.orange
                            Button {
                                if allSelectedSkipped {
                                    includeSelectedColumns()
                                } else {
                                    skipSelectedColumns()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: allSelectedSkipped ? "arrow.uturn.backward" : "nosign")
                                        .font(.system(size: 9, weight: .bold))
                                    Text(allSelectedSkipped
                                         ? (selectedColumns.count > 1 ? "Include (\(selectedColumns.count))" : "Include")
                                         : (selectedColumns.count > 1 ? "Skip (\(selectedColumns.count))" : "Skip"))
                                        .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isSkipLit ? skipColor.opacity(0.18) : Color.primary.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(isSkipLit ? skipColor : Color.secondary.opacity(0.25), lineWidth: isSkipLit ? 1.2 : 0.8)
                                )
                                .foregroundStyle(isSkipLit ? skipColor : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .onHover { h in
                                if h { hoveredToolbarRole = allSelectedSkipped ? .channel : .skip }
                                else if hoveredToolbarRole == (allSelectedSkipped ? .channel : .skip) { hoveredToolbarRole = nil }
                            }

                            // 2. Set X Button (Uniform 24pt, dynamic illumination)
                            let isXLit = (focusedToolbarRole == .x)
                            Button {
                                setSelectedColumnsRole(isX: true, isY: false)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("X")
                                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                    Text(selectedColumns.count > 1 ? "Set X (\(selectedColumns.count))" : "Set X")
                                        .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isXLit ? Color.blue.opacity(0.18) : Color.primary.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(isXLit ? Color.blue : Color.secondary.opacity(0.25), lineWidth: isXLit ? 1.2 : 0.8)
                                )
                                .foregroundStyle(isXLit ? Color.blue : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .onHover { h in
                                if h { hoveredToolbarRole = .x }
                                else if hoveredToolbarRole == .x { hoveredToolbarRole = nil }
                            }

                            // 3. Set Y Button (Uniform 24pt, dynamic illumination)
                            let isYLit = (focusedToolbarRole == .y)
                            Button {
                                setSelectedColumnsRole(isX: false, isY: true)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Y")
                                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                    Text(selectedColumns.count > 1 ? "Set Y (\(selectedColumns.count))" : "Set Y")
                                        .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isYLit ? Color.green.opacity(0.18) : Color.primary.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(isYLit ? Color.green : Color.secondary.opacity(0.25), lineWidth: isYLit ? 1.2 : 0.8)
                                )
                                .foregroundStyle(isYLit ? Color.green : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .onHover { h in
                                if h { hoveredToolbarRole = .y }
                                else if hoveredToolbarRole == .y { hoveredToolbarRole = nil }
                            }

                            // 4. Set Prog Menu (Uniform 24pt, dynamic illumination)
                            let isProgLit = (focusedToolbarRole == .progression)
                            Menu {
                                Menu("Time Progression") {
                                    Button("Continuous (Time Range)") {
                                        setSelectedColumnsProgression(type: .time, behavior: .continuous)
                                    }
                                    Button("Discrete (Time Steps)") {
                                        setSelectedColumnsProgression(type: .time, behavior: .discrete)
                                    }
                                }
                                Menu("Index / Cycle Progression") {
                                    Button("Discrete (Multi-select Cycles)") {
                                        setSelectedColumnsProgression(type: .index, behavior: .discrete)
                                    }
                                    Button("Continuous (Index Range)") {
                                        setSelectedColumnsProgression(type: .index, behavior: .continuous)
                                    }
                                }
                                Menu("Custom Progression…") {
                                    Button("Discrete (Custom Cycles)") {
                                        setSelectedColumnsProgression(type: .custom, behavior: .discrete)
                                    }
                                    Button("Continuous (Custom Slices)") {
                                        setSelectedColumnsProgression(type: .custom, behavior: .continuous)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 8.5))
                                    Text(selectedColumns.count > 1 ? "Set Prog (\(selectedColumns.count))" : "Set Prog")
                                        .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 7))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isProgLit ? Color.purple.opacity(0.18) : Color.primary.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(isProgLit ? Color.purple : Color.secondary.opacity(0.25), lineWidth: isProgLit ? 1.2 : 0.8)
                                )
                                .foregroundStyle(isProgLit ? Color.purple : Color.primary)
                            }
                            .menuStyle(.borderlessButton)
                            .onHover { h in
                                if h { hoveredToolbarRole = .progression }
                                else if hoveredToolbarRole == .progression { hoveredToolbarRole = nil }
                            }

                            Button("Clear (⌘D)") {
                                selectedColumns.removeAll()
                                lastClickedColumn = nil
                            }
                            .font(StudioTokens.caption(uiFontSize: uiFontSize))
                            .buttonStyle(.borderless)
                        }
                    } else if let hColIdx = hoveredColumn, hColIdx < columns.count {
                        let col = columns[hColIdx]
                        HStack(spacing: 6) {
                            Text("Col #\(hColIdx + 1):")
                                .font(StudioTokens.captionBold(uiFontSize: uiFontSize))
                                .foregroundStyle(.secondary)
                            Text(col.label.isEmpty ? (col.name.isEmpty ? "Column" : col.name) : col.label)
                                .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                                .foregroundStyle(Color.primary)
                            StudioRoleBadgeView(
                                text: rolePillText(col: col),
                                roleColor: StudioTokens.roleColor(col: col),
                                hasDropdown: false,
                                uiFontSize: uiFontSize
                            )
                            Text("— Click column header to select")
                                .font(StudioTokens.caption(uiFontSize: uiFontSize))
                                .foregroundStyle(.tertiary)
                        }
                    } else if !selectedLines.isEmpty {
                        HStack(spacing: 5) {
                            Text("\(selectedLines.count) rows")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.accentColor)

                            Button("Skip") {
                                for line in selectedLines { skippedMetadataLines.insert(line) }
                            }
                            .font(.system(size: 9.5))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("Active Meta") {
                                for line in selectedLines { skippedMetadataLines.remove(line) }
                            }
                            .font(.system(size: 9.5))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("Clear") {
                                selectedLines.removeAll()
                            }
                            .font(.system(size: 9.5))
                            .buttonStyle(.borderless)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "cursorarrow.click.2")
                                .font(.system(size: 8))
                            Text("Click, ⇧Click, ⌘Click columns in grid to batch assign")
                                .font(.system(size: 9.5))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(NSColor.windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.8))

                Spacer()

                // CARD 4: Run Actions
                VStack(alignment: .trailing, spacing: 5) {
                    // Row 1: Re-run Auto Detect Button
                    Button {
                        onRunAutoDetect?()
                        selectedDelimiter = delimiter
                        selectedDecimal = decimalSeparator
                        headerLineChoice = currentHeaderLine ?? 0
                        headerLineText = headerLineChoice <= 0 ? "" : "\(headerLineChoice)"
                        dataStartLineChoice = currentDataStartLine
                        dataStartLineText = "\(dataStartLineChoice)"
                        skippedMetadataLines.removeAll()
                        selectedColumns.removeAll()
                        selectedLines.removeAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("Auto Detect")
                            ShortcutBadge("autoDetect")
                        }
                        .font(.system(size: 10.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("d", modifiers: [.command])

                    // Row 2: Apply Button
                    Button {
                        let finalDelim = selectedDelimiter == "CUSTOM" ? customDelimiterText : selectedDelimiter
                        onApplyCustomStructure?(finalDelim, selectedDecimal, effectiveHeaderLine, effectiveDataStartLine, skippedMetadataLines)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text("Apply & Parse")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(NSColor.windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // MARK: - Color-Coded Token Stream Grid (Pinned Top-Leading, Left-Aligned)
            GeometryReader { scrollGeo in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(linesToDisplay, id: \.self) { lineNum in
                                if lineNum == -1 {
                                    // Collapsed middle data divider banner
                                    collapsedDataBanner
                                } else {
                                    let lineIdx = lineNum - 1
                                    if lineIdx >= 0 && lineIdx < lines.count {
                                        streamRow(lineNum: lineNum, rawLine: lines[lineIdx])
                                    }
                                }
                            }

                            if isDataExpanded {
                                HStack {
                                    Spacer()
                                    Button {
                                        isDataExpanded = false
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "chevron.up")
                                            Text("Collapse to Head & Tail Preview")
                                        }
                                        .font(.system(size: 10.5, weight: .semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                    .frame(minWidth: scrollGeo.size.width, minHeight: scrollGeo.size.height, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectedDelimiter = delimiter
            selectedDecimal = decimalSeparator
            headerLineChoice = currentHeaderLine ?? 0
            headerLineText = headerLineChoice <= 0 ? "" : "\(headerLineChoice)"
            dataStartLineChoice = currentDataStartLine
            dataStartLineText = "\(dataStartLineChoice)"
        }
    }

    // MARK: - Column Skipping & Metadata Helpers
    private func autoSkipEmptyColumns() {
        guard !columns.isEmpty else { return }
        let dataStart = effectiveDataStartLine
        let sampleLimit = min(lines.count, dataStart + 40)
        guard dataStart <= sampleLimit else { return }

        for cIdx in 0..<columns.count {
            var allEmpty = true
            for lNum in dataStart...sampleLimit {
                let lIdx = lNum - 1
                if lIdx < lines.count {
                    let toks = tokensForLine(rawLine: lines[lIdx])
                    if cIdx < toks.count {
                        let val = toks[cIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !val.isEmpty && val != "—" && val != "NaN" && val != "null" {
                            allEmpty = false
                            break
                        }
                    }
                }
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

    /// Computes content-aware uniform column width based on Header token, Column Title/Unit, and data samples.
    /// Used across ALL rows (Header, Data Matrix, Metadata) to guarantee 100% strict vertical grid alignment.
    private func uniformColumnWidth(colIdx: Int) -> CGFloat {
        // 1. Get header token for this column
        let headerToken: String
        if let h = effectiveHeaderLine, h > 0, h <= lines.count {
            let hTokens = tokensForLine(rawLine: lines[h - 1])
            headerToken = colIdx < hTokens.count ? hTokens[colIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        } else {
            headerToken = colIdx < columns.count ? columns[colIdx].name : ""
        }

        if headerRowMode == .raw {
            let headerLen = headerToken.count
            let approxWidth = CGFloat(headerLen) * 8.5 + 24
            return min(max(approxWidth, 110), 220)
        }

        let col = (colIdx < columns.count) ? columns[colIdx] : ColumnDefinition(name: headerToken)
        let titleLen = max(col.label.count, col.name.count, headerToken.count)
        let unitLen = col.unit.count

        // Base estimate from header card: Title + Unit + Role badge + index
        var maxCharEstimate = titleLen + unitLen + 8

        // 2. Sample up to 15 data rows to check numeric/content length (capping floating point estimation at .3f)
        let dataStart = effectiveDataStartLine
        let maxSampleRow = min(lines.count, dataStart + 15)
        if dataStart <= maxSampleRow {
            for lNum in dataStart...maxSampleRow {
                let lIdx = lNum - 1
                if lIdx < lines.count {
                    let toks = tokensForLine(rawLine: lines[lIdx])
                    if colIdx < toks.count {
                        let rawVal = toks[colIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                        if let num = Double(rawVal.replacingOccurrences(of: ",", with: ".")) {
                            let compactStr = String(format: "%.3f", num)
                            maxCharEstimate = max(maxCharEstimate, compactStr.count + 4)
                        } else {
                            maxCharEstimate = max(maxCharEstimate, min(rawVal.count, 14) + 4)
                        }
                    }
                }
            }
        }

        // Each character roughly takes 7.8pt monospaced/bold plus padding for Title, Slash, Unit and Autocomplete chevron
        let calculated = CGFloat(maxCharEstimate) * 8.2 + 54
        return min(max(calculated, 145), 280)
    }

    private func metadataTagFor(lineIndex: Int, tokenIndex: Int) -> MetadataCellTag? {
        metadataCellTags["\(lineIndex):\(tokenIndex)"]
    }

    private func tagBadgeText(_ tag: MetadataCellTag) -> String {
        if let param = tag.parameterKey, !param.isEmpty {
            return param
        }
        switch tag.entityType {
        case .instrumentName: return "Model"
        case .instrumentID: return "ID"
        case .dateTime: return "DateTime"
        case .dateOnly: return "Date"
        case .timeOnly: return "Time"
        case .operatorName: return "Operator"
        case .sampleName: return "Sample"
        case .technique: return "Technique"
        case .parameter: return tag.customKey ?? "Param"
        case .ignore: return "Skip"
        }
    }

    private func tagIcon(for type: MetadataCellTag.EntityType) -> Image {
        switch type {
        case .instrumentName, .instrumentID:
            return Image(systemName: "cpu")
        case .dateTime, .dateOnly, .timeOnly:
            return Image(systemName: "clock")
        case .parameter:
            return Image(systemName: "slider.horizontal.3")
        case .operatorName, .sampleName, .technique:
            return Image(systemName: "person.crop.circle")
        case .ignore:
            return Image(systemName: "slash.circle")
        }
    }

    private func tagColor(for type: MetadataCellTag.EntityType) -> Color {
        switch type {
        case .instrumentName, .instrumentID:
            return Color.purple
        case .dateTime, .dateOnly, .timeOnly:
            return Color.blue
        case .parameter:
            return Color.orange
        case .operatorName, .sampleName, .technique:
            return Color.teal
        case .ignore:
            return Color.secondary
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

    private func rolePillBackground(col: ColumnDefinition) -> Color {
        if col.isSkipped || col.role == .skip { return Color.secondary.opacity(0.12) }
        if col.role == .progression { return Color.purple.opacity(0.15) }
        if col.isXAxis || col.role == .x { return Color.blue.opacity(0.14) }
        if col.isYAxis || col.role == .y { return Color.green.opacity(0.14) }
        return Color.primary.opacity(0.05)
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

    private func rolePillTextColor(col: ColumnDefinition) -> Color {
        if col.isSkipped || col.role == .skip { return Color.secondary }
        if col.role == .progression { return Color.purple }
        if col.isXAxis || col.role == .x { return Color.blue }
        if col.isYAxis || col.role == .y { return Color.green }
        return Color.secondary
    }

    @ViewBuilder
    private func metadataCellContextMenu(lineIdx: Int, tokenIdx: Int, token: String, tag: MetadataCellTag?) -> some View {
        Menu("Instrument") {
            Button("Instrument Name / Model") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .instrumentName))
            }
            Button("Instrument Serial / ID") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .instrumentID))
            }
        }

        Menu("Date & Time") {
            Button("Date & Time (ISO 8601: YYYY-MM-DD HH:mm:ss)") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateTime, format: "yyyy-MM-dd HH:mm:ss"))
            }
            Button("Date & Time (Slash: DD/MM/YYYY HH:mm:ss)") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateTime, format: "dd/MM/yyyy HH:mm:ss"))
            }
            Button("Date & Time (Slash: MM/DD/YYYY HH:mm:ss)") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateTime, format: "MM/dd/yyyy HH:mm:ss"))
            }
            Button("Date & Time (US: MM/DD/YYYY hh:mm:ss a)") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateTime, format: "MM/dd/yyyy hh:mm:ss a"))
            }
            Divider()
            Button("Date Only (YYYY-MM-DD or DD/MM/YYYY)") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .dateOnly))
            }
            Button("Time Only (HH:mm:ss)") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .timeOnly))
            }
        }

        Menu("Experimental Parameter") {
            Button("Scan Rate (v)") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .parameter, customKey: "scan_rate"))
            }
            Button("Temperature (T)") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .parameter, customKey: "temperature"))
            }
            Button("pH") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .parameter, customKey: "pH"))
            }
            Button("Custom Parameter Key…") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .parameter, customKey: token))
            }
        }

        Menu("Context") {
            Button("Operator") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .operatorName))
            }
            Button("Sample Name") {
                onTagMetadataCell?(MetadataCellTag(lineIndex: lineIdx, tokenIndex: tokenIdx, rawValue: token, entityType: .sampleName))
            }
            Button("Technique / Method") {
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

    // MARK: - Metadata Cell Parameter Popover View
    struct MetadataCellPopoverView: View {
        let target: CellTarget
        let existingTag: MetadataCellTag?
        let adjacentTokens: [String]
        let onSave: (MetadataCellTag) -> Void
        let onRemove: () -> Void
        let onDismiss: () -> Void

        @State private var selectedEntity: MetadataCellTag.EntityType = .parameter
        @State private var parameterKeyText: String = ""
        @State private var customFormatText: String = ""

        init(
            target: CellTarget,
            existingTag: MetadataCellTag?,
            adjacentTokens: [String],
            onSave: @escaping (MetadataCellTag) -> Void,
            onRemove: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.target = target
            self.existingTag = existingTag
            self.adjacentTokens = adjacentTokens
            self.onSave = onSave
            self.onRemove = onRemove
            self.onDismiss = onDismiss
            _selectedEntity = State(initialValue: existingTag?.entityType ?? .parameter)
            _parameterKeyText = State(initialValue: existingTag?.parameterKey ?? existingTag?.customKey ?? adjacentTokens.first ?? "")
            _customFormatText = State(initialValue: existingTag?.format ?? "")
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack(spacing: 5) {
                    Image(systemName: "tag.fill")
                        .foregroundStyle(Color.purple)
                    Text("Tag Metadata Cell")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("L\(target.lineIdx + 1), Col \(target.tokenIdx + 1)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Selected Value display
                VStack(alignment: .leading, spacing: 3) {
                    Text("Selected Value:")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(target.token.isEmpty ? "— (empty)" : target.token)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2), lineWidth: 0.8))
                }

                // Entity Type Picker
                VStack(alignment: .leading, spacing: 3) {
                    Text("Entity Type:")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $selectedEntity) {
                        ForEach(MetadataCellTag.EntityType.allCases, id: \.self) { entity in
                            Text(entity.rawValue).tag(entity)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                // Parameter Key with Suggestions
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parameter Key / Name:")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextField("e.g. Scan Rate, Temperature, Date", text: $parameterKeyText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                    if !adjacentTokens.isEmpty {
                        HStack(spacing: 4) {
                            Text("Suggested:")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                            ForEach(adjacentTokens.prefix(3), id: \.self) { sug in
                                Button(sug) {
                                    parameterKeyText = sug
                                }
                                .font(.system(size: 8.5, weight: .medium))
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }

                // Optional Format (for Date/Time)
                if selectedEntity == .dateTime || selectedEntity == .dateOnly || selectedEntity == .timeOnly {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Format (Optional):")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField("e.g. yyyy-MM-dd HH:mm:ss", text: $customFormatText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                }

                Divider()

                // Actions
                HStack(spacing: 8) {
                    if existingTag != nil {
                        Button("Clear Tag", role: .destructive) {
                            onRemove()
                            onDismiss()
                        }
                        .font(.system(size: 10.5))
                        .controlSize(.small)
                    }

                    Spacer()

                    Button("Cancel") {
                        onDismiss()
                    }
                    .font(.system(size: 10.5))
                    .controlSize(.small)

                    Button("Assign Tag") {
                        let tag = MetadataCellTag(
                            lineIndex: target.lineIdx,
                            tokenIndex: target.tokenIdx,
                            rawValue: target.token,
                            entityType: selectedEntity,
                            customKey: parameterKeyText.isEmpty ? nil : parameterKeyText,
                            format: customFormatText.isEmpty ? nil : customFormatText,
                            parameterKey: parameterKeyText.isEmpty ? nil : parameterKeyText
                        )
                        onSave(tag)
                        onDismiss()
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(width: 280)
        }
    }

    private func headerFill(col: ColumnDefinition, colColor: Color) -> Color {
        if col.isSkipped { return Color.primary.opacity(0.02) }
        if col.isXAxis { return Color.blue.opacity(0.12) }
        if col.isYAxis { return Color.green.opacity(0.12) }
        return colColor.opacity(0.12)
    }

    private func headerBorderColor(col: ColumnDefinition, colColor: Color) -> Color {
        if col.isSkipped { return Color.secondary.opacity(0.2) }
        if col.isXAxis { return Color.blue.opacity(0.5) }
        if col.isYAxis { return Color.green.opacity(0.5) }
        return colColor.opacity(0.5)
    }

    private func handleColumnClick(colIdx: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            let anchor = lastClickedColumn ?? colIdx
            let low = min(anchor, colIdx)
            let high = max(anchor, colIdx)
            selectedColumns.formUnion(low...high)
        } else if flags.contains(.command) {
            if selectedColumns.contains(colIdx) {
                selectedColumns.remove(colIdx)
            } else {
                selectedColumns.insert(colIdx)
            }
            lastClickedColumn = colIdx
        } else {
            if selectedColumns == [colIdx] {
                selectedColumns.removeAll()
                lastClickedColumn = nil
            } else {
                selectedColumns = [colIdx]
                lastClickedColumn = colIdx
            }
        }
    }

    private func skipSelectedColumns() {
        for cIdx in selectedColumns where cIdx < columns.count {
            var updated = columns[cIdx]
            updated.isSkipped = true
            onUpdateColumn?(cIdx, updated)
        }
    }

    private func includeSelectedColumns() {
        for cIdx in selectedColumns where cIdx < columns.count {
            var updated = columns[cIdx]
            updated.isSkipped = false
            onUpdateColumn?(cIdx, updated)
        }
    }

    private func setColumnRole(_ colIdx: Int, isX: Bool, isY: Bool) {
        guard colIdx < columns.count else { return }
        var updated = columns[colIdx]
        updated.isXAxis = isX
        updated.isYAxis = isY
        updated.isSkipped = false
        updated.role = isX ? .x : (isY ? .y : .channel)
        updated.progressionType = nil
        let xCols = columns.filter { ($0.isXAxis || $0.role == .x) && !$0.isSkipped }
        let yCols = columns.filter { ($0.isYAxis || $0.role == .y) && !$0.isSkipped }
        if isX && (xCols.isEmpty || (xCols.count == 1 && xCols.first?.name == updated.name)) {
            updated.isDefaultX = true
        } else if !isX {
            updated.isDefaultX = false
        }
        if isY && (yCols.isEmpty || (yCols.count == 1 && yCols.first?.name == updated.name)) {
            updated.isDefaultY = true
        } else if !isY {
            updated.isDefaultY = false
        }
        columns[colIdx] = updated
        onUpdateColumn?(colIdx, updated)
    }

    private func setDefaultX(colIdx: Int) {
        guard colIdx < columns.count else { return }
        for i in 0..<columns.count {
            var col = columns[i]
            if i == colIdx {
                col.isDefaultX = true
                col.isXAxis = true
                col.role = .x
                col.isSkipped = false
            } else {
                col.isDefaultX = false
            }
            columns[i] = col
            onUpdateColumn?(i, col)
        }
    }

    private func setDefaultY(colIdx: Int) {
        guard colIdx < columns.count else { return }
        for i in 0..<columns.count {
            var col = columns[i]
            if i == colIdx {
                col.isDefaultY = true
                col.isYAxis = true
                col.role = .y
                col.isSkipped = false
            } else {
                col.isDefaultY = false
            }
            columns[i] = col
            onUpdateColumn?(i, col)
        }
    }

    private func setSelectedColumnsRole(isX: Bool, isY: Bool) {
        for cIdx in selectedColumns where cIdx < columns.count {
            setColumnRole(cIdx, isX: isX, isY: isY)
        }
    }

    private func setColumnProgression(_ colIdx: Int, type: ProgressionType, behavior: ProgressionBehavior) {
        guard colIdx < columns.count else { return }
        var updated = columns[colIdx]
        updated.isXAxis = false
        updated.isYAxis = false
        updated.isDefaultX = false
        updated.isDefaultY = false
        updated.role = .progression
        updated.progressionType = type
        updated.progressionBehavior = behavior
        if type == .custom && (updated.customProgressionName == nil || updated.customProgressionName?.isEmpty == true) {
            updated.customProgressionName = updated.label.isEmpty ? updated.name : updated.label
        }
        updated.isSkipped = false
        columns[colIdx] = updated
        onUpdateColumn?(colIdx, updated)
    }

    private func setSelectedColumnsProgression(type: ProgressionType, behavior: ProgressionBehavior) {
        for cIdx in selectedColumns where cIdx < columns.count {
            setColumnProgression(cIdx, type: type, behavior: behavior)
        }
    }

    @ViewBuilder
    private func columnContextMenu(colIdx: Int, col: ColumnDefinition) -> some View {
        if selectedColumns.contains(colIdx) && selectedColumns.count > 1 {
            let count = selectedColumns.count
            Button("Set \(count) Selected as X") {
                setSelectedColumnsRole(isX: true, isY: false)
            }
            Button("Set \(count) Selected as Y") {
                setSelectedColumnsRole(isX: false, isY: true)
            }
            Menu("Set \(count) Selected as Progression…") {
                Menu("Time Progression") {
                    Button("Continuous (Time Range)") {
                        setSelectedColumnsProgression(type: .time, behavior: .continuous)
                    }
                    Button("Discrete (Time Steps)") {
                        setSelectedColumnsProgression(type: .time, behavior: .discrete)
                    }
                }
                Menu("Index / Cycle Progression") {
                    Button("Discrete (Multi-select Cycles)") {
                        setSelectedColumnsProgression(type: .index, behavior: .discrete)
                    }
                    Button("Continuous (Index Range)") {
                        setSelectedColumnsProgression(type: .index, behavior: .continuous)
                    }
                }
                Menu("Custom Progression…") {
                    Button("Discrete (Cycle / Stage)") {
                        setSelectedColumnsProgression(type: .custom, behavior: .discrete)
                    }
                    Button("Continuous (Range)") {
                        setSelectedColumnsProgression(type: .custom, behavior: .continuous)
                    }
                }
            }
            Button("Set \(count) Selected as Data (Aux)") {
                setSelectedColumnsRole(isX: false, isY: false)
            }
            Divider()
            Button("⊘ Skip \(count) Selected Columns", role: .destructive) {
                skipSelectedColumns()
            }
            Button("↩ Include \(count) Selected Columns") {
                includeSelectedColumns()
            }
            Divider()
            Button("Clear Column Selection") {
                selectedColumns.removeAll()
                lastClickedColumn = nil
            }
        } else {
            let xCount = columns.filter { ($0.isXAxis || $0.role == .x) && !$0.isSkipped }.count
            let yCount = columns.filter { ($0.isYAxis || $0.role == .y) && !$0.isSkipped }.count

            if col.isXAxis || col.role == .x {
                if xCount > 1 {
                    Button(isPrimaryX(col: col) ? "★ Default X (Active Plot)" : "★ Set as Default X (Live Plot)") {
                        setDefaultX(colIdx: colIdx)
                    }
                    Divider()
                }
            } else {
                Button("Set as X Axis") {
                    setColumnRole(colIdx, isX: true, isY: false)
                }
            }

            if col.isYAxis || col.role == .y {
                if yCount > 1 {
                    Button(isPrimaryY(col: col) ? "★ Default Y (Active Plot)" : "★ Set as Default Y (Live Plot)") {
                        setDefaultY(colIdx: colIdx)
                    }
                    Divider()
                }
            } else {
                Button("Set as Y Axis") {
                    setColumnRole(colIdx, isX: false, isY: true)
                }
            }

            Menu("Set as Progression…") {
                Menu("Time Progression") {
                    Button("Continuous (Time Range)") {
                        setColumnProgression(colIdx, type: .time, behavior: .continuous)
                    }
                    Button("Discrete (Time Steps)") {
                        setColumnProgression(colIdx, type: .time, behavior: .discrete)
                    }
                }
                Menu("Index / Cycle Progression") {
                    Button("Discrete (Multi-select Cycles)") {
                        setColumnProgression(colIdx, type: .index, behavior: .discrete)
                    }
                    Button("Continuous (Index Range)") {
                        setColumnProgression(colIdx, type: .index, behavior: .continuous)
                    }
                }
                Menu("Custom Progression…") {
                    Button("Discrete (Cycle / Stage)") {
                        setColumnProgression(colIdx, type: .custom, behavior: .discrete)
                    }
                    Button("Continuous (Range)") {
                        setColumnProgression(colIdx, type: .custom, behavior: .continuous)
                    }
                }
            }
            Button("Set as Data Channel (Aux)") {
                setColumnRole(colIdx, isX: false, isY: false)
            }
            Divider()
            if col.isSkipped {
                Button("↩ Include / Use Column") {
                    var updated = col
                    updated.isSkipped = false
                    columns[colIdx] = updated
                    onUpdateColumn?(colIdx, updated)
                }
            } else {
                Button("⊘ Skip / Ignore Column", role: .destructive) {
                    var updated = col
                    updated.isSkipped = true
                    columns[colIdx] = updated
                    onUpdateColumn?(colIdx, updated)
                }
            }
        }
    }

    // MARK: - Unit Autocomplete Field Component
    struct UnitAutocompleteField: View {
        let unit: String
        let isColSelected: Bool
        let isSkipped: Bool
        let onSelectUnit: (String) -> Void

        @State private var textInput: String = ""
        @State private var isShowingPopover: Bool = false

        private var filteredSuggestions: [(category: String, units: [String])] {
            let query = textInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if query.isEmpty {
                return ScientificTypography.unitCategories
            }
            return ScientificTypography.unitCategories.compactMap { cat in
                let matched = cat.units.filter { u in
                    u.lowercased().contains(query) ||
                    ScientificTypography.format(u).lowercased().contains(query)
                }
                return matched.isEmpty ? nil : (category: cat.category, units: matched)
            }
        }

        var body: some View {
            HStack(spacing: 2) {
                TextField("Unit", text: $textInput)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(minWidth: 26, maxWidth: 44)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isSkipped ? Color.secondary.opacity(0.6) : Color.primary)
                    .onAppear {
                        textInput = unit
                    }
                    .onChange(of: unit) { _, newUnit in
                        if textInput != newUnit {
                            textInput = newUnit
                        }
                    }
                    .onChange(of: textInput) { _, newValue in
                        let formatted = ScientificTypography.format(newValue)
                        if formatted != unit {
                            onSelectUnit(formatted)
                        }
                    }

                Button {
                    isShowingPopover.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            TextField("Filter unit…", text: $textInput)
                                .font(.system(size: 11, design: .monospaced))
                                .textFieldStyle(.plain)
                            if !textInput.isEmpty {
                                Button {
                                    textInput = ""
                                    onSelectUnit("")
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.controlBackgroundColor)))

                        Divider()

                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                if filteredSuggestions.isEmpty {
                                    Text("No matching units. Type your custom unit above.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 6)
                                } else {
                                    ForEach(filteredSuggestions, id: \.category) { section in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(section.category)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 2)

                                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 4)], spacing: 4) {
                                                ForEach(section.units, id: \.self) { u in
                                                    Button {
                                                        let target = u.isEmpty ? "" : u
                                                        textInput = target
                                                        onSelectUnit(target)
                                                        isShowingPopover = false
                                                    } label: {
                                                        Text(u.isEmpty ? "None" : u)
                                                            .font(.system(size: 10, weight: unit == u ? .bold : .medium, design: .monospaced))
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 3)
                                                            .frame(maxWidth: .infinity)
                                                            .background(
                                                                RoundedRectangle(cornerRadius: 3.5)
                                                                    .fill(unit == u ? Color.accentColor.opacity(0.18) : Color(NSColor.controlBackgroundColor))
                                                            )
                                                            .overlay(
                                                                RoundedRectangle(cornerRadius: 3.5)
                                                                    .stroke(unit == u ? Color.accentColor : Color.clear, lineWidth: 1)
                                                            )
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .frame(width: 250, height: 200)
                    }
                    .padding(8)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(Color(NSColor.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(isColSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.22), lineWidth: 0.8))
        }
    }

    @ViewBuilder
    private func unitComboBox(colIdx: Int, col: ColumnDefinition) -> some View {
        let isColSelected = selectedColumns.contains(colIdx)
        UnitAutocompleteField(
            unit: col.unit,
            isColSelected: isColSelected,
            isSkipped: col.isSkipped,
            onSelectUnit: { selectedUnit in
                var updated = col
                updated.unit = selectedUnit
                columns[colIdx] = updated
                onUpdateColumn?(colIdx, updated)
            }
        )
    }

    @ViewBuilder
    private func streamHeaderCell(colIdx: Int, token: String, colColor: Color) -> some View {
        let col = (colIdx < columns.count) ? columns[colIdx] : ColumnDefinition(name: token, label: token, unit: "")
        let isColSelected = selectedColumns.contains(colIdx)

        if headerRowMode == .raw {
            // State 1: Raw Header (Trạng thái chả có gì, raw file như nào thì hiện như thế)
            HStack(spacing: 3) {
                Text(token.isEmpty ? "—" : token)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: uniformColumnWidth(colIdx: colIdx), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isColSelected ? Color.accentColor.opacity(0.12) : colColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isColSelected ? Color.accentColor : colColor.opacity(0.2), lineWidth: isColSelected ? 1.2 : 0.6)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredColumn = colIdx }
                else if hoveredColumn == colIdx { hoveredColumn = nil }
            }
            .onTapGesture {
                handleColumnClick(colIdx: colIdx)
            }
            .contextMenu {
                columnContextMenu(colIdx: colIdx, col: col)
            }
        } else {
            // State 2: Configured Column Card (Tên raw giữ nguyên, Title + Unit trên cùng 1 hàng)
            VStack(alignment: .leading, spacing: 3) {
                // Row 1: # Index Badge & Role Pill Menu
                HStack(spacing: 4) {
                    Circle()
                        .fill(isColSelected ? Color.accentColor : colColor)
                        .frame(width: 5.5, height: 5.5)

                    Text("#\(colIdx + 1)")
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(isColSelected ? Color.accentColor : colColor)

                    Spacer(minLength: 2)

                    // Role Badge / Menu
                    Menu {
                        Button("Set as X Axis") {
                            var updated = col
                            updated.isXAxis = true
                            updated.isYAxis = false
                            updated.isSkipped = false
                            updated.role = .x
                            onUpdateColumn?(colIdx, updated)
                        }
                        Button("Set as Y Axis") {
                            var updated = col
                            updated.isXAxis = false
                            updated.isYAxis = true
                            updated.isSkipped = false
                            updated.role = .y
                            onUpdateColumn?(colIdx, updated)
                        }

                        Menu("Set as Progression…") {
                            Menu("Time Progression") {
                                Button("Continuous (Time Range)") {
                                    setColumnProgression(colIdx, type: .time, behavior: .continuous)
                                }
                                Button("Discrete (Time Steps)") {
                                    setColumnProgression(colIdx, type: .time, behavior: .discrete)
                                }
                            }

                            Menu("Index / Cycle Progression") {
                                Button("Discrete (Multi-select Cycles)") {
                                    setColumnProgression(colIdx, type: .index, behavior: .discrete)
                                }
                                Button("Continuous (Index Range)") {
                                    setColumnProgression(colIdx, type: .index, behavior: .continuous)
                                }
                            }

                            Menu("Custom Progression…") {
                                Button("Discrete (Cycle / Stage)") {
                                    setColumnProgression(colIdx, type: .custom, behavior: .discrete)
                                }
                                Button("Continuous (Range)") {
                                    setColumnProgression(colIdx, type: .custom, behavior: .continuous)
                                }
                            }
                        }

                        Button("Set as Data Channel (Aux)") {
                            var updated = col
                            updated.isXAxis = false
                            updated.isYAxis = false
                            updated.isSkipped = false
                            updated.role = .channel
                            updated.progressionType = nil
                            onUpdateColumn?(colIdx, updated)
                        }
                        Divider()
                        if col.isSkipped || col.role == .skip {
                            Button("↩ Include / Use Column") {
                                var updated = col
                                updated.isSkipped = false
                                updated.role = .channel
                                onUpdateColumn?(colIdx, updated)
                            }
                        } else {
                            Button("⊘ Skip / Ignore Column", role: .destructive) {
                                var updated = col
                                updated.isSkipped = true
                                updated.role = .skip
                                onUpdateColumn?(colIdx, updated)
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

            // Row 2: Original Raw Header Token (Immutable Ground Truth - Multi-line wrap so nothing is truncated)
                HStack(alignment: .top, spacing: 3) {
                    Text("Raw:")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                    Text(token.isEmpty ? "—" : token)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(col.isSkipped ? Color.secondary.opacity(0.45) : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                // Row 3: Title Name & Unit ON THE SAME ROW!
                HStack(spacing: 3) {
                    TextField("Title", text: Binding(
                        get: { col.label.isEmpty ? (col.name.isEmpty ? token : col.name) : col.label },
                        set: { newName in
                            var updated = col
                            let formatted = ScientificTypography.format(newName)
                            updated.label = formatted
                            if updated.name.isEmpty { updated.name = formatted }
                            columns[colIdx] = updated
                            onUpdateColumn?(colIdx, updated)
                        }
                    ))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .textFieldStyle(.plain)
                    .foregroundStyle(col.isSkipped ? Color.secondary.opacity(0.6) : Color.primary)
                    .frame(minWidth: 35, maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(NSColor.textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(isColSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.18), lineWidth: 0.8))

                    Text("/")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)

                    unitComboBox(colIdx: colIdx, col: col)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(width: uniformColumnWidth(colIdx: colIdx), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isColSelected ? Color.accentColor.opacity(0.16) : (col.isSkipped ? Color.primary.opacity(0.02) : headerFill(col: col, colColor: colColor)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isColSelected ? Color.accentColor : headerBorderColor(col: col, colColor: colColor), lineWidth: isColSelected ? 1.8 : 1.0)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredColumn = colIdx }
                else if hoveredColumn == colIdx { hoveredColumn = nil }
            }
            .onTapGesture {
                handleColumnClick(colIdx: colIdx)
            }
            .contextMenu {
                columnContextMenu(colIdx: colIdx, col: col)
            }
        }
    }

    // MARK: - Row View Component
    @ViewBuilder
    private func streamRow(lineNum: Int, rawLine: String) -> some View {
        let isHeader = (lineNum == effectiveHeaderLine)
        let isData = (lineNum >= effectiveDataStartLine)
        let isDataStart = (lineNum == effectiveDataStartLine)
        let isUserSkipped = skippedMetadataLines.contains(lineNum)
        let isMeta = (!isHeader && !isData && !rawLine.trimmingCharacters(in: .whitespaces).isEmpty && !isUserSkipped)
        let isSkipped = (!isHeader && !isData && (rawLine.trimmingCharacters(in: .whitespaces).isEmpty || isUserSkipped))
        let isSelected = selectedLines.contains(lineNum)

        let rawTokens = tokensForLine(rawLine: rawLine)
        let totalCols = streamColumnCount
        let lineIdx = lineNum - 1

        HStack(alignment: .center, spacing: 6) {
            // Selection indicator bar
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 18)

            // 1. Line Number Badge with Semantic Role
            if isHeader {
                Text("L\(lineNum) HDR")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.blue)
                    .frame(width: 68, alignment: .trailing)
            } else {
                Text(isMeta ? "L\(lineNum) META" : (isSkipped ? "L\(lineNum) SKIP" : "L\(lineNum)"))
                    .font(.system(size: 10, weight: isMeta ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isMeta ? Color.purple : (isSkipped ? Color.secondary.opacity(0.4) : Color.secondary))
                    .frame(width: 68, alignment: .trailing)
            }

            // 2. Token Cells - Strict Matrix Grid Alignment
            HStack(spacing: 6) {
                ForEach(0..<totalCols, id: \.self) { colIdx in
                    let token = (colIdx < rawTokens.count) ? rawTokens[colIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let colColor = ParserSettingsCanvasView.columnPalette[colIdx % ParserSettingsCanvasView.columnPalette.count]
                    let colWidth = uniformColumnWidth(colIdx: colIdx)

                    if isHeader {
                        // Zone 2: Header Token Cell (Raw Mode or Configured Card)
                        streamHeaderCell(colIdx: colIdx, token: token, colColor: colColor)
                    } else if isData {
                        // Zone 2: Data Matrix Token Cell (Dimmed if column is skipped, highlighted if column is selected)
                        let isColSelected = selectedColumns.contains(colIdx)
                        let isColSkipped = (colIdx < columns.count && columns[colIdx].isSkipped)
                        HStack(spacing: 3) {
                            Text(token.isEmpty ? "—" : token)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(isColSkipped ? Color.secondary.opacity(0.35) : (token.isEmpty ? Color.secondary.opacity(0.35) : Color.primary))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .frame(width: colWidth, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isColSelected ? Color.accentColor.opacity(isColSkipped ? 0.08 : 0.16) : (colColor.opacity(isColSkipped ? 0.015 : 0.08)))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isColSelected ? Color.accentColor.opacity(0.6) : (colColor.opacity(isColSkipped ? 0.06 : 0.25)), lineWidth: isColSelected ? 1.0 : 0.6)
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { hoveredColumn = colIdx }
                            else if hoveredColumn == colIdx { hoveredColumn = nil }
                        }
                        .onTapGesture {
                            handleColumnClick(colIdx: colIdx)
                        }
                    } else {
                        // Zone 1: Metadata Token Cell (Clean text, tag badge, right-click entity mapping, NO X/Y/Skip buttons)
                        let tag = metadataTagFor(lineIndex: lineIdx, tokenIndex: colIdx)
                        HStack(spacing: 4) {
                            Text(token.isEmpty ? "—" : token)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(isSkipped ? Color.secondary.opacity(0.4) : Color.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)

                            if let t = tag {
                                HStack(spacing: 2) {
                                    tagIcon(for: t.entityType)
                                        .font(.system(size: 7))
                                    Text(tagBadgeText(t))
                                        .font(.system(size: 8, weight: .bold))
                                    }
                                    .foregroundStyle(tagColor(for: t.entityType))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(tagColor(for: t.entityType).opacity(0.14)))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .frame(width: colWidth, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(tag != nil ? tagColor(for: tag!.entityType).opacity(0.08) : colColor.opacity(isSkipped ? 0.015 : 0.03))
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !token.isEmpty {
                                activeCellPopover = CellTarget(lineIdx: lineIdx, tokenIdx: colIdx, token: token)
                            }
                        }
                        .popover(isPresented: Binding(
                            get: { activeCellPopover?.lineIdx == lineIdx && activeCellPopover?.tokenIdx == colIdx },
                            set: { if !$0 { activeCellPopover = nil } }
                        ), arrowEdge: .bottom) {
                            if let target = activeCellPopover, target.lineIdx == lineIdx, target.tokenIdx == colIdx {
                                let adjacent = tokensForLine(rawLine: rawLine)
                                    .enumerated()
                                    .filter { $0.offset != colIdx && !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                    .map { $0.element.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces) }
                                MetadataCellPopoverView(
                                    target: target,
                                    existingTag: tag,
                                    adjacentTokens: adjacent,
                                    onSave: { newTag in
                                        onTagMetadataCell?(newTag)
                                    },
                                    onRemove: {
                                        onRemoveMetadataTag?(lineIdx, colIdx)
                                    },
                                    onDismiss: {
                                        activeCellPopover = nil
                                    }
                                )
                            }
                        }
                        .contextMenu {
                            if !token.isEmpty {
                                metadataCellContextMenu(lineIdx: lineIdx, tokenIdx: colIdx, token: token, tag: tag)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.14)
                : (isHeader
                    ? Color.blue.opacity(0.05)
                    : (isDataStart ? Color.green.opacity(0.04) : (lineNum % 2 == 0 ? Color.clear : Color.primary.opacity(0.015))))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleRowClick(lineNum: lineNum)
        }
        .contextMenu {
            streamRowContextMenu(lineNum: lineNum, isData: isData, isHeader: isHeader)
        }
    }

    @ViewBuilder
    private func streamRowContextMenu(lineNum: Int, isData: Bool, isHeader: Bool) -> some View {
        let targets = selectedLines.contains(lineNum) ? selectedLines : [lineNum]
        let count = targets.count

        if !isData && !isHeader {
            Button {
                for target in targets {
                    skippedMetadataLines.remove(target)
                }
            } label: {
                Label("Mark as Active Metadata (\(count) lines)", systemImage: "tag.fill")
            }

            Button {
                for target in targets {
                    skippedMetadataLines.insert(target)
                }
            } label: {
                Label("Skip / Ignore (\(count) lines)", systemImage: "slash.circle")
            }

            Divider()
        }

        Button {
            headerLineChoice = lineNum
            headerLineText = "\(lineNum)"
            if dataStartLineChoice <= lineNum {
                dataStartLineChoice = lineNum + 1
                dataStartLineText = "\(lineNum + 1)"
            }
        } label: {
            Label("Set Line \(lineNum) as Header", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            dataStartLineChoice = lineNum
            dataStartLineText = "\(lineNum)"
        } label: {
            Label("Set Line \(lineNum) as Data Start", systemImage: "tablecells")
        }
    }

    // MARK: - Metadata Popover Content
    private var metadataPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Metadata Selection", systemImage: "tag.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.purple)
                Spacer()
                Button("All") {
                    skippedMetadataLines.removeAll()
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)

                Button("None") {
                    skippedMetadataLines = Set(metadataEntries.map { $0.lineNum })
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
            }
            Text("Check items to include in profile metadata. Unchecked lines will be skipped.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Divider()

            if metadataEntries.isEmpty {
                Text("No metadata lines detected before data rows.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(metadataEntries) { item in
                            let isIncluded = !skippedMetadataLines.contains(item.lineNum)
                            Button {
                                if isIncluded {
                                    skippedMetadataLines.insert(item.lineNum)
                                } else {
                                    skippedMetadataLines.remove(item.lineNum)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(isIncluded ? Color.purple : Color.secondary)
                                    Text("L\(item.lineNum)")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .trailing)
                                    Text(item.key)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(isIncluded ? Color.primary : Color.secondary)
                                    if !item.value.isEmpty {
                                        Text(":")
                                            .foregroundStyle(.secondary)
                                        Text(item.value)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(isIncluded ? Color.primary : Color.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Collapsed Data Banner
    private var collapsedDataBanner: some View {
        let dataStart = effectiveDataStartLine
        let total = lines.count
        let collapsedCount = max(0, total - (dataStart + 15) - 10)

        return HStack(spacing: 12) {
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("\(collapsedCount) data rows collapsed (showing head & tail)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    isDataExpanded = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.down")
                        Text("Expand Preview")
                    }
                    .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}
