import SwiftUI
import RawViewCore

/// Panel 1 (Left Sidebar): Unified Profile Specification Sidebar
/// Reintegrates:
/// - Section A: Compact Source Card (Active target file & Saved Profiles dropdown menu)
/// - Section B: Profile Identity (Profile ID with token picker, Display Name)
/// - Section C: Filename Semantic Elements (Interactive visual chips, standard category role badges, format hints, live sibling match)
/// - Sticky Footer Actions: Test Against Cohort + Build Profile (Cmd+S)
struct EditorLeftSidebarView: View {
    @ObservedObject var model: EditorWorkspaceViewModel
    let sources: [RawSource]

    init(model: EditorWorkspaceViewModel, sources: [RawSource]) {
        self.model = model
        self.sources = sources
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sidebar Header
            HStack {
                Label("Profile Specification", systemImage: "slider.horizontal.2.square")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Button {
                    model.refreshSavedProfiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Refresh saved profiles")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // SECTION A: Compact File & Profile Sources
                    compactSourceCard

                    // SECTION B: Profile Identity
                    profileIdentitySection

                    // SECTION C: Filename Semantic Elements
                    filenameSemanticSection
                }
                .padding(12)
            }

            Divider()

            // Sticky Bottom Actions
            sidebarActionFooter
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Section A: Compact Source Card (Active File & Saved Profiles Menu)
    private var compactSourceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Target Sample & Profile", systemImage: "doc.text")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let sel = model.selectedSource {
                        Text("\(sel.url.pathExtension.uppercased()) • \(model.editor.lines.count) lines")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // Active Source Display
                if let current = model.selectedSource {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(current.url.lastPathComponent)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Text(current.relativePath)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(5)
                }

                // Action Bar: Switch Sample & Saved Profiles Menu
                HStack(spacing: 6) {
                    Menu {
                        ForEach(sources.prefix(40)) { src in
                            Button(src.url.lastPathComponent) {
                                model.selectSource(src)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Switch Sample…")
                        }
                        .font(.system(size: 10))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)

                    Spacer(minLength: 0)

                    // Pin Example Button
                    Button {
                        model.pinCurrentAsExample()
                    } label: {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Pin current file as the canonical reference example in .rawviewer/instrument/examples/")

                    // Saved Profiles Menu
                    Menu {
                        if model.savedProfiles.isEmpty {
                            Text("No saved profiles found").font(.caption)
                        } else {
                            ForEach(model.savedProfiles, id: \.self) { profileURL in
                                Button(profileURL.deletingPathExtension().lastPathComponent) {
                                    model.loadSavedProfile(url: profileURL)
                                }
                            }
                        }
                        Divider()
                        Button("Import YAML Profile…") {
                            model.importProfile()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                            Text("Saved (\(model.savedProfiles.count))")
                        }
                        .font(.system(size: 10))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Section B: Profile Identity
    private var profileIdentitySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Profile Identity", systemImage: "cpu")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Profile ID")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
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
                    Text("Display Name")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("e.g. Autolab PGSTAT302N", text: $model.editor.instrumentName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }
            .padding(4)
        }
    }

    // MARK: - Section C: Filename Semantic Elements
    private var filenameSemanticSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Filename Token Rules", systemImage: "text.word.spacing")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.tokens.count) tokens")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Interactive Token Chips Bar
                if !model.tokens.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Filename Segments (Click to map):")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(Array(model.tokens.enumerated()), id: \.offset) { idx, tok in
                                    let assigned = model.semanticElements.first(where: { $0.token == tok || $0.index == idx })
                                    Menu {
                                        Button("Add as Category Role") {
                                            model.addElement(token: tok, role: "Study", tagName: "Category")
                                        }
                                        Button("Add as Device / Legend") {
                                            model.addElement(token: tok, role: "Device ID", tagName: "Device")
                                        }
                                        Button("Add as Date / Time") {
                                            model.addElement(token: tok, role: "Date & Time", tagName: "Timestamp")
                                        }
                                        Button("Add as Metadata Field") {
                                            model.addElement(token: tok, role: "Remarks", tagName: "Remark")
                                        }
                                        Divider()
                                        Button("Use as Profile ID") {
                                            model.editor.instrumentID = tok
                                        }
                                        Button("Use as Display Name") {
                                            model.editor.instrumentName = tok
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(roleColor(assigned?.role ?? ""))
                                                .frame(width: 6, height: 6)
                                            Text(tok)
                                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        }
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3.5)
                                        .background(assigned != nil ? roleColor(assigned?.role ?? "").opacity(0.12) : Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(assigned != nil ? roleColor(assigned?.role ?? "").opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1))
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

                // Semantic Elements Cards
                if model.semanticElements.isEmpty {
                    VStack(spacing: 4) {
                        Text("No category elements mapped.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Click any filename segment above to assign its scientific category role.")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary.opacity(0.25)))
                } else {
                    VStack(spacing: 7) {
                        ForEach($model.semanticElements) { $el in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    // Token Text
                                    TextField("Token", text: $el.token)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .frame(maxWidth: 95)

                                    // User Tag Name
                                    TextField("Label", text: $el.tagName)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 10))

                                    // Role Picker
                                    Picker("", selection: $el.role) {
                                        ForEach(SemanticTokenElement.standardRoles + ["Custom..."], id: \.self) { role in
                                            Text(role).tag(role)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .font(.system(size: 9.5))
                                    .controlSize(.mini)
                                    .frame(width: 95)

                                    Button {
                                        model.removeElement(id: el.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                if el.role == "Date & Time" {
                                    HStack(spacing: 5) {
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
                                    .padding(.leading, 4)
                                }
                            }
                            .padding(6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(5)
                        }
                    }
                }

                // Live Sibling Matching Preview
                if !model.siblingPreviews.isEmpty {
                    Divider().padding(.vertical, 2)
                    HStack {
                        Text("Live Sibling Match:")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.siblingPreviews) { sib in
                            HStack(spacing: 4) {
                                Text(sib.filename)
                                    .font(.system(size: 9, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                if let cat = sib.category {
                                    Text(cat)
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.purple)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
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

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "Study", "Mode", "category": return .purple
        case "Device ID", "Library", "legend": return .blue
        case "Date & Time": return .green
        case "Remarks", "metadata": return .orange
        default: return .secondary
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
