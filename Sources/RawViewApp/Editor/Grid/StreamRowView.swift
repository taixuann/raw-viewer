import SwiftUI
import RawViewCore

// MARK: - StreamRowView

/// Renders an individual row in the tokenized raw data canvas:
/// - Selection indicator bar
/// - Line number badge with semantic role (`L# HDR`, `L# META`, `L# SKIP`, `L#`)
/// - Token cells with strict matrix grid alignment matching `uniformColumnWidth`:
///   - Header cell (delegates to `StreamHeaderCardView`)
///   - Data Matrix cells (dimmed if skipped, highlighted on column selection)
///   - Zone 1 Metadata cells (pill badge, popover trigger, context menu)
/// - Row context menu (`Mark as Active Metadata`, `Skip / Ignore`, `Set Line as Header`, `Set Line as Data Start`)
struct StreamRowView: View {
    let lineNum: Int
    let rawLine: String
    let effectiveHeaderLine: Int?
    let effectiveDataStartLine: Int
    let effectiveDelimiter: String
    let streamColumnCount: Int
    let uniformColumnWidth: (Int) -> CGFloat
    let headerRowMode: ParserSettingsCanvasView.HeaderRowMode

    @Binding var columns: [ColumnDefinition]
    @Binding var selectedColumns: Set<Int>
    @Binding var lastClickedColumn: Int?
    @Binding var hoveredColumn: Int?
    @Binding var selectedLines: Set<Int>
    @Binding var skippedMetadataLines: Set<Int>
    @Binding var activeCellPopover: ParserSettingsCanvasView.CellTarget?
    @Binding var headerLineChoice: Int
    @Binding var headerLineText: String
    @Binding var dataStartLineChoice: Int
    @Binding var dataStartLineText: String

    let metadataCellTags: [String: MetadataCellTag]
    let uiFontSize: Double

    // Callbacks
    let onUpdateColumn: ((Int, ColumnDefinition) -> Void)?
    let onSetColumnRole: (_ colIdx: Int, _ isX: Bool, _ isY: Bool) -> Void
    let onSetColumnProgression: (_ colIdx: Int, _ type: ProgressionType, _ behavior: ProgressionBehavior) -> Void
    let onSetDefaultX: (Int) -> Void
    let onSetDefaultY: (Int) -> Void
    let onSkipSelectedColumns: () -> Void
    let onIncludeSelectedColumns: () -> Void
    let onSetSelectedColumnsRole: (_ isX: Bool, _ isY: Bool) -> Void
    let onSetSelectedColumnsProgression: (_ type: ProgressionType, _ behavior: ProgressionBehavior) -> Void
    let rolePillText: (ColumnDefinition) -> String
    let onTagMetadataCell: ((MetadataCellTag) -> Void)?
    let onRemoveMetadataTag: ((Int, Int) -> Void)?
    let onRowClick: (Int) -> Void

    private var isHeader: Bool { lineNum == effectiveHeaderLine }
    private var isData: Bool { lineNum >= effectiveDataStartLine }
    private var isDataStart: Bool { lineNum == effectiveDataStartLine }
    private var isUserSkipped: Bool { skippedMetadataLines.contains(lineNum) }
    private var isMeta: Bool { !isHeader && !isData && !rawLine.trimmingCharacters(in: .whitespaces).isEmpty && !isUserSkipped }
    private var isSkipped: Bool { !isHeader && !isData && (rawLine.trimmingCharacters(in: .whitespaces).isEmpty || isUserSkipped) }
    private var isSelected: Bool { selectedLines.contains(lineNum) }

    private var rawTokens: [String] {
        rawLine.components(separatedBy: effectiveDelimiter)
    }

