import SwiftUI
import RawViewCore

// MARK: - StreamToolbarCards

/// Top control toolbar for Stream Parser Settings composed of 4 macOS Studio Cards:
/// - Card 1: Delimiter & Decimal Delimiters block
/// - Card 2: Row bounds (Header L# & Data Start L# stepper)
/// - Card 3: Metadata & Columns Status, Preview rows selector, Expand All, Column summary & auto-skip
/// - Card 4: Run auto-detect and Apply buttons
/// Plus contextual batch selection / column actions card.
struct StreamToolbarCards: View {
    let linesCount: Int
    @Binding var selectedDelimiter: String
    @Binding var customDelimiterText: String
    @Binding var selectedDecimal: String
    @Binding var headerLineChoice: Int
    @Binding var headerLineText: String
    @Binding var dataStartLineChoice: Int
    @Binding var dataStartLineText: String
    @Binding var showMetadataPopover: Bool
    let activeMetadataCount: Int
    let metadataEntriesCount: Int
    @Binding var previewRowCount: Int
    @Binding var isDataExpanded: Bool
    @Binding var columns: [ColumnDefinition]
    @Binding var headerRowMode: ParserSettingsCanvasView.HeaderRowMode
    @Binding var selectedColumns: Set<Int>
    @Binding var lastClickedColumn: Int?
    @Binding var selectedLines: Set<Int>
    @Binding var skippedMetadataLines: Set<Int>
    let hoveredColumn: Int?
    let focusedToolbarRole: ColumnRole?
    @Binding var hoveredToolbarRole: ColumnRole?
    let uiFontSize: Double

    // Callbacks
    let metadataPopoverContent: AnyView
    let onIncludeAllColumns: () -> Void
    let onAutoSkipEmptyColumns: () -> Void
    let onIncludeSelectedColumns: () -> Void
    let onSkipSelectedColumns: () -> Void
    let onSetSelectedColumnsRole: (_ isX: Bool, _ isY: Bool) -> Void
    let onSetSelectedColumnsProgression: (_ type: ProgressionType, _ behavior: ProgressionBehavior) -> Void
    let rolePillText: (ColumnDefinition) -> String
    let onRunAutoDetect: () -> Void
    let onApplyCustomStructure: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // CARD 1: Delimiter & Decimal Delimiters Block
            card1DelimiterAndDecimal

            // CARD 2: Row Bounds (Header L# & Data Start L#)
            card2RowBounds

            // CARD 3: Metadata & Columns Status & Preview Controls
            card3MetadataAndColumnsStatus

            // Contextual Column & Row Selection Actions Card
            contextualSelectionCard

            Spacer()

            // CARD 4: Run Actions (Auto-detect & Apply)
            card4RunActions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Card 1: Delimiter & Decimal Delimiters Block
    private var card1DelimiterAndDecimal: some View {
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

            // Row 2: Decimal
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
    }

    // MARK: - Card 2: Row Bounds
    private var card2RowBounds: some View {
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
                ), in: 0...max(linesCount, 1))
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
                ), in: 1...max(linesCount, 1))
                .labelsHidden()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(NSColor.windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.8))
    }

    // MARK: - Card 3: Metadata & Columns Status & Preview Controls
    private var card3MetadataAndColumnsStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1: Metadata Items Popover Button & Preview Row Control
            HStack(spacing: 6) {
                Button {
                    showMetadataPopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill")
                            .foregroundStyle(Color.purple)
                        Text("Metadata Tags (\(activeMetadataCount)/\(metadataEntriesCount))")
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
                    onIncludeAllColumns()
                }
                .font(.system(size: 9.5))
                .buttonStyle(.borderless)
                .controlSize(.mini)

                Button("⊘ Auto-Skip Empty") {
                    onAutoSkipEmptyColumns()
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
    }

    // MARK: - Contextual Column / Row Selection Actions Card
    private var contextualSelectionCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1: Header Mode Segmented Switch (Raw Header vs Column Cards)
            HStack(spacing: 6) {
                Text("Header View:")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)

                Picker("", selection: $headerRowMode) {
                    Label("Raw Stream", systemImage: "doc.text")
                        .tag(ParserSettingsCanvasView.HeaderRowMode.raw)
                    Label("Column Cards", systemImage: "rectangle.split.3x1.fill")
                        .tag(ParserSettingsCanvasView.HeaderRowMode.configured)
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
                            onIncludeSelectedColumns()
                        } else {
                            onSkipSelectedColumns()
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
                        onSetSelectedColumnsRole(true, false)
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
                        onSetSelectedColumnsRole(false, true)
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
                            Button("Discrete (Custom Cycles)") {
                                onSetSelectedColumnsProgression(.custom, .discrete)
                            }
                            Button("Continuous (Custom Slices)") {
                                onSetSelectedColumnsProgression(.custom, .continuous)
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
                        text: rolePillText(col),
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
    }

    // MARK: - Card 4: Run Actions
    private var card4RunActions: some View {
        VStack(alignment: .trailing, spacing: 5) {
            // Row 1: Re-run Auto Detect Button
            Button {
                onRunAutoDetect()
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
                onApplyCustomStructure()
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
}
