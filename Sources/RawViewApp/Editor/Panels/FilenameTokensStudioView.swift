import SwiftUI
import RawViewCore

/// Dedicated Workspace Tab: Filename Grammar & Pattern Studio
/// Allows defining declarative naming conventions using smart pattern templates
/// (e.g. `{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]`),
/// managing `.rawviewer/view/grammar.yaml`, inspecting live pattern match status,
/// and mapping variables to scientific semantic roles.
struct FilenameTokensStudioView: View {
    @ObservedObject var model: EditorWorkspaceViewModel

    @State private var showingNewGrammarDialog: Bool = false
    @State private var newGrammarName: String = ""
    @State private var newGrammarTemplate: String = "{date}_{instrument}.{mode}_[{device-id}]_{study}"
    @State private var isShowingLegacyDelimiters: Bool = false
    @State private var customDelimiterText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    // 1. GRAMMAR CATALOG SELECTOR & PRESET CONTROLS
                    grammarCatalogBar

                    // 2. PATTERN TEMPLATE HERO EDITOR WITH 1-TAP VARIABLE PILLS
                    patternTemplateCard

                    // 3. SMART PATTERN MATCH STATUS BANNER
                    patternMatchStatusBanner

                    // 4. EXTRACTED VARIABLES & SEMANTIC ROLE MAPPING TABLE
                    extractedVariablesCard

                    // 5. LEGACY DELIMITER FALLBACK (Collapsible)
                    legacyDelimiterSection

