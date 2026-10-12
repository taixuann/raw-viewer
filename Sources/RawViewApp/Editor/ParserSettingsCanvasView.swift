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
    @Binding var activeGrammarID: String
    var availableGrammars: [FilenameGrammar] = []
    var onCreateNewGrammar: (() -> Void)? = nil
    var onSaveProfile: (() -> Void)? = nil
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

    // Stream Controls
    @State private var selectedLines: Set<Int> = [] // 1-based line numbers for Shift/Cmd selection
    @State private var lastClickedLine: Int? = nil // Selection anchor for Shift+Click range
    @State private var isDataExpanded: Bool = false // Toggle between head+tail inspection and full stream
    @State private var previewRowCount: Int = 25 // Number of data preview rows before folding

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
    static let columnPalette: [Color] = [
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

    private var metadataEntries: [MetadataSummaryEntry] {
        var entries: [MetadataSummaryEntry] = []
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
                entries.append(MetadataSummaryEntry(lineIndex: i, rawText: trimmed, key: k, value: v))
            } else if let eqIdx = clean.firstIndex(of: "=") {
                let k = String(clean[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                let v = String(clean[clean.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                entries.append(MetadataSummaryEntry(lineIndex: i, rawText: trimmed, key: k, value: v))
            } else {
                entries.append(MetadataSummaryEntry(lineIndex: i, rawText: trimmed, key: clean, value: ""))
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
            // MARK: - Top Toolbar Cards
            StreamToolbarCards(
                linesCount: lines.count,
                selectedDelimiter: $selectedDelimiter,
                customDelimiterText: $customDelimiterText,
                selectedDecimal: $selectedDecimal,
                headerLineChoice: $headerLineChoice,
                headerLineText: $headerLineText,
                dataStartLineChoice: $dataStartLineChoice,
                dataStartLineText: $dataStartLineText,
                activeGrammarID: $activeGrammarID,
                availableGrammars: availableGrammars,
                showMetadataPopover: $showMetadataPopover,
                activeMetadataCount: activeMetadataCount,
                metadataEntriesCount: metadataEntries.count,
                previewRowCount: $previewRowCount,
                isDataExpanded: $isDataExpanded,
                columns: $columns,
                headerRowMode: $headerRowMode,
                selectedColumns: $selectedColumns,
                lastClickedColumn: $lastClickedColumn,
                selectedLines: $selectedLines,
                skippedMetadataLines: $skippedMetadataLines,
                hoveredColumn: hoveredColumn,
                focusedToolbarRole: focusedToolbarRole,
                hoveredToolbarRole: $hoveredToolbarRole,
                uiFontSize: uiFontSize,
                metadataPopoverContent: AnyView(metadataPopoverContent),
                onIncludeAllColumns: includeAllColumns,
                onAutoSkipEmptyColumns: autoSkipEmptyColumns,
                onIncludeSelectedColumns: includeSelectedColumns,
                onSkipSelectedColumns: skipSelectedColumns,
                onSetSelectedColumnsRole: { isX, isY in setSelectedColumnsRole(isX: isX, isY: isY) },
                onSetSelectedColumnsProgression: { type, behavior in setSelectedColumnsProgression(type: type, behavior: behavior) },
                rolePillText: rolePillText,
                onApplyCustomStructure: {
                    applyLiveReparse()
                },
                onCreateNewGrammar: {
                    onCreateNewGrammar?()
                },
                onSaveProfile: {
                    onSaveProfile?()
                }
            )

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
                                        StreamRowView(
                                            lineNum: lineNum,
                                            rawLine: lines[lineIdx],
                                            effectiveHeaderLine: effectiveHeaderLine,
                                            effectiveDataStartLine: effectiveDataStartLine,
                                            effectiveDelimiter: effectiveDelimiter,
                                            streamColumnCount: streamColumnCount,
                                            uniformColumnWidth: uniformColumnWidth,
                                            headerRowMode: headerRowMode,
                                            columns: $columns,
                                            selectedColumns: $selectedColumns,
                                            lastClickedColumn: $lastClickedColumn,
                                            hoveredColumn: $hoveredColumn,
                                            selectedLines: $selectedLines,
                                            skippedMetadataLines: $skippedMetadataLines,
                                            activeCellPopover: $activeCellPopover,
                                            headerLineChoice: $headerLineChoice,
                                            headerLineText: $headerLineText,
                                            dataStartLineChoice: $dataStartLineChoice,
                                            dataStartLineText: $dataStartLineText,
                                            metadataCellTags: metadataCellTags,
                                            uiFontSize: uiFontSize,
                                            onUpdateColumn: onUpdateColumn,
                                            onSetColumnRole: { colIdx, isX, isY in setColumnRole(colIdx, isX: isX, isY: isY) },
                                            onSetColumnProgression: { colIdx, type, behavior in setColumnProgression(colIdx, type: type, behavior: behavior) },
                                            onSetDefaultX: setDefaultX,
                                            onSetDefaultY: setDefaultY,
                                            onSkipSelectedColumns: skipSelectedColumns,
                                            onIncludeSelectedColumns: includeSelectedColumns,
                                            onSetSelectedColumnsRole: { isX, isY in setSelectedColumnsRole(isX: isX, isY: isY) },
                                            onSetSelectedColumnsProgression: { type, behavior in setSelectedColumnsProgression(type: type, behavior: behavior) },
                                            rolePillText: rolePillText,
                                            onTagMetadataCell: onTagMetadataCell,
                                            onRemoveMetadataTag: onRemoveMetadataTag,
                                            onRowClick: handleRowClick
                                        )
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
        .onChange(of: selectedDelimiter) { _, _ in
            applyLiveReparse()
        }
        .onChange(of: customDelimiterText) { _, _ in
            if selectedDelimiter == "CUSTOM" {
                applyLiveReparse()
            }
        }
        .onChange(of: selectedDecimal) { _, _ in
            applyLiveReparse()
        }
        .onChange(of: headerLineChoice) { _, _ in
            applyLiveReparse()
        }
        .onChange(of: dataStartLineChoice) { _, _ in
            applyLiveReparse()
        }
        .onChange(of: skippedMetadataLines) { _, _ in
            applyLiveReparse()
        }
    }

    private func applyLiveReparse() {
        let finalDelim = selectedDelimiter == "CUSTOM" ? customDelimiterText : selectedDelimiter
        onApplyCustomStructure?(finalDelim, selectedDecimal, effectiveHeaderLine, effectiveDataStartLine, skippedMetadataLines)
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

    // MARK: - Metadata Popover Content
    private var metadataPopoverContent: some View {
        MetadataSummaryPopover(
            metadataEntries: metadataEntries,
            skippedMetadataLines: $skippedMetadataLines
        )
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
