import SwiftUI
import RawViewCore

// MARK: - StreamToolbarCards

/// Top control toolbar for Stream Parser Settings redesigned as a flat unified toolbar band:
/// - Section 1: Structure (Delimiter & Decimal Delimiters, Header L# & Data Starts steppers) with live auto-reparsing
/// - Section 2: Linked Grammar (Active Grammar selector with project & global grammars, Create New Grammar action)
/// - Section 3: View & Metadata (Header View segmented switch, Preview row count, Metadata Tags popover, Columns summary & auto-skip)
/// - Contextual Selection: Column & Row batch selection actions & hover inspector
/// - Section 4: Primary Action (Save Profile)
struct StreamToolbarCards: View {
    let linesCount: Int
    @Binding var selectedDelimiter: String
    @Binding var customDelimiterText: String
    @Binding var selectedDecimal: String
    @Binding var headerLineChoice: Int
    @Binding var headerLineText: String
    @Binding var dataStartLineChoice: Int
    @Binding var dataStartLineText: String
    @Binding var activeGrammarID: String
    let availableGrammars: [FilenameGrammar]
    let currentProfileName: String
    let savedProfiles: [URL]
    let onLoadProfile: (URL) -> Void
    let onDuplicateProfile: (String, String) -> Void
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
    let onApplyCustomStructure: () -> Void
    let onCreateNewGrammar: () -> Void
    let onSaveProfile: () -> Void

    @State private var showingNewProfilePopover = false
    @State private var newProfileID = ""
    @State private var newProfileName = ""

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // SECTION 1: Structure (Delimiter, Decimal, Header L#, Data Starts)
            section1Structure

            Divider()
                .frame(height: 22)

            // SECTION 2: Profile & Linked Grammar (2 rows)
            section3ProfileAndGrammar

            Divider()
                .frame(height: 22)

            // SECTION 3: View & Metadata Controls
            section2ViewAndMetadata

            Divider()
                .frame(height: 22)

            // Contextual Column & Row Selection Actions
            contextualSelectionSection

            Spacer(minLength: 8)

            Divider()
                .frame(height: 22)

