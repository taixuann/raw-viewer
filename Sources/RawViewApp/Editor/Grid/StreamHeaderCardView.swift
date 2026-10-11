import SwiftUI
import RawViewCore

// MARK: - UnitAutocompleteField Component

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

// MARK: - StreamHeaderCardView

/// Header cell component supporting two visual modes:
/// 1. Raw Stream mode (verbatim raw text cell)
/// 2. Configured Column Card mode (#index, role pill menu, immutable raw token label, editable Title / Unit autocomplete)
struct StreamHeaderCardView: View {
    let colIdx: Int
    let token: String
    let colColor: Color
    let columnWidth: CGFloat
    let headerRowMode: ParserSettingsCanvasView.HeaderRowMode
    @Binding var columns: [ColumnDefinition]
    @Binding var selectedColumns: Set<Int>
    @Binding var lastClickedColumn: Int?
    @Binding var hoveredColumn: Int?
    let uiFontSize: Double
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

    private var col: ColumnDefinition {
        (colIdx < columns.count) ? columns[colIdx] : ColumnDefinition(name: token, label: token, unit: "")
    }

    private var isColSelected: Bool {
        selectedColumns.contains(colIdx)
    }

    private func excelColumnLetter(_ index: Int) -> String {
        var n = index
        var result = ""
        while n >= 0 {
            let rem = n % 26
            result = String(UnicodeScalar(65 + rem)!) + result
            n = (n / 26) - 1
        }
        return result
    }

    var body: some View {
        if headerRowMode == .raw {
            rawHeaderModeView
        } else {
            configuredCardModeView
        }
    }

    // MARK: - State 1: Raw Header Mode
    private var rawHeaderModeView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(excelColumnLetter(colIdx))
                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                    .foregroundStyle(isColSelected ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(2)

                Text(token.isEmpty ? "—" : token)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: columnWidth, alignment: .leading)
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
            handleColumnClick()
        }
        .contextMenu {
            columnContextMenu
        }
    }

    // MARK: - State 2: Configured Column Card Mode
    private var configuredCardModeView: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Row 1: Excel Coordinate Badge & Index Badge & Role Pill Menu
            HStack(spacing: 4) {
                Circle()
                    .fill(isColSelected ? Color.accentColor : colColor)
                    .frame(width: 5.5, height: 5.5)

                Text(excelColumnLetter(colIdx))
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(isColSelected ? Color.accentColor : colColor)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background((isColSelected ? Color.accentColor : colColor).opacity(0.12))
                    .cornerRadius(2.5)

                Text("#\(colIdx + 1)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

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
                                onSetColumnProgression(colIdx, .time, .continuous)
                            }
                            Button("Discrete (Time Steps)") {
                                onSetColumnProgression(colIdx, .time, .discrete)
                            }
                        }

                        Menu("Index / Cycle Progression") {
                            Button("Discrete (Multi-select Cycles)") {
                                onSetColumnProgression(colIdx, .index, .discrete)
                            }
                            Button("Continuous (Index Range)") {
                                onSetColumnProgression(colIdx, .index, .continuous)
                            }
                        }

                        Menu("Custom Progression…") {
                            Button("Discrete (Cycle / Stage)") {
                                onSetColumnProgression(colIdx, .custom, .discrete)
                            }
                            Button("Continuous (Range)") {
                                onSetColumnProgression(colIdx, .custom, .continuous)
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
                        text: rolePillText(col),
                        roleColor: StudioTokens.roleColor(col: col),
                        hasDropdown: true,
                        uiFontSize: uiFontSize
                    )
                }
                .menuStyle(.borderlessButton)
            }

            // Row 2: Original Raw Header Token
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

            // Row 3: Title Name & Unit ON THE SAME ROW
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
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: columnWidth, alignment: .leading)
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
            handleColumnClick()
        }
        .contextMenu {
            columnContextMenu
        }
    }

    // MARK: - Helpers
    private func handleColumnClick() {
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

    @ViewBuilder
    private var columnContextMenu: some View {
        if selectedColumns.contains(colIdx) && selectedColumns.count > 1 {
            let count = selectedColumns.count
            Button("Set \(count) Selected as X") {
                onSetSelectedColumnsRole(true, false)
            }
            Button("Set \(count) Selected as Y") {
                onSetSelectedColumnsRole(false, true)
            }
            Menu("Set \(count) Selected as Progression…") {
                Menu("Time Progression") {
                    Button("Continuous (Time Range)") {
                        onSetSelectedColumnsProgression(.time, .continuous)
                    }
                    Button("Discrete (Time Steps)") {
                        onSetSelectedColumnsProgression(.time, .discrete)
                    }
                }
                Menu("Index / Cycle Progression") {
                    Button("Discrete (Multi-select Cycles)") {
                        onSetSelectedColumnsProgression(.index, .discrete)
                    }
                    Button("Continuous (Index Range)") {
                        onSetSelectedColumnsProgression(.index, .continuous)
                    }
                }
                Menu("Custom Progression…") {
                    Button("Discrete (Cycle / Stage)") {
                        onSetSelectedColumnsProgression(.custom, .discrete)
                    }
                    Button("Continuous (Range)") {
                        onSetSelectedColumnsProgression(.custom, .continuous)
                    }
                }
            }
            Button("Set \(count) Selected as Data (Aux)") {
                onSetSelectedColumnsRole(false, false)
            }
            Divider()
            Button("⊘ Skip \(count) Selected Columns", role: .destructive) {
                onSkipSelectedColumns()
            }
            Button("↩ Include \(count) Selected Columns") {
                onIncludeSelectedColumns()
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
                        onSetDefaultX(colIdx)
                    }
                    Divider()
                }
            } else {
                Button("Set as X Axis") {
                    onSetColumnRole(colIdx, true, false)
                }
            }

            if col.isYAxis || col.role == .y {
                if yCount > 1 {
                    Button(isPrimaryY(col: col) ? "★ Default Y (Active Plot)" : "★ Set as Default Y (Live Plot)") {
                        onSetDefaultY(colIdx)
                    }
                    Divider()
                }
            } else {
                Button("Set as Y Axis") {
                    onSetColumnRole(colIdx, false, true)
                }
            }

            Menu("Set as Progression…") {
                Menu("Time Progression") {
                    Button("Continuous (Time Range)") {
                        onSetColumnProgression(colIdx, .time, .continuous)
                    }
                    Button("Discrete (Time Steps)") {
                        onSetColumnProgression(colIdx, .time, .discrete)
                    }
                }
                Menu("Index / Cycle Progression") {
                    Button("Discrete (Multi-select Cycles)") {
                        onSetColumnProgression(colIdx, .index, .discrete)
                    }
                    Button("Continuous (Index Range)") {
                        onSetColumnProgression(colIdx, .index, .continuous)
                    }
                }
                Menu("Custom Progression…") {
                    Button("Discrete (Cycle / Stage)") {
                        onSetColumnProgression(colIdx, .custom, .discrete)
                    }
                    Button("Continuous (Range)") {
                        onSetColumnProgression(colIdx, .custom, .continuous)
                    }
                }
            }
            Button("Set as Data Channel (Aux)") {
                onSetColumnRole(colIdx, false, false)
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
}
