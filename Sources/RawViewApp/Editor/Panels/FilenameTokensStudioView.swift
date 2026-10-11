import SwiftUI
import RawViewCore

/// Dedicated Workspace Tab: Filename Grammar & Pattern Studio
/// Designed in restrained Operate mode:
/// - Block 1: Unified Grammar Profile & Pattern Definition (Preset switcher, Hero Filename with pointer alignment, Pattern input, Variable mapping table with Required/Optional & Filter toggles).
/// - Block 2: Cohort Validation Matrix with full filenames and cross-project match verification.
struct FilenameTokensStudioView: View {
    @ObservedObject var model: EditorWorkspaceViewModel

    @State private var showingNewGrammarDialog: Bool = false
    @State private var newGrammarName: String = ""
    @State private var newGrammarTemplate: String = "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]"

    var body: some View {
        VStack(spacing: 0) {
            topNavBar
            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // BLOCK 1: UNIFIED GRAMMAR DEFINITION & PATTERN STUDIO
                    unifiedGrammarCard

                    // BLOCK 2: COHORT VALIDATION MATRIX (FULL FILENAMES & MATCH AUDIT)
                    cohortValidationCard
                }
                .padding(18)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.35))
        .sheet(isPresented: $showingNewGrammarDialog) {
            newGrammarSheet
        }
    }

    // MARK: - Top Nav Bar
    private var topNavBar: some View {
        HStack(spacing: 10) {
            Label("Filename Grammar Studio", systemImage: "text.word.spacing")
                .font(.system(size: 13, weight: .bold))

            Spacer()

            if let target = model.selectedSource {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.sampleExtractedFacts.isMatched ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text("Sample:")
                        .font(.system(size: 11, weight: .medium))
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
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - BLOCK 1: Unified Grammar Definition & Pattern Studio Card
    private var unifiedGrammarCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1.1 Card Header: Active Grammar, Renaming, and Save Action
            HStack(spacing: 10) {
                Label("Grammar Profile:", systemImage: "character.textbox")
                    .font(.system(size: 12, weight: .bold))

                Picker("", selection: Binding(
                    get: { model.activeGrammarID },
                    set: { model.selectGrammar(id: $0) }
                )) {
                    ForEach(model.grammarCatalog.grammars) { g in
                        Text(g.name).tag(g.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)

                Button {
                    newGrammarName = "New Scientific Convention"
                    newGrammarTemplate = model.activeTemplate
                    showingNewGrammarDialog = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(.system(size: 11))
                }
                .controlSize(.small)

                Spacer()

                Button {
                    model.saveGrammarCatalog()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save Grammar")
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .controlSize(.small)
            }

            Divider()

            // 1.2 Centered Hero Filename & Direct Visual Token Mapping (Pointer Arrows)
            if let target = model.selectedSource {
                VStack(spacing: 10) {
                    HStack {
                        Text("Active Target Filename:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.sampleExtractedFacts.isMatched {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.green)
                                Text("100% Matched")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(Color.green)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(4)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.orange)
                                Text(model.grammarMatchError ?? model.sampleExtractedFacts.unmatchedReason ?? "Mismatch")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Color.orange)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(4)
                        }
                    }

                    // Hero Filename Display Banner (Crisp Monospaced, Centered)
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)

                        Text(target.url.lastPathComponent)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )

                    // Aligned Segment Inspection Chips with Down Arrows (↓)
                    if !model.sampleExtractedFacts.extractedFields.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                let activeGrammar = model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID })
                                ForEach(Array(model.sampleExtractedFacts.extractedFields.keys.sorted()), id: \.self) { varName in
                                    let val = model.sampleExtractedFacts.extractedFields[varName] ?? ""
                                    let field = activeGrammar?.fields.first(where: { $0.name == varName })
                                    let role = field?.role ?? "Remarks"
                                    let isOpt = field?.isOptional ?? false

                                    VStack(spacing: 4) {
                                        // Extracted Value Chip
                                        Text(val)
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color(NSColor.controlBackgroundColor))
                                            .cornerRadius(4)
                                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15), lineWidth: 1))

                                        // Down Pointer Arrow
                                        Image(systemName: "arrow.down")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Color.secondary.opacity(0.7))

                                        // Pattern Variable Label
                                        HStack(spacing: 3) {
                                            Text("{\(varName)}")
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            if isOpt {
                                                Text("?")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(badgeBackground(for: role))
                                        .foregroundStyle(badgeForeground(for: role))
                                        .cornerRadius(4)
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }

            Divider()

            // 1.3 Pattern Template Input Field & Variable Pills
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Pattern Template:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Literal delimiters (_, ., -, []) are matched exactly.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("Enter pattern (e.g. {date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}])", text: Binding(
                        get: { model.activeTemplate },
                        set: { model.updateActiveTemplate($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))

                    if !model.activeTemplate.isEmpty {
                        Button {
                            model.updateActiveTemplate("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 1))

                // Restrained Variable Insertion Chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Add Token:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)

                        variableChip(name: "{date}")
                        variableChip(name: "{instrument}")
                        variableChip(name: "{mode}")
                        variableChip(name: "[{device-id}]")
                        variableChip(name: "{study}")
                        variableChip(name: "r.[{remarks}]")
                        variableChip(name: "{batch}")
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            // 1.4 Variables Configuration Table (Role, Optional/Required, and Search Filter)
            VStack(alignment: .leading, spacing: 8) {
                Text("Variable Role & Explorer Filter Configuration:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if model.sampleExtractedFacts.extractedFields.isEmpty {
                    Text("No variables active. Edit the pattern template above to define filename variables.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 4) {
                        // Header
                        HStack(spacing: 8) {
                            Text("Variable")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 130, alignment: .leading)
                            Text("Sample Value")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 190, alignment: .leading)
                            Text("Scientific Role")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 140, alignment: .leading)
                            Text("Rule")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 100, alignment: .leading)
                            Text("Filter in Explorer")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 120, alignment: .leading)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(4)

                        // Rows
                        let activeGrammar = model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID })
                        ForEach(Array(model.sampleExtractedFacts.extractedFields.keys.sorted()), id: \.self) { varName in
                            let val = model.sampleExtractedFacts.extractedFields[varName] ?? ""
                            let field = activeGrammar?.fields.first(where: { $0.name == varName })
                            let currentRole = field?.role ?? "Remarks"
                            let currentFormat = field?.formatHint ?? ""
                            let currentStrip = field?.stripBrackets ?? false
                            let currentOpt = field?.isOptional ?? false
                            let currentFacet = field?.isFacet ?? true

                            HStack(spacing: 8) {
                                // Variable Token
                                Text("{\(varName)}")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .frame(width: 130, alignment: .leading)

                                // Sample Value
                                Text(val.isEmpty ? "(not present)" : val)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(val.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                                    .frame(width: 190, alignment: .leading)

                                // Role Picker
                                Picker("", selection: Binding(
                                    get: { currentRole },
                                    set: { newRole in
                                        model.updateGrammarField(
                                            name: varName,
                                            role: newRole,
                                            formatHint: currentFormat,
                                            stripBrackets: currentStrip,
                                            isOptional: currentOpt,
                                            isFacet: currentFacet
                                        )
                                    }
                                )) {
                                    ForEach(SemanticTokenElement.standardRoles + ["Skip"], id: \.self) { r in
                                        Text(r).tag(r)
                                    }
                                }
                                .pickerStyle(.menu)
                                .font(.system(size: 10))
                                .frame(width: 140)

                                // Required vs Optional Picker
                                Picker("", selection: Binding(
                                    get: { currentOpt },
                                    set: { newOpt in
                                        model.updateGrammarField(
                                            name: varName,
                                            role: currentRole,
                                            formatHint: currentFormat,
                                            stripBrackets: currentStrip,
                                            isOptional: newOpt,
                                            isFacet: currentFacet
                                        )
                                    }
                                )) {
                                    Text("Required").tag(false)
                                    Text("Optional").tag(true)
                                }
                                .pickerStyle(.menu)
                                .font(.system(size: 10))
                                .frame(width: 100)

                                // Search Filter Checkbox
                                Toggle("Facet Filter", isOn: Binding(
                                    get: { currentFacet },
                                    set: { newFacet in
                                        model.updateGrammarField(
                                            name: varName,
                                            role: currentRole,
                                            formatHint: currentFormat,
                                            stripBrackets: currentStrip,
                                            isOptional: currentOpt,
                                            isFacet: newFacet
                                        )
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 10))
                                .frame(width: 120, alignment: .leading)

                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - BLOCK 2: Cohort Validation Matrix Card (Full Filenames)
    private var cohortValidationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            let cohortSamples = Array(model.sources.prefix(15))
            let activeGrammar = model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID }) ?? FilenameGrammarCatalog.standardDefaults[0]
            let matchCount = cohortSamples.filter { FilenameGrammarEngine.extract(from: $0.url.lastPathComponent, grammar: activeGrammar).isMatched }.count

            HStack {
                Label("Cohort Validation Matrix (Project Files Verification)", systemImage: "tablecells")
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                if !cohortSamples.isEmpty {
                    Text("\(matchCount)/\(cohortSamples.count) Matched (\(Int(Double(matchCount) / Double(cohortSamples.count) * 100))%)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(matchCount == cohortSamples.count ? Color.green : Color.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(matchCount == cohortSamples.count ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                        .cornerRadius(4)
                }
            }

            Divider()

            if cohortSamples.isEmpty {
                Text("No files in project to preview.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 3) {
                        // Table Column Headers
                        HStack(spacing: 10) {
                            Text("Status")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 65, alignment: .leading)
                            Text("Full Filename")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 480, alignment: .leading)
                            Text("Device ID")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 110, alignment: .leading)
                            Text("Study / Category")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 140, alignment: .leading)
                            Text("Instrument")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 110, alignment: .leading)
                            Text("Date & Time")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 130, alignment: .leading)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(4)

                        // Sample Rows
                        ForEach(cohortSamples) { src in
                            let facts = FilenameGrammarEngine.extract(from: src.url.lastPathComponent, grammar: activeGrammar)
                            let isCurrent = (src.url == model.selectedSource?.url)

                            HStack(spacing: 10) {
                                // Match Badge
                                HStack(spacing: 3) {
                                    if facts.isMatched {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Color.green)
                                        Text("Match")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(Color.green)
                                    } else {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Color.orange)
                                        Text("Miss")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(Color.orange)
                                    }
                                }
                                .frame(width: 65, alignment: .leading)

                                // Full Monospaced Filename (No Truncation)
                                Text(src.url.lastPathComponent)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .frame(width: 480, alignment: .leading)

                                // Device ID
                                Text(facts.deviceID ?? "—")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(facts.deviceID != nil ? Color.primary : Color.secondary)
                                    .frame(width: 110, alignment: .leading)

                                // Study
                                Text(facts.category ?? "—")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(facts.category != nil ? Color.primary : Color.secondary)
                                    .frame(width: 140, alignment: .leading)

                                // Instrument
                                Text(facts.instrument ?? "—")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)

                                // Date
                                Text(facts.timestamp ?? "—")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 130, alignment: .leading)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
                            .cornerRadius(4)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - New Grammar Modal Sheet
    private var newGrammarSheet: some View {
        VStack(spacing: 14) {
            Text("New Filename Grammar")
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                Text("Grammar Name:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. Autolab CV Convention", text: $newGrammarName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Pattern Template:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. {date}_{instrument}.{mode}_[{device-id}]_{study}", text: $newGrammarTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            HStack {
                Button("Cancel") {
                    showingNewGrammarDialog = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    let trimmed = newGrammarName.trimmingCharacters(in: .whitespaces)
                    let name = trimmed.isEmpty ? "Custom Grammar" : trimmed
                    model.addNewGrammar(name: name, template: newGrammarTemplate)
                    showingNewGrammarDialog = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    // MARK: - Helpers
    private func variableChip(name: String) -> some View {
        Button {
            insertTokenIntoTemplate(name)
        } label: {
            Text(name)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private func insertTokenIntoTemplate(_ token: String) {
        if model.activeTemplate.isEmpty {
            model.updateActiveTemplate(token)
        } else if model.activeTemplate.hasSuffix("_") || model.activeTemplate.hasSuffix(".") || model.activeTemplate.hasSuffix("-") {
            model.updateActiveTemplate(model.activeTemplate + token)
        } else {
            model.updateActiveTemplate(model.activeTemplate + "_" + token)
        }
    }

    private func badgeBackground(for role: String) -> Color {
        switch role {
        case "Study", "category": return Color.purple.opacity(0.1)
        case "Device ID", "legend": return Color.blue.opacity(0.1)
        case "Date & Time": return Color.green.opacity(0.1)
        case "Remarks": return Color.orange.opacity(0.1)
        default: return Color.primary.opacity(0.06)
        }
    }

    private func badgeForeground(for role: String) -> Color {
        switch role {
        case "Study", "category": return .purple
        case "Device ID", "legend": return .blue
        case "Date & Time": return .green
        case "Remarks": return .orange
        default: return .primary
        }
    }
}
