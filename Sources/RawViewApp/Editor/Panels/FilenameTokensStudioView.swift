import SwiftUI
import RawViewCore

/// Dedicated Workspace Tab: Filename Tokens Studio
/// Provides an unbiased, flexible workspace for inspecting filename tokenization across cohort samples:
/// - Delimiter configurator (supports freeform delimiters: _, -, ., whitespace, custom symbols)
/// - Visual interactive token segment chips with role assignment
/// - Cohort Filename Matrix: parses 10+ samples in project into aligned token columns (Excel-style)
/// - Live category & device extraction preview
struct FilenameTokensStudioView: View {
    @ObservedObject var model: EditorWorkspaceViewModel

    @State private var customDelimiterText: String = ""
    @State private var selectedSampleBasename: String = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbarBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // SECTION 1: Token Delimiters & Active Sample Chips
                    tokenConfigurationCard

                    // SECTION 2: Cohort Token Matrix Table (Excel-like token breakdown across files)
                    cohortTokensMatrixCard

                    // SECTION 3: Mapped Semantic Category Rules
                    mappedRulesCard
                }
                .padding(16)
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
    }

    // MARK: - Toolbar Bar
    private var toolbarBar: some View {
        HStack(spacing: 12) {
            Label("Filename Tokens & Category Rules", systemImage: "text.word.spacing")
                .font(.system(size: 13, weight: .bold))

            Spacer()

            if let target = model.selectedSource {
                Text("Sample: \(target.url.lastPathComponent)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Section 1: Token Configuration & Segment Chips
    private var tokenConfigurationCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Token Segmentation Rules", systemImage: "scissors")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("\(model.tokens.count) tokens detected in sample")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Delimiter selector
                HStack(spacing: 10) {
                    Text("Token Delimiters:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        delimiterToggleChip("_", label: "Underscore (_)")
                        delimiterToggleChip("-", label: "Hyphen (-)")
                        delimiterToggleChip(".", label: "Dot (.)")
                        delimiterToggleChip(" ", label: "Space")
                    }

                    // Custom freeform delimiter input
                    HStack(spacing: 4) {
                        TextField("Custom…", text: $customDelimiterText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 65)
                            .onSubmit {
                                addCustomDelimiter()
                            }
                        if !customDelimiterText.isEmpty {
                            Button("Add") {
                                addCustomDelimiter()
                            }
                            .font(.system(size: 9.5, weight: .bold))
                            .controlSize(.mini)
                        }
                    }

                    Spacer()
                }

                Divider()

                // Interactive Token Chips
                VStack(alignment: .leading, spacing: 6) {
                    Text("Active Sample Segments (Click to map scientific role):")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    if model.tokens.isEmpty {
                        Text("No tokens detected with current delimiters.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(model.tokens.enumerated()), id: \.offset) { idx, tok in
                                    let assigned = model.semanticElements.first(where: { $0.token == tok || $0.index == idx })
                                    Menu {
                                        Button("Map as Category / Study") {
                                            model.addElement(token: tok, role: "Study", tagName: "Category")
                                        }
                                        Button("Map as Device / Legend") {
                                            model.addElement(token: tok, role: "Device ID", tagName: "Device")
                                        }
                                        Button("Map as Date & Time") {
                                            model.addElement(token: tok, role: "Date & Time", tagName: "Timestamp")
                                        }
                                        Button("Map as Measurement Mode") {
                                            model.addElement(token: tok, role: "Mode", tagName: "Mode")
                                        }
                                        Button("Map as Metadata Field") {
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
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 4) {
                                                Text("Col \(idx + 1)")
                                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                if let assigned = assigned {
                                                    Circle()
                                                        .fill(roleColor(assigned.role))
                                                        .frame(width: 6, height: 6)
                                                }
                                            }
                                            Text(tok)
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            if let assigned = assigned {
                                                Text(assigned.role)
                                                    .font(.system(size: 8.5, weight: .bold))
                                                    .foregroundStyle(roleColor(assigned.role))
                                            }
                                        }
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                        .background(assigned != nil ? roleColor(assigned!.role).opacity(0.12) : Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(6)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(assigned != nil ? roleColor(assigned!.role).opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1))
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Section 2: Cohort Token Matrix Card
    private var cohortTokensMatrixCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Cohort Token Matrix (Project Samples)", systemImage: "tablecells")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("Live token alignment across project files")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                let cohortSamples = Array(model.sources.prefix(12))
                if cohortSamples.isEmpty {
                    Text("No files in project to preview.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        // Header
                        HStack(spacing: 8) {
                            Text("Filename")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 220, alignment: .leading)
                            Text("Category")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 140, alignment: .leading)
                            Text("Device ID")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 140, alignment: .leading)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(4)

                        // Rows
                        ForEach(cohortSamples) { src in
                            let catIndex = model.semanticElements.first(where: { $0.role == "category" || $0.role == "Study" })?.index
                            let devIndex = model.semanticElements.first(where: { $0.role == "legend" || $0.role == "Device ID" })?.index
                            let rule = CategoryRule(
                                delimiters: model.editor.tokenDelimiters,
                                categoryIndex: catIndex,
                                deviceIndex: devIndex,
                                elements: model.semanticElements
                            )
                            let facts = CategoryRuleEngine.extract(from: src.url.lastPathComponent, rules: rule)

                            HStack(spacing: 8) {
                                Text(src.url.lastPathComponent)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .lineLimit(1)
                                    .frame(width: 220, alignment: .leading)

                                Text(facts.category ?? "—")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.purple)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.1))
                                    .cornerRadius(3)
                                    .frame(width: 140, alignment: .leading)

                                Text(facts.deviceID ?? "—")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.blue)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(3)
                                    .frame(width: 140, alignment: .leading)

                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(src.url == model.selectedSource?.url ? Color.accentColor.opacity(0.08) : Color.clear)
                            .cornerRadius(4)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Section 3: Mapped Rules Card
    private var mappedRulesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Configured Token Elements", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Button {
                        model.addElement(token: "")
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                            Text("Add Custom Element")
                        }
                        .font(.system(size: 10.5))
                    }
                    .controlSize(.small)
                }

                if model.semanticElements.isEmpty {
                    Text("No elements mapped yet. Click any segment above to define category or device rules.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(6)
                } else {
                    VStack(spacing: 6) {
                        ForEach($model.semanticElements) { $el in
                            HStack(spacing: 8) {
                                TextField("Token", text: $el.token)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .frame(width: 140)

                                TextField("Tag Label", text: $el.tagName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10.5))
                                    .frame(width: 130)

                                Picker("", selection: $el.role) {
                                    ForEach(SemanticTokenElement.standardRoles + ["Custom..."], id: \.self) { role in
                                        Text(role).tag(role)
                                    }
                                }
                                .pickerStyle(.menu)
                                .font(.system(size: 10))
                                .frame(width: 130)

                                if el.role == "Date & Time" {
                                    TextField("Format", text: $el.formatHint)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 10, design: .monospaced))
                                        .frame(width: 140)
                                }

                                Spacer()

                                Button {
                                    model.removeElement(id: el.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(5)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func delimiterToggleChip(_ delim: String, label: String) -> some View {
        let isSelected = model.editor.tokenDelimiters.contains(delim)
        Button {
            if isSelected {
                if model.editor.tokenDelimiters.count > 1 {
                    model.editor.tokenDelimiters.removeAll(where: { $0 == delim })
                }
            } else {
                model.editor.tokenDelimiters.append(delim)
            }
            if let src = model.selectedSource {
                model.selectSource(src, preserveProfile: true)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 10, weight: isSelected ? .bold : .regular))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(isSelected ? Color.blue.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            .foregroundStyle(isSelected ? Color.blue : Color.primary)
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? Color.blue : Color.secondary.opacity(0.2), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private func addCustomDelimiter() {
        let trimmed = customDelimiterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !model.editor.tokenDelimiters.contains(trimmed) {
            model.editor.tokenDelimiters.append(trimmed)
            if let src = model.selectedSource {
                model.selectSource(src, preserveProfile: true)
            }
        }
        customDelimiterText = ""
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
}