                    // 6. COHORT VALIDATION MATRIX (Cross-project verification)
                    cohortValidationMatrixCard
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
        .sheet(isPresented: $showingNewGrammarDialog) {
            newGrammarSheet
        }
    }

    // MARK: - 1. Header Bar
    private var headerBar: some View {
        HStack(spacing: 12) {
            Label("Filename Grammar & Pattern Studio", systemImage: "character.textbox")
                .font(.system(size: 13, weight: .bold))

            Spacer()

            if let target = model.selectedSource {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.sampleExtractedFacts.isMatched ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text("Target:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(target.url.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(5)
            }

            Button {
                model.saveGrammarCatalog()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Save Grammar Catalog")
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - 2. Grammar Catalog Preset Bar
    private var grammarCatalogBar: some View {
        HStack(spacing: 12) {
            Label("Active Grammar:", systemImage: "text.book.closed")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { model.activeGrammarID },
                set: { model.selectGrammar(id: $0) }
            )) {
                ForEach(model.grammarCatalog.grammars) { g in
                    HStack {
                        Text(g.name)
                        if g.isDefault {
                            Text("(Default)").font(.caption)
                        }
                    }
                    .tag(g.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 260)

            Button {
                newGrammarName = "Custom Scientific Convention"
                newGrammarTemplate = model.activeTemplate
                showingNewGrammarDialog = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("New Grammar")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .controlSize(.small)

            Spacer()

            if let active = model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID }) {
                Text(active.description.isEmpty ? "Declarative Filename Pattern" : active.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - 3. Pattern Template Hero Editor
    private var patternTemplateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Pattern Template (Option A Grammar)", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("Enclose variables in {token}. Brackets [ ] or delimiters . _ - are preserved as literals.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            // Hero Template TextField
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                TextField("Pattern template (e.g. {date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}])", text: Binding(
                    get: { model.activeTemplate },
                    set: { model.updateActiveTemplate($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.primary)

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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(model.sampleExtractedFacts.isMatched ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.15), lineWidth: 1.2)
            )

            // 1-Tap Quick Variable Insertion Pills
            VStack(alignment: .leading, spacing: 6) {
                Text("Insert Variable Pill:")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    variableChip(name: "{date}", role: "Date & Time", color: .green)
                    variableChip(name: "{instrument}", role: "Instrument", color: .pink)
                    variableChip(name: "{mode}", role: "Mode", color: .purple)
                    variableChip(name: "[{device-id}]", role: "Device ID", color: .blue)
                    variableChip(name: "{study}", role: "Study", color: .purple)
                    variableChip(name: "r.[{remarks}]", role: "Remarks", color: .orange)
                    variableChip(name: "{batch}", role: "Custom", color: .teal)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func variableChip(name: String, role: String, color: Color) -> some View {
        Button {
            insertTokenIntoTemplate(name)
        } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.1))
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.3), lineWidth: 0.8))
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

    // MARK: - 4. Smart Pattern Match Status Banner
    private var patternMatchStatusBanner: some View {
        HStack(spacing: 12) {
            if model.sampleExtractedFacts.isMatched {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MATCHED PATTERN")
                        .font(.system(size: 11.5, weight: .heavy))
                        .foregroundStyle(Color.green)
                    Text("Sample filename conforms 100% to grammar pattern. \(model.sampleExtractedFacts.extractedFields.count) variables extracted.")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("PATTERN MISMATCH")
                        .font(.system(size: 11.5, weight: .heavy))
                        .foregroundStyle(Color.orange)
                    Text(model.grammarMatchError ?? model.sampleExtractedFacts.unmatchedReason ?? "Target filename does not match the active template structure.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let target = model.selectedSource {
                Text(target.url.lastPathComponent)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(model.sampleExtractedFacts.isMatched ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(model.sampleExtractedFacts.isMatched ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - 5. Extracted Variables & Semantic Roles Mapping Matrix
    private var extractedVariablesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Extracted Variables & Semantic Roles", systemImage: "slider.horizontal.2.square")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("Variables automatically mapped to scientific catalog fields")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                if model.sampleExtractedFacts.extractedFields.isEmpty {
                    Text("No variables extracted. Edit the pattern template above to match filename segments.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(10)
                } else {
                    VStack(spacing: 6) {
                        // Table Header
                        HStack(spacing: 8) {
                            Text("Variable")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 140, alignment: .leading)
                            Text("Extracted Value")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 220, alignment: .leading)
                            Text("Semantic Role")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 160, alignment: .leading)
                            Text("Format Hint / Option")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 160, alignment: .leading)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(4)

                        // Extracted variable rows
                        let activeGrammar = model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID })
                        ForEach(Array(model.sampleExtractedFacts.extractedFields.keys.sorted()), id: \.self) { varName in
                            let val = model.sampleExtractedFacts.extractedFields[varName] ?? ""
                            let field = activeGrammar?.fields.first(where: { $0.name == varName })
                            let currentRole = field?.role ?? "Remarks"
                            let currentFormat = field?.formatHint ?? ""
                            let currentStrip = field?.stripBrackets ?? false

                            HStack(spacing: 8) {
                                // Variable name chip
                                Text("{\(varName)}")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(roleColor(currentRole))
                                    .frame(width: 140, alignment: .leading)

                                // Extracted Value
                                Text(val)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)
                                    .help(val)
                                    .frame(width: 220, alignment: .leading)

                                // Semantic Role Picker
                                Picker("", selection: Binding(
                                    get: { currentRole },
                                    set: { newRole in
                                        model.updateGrammarField(name: varName, role: newRole, formatHint: currentFormat, stripBrackets: currentStrip)
                                    }
                                )) {
                                    ForEach(SemanticTokenElement.standardRoles + ["Skip"], id: \.self) { r in
                                        Text(r).tag(r)
                                    }
                                }
                                .pickerStyle(.menu)
                                .font(.system(size: 10))
                                .frame(width: 160)

                                // Format / Bracket Option
                                HStack(spacing: 6) {
                                    if currentRole == "Date & Time" {
                                        TextField("Format", text: Binding(
                                            get: { currentFormat },
                                            set: { newHint in
                                                model.updateGrammarField(name: varName, role: currentRole, formatHint: newHint, stripBrackets: currentStrip)
                                            }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 10, design: .monospaced))
                                    } else {
                                        Toggle("Strip [ ]", isOn: Binding(
                                            get: { currentStrip },
                                            set: { newStrip in
                                                model.updateGrammarField(name: varName, role: currentRole, formatHint: currentFormat, stripBrackets: newStrip)
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                        .font(.system(size: 10))
                                    }
                                }
                                .frame(width: 160, alignment: .leading)

                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(5)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    // MARK: - 6. Collapsible Legacy Delimiter Fallback
    private var legacyDelimiterSection: some View {
        DisclosureGroup(
            isExpanded: $isShowingLegacyDelimiters,
            content: {
                HStack(spacing: 12) {
                    Label("Legacy Split Delimiter:", systemImage: "scissors")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: Binding(
                        get: { model.editor.tokenDelimiters.first ?? "_" },
                        set: { model.editor.tokenDelimiters = [$0]; refreshSampleTokens() }
                    )) {
                        Text("Underscore (_)").tag("_")
                        Text("Hyphen (-)").tag("-")
                        Text("Dot (.)").tag(".")
                        Text("Space ( )").tag(" ")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)

                    Spacer()
                }
                .padding(.top, 6)
            },
            label: {
                Text("Advanced / Legacy Delimiter Fallback")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    // MARK: - 7. Cohort Validation Matrix
    private var cohortValidationMatrixCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Cohort Validation Matrix (Cross-Sample Matching)", systemImage: "tablecells")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("Verifies active grammar against all project data samples")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                let cohortSamples = Array(model.sources.prefix(15))
                if cohortSamples.isEmpty {
                    Text("No files in project to preview.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    let activeGrammar = model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID }) ?? FilenameGrammarCatalog.standardDefaults[0]
                    VStack(alignment: .leading, spacing: 4) {
                        // Header
                        HStack(spacing: 8) {
                            Text("Status")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 70, alignment: .leading)
                            Text("Sample Filename")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 250, alignment: .leading)
                            Text("Date & Time")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 130, alignment: .leading)
                            Text("Instrument / Mode")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 130, alignment: .leading)
                            Text("Device ID")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 120, alignment: .leading)
                            Text("Study / Category")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 140, alignment: .leading)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(4)

                        // Rows
                        ForEach(cohortSamples) { src in
                            let facts = FilenameGrammarEngine.extract(from: src.url.lastPathComponent, grammar: activeGrammar)
                            let isCurrent = (src.url == model.selectedSource?.url)

                            HStack(spacing: 8) {
                                // Match badge
                                HStack(spacing: 3) {
                                    if facts.isMatched {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.green)
                                        Text("Match")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(Color.green)
                                    } else {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(Color.orange)
                                        Text("Miss")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(Color.orange)
                                    }
                                }
                                .frame(width: 70, alignment: .leading)

                                // Filename
                                Text(src.url.lastPathComponent)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .lineLimit(1)
                                    .help(src.url.lastPathComponent)
                                    .frame(width: 250, alignment: .leading)

                                // Date
                                Text(facts.timestamp ?? "—")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(facts.timestamp != nil ? Color.green : Color.secondary)
                                    .frame(width: 130, alignment: .leading)

                                // Instrument / Mode
                                Text(formatInstrumentMode(facts))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(facts.instrument != nil ? Color.pink : Color.secondary)
                                    .frame(width: 130, alignment: .leading)

                                // Device ID
                                Text(facts.deviceID ?? "—")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(facts.deviceID != nil ? Color.blue : Color.secondary)
                                    .frame(width: 120, alignment: .leading)

                                // Study
                                Text(facts.category ?? "—")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(facts.category != nil ? Color.purple : Color.secondary)
                                    .frame(width: 140, alignment: .leading)

                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4.5)
                            .background(isCurrent ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(4)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    // MARK: - New Grammar Sheet
    private var newGrammarSheet: some View {
        VStack(spacing: 16) {
            Text("Create New Filename Grammar")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Grammar Name:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. Autolab Cyclic Voltammetry", text: $newGrammarName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
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

                Button("Add Grammar") {
                    let trimmedName = newGrammarName.trimmingCharacters(in: .whitespaces)
                    let name = trimmedName.isEmpty ? "Custom Grammar" : trimmedName
                    model.addNewGrammar(name: name, template: newGrammarTemplate)
                    showingNewGrammarDialog = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - Helpers
    private func formatInstrumentMode(_ facts: ExtractedGrammarFacts) -> String {
        if let inst = facts.instrument, let m = facts.mode {
            return "\(inst) (\(m))"
        } else if let inst = facts.instrument {
            return inst
        } else if let m = facts.mode {
            return m
        }
        return "—"
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "Study", "Mode", "category": return .purple
        case "Device ID", "Library", "legend": return .blue
        case "Date & Time": return .green
        case "Remarks", "metadata": return .orange
        case "Instrument": return .pink
        default: return .teal
        }
    }

    private func refreshSampleTokens() {
        if let src = model.selectedSource {
            model.selectSource(src, preserveProfile: true)
        }
    }
}
