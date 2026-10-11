import SwiftUI
import RawViewCore

/// Panel 3 (Right Inspector): Tab selection (`SpecTab` & `StudioTab`), Instrument Identity,
/// Filename Token Rules mapper, Column Definitions & Roles list, and Save/Compile YAML actions.
struct EditorRightInspectorView: View {
    @ObservedObject var model: EditorWorkspaceViewModel
    @Binding var selectedSpecTab: EditorWorkspaceView.SpecTab

    init(
        model: EditorWorkspaceViewModel,
        selectedSpecTab: Binding<EditorWorkspaceView.SpecTab>
    ) {
        self.model = model
        self._selectedSpecTab = selectedSpecTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Inspector Header / Tab Switcher
            HStack {
                Picker("", selection: $selectedSpecTab) {
                    ForEach(EditorWorkspaceView.SpecTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedSpecTab {
                    case .identity:
                        instrumentIdentitySection
                        columnRolesSection

                    case .tokens:
                        filenameSemanticSection

                    case .library:
                        // Column definitions & quick properties summary
                        columnRolesSection
                    }
                }
                .padding(12)
            }

            Divider()

            // Sticky Bottom Actions
            sidebarActionFooter
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Section: Instrument Identity
    private var instrumentIdentitySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Instrument Identity", systemImage: "cpu")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Profile ID").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if !model.tokens.isEmpty {
                            Menu {
                                ForEach(model.tokens, id: \.self) { tok in
                                    Button(tok) {
                                        model.editor.instrumentID = tok
                                        if model.editor.instrumentName.isEmpty {
                                            model.editor.instrumentName = tok
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "wand.and.stars")
                                    Text("Pick from Token…")
                                }
                                .font(.system(size: 9.5))
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                    TextField("e.g. autolab-pgstat", text: $model.editor.instrumentID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Display Name").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("e.g. Autolab PGSTAT302N", text: $model.editor.instrumentName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                HStack {
                    Text("Delimiter:")
                        .font(.system(size: 11))
                    Spacer()
                    Picker("", selection: $model.editor.delimiter) {
                        Text("Comma (,)").tag(",")
                        Text("Tab (\\t)").tag("\t")
                        Text("Semicolon (;)").tag(";")
                        Text("Space").tag(" ")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Section: Column Definitions & Scientific Roles
    private var columnRolesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Column Definitions (\(model.editor.columns.count))", systemImage: "tablecells")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    let activeCount = model.editor.columns.filter { !$0.isSkipped }.count
                    Text("\(activeCount) active")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if model.editor.columns.isEmpty {
                    Text("No columns detected yet. Click 'Auto Detect' in canvas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(4)
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(model.editor.columns.enumerated()), id: \.offset) { idx, col in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("#\(idx + 1)")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22, alignment: .leading)

                                    TextField("Label", text: Binding(
                                        get: { col.label },
                                        set: { newLabel in
                                            var updated = col
                                            updated.label = newLabel
                                            model.updateColumn(index: idx, column: updated)
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10, weight: .medium))

                                    TextField("Unit", text: Binding(
                                        get: { col.unit },
                                        set: { newUnit in
                                            var updated = col
                                            updated.unit = newUnit
                                            model.updateColumn(index: idx, column: updated)
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(width: 50)

                                    // Role Toggle Menu
                                    Menu {
                                        Button("Set as X Axis (X)") {
                                            var updated = col
                                            updated.isXAxis = true
                                            updated.isYAxis = false
                                            updated.isSkipped = false
                                            model.updateColumn(index: idx, column: updated)
                                        }
                                        Button("Set as Y Axis (Y)") {
                                            var updated = col
                                            updated.isXAxis = false
                                            updated.isYAxis = true
                                            updated.isSkipped = false
                                            model.updateColumn(index: idx, column: updated)
                                        }
                                        Button("Set as Auxiliary (Aux)") {
                                            var updated = col
                                            updated.isXAxis = false
                                            updated.isYAxis = false
                                            updated.isSkipped = false
                                            model.updateColumn(index: idx, column: updated)
                                        }
                                        Divider()
                                        if col.isSkipped {
                                            Button("Include Column") {
                                                var updated = col
                                                updated.isSkipped = false
                                                model.updateColumn(index: idx, column: updated)
                                            }
                                        } else {
                                            Button("Skip Column", role: .destructive) {
                                                var updated = col
                                                updated.isSkipped = true
                                                model.updateColumn(index: idx, column: updated)
                                            }
                                        }
                                    } label: {
                                        Text(roleLabel(for: col))
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(roleColor(for: col))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(roleColor(for: col).opacity(0.15))
                                            )
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                            }
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private func roleLabel(for col: ColumnDefinition) -> String {
        if col.isSkipped { return "Skip" }
        if col.isXAxis { return "X" }
        if col.isYAxis { return "Y" }
        return "Aux"
    }

    private func roleColor(for col: ColumnDefinition) -> Color {
        if col.isSkipped { return .secondary }
        if col.isXAxis { return .blue }
        if col.isYAxis { return .green }
        return .orange
    }

    // MARK: - Section: Filename Semantic Elements
    private var filenameSemanticSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Filename Semantic Elements", systemImage: "text.word.spacing")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.tokens.count) tokens")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Detected Token Segments - Quick chips to define element or set identity
                if !model.tokens.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detected Segments (Click to define):")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(model.tokens, id: \.self) { tok in
                                    Menu {
                                        Button("Add as Element") {
                                            model.addElement(token: tok)
                                        }
                                        Button("Use as Profile ID") {
                                            model.editor.instrumentID = tok
                                        }
                                        Button("Use as Display Name") {
                                            model.editor.instrumentName = tok
                                        }
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.blue)
                                            Text(tok)
                                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.blue.opacity(0.3), lineWidth: 1))
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                            }
                        }
                    }
                }

                // Add / Clear Controls
                HStack {
                    Button {
                        model.addElement(token: "")
                    } label: {
                        Label("Add Element", systemImage: "plus")
                            .font(.system(size: 10))
                    }
                    .controlSize(.small)

                    Spacer()

                    if !model.semanticElements.isEmpty {
                        Button(role: .destructive) {
                            model.clearAllElements()
                        } label: {
                            Text("Clear All")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                // Dynamic Elements Cards List
                if model.semanticElements.isEmpty {
                    VStack(spacing: 4) {
                        Text("No elements defined yet.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Click a token segment above or 'Add Element' to define your custom rules.")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary.opacity(0.25)))
                } else {
                    VStack(spacing: 8) {
                        ForEach($model.semanticElements) { $el in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    TextField("Token", text: $el.token)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .frame(maxWidth: 105)

                                    TextField("Tag (e.g. Date)", text: $el.tagName)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 10))

                                    Picker("", selection: $el.role) {
                                        ForEach(SemanticTokenElement.standardRoles + ["Custom..."], id: \.self) { role in
                                            Text(role).tag(role)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .font(.system(size: 9.5))
                                    .controlSize(.mini)
                                    .frame(width: 90)

                                    Button {
                                        model.removeElement(id: el.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                if el.role == "Custom..." || (!SemanticTokenElement.standardRoles.contains(el.role) && el.role != "Remarks") {
                                    HStack(spacing: 6) {
                                        Text("Custom Role:").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                        TextField("e.g. Concentration, Cell, Operator", text: $el.role)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 9.5))
                                    }
                                    .padding(.leading, 4)
                                }

                                if el.role == "Date & Time" {
                                    HStack(spacing: 6) {
                                        Text("Format:").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                        TextField("DDMMYYYY-HHmmSS", text: $el.formatHint)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 9.5, design: .monospaced))
                                        Menu("Presets") {
                                            ForEach(SemanticTokenElement.standardDateFormats, id: \.self) { fmt in
                                                Button(fmt) { el.formatHint = fmt }
                                            }
                                        }
                                        .menuStyle(.borderlessButton)
                                        .font(.system(size: 9))
                                    }
                                    .padding(.leading, 6)
                                }
                            }
                            .padding(6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }

                if !model.siblingPreviews.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Live Sibling Match:")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.siblingPreviews) { sib in
                            HStack(spacing: 4) {
                                Text(sib.filename)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                if let cat = sib.category {
                                    Text(cat)
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.purple)
                                        .padding(.horizontal, 3).padding(.vertical, 1)
                                        .background(Color.purple.opacity(0.12)).cornerRadius(3)
                                }
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Sidebar Action Footer (Cohort & Build Actions)
    private var sidebarActionFooter: some View {
        VStack(spacing: 8) {
            Button {
                model.testAgainstCohort()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal")
                    Text("Test Against Cohort")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)

            if let status = model.cohortTestResult {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(model.cohortTestSuccess ? .green : .orange)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
            }

            Button {
                model.saveProfileAndRules()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 11))
                    Text("Build Profile")
                        .font(.system(size: 11, weight: .semibold))
                    ShortcutBadge("buildProfile")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(model.editor.instrumentID.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut("s", modifiers: [.command])
            .help("Builds and saves this instrument profile & category rules to .rawviewer/ (Cmd+S)")
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
