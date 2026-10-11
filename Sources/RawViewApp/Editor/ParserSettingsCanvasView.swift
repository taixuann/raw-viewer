import SwiftUI
import RawViewCore

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
