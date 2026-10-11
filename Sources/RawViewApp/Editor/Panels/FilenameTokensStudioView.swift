import SwiftUI
import RawViewCore

/// Dedicated Workspace Tab: Filename Tokens Studio
/// Provides an ergonomic visual workspace for filename tokenization and category rule mapping:
/// - Prominent Centered Hero Filename Canvas (16–18pt monospaced bold)
/// - Visual pointer arrows (↓) and interactive text segment chips with synchronized color highlights
/// - Streamlined Delimiter selector (Dropdown / Menu with None, Underscore, Hyphen, Dot, Space, Custom)
/// - Configured Token Elements list
/// - Cohort Token Matrix reordered to the bottom for clear project-wide validation
struct FilenameTokensStudioView: View {
    @ObservedObject var model: EditorWorkspaceViewModel

    @State private var customDelimiterText: String = ""
    @State private var isShowingCustomInput: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // 1. CENTERED HERO FILENAME CANVAS (Highlight, Pointer Arrows & Direct Tagging)
                    heroFilenameCanvas

                    // 2. DELIMITER SELECTOR BAR
                    delimiterBar

                    // 3. CONFIGURED TOKEN ELEMENTS TABLE
                    configuredElementsCard

                    // 4. COHORT TOKEN MATRIX (Aligned at the bottom for cross-file inspection)
                    cohortTokensMatrixCard
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 12) {
            Label("Filename Tokens & Category Rules", systemImage: "text.word.spacing")
                .font(.system(size: 13, weight: .bold))

            Spacer()

            if let target = model.selectedSource {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Target:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(target.url.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - 1. Hero Filename Canvas (To chình ình ở giữa với Mũi tên chỉ trỏ & Highlight màu)
    private var heroFilenameCanvas: some View {
        VStack(spacing: 16) {
            // Container Header
            HStack {
                Label("Active Sample Filename Inspection", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(model.tokens.count) segments detected")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Big Centered Filename Display
            if let target = model.selectedSource {
                VStack(spacing: 14) {
                    // Monospaced Full Basename Banner (Big, clear, centered)
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)

                        Text(target.url.lastPathComponent)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                    // Interactive Segments with Pointer Arrows (↓)
                    if model.tokens.isEmpty {
                        Text("No delimiter split. Using entire filename as 1 segment.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 6) {
                            Text("Interactive Segments (Click arrow or word to map scientific category):")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(Array(model.tokens.enumerated()), id: \.offset) { idx, tok in
                                        let assigned = model.semanticElements.first(where: { $0.token == tok || $0.index == idx })
                                        segmentColumnCard(index: idx, token: tok, assigned: assigned)
                                    }
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
            } else {
                Text("No sample file selected. Choose a target file from the left sidebar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Segment Column with Pointer Arrow (↓) & Synchronized Color
    @ViewBuilder
    private func segmentColumnCard(index: Int, token: String, assigned: SemanticTokenElement?) -> some View {
        let color = assigned != nil ? roleColor(assigned!.role) : Color.secondary

        VStack(spacing: 5) {
            // Token Word Text Chip (Big, clear, 13pt bold monospaced)
            Menu {
                roleAssignmentMenu(token: token)
            } label: {
                HStack(spacing: 5) {
                    Text(token)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(assigned != nil ? color : Color.primary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(assigned != nil ? color.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(assigned != nil ? color.opacity(0.5) : Color.primary.opacity(0.18), lineWidth: assigned != nil ? 1.5 : 1)
                )
            }
            .menuStyle(.borderlessButton)

            // Visual Pointer Arrow (↓)
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(assigned != nil ? color : Color.secondary.opacity(0.4))

            // Assigned Role Capsule Badge
            Menu {
                roleAssignmentMenu(token: token)
            } label: {
                HStack(spacing: 4) {
                    if let assigned = assigned {
                        Circle()
                            .fill(color)
                            .frame(width: 6, height: 6)
                        Text(assigned.role)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(color)
                    } else {
                        Text("Unmapped")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(assigned != nil ? color.opacity(0.1) : Color.primary.opacity(0.04))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(assigned != nil ? color.opacity(0.3) : Color.secondary.opacity(0.15), lineWidth: 0.8)
                )
            }
            .menuStyle(.borderlessButton)

            // Index Position label
            Text("Col \(excelColumnLetter(index)) (#\(index + 1))")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 80)
    }

    // MARK: - Role Assignment Menu
    @ViewBuilder
    private func roleAssignmentMenu(token: String) -> some View {
        Button {
            model.addElement(token: token, role: "Study", tagName: "Category")
        } label: {
            Label("Map as Category / Study (Purple)", systemImage: "tag.fill")
        }

        Button {
            model.addElement(token: token, role: "Device ID", tagName: "Device")
        } label: {
            Label("Map as Device / Legend (Blue)", systemImage: "cpu")
        }

        Button {
            model.addElement(token: token, role: "Date & Time", tagName: "Timestamp")
        } label: {
            Label("Map as Date & Time (Green)", systemImage: "calendar")
        }

        Button {
            model.addElement(token: token, role: "Mode", tagName: "Mode")
        } label: {
            Label("Map as Measurement Mode (Pink)", systemImage: "waveform.path")
        }

        Button {
            model.addElement(token: token, role: "Remarks", tagName: "Remark")
        } label: {
            Label("Map as Metadata Field (Orange)", systemImage: "note.text")
        }

        Divider()

        Button("Use as Profile ID") {
            model.editor.instrumentID = token
        }

        Button("Use as Display Name") {
            model.editor.instrumentName = token
        }

        Divider()

        Button(role: .destructive) {
            if let el = model.semanticElements.first(where: { $0.token == token }) {
                model.removeElement(id: el.id)
            }
        } label: {
            Label("Clear Role Mapping", systemImage: "xmark.circle")
        }
    }

    // MARK: - 2. Delimiter Bar (Single Dropdown Picker with None option)
    private var delimiterBar: some View {
        HStack(spacing: 12) {
            Label("Token Delimiter:", systemImage: "scissors")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Menu {
                Button("Underscore (_)") {
                    setSingleDelimiter("_")
                }
                Button("Hyphen (-)") {
                    setSingleDelimiter("-")
                }
                Button("Dot (.)") {
                    setSingleDelimiter(".")
                }
                Button("Space ( )") {
                    setSingleDelimiter(" ")
                }
                Divider()
                Button("None (No delimiter - whole filename)") {
                    setNoDelimiter()
                }
                Divider()
                Button("Custom Delimiter…") {
                    isShowingCustomInput = true
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentDelimiterLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)

            if isShowingCustomInput {
                HStack(spacing: 4) {
                    TextField("Enter symbol…", text: $customDelimiterText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(width: 90)
                        .onSubmit {
                            commitCustomDelimiter()
                        }

                    Button("Apply") {
                        commitCustomDelimiter()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .controlSize(.small)

                    Button {
                        isShowingCustomInput = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(7)
    }

    private var currentDelimiterLabel: String {
        let delims = model.editor.tokenDelimiters
        if delims.isEmpty {
            return "None (Single string)"
        } else if delims.count == 1 {
            switch delims[0] {
            case "_": return "Underscore (_)"
            case "-": return "Hyphen (-)"
            case ".": return "Dot (.)"
            case " ": return "Space ( )"
            default: return "Custom '\(delims[0])'"
            }
        } else {
            return "\(delims.joined(separator: ", "))"
        }
    }

    private func setSingleDelimiter(_ delim: String) {
        model.editor.tokenDelimiters = [delim]
        isShowingCustomInput = false
        refreshSampleTokens()
    }

    private func setNoDelimiter() {
        model.editor.tokenDelimiters = []
        isShowingCustomInput = false
        refreshSampleTokens()
    }

    private func commitCustomDelimiter() {
        let trimmed = customDelimiterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.editor.tokenDelimiters = [trimmed]
        isShowingCustomInput = false
        customDelimiterText = ""
        refreshSampleTokens()
    }

    private func refreshSampleTokens() {
        if let src = model.selectedSource {
            model.selectSource(src, preserveProfile: true)
        }
    }

    // MARK: - 3. Configured Token Elements Table
    private var configuredElementsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Configured Token Elements & Semantic Roles", systemImage: "list.bullet.rectangle")
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
                    Text("No elements mapped yet. Click any segment above or use pointer arrow (↓) to define category or device rules.")
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

    // MARK: - 4. Cohort Token Matrix (Reordered to the Bottom)
    private var cohortTokensMatrixCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Cohort Token Matrix (Project Samples Validation)", systemImage: "tablecells")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("Cross-file category and device extraction preview")
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
                            Text("Sample Filename")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 260, alignment: .leading)
                            Text("Matched Category")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 150, alignment: .leading)
                            Text("Matched Device ID")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 150, alignment: .leading)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
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
                                    .help(src.url.lastPathComponent)
                                    .frame(width: 260, alignment: .leading)

                                Text(facts.category ?? "—")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.purple)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.1))
                                    .cornerRadius(3)
                                    .frame(width: 150, alignment: .leading)

                                Text(facts.deviceID ?? "—")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.blue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(3)
                                    .frame(width: 150, alignment: .leading)

                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(src.url == model.selectedSource?.url ? Color.accentColor.opacity(0.08) : Color.clear)
                            .cornerRadius(4)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Helpers
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

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "Study", "Mode", "category": return .purple
        case "Device ID", "Library", "legend": return .blue
        case "Date & Time": return .green
        case "Remarks", "metadata": return .orange
        default: return .pink
        }
    }
}