            // SECTION 4: Actions (Save Profile)
            section4Actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Section 1: Structure (Delimiter, Decimal, Header L#, Data Starts)
    private var section1Structure: some View {
        HStack(spacing: 12) {
            // Column 1: Delimiter & Decimal
            VStack(alignment: .leading, spacing: 4) {
                // Row 1: Delimiter
                HStack(spacing: 4) {
                    Text("Delimiter:")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { selectedDelimiter },
                        set: { newVal in
                            selectedDelimiter = newVal
                            onApplyCustomStructure()
                        }
                    )) {
                        Text("Semicolon (;)").tag(";")
                        Text("Comma (,)").tag(",")
                        Text("Tab (\\t)").tag("\t")
                        Text("Space").tag(" ")
                        Text("Custom…").tag("CUSTOM")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)

                    if selectedDelimiter == "CUSTOM" {
                        TextField("|", text: Binding(
                            get: { customDelimiterText },
                            set: { newVal in
                                customDelimiterText = newVal
                                onApplyCustomStructure()
                            }
                        ))
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
                    Picker("", selection: Binding(
                        get: { selectedDecimal },
                        set: { newVal in
                            selectedDecimal = newVal
                            onApplyCustomStructure()
                        }
                    )) {
                        Text("Period (.)").tag(".")
                        Text("Comma (,)").tag(",")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
            }

            // Column 2: Header L# & Data Starts
            VStack(alignment: .leading, spacing: 4) {
                // Row 1: Header Line
                HStack(spacing: 4) {
                    Text("Header L#:")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
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
                            onApplyCustomStructure()
                        }
                    Stepper("", value: Binding(
                        get: { headerLineChoice },
                        set: { newVal in
                            headerLineChoice = max(0, newVal)
                            headerLineText = newVal <= 0 ? "" : "\(newVal)"
                            onApplyCustomStructure()
                        }
                    ), in: 0...max(linesCount, 1))
                    .labelsHidden()
                }

                // Row 2: Data Starts (84pt width so it NEVER wraps)
                HStack(spacing: 4) {
                    Text("Data Starts:")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    TextField("1", text: $dataStartLineText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 42)
                        .onChange(of: dataStartLineText) { _, newValue in
                            if let val = Int(newValue.trimmingCharacters(in: .whitespaces)) {
                                dataStartLineChoice = max(1, val)
                            }
                            onApplyCustomStructure()
                        }
                    Stepper("", value: Binding(
                        get: { dataStartLineChoice },
                        set: { newVal in
                            dataStartLineChoice = max(1, newVal)
                            dataStartLineText = "\(dataStartLineChoice)"
                            onApplyCustomStructure()
                        }
                    ), in: 1...max(linesCount, 1))
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - Section 2: View & Metadata Controls
    private var section2ViewAndMetadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: Header View segmented switch & Preview rows selector
            HStack(spacing: 8) {
                HStack(spacing: 4) {
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
                    .frame(width: 195)
                }

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
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 14, height: 14, alignment: .center)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
                    .help(isDataExpanded ? "Collapse to preview rows" : "Expand all rows")
                }
            }

            // Row 2: Metadata Tags Button & Columns Summary / Quick Actions
            HStack(spacing: 8) {
                Button {
                    showMetadataPopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill")
                            .foregroundStyle(Color.purple)
                        Text("Metadata Tags (\(activeMetadataCount)/\(metadataEntriesCount))")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .frame(height: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showMetadataPopover, arrowEdge: .bottom) {
                    metadataPopoverContent
                }

                HStack(spacing: 5) {
                    let activeCols = columns.filter { !$0.isSkipped }.count
                    Text("Cols: \(activeCols)/\(columns.count)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(activeCols < columns.count ? Color.orange : Color.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))

                    Button("Include All") {
                        onIncludeAllColumns()
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(height: 24)

                    Button("⊘ Auto-Skip Empty") {
                        onAutoSkipEmptyColumns()
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(height: 24)
                    .help("Automatically marks completely empty data columns as skipped")
                }
            }
        }
    }

    // MARK: - Section 3: Profile & Linked Grammar (2 Rows)
    private var section3ProfileAndGrammar: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: Profile Selector & New Button
            HStack(spacing: 5) {
                Text("Profile:")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)

                Menu {
                    if savedProfiles.isEmpty {
                        Text("No saved profiles")
                    } else {
                        ForEach(savedProfiles, id: \.self) { profileURL in
                            let profileBaseName = profileURL.deletingPathExtension().lastPathComponent
                            let isCurrent = (currentProfileName == profileBaseName)
                            Button {
                                onLoadProfile(profileURL)
                            } label: {
                                if isCurrent {
                                    Label(profileBaseName, systemImage: "checkmark")
                                } else {
                                    Text(profileBaseName)
                                }
                            }
                        }
                    }
                } label: {
                    Text(currentProfileName.isEmpty ? "Untitled" : currentProfileName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .frame(maxWidth: 160)
                .help("Switch active instrument profile")

                Button {
                    newProfileID = currentProfileName.isEmpty ? "new-profile" : "\(currentProfileName)-copy"
                    newProfileName = currentProfileName.isEmpty ? "New Profile" : "\(currentProfileName) (Copy)"
                    showingNewProfilePopover = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Create a new profile by duplicating current setup (non-destructive)")
                .popover(isPresented: $showingNewProfilePopover) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Duplicate Profile")
                            .font(.system(size: 12, weight: .bold))

                        Text("Creates a new profile preserving current column mappings, delimiter, and line tags.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Profile ID")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. autolab-pgstat", text: $newProfileID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Display Name")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. Autolab PGSTAT302N", text: $newProfileName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }

                        HStack {
                            Button("Cancel") {
                                showingNewProfilePopover = false
                            }
                            .controlSize(.small)

                            Spacer()

                            Button("Create Profile") {
                                let cleanID = newProfileID.trimmingCharacters(in: .whitespaces)
                                let cleanName = newProfileName.trimmingCharacters(in: .whitespaces)
                                if !cleanID.isEmpty {
                                    onDuplicateProfile(cleanID, cleanName)
                                    showingNewProfilePopover = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newProfileID.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(14)
                    .frame(width: 280)
                }
            }

            // Row 2: Grammar Selector
            HStack(spacing: 5) {
                Text("Grammar:")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)

                Menu {
                    let projectGrammars = availableGrammars.filter { $0.scope == .project }
                    let globalGrammars = availableGrammars.filter { $0.scope == .global || ($0.scope == nil && $0.isDefault) }
                    let otherGrammars = availableGrammars.filter { $0.scope != .project && !globalGrammars.contains($0) }

                    if !projectGrammars.isEmpty {
                        Section("Project Grammars") {
                            ForEach(projectGrammars) { g in
                                Button {
                                    activeGrammarID = g.id
                                } label: {
                                    if g.id == activeGrammarID {
                                        Label("📁 \(g.name) (Project)", systemImage: "checkmark")
                                    } else {
                                        Text("📁 \(g.name) (Project)")
                                    }
                                }
                            }
                        }
                    }

                    if !globalGrammars.isEmpty {
                        Section("Global Grammars") {
                            ForEach(globalGrammars) { g in
                                Button {
                                    activeGrammarID = g.id
                                } label: {
                                    if g.id == activeGrammarID {
                                        Label("🌐 \(g.name) (Global)", systemImage: "checkmark")
                                    } else {
                                        Text("🌐 \(g.name) (Global)")
                                    }
                                }
                            }
                        }
                    }

                    if !otherGrammars.isEmpty {
                        Section("Other Grammars") {
                            ForEach(otherGrammars) { g in
                                Button {
                                    activeGrammarID = g.id
                                } label: {
                                    if g.id == activeGrammarID {
                                        Label(g.name, systemImage: "checkmark")
                                    } else {
                                        Text(g.name)
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Button {
                        onCreateNewGrammar()
                    } label: {
                        Label("+ Create New Grammar…", systemImage: "plus")
                    }
                } label: {
                    let active = availableGrammars.first(where: { $0.id == activeGrammarID })
                    let icon = (active?.scope == .project) ? "📁" : "🌐"
                    let scopeLabel = (active?.scope == .project) ? " (Project)" : " (Global)"
                    let name = active?.name ?? "Standard Filename Pattern"
                    let displayText = "\(icon) \(name)\(active?.scope != nil ? scopeLabel : "")"

                    Text(displayText)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .frame(maxWidth: 220)
            }
        }
    }

    // MARK: - Contextual Column / Row Selection Actions Section
    private var contextualSelectionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !selectedColumns.isEmpty {
                let allSelectedSkipped = selectedColumns.allSatisfy { $0 < columns.count && columns[$0].isSkipped }

                HStack(spacing: 5) {
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
                        HStack(spacing: 3) {
                            Image(systemName: allSelectedSkipped ? "arrow.uturn.backward" : "nosign")
                                .font(.system(size: 8.5, weight: .bold))
                            Text(allSelectedSkipped
                                 ? (selectedColumns.count > 1 ? "Include (\(selectedColumns.count))" : "Include")
                                 : (selectedColumns.count > 1 ? "Skip (\(selectedColumns.count))" : "Skip"))
                                .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .frame(height: 22)
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
                        HStack(spacing: 3) {
                            Text("X")
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            Text(selectedColumns.count > 1 ? "Set X (\(selectedColumns.count))" : "Set X")
                                .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .frame(height: 22)
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
                        HStack(spacing: 3) {
                            Text("Y")
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            Text(selectedColumns.count > 1 ? "Set Y (\(selectedColumns.count))" : "Set Y")
                                .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .frame(height: 22)
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
                        HStack(spacing: 3) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 8))
                            Text(selectedColumns.count > 1 ? "Set Prog (\(selectedColumns.count))" : "Set Prog")
                                .font(StudioTokens.toolbarLabel(uiFontSize: uiFontSize))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 6.5))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .frame(height: 22)
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
                HStack(spacing: 5) {
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
                    Text("— Click header to select")
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
                    Text("Click columns to batch assign")
                        .font(.system(size: 9.5))
                }
                .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Section 4: Actions (Save Profile)
    private var section4Actions: some View {
        Button {
            onSaveProfile()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 10.5))
                Text("Save Profile")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .keyboardShortcut("s", modifiers: [.command])
        .help("Save instrument profile and parsing rules to project (⌘S)")
    }
}