    private var lineIdx: Int { lineNum - 1 }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // Selection indicator bar
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 18)

            // 1. Line Number Badge with Semantic Role
            lineNumberBadge

            // 2. Token Cells - Strict Matrix Grid Alignment
            HStack(spacing: 6) {
                ForEach(0..<streamColumnCount, id: \.self) { colIdx in
                    let token = (colIdx < rawTokens.count) ? rawTokens[colIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let colColor = ParserSettingsCanvasView.columnPalette[colIdx % ParserSettingsCanvasView.columnPalette.count]
                    let colWidth = uniformColumnWidth(colIdx)

                    if isHeader {
                        // Zone 2: Header Token Cell (Raw Mode or Configured Card)
                        StreamHeaderCardView(
                            colIdx: colIdx,
                            token: token,
                            colColor: colColor,
                            columnWidth: colWidth,
                            headerRowMode: headerRowMode,
                            columns: $columns,
                            selectedColumns: $selectedColumns,
                            lastClickedColumn: $lastClickedColumn,
                            hoveredColumn: $hoveredColumn,
                            uiFontSize: uiFontSize,
                            onUpdateColumn: onUpdateColumn,
                            onSetColumnRole: onSetColumnRole,
                            onSetColumnProgression: onSetColumnProgression,
                            onSetDefaultX: onSetDefaultX,
                            onSetDefaultY: onSetDefaultY,
                            onSkipSelectedColumns: onSkipSelectedColumns,
                            onIncludeSelectedColumns: onIncludeSelectedColumns,
                            onSetSelectedColumnsRole: onSetSelectedColumnsRole,
                            onSetSelectedColumnsProgression: onSetSelectedColumnsProgression,
                            rolePillText: rolePillText
                        )
                    } else if isData {
                        // Zone 2: Data Matrix Token Cell (Dimmed if column is skipped, highlighted if column is selected)
                        dataMatrixCell(colIdx: colIdx, token: token, colColor: colColor, colWidth: colWidth)
                    } else {
                        // Zone 1: Metadata Token Cell
                        metadataCell(colIdx: colIdx, token: token, colColor: colColor, colWidth: colWidth)
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
            onRowClick(lineNum)
        }
        .contextMenu {
            rowContextMenu
        }
    }

    // MARK: - Line Number Badge
    private var lineNumberBadge: some View {
        Group {
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
        }
    }

    // MARK: - Data Matrix Cell
    private func dataMatrixCell(colIdx: Int, token: String, colColor: Color, colWidth: CGFloat) -> some View {
        let isColSelected = selectedColumns.contains(colIdx)
        let isColSkipped = (colIdx < columns.count && columns[colIdx].isSkipped)

        return HStack(spacing: 3) {
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
    }

    // MARK: - Zone 1: Metadata Cell
    private func metadataCell(colIdx: Int, token: String, colColor: Color, colWidth: CGFloat) -> some View {
        let tag = metadataCellTags["\(lineIdx):\(colIdx)"]

        return HStack(spacing: 4) {
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
                activeCellPopover = ParserSettingsCanvasView.CellTarget(lineIdx: lineIdx, tokenIdx: colIdx, token: token)
            }
        }
        .popover(isPresented: Binding(
            get: { activeCellPopover?.lineIdx == lineIdx && activeCellPopover?.tokenIdx == colIdx },
            set: { if !$0 { activeCellPopover = nil } }
        ), arrowEdge: .bottom) {
            if let target = activeCellPopover, target.lineIdx == lineIdx, target.tokenIdx == colIdx {
                let adjacent = rawLine.components(separatedBy: effectiveDelimiter)
                    .enumerated()
                    .filter { $0.offset != colIdx && !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { $0.element.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces) }
                ParserSettingsCanvasView.MetadataCellPopoverView(
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

    // MARK: - Row Context Menu
    private var rowContextMenu: some View {
        let targets = selectedLines.contains(lineNum) ? selectedLines : [lineNum]
        let count = targets.count

        return Group {
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
    }

    // MARK: - Column Click Handling
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

    // MARK: - Metadata Tag Helpers
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
}
