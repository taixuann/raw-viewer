import SwiftUI
import RawViewCore

/// Dedicated Workspace Tab: Filename Grammar & Pattern Studio
/// Designed in restrained Operate mode:
/// - Block 1: Unified Grammar Profile & Pattern Definition (Preset switcher, Hero Filename with pointer alignment, Pattern input, Variable mapping table with Required/Optional & Filter toggles).
/// - Block 2: Cohort Validation Matrix with full filenames and cross-project match verification.
struct FilenameTokensStudioView: View {
    @ObservedObject var model: EditorWorkspaceViewModel
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    @State private var showingNewGrammarDialog: Bool = false
    @State private var newGrammarName: String = ""
    @State private var newGrammarTemplate: String = "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]"

    var body: some View {
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
        .background(Color(NSColor.windowBackgroundColor).opacity(0.35))
        .sheet(isPresented: $showingNewGrammarDialog) {
            newGrammarSheet
        }
    }

    // MARK: - BLOCK 1: Unified Grammar Definition & Pattern Studio Card
    private var unifiedGrammarCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1.1 Card Header: Active Grammar, Inline Renaming, and Save Action
            HStack(spacing: 8) {
                Label("Profile:", systemImage: "character.textbox")
                    .font(AppTypography.sectionHeadline(uiFontSize: uiFontSize))

                // Profile Selector Menu
                Picker("", selection: Binding(
                    get: { model.activeGrammarID },
                    set: { model.selectGrammar(id: $0) }
                )) {
                    ForEach(model.grammarCatalog.grammars) { g in
                        Text(g.name).tag(g.id)
                    }
                }
                .pickerStyle(.menu)
                .font(AppTypography.body(uiFontSize: uiFontSize))
                .frame(width: 170)

                // Inline Profile Name Editor
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(AppTypography.caption(uiFontSize: uiFontSize))
                        .foregroundStyle(.secondary)
                    TextField("Profile Name", text: Binding(
                        get: { model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID })?.name ?? "" },
                        set: { newName in
                            model.renameActiveGrammar(to: newName)
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(AppTypography.body(uiFontSize: uiFontSize))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .frame(minWidth: 160, maxWidth: 260)

                Button {
                    newGrammarName = "New Scientific Convention"
                    newGrammarTemplate = model.activeTemplate
                    showingNewGrammarDialog = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(AppTypography.toolbarLabel(uiFontSize: uiFontSize))
                }
                .controlSize(.small)

                Spacer()

                Menu {
                    Button {
                        model.saveGrammarToProject()
                    } label: {
                        Label("Save to Project (.rawviewer/view/grammar.yaml)", systemImage: "folder")
                    }

                    Button {
                        model.saveGrammarToGlobal()
                    } label: {
                        Label("Save as Global Template (~/.rawviewer/grammar.yaml)", systemImage: "globe")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save Grammar")
                    }
                    .font(AppTypography.toolbarLabel(uiFontSize: uiFontSize))
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
            }

            // 1.2 Centered Hero Filename & Direct Visual Token Mapping (Pointer Arrows)
            if let target = model.selectedSource {
                Divider()

                VStack(spacing: 10) {
                    HStack {
                        Text("Active Target Filename:")
                            .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.sampleExtractedFacts.isMatched {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.green)
                                Text("100% Matched")
                                    .font(AppTypography.captionBold(uiFontSize: uiFontSize))
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
                                    .font(AppTypography.caption(uiFontSize: uiFontSize))
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
                            .font(AppTypography.title(uiFontSize: uiFontSize))
                            .foregroundStyle(.secondary)

                        Text(target.url.lastPathComponent)
                            .font(AppTypography.mono(size: 13.5, weight: .bold, uiFontSize: uiFontSize))
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
                    if !model.templateVariableNames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                let activeGrammar = model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID })
                                ForEach(model.templateVariableNames, id: \.self) { varName in
                                    let val = model.sampleExtractedFacts.extractedFields[varName]
                                    let field = activeGrammar?.fields.first(where: { $0.name == varName })
                                    let role = field?.role ?? "Remarks"
                                    let isOpt = field?.isOptional ?? false

                                    VStack(spacing: 4) {
                                        // Extracted Value Chip
                                        Text(val ?? "—")
                                            .font(AppTypography.mono(size: 12, weight: .semibold, uiFontSize: uiFontSize))
                                            .foregroundStyle(val != nil ? Color.primary : Color.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color(NSColor.controlBackgroundColor))
                                            .cornerRadius(4)
                                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(val != nil ? Color.primary.opacity(0.18) : Color.orange.opacity(0.4), lineWidth: 1))

                                        // Down Pointer Arrow
                                        Image(systemName: "arrow.down")
                                            .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                            .foregroundStyle(val != nil ? Color.secondary.opacity(0.7) : Color.orange.opacity(0.6))

                                        // Pattern Variable Label
                                        HStack(spacing: 3) {
                                            Text("{\(varName)}")
                                                .font(AppTypography.mono(size: 10, weight: .bold, uiFontSize: uiFontSize))
                                            if isOpt {
                                                Text("opt")
                                                    .font(AppTypography.caption(uiFontSize: uiFontSize))
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
                        .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Any text in {name} creates a dynamic variable. Brackets [ ] or delimiters . _ - are preserved.")
                        .font(AppTypography.caption(uiFontSize: uiFontSize))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "curlybraces")
                        .font(AppTypography.body(uiFontSize: uiFontSize))
                        .foregroundStyle(.secondary)

                    TextField("Enter pattern (e.g. {date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}])", text: Binding(
                        get: { model.activeTemplate },
                        set: { model.updateActiveTemplate($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(AppTypography.mono(size: 12, weight: .medium, uiFontSize: uiFontSize))

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

                // Variable Insertion Chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Add Token:")
                            .font(AppTypography.caption(uiFontSize: uiFontSize))
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

            // 1.4 Variables Configuration Table (Role, Data Type, Format, Optional/Required, and Search Filter)
            VStack(alignment: .leading, spacing: 8) {
                Text("Variable Role & Explorer Filter Configuration:")
                    .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)

                if model.templateVariableNames.isEmpty {
                    Text("No variables declared. Type {variable_name} in the pattern template above.")
                        .font(AppTypography.body(uiFontSize: uiFontSize))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                            // Header Row
                            GridRow {
                                Text("Token")
                                    .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                    .frame(width: 115, alignment: .leading)
                                Text("Sample Value")
                                    .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                    .frame(width: 135, alignment: .leading)
                                Text("Scientific Role")
                                    .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                    .frame(width: 120, alignment: .leading)
                                Text("Data Type")
                                    .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                    .frame(width: 100, alignment: .leading)
                                Text("Format / Pattern")
                                    .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                    .frame(width: 140, alignment: .leading)
                                Text("Rule")
                                    .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                    .frame(width: 90, alignment: .leading)
                                Text("Filter in Explorer")
                                    .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                    .frame(width: 110, alignment: .leading)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(4)

                            // Item Rows
                            let activeGrammar = model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID })
                            ForEach(model.templateVariableNames, id: \.self) { varName in
                                let val = model.sampleExtractedFacts.extractedFields[varName]
                                let field = activeGrammar?.fields.first(where: { $0.name == varName })
                                let currentRole = field?.role ?? "Remarks"
                                let currentType = field?.type ?? .string
                                let currentFormat = field?.formatHint ?? ""
                                let currentStrip = field?.stripBrackets ?? false
                                let currentOpt = field?.isOptional ?? false
                                let currentFacet = field?.isFacet ?? true

                                GridRow {
                                    // 1. Token (115pt)
                                    Text("{\(varName)}")
                                        .font(AppTypography.mono(size: 11, weight: .bold, uiFontSize: uiFontSize))
                                        .frame(width: 115, alignment: .leading)

                                    // 2. Sample Value (135pt)
                                    Text(val ?? "(not in sample)")
                                        .font(AppTypography.mono(size: 11, uiFontSize: uiFontSize))
                                        .foregroundStyle(val != nil ? Color.primary : Color.secondary)
                                        .lineLimit(1)
                                        .frame(width: 135, alignment: .leading)

                                    // 3. Scientific Role (120pt)
                                    Picker("", selection: Binding(
                                        get: { currentRole },
                                        set: { newRole in
                                            model.updateGrammarField(
                                                name: varName,
                                                role: newRole,
                                                type: currentType,
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
                                    .font(AppTypography.caption(uiFontSize: uiFontSize))
                                    .frame(width: 120)

                                    // 4. Data Type (100pt)
                                    Picker("", selection: Binding(
                                        get: { currentType },
                                        set: { newType in
                                            let defaultFmt = newType == .number ? (currentFormat.isEmpty ? "01" : currentFormat) :
                                                             newType == .datetime ? (currentFormat.isEmpty ? "yyMMdd" : currentFormat) : ""
                                            model.updateGrammarField(
                                                name: varName,
                                                role: currentRole,
                                                type: newType,
                                                formatHint: defaultFmt,
                                                stripBrackets: currentStrip,
                                                isOptional: currentOpt,
                                                isFacet: currentFacet
                                            )
                                        }
                                    )) {
                                        ForEach(GrammarFieldType.allCases) { t in
                                            Text(t.displayName).tag(t)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .font(AppTypography.caption(uiFontSize: uiFontSize))
                                    .frame(width: 100)

                                    // 5. Format / Pattern (140pt)
                                    formatPatternCell(
                                        varName: varName,
                                        currentRole: currentRole,
                                        currentType: currentType,
                                        currentFormat: currentFormat,
                                        currentStrip: currentStrip,
                                        currentOpt: currentOpt,
                                        currentFacet: currentFacet
                                    )
                                    .frame(width: 140, alignment: .leading)

                                    // 6. Rule (90pt)
                                    Picker("", selection: Binding(
                                        get: { currentOpt },
                                        set: { newOpt in
                                            model.updateGrammarField(
                                                name: varName,
                                                role: currentRole,
                                                type: currentType,
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
                                    .font(AppTypography.caption(uiFontSize: uiFontSize))
                                    .frame(width: 90)

                                    // 7. Filter in Explorer (110pt)
                                    Toggle("Facet Filter", isOn: Binding(
                                        get: { currentFacet },
                                        set: { newFacet in
                                            model.updateGrammarField(
                                                name: varName,
                                                role: currentRole,
                                                type: currentType,
                                                formatHint: currentFormat,
                                                stripBrackets: currentStrip,
                                                isOptional: currentOpt,
                                                isFacet: newFacet
                                            )
                                        }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .font(AppTypography.caption(uiFontSize: uiFontSize))
                                    .frame(width: 110, alignment: .leading)
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
        }
        .padding(14)
        .background(studioCardBackground())
    }

    // MARK: - Format / Pattern Cell Helper
    @ViewBuilder
    private func formatPatternCell(
        varName: String,
        currentRole: String,
        currentType: GrammarFieldType,
        currentFormat: String,
        currentStrip: Bool,
        currentOpt: Bool,
        currentFacet: Bool
    ) -> some View {
        if currentType == .number {
            HStack(spacing: 4) {
                TextField("#", text: Binding(
                    get: { currentFormat.isEmpty ? "#" : currentFormat },
                    set: { newFmt in
                        model.updateGrammarField(
                            name: varName,
                            role: currentRole,
                            type: currentType,
                            formatHint: newFmt,
                            stripBrackets: currentStrip,
                            isOptional: currentOpt,
                            isFacet: currentFacet
                        )
                    }
                ))
                .textFieldStyle(.plain)
                .font(AppTypography.mono(size: 10.5, uiFontSize: uiFontSize))
                .padding(.horizontal, 4)
                .padding(.vertical, 2.5)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(3)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.12), lineWidth: 1))

                Menu {
                    Button("Any Integer (#)") {
                        model.updateGrammarField(name: varName, role: currentRole, type: currentType, formatHint: "#", stripBrackets: currentStrip, isOptional: currentOpt, isFacet: currentFacet)
                    }
                    Button("2-Digit (01, 02)") {
                        model.updateGrammarField(name: varName, role: currentRole, type: currentType, formatHint: "01", stripBrackets: currentStrip, isOptional: currentOpt, isFacet: currentFacet)
                    }
                    Button("3-Digit (001, 002)") {
                        model.updateGrammarField(name: varName, role: currentRole, type: currentType, formatHint: "001", stripBrackets: currentStrip, isOptional: currentOpt, isFacet: currentFacet)
                    }
                    Button("Decimal (0.0)") {
                        model.updateGrammarField(name: varName, role: currentRole, type: currentType, formatHint: "0.0", stripBrackets: currentStrip, isOptional: currentOpt, isFacet: currentFacet)
                    }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(AppTypography.caption(uiFontSize: uiFontSize))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20, height: 20)
            }
        } else if currentType == .datetime {
            HStack(spacing: 4) {
                TextField("yyMMdd", text: Binding(
                    get: { currentFormat.isEmpty ? "yyMMdd" : currentFormat },
                    set: { newFmt in
                        model.updateGrammarField(
                            name: varName,
                            role: currentRole,
                            type: currentType,
                            formatHint: newFmt,
                            stripBrackets: currentStrip,
                            isOptional: currentOpt,
                            isFacet: currentFacet
                        )
                    }
                ))
                .textFieldStyle(.plain)
                .font(AppTypography.mono(size: 10.5, uiFontSize: uiFontSize))
                .padding(.horizontal, 4)
                .padding(.vertical, 2.5)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(3)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.12), lineWidth: 1))

                Menu {
                    Button("yyMMdd (261012)") {
                        model.updateGrammarField(name: varName, role: currentRole, type: currentType, formatHint: "yyMMdd", stripBrackets: currentStrip, isOptional: currentOpt, isFacet: currentFacet)
                    }
                    Button("yyyyMMdd (20261012)") {
                        model.updateGrammarField(name: varName, role: currentRole, type: currentType, formatHint: "yyyyMMdd", stripBrackets: currentStrip, isOptional: currentOpt, isFacet: currentFacet)
                    }
                    Button("yyyy-MM-dd (2026-10-12)") {
                        model.updateGrammarField(name: varName, role: currentRole, type: currentType, formatHint: "yyyy-MM-dd", stripBrackets: currentStrip, isOptional: currentOpt, isFacet: currentFacet)
                    }
                    Button("DDMMYY-HHmmSS") {
                        model.updateGrammarField(name: varName, role: currentRole, type: currentType, formatHint: "DDMMYY-HHmmSS", stripBrackets: currentStrip, isOptional: currentOpt, isFacet: currentFacet)
                    }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(AppTypography.caption(uiFontSize: uiFontSize))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20, height: 20)
            }
        } else {
            Text("—")
                .font(AppTypography.body(uiFontSize: uiFontSize))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .center)
        }
    }

    // MARK: - BLOCK 2: Cohort Validation Matrix Card (Full Filenames)
    private var cohortValidationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            let cohortSamples = Array(model.sources.prefix(15))
            let activeGrammar = model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID }) ?? FilenameGrammarCatalog.standardDefaults[0]
            let matchCount = cohortSamples.filter { FilenameGrammarEngine.extract(from: $0.url.lastPathComponent, grammar: activeGrammar).isMatched }.count

            HStack {
                Label("Cohort Validation Matrix (Project Files Verification)", systemImage: "tablecells")
                    .font(AppTypography.sectionHeadline(uiFontSize: uiFontSize))

                Spacer()

                if !cohortSamples.isEmpty {
                    Text("\(matchCount)/\(cohortSamples.count) Matched (\(Int(Double(matchCount) / Double(cohortSamples.count) * 100))%)")
                        .font(AppTypography.monoBadge(uiFontSize: uiFontSize))
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
                    .font(AppTypography.body(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 3) {
                        // Table Column Headers
                        HStack(spacing: 10) {
                            Text("Status")
                                .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                .frame(width: 65, alignment: .leading)
                            Text("Full Filename")
                                .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                .frame(width: 480, alignment: .leading)
                            Text("Device ID")
                                .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                .frame(width: 110, alignment: .leading)
                            Text("Study / Category")
                                .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                .frame(width: 140, alignment: .leading)
                            Text("Instrument")
                                .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                .frame(width: 110, alignment: .leading)
                            Text("Date & Time")
                                .font(AppTypography.captionBold(uiFontSize: uiFontSize))
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
                                            .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                            .foregroundStyle(Color.green)
                                        Text("Match")
                                            .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                            .foregroundStyle(Color.green)
                                    } else {
                                        Image(systemName: "xmark")
                                            .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                            .foregroundStyle(Color.orange)
                                        Text("Miss")
                                            .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                            .foregroundStyle(Color.orange)
                                    }
                                }
                                .frame(width: 65, alignment: .leading)

                                // Full Monospaced Filename (No Truncation)
                                Text(src.url.lastPathComponent)
                                    .font(AppTypography.mono(size: 10.5, uiFontSize: uiFontSize))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .frame(width: 480, alignment: .leading)

                                // Device ID
                                Text(facts.deviceID ?? "—")
                                    .font(AppTypography.mono(size: 10, weight: .medium, uiFontSize: uiFontSize))
                                    .foregroundStyle(facts.deviceID != nil ? Color.primary : Color.secondary)
                                    .frame(width: 110, alignment: .leading)

                                // Study
                                Text(facts.category ?? "—")
                                    .font(AppTypography.font(size: 10, weight: .medium, uiFontSize: uiFontSize))
                                    .foregroundStyle(facts.category != nil ? Color.primary : Color.secondary)
                                    .frame(width: 140, alignment: .leading)

                                // Instrument
                                Text(facts.instrument ?? "—")
                                    .font(AppTypography.font(size: 10, uiFontSize: uiFontSize))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)

                                // Date
                                Text(facts.timestamp ?? "—")
                                    .font(AppTypography.mono(size: 10, uiFontSize: uiFontSize))
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
        .background(studioCardBackground())
    }

    // MARK: - New Grammar Modal Sheet
    private var newGrammarSheet: some View {
        VStack(spacing: 14) {
            Text("New Filename Grammar")
                .font(AppTypography.title(uiFontSize: uiFontSize))

            VStack(alignment: .leading, spacing: 5) {
                Text("Grammar Name:")
                    .font(AppTypography.caption(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
                TextField("e.g. Autolab CV Convention", text: $newGrammarName)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.body(uiFontSize: uiFontSize))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Pattern Template:")
                    .font(AppTypography.caption(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
                TextField("e.g. {date}_{instrument}.{mode}_[{device-id}]_{study}", text: $newGrammarTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.mono(size: 12, uiFontSize: uiFontSize))
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
                .font(AppTypography.mono(size: 10.5, weight: .medium, uiFontSize: uiFontSize))
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

    private func studioCardBackground() -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(NSColor.windowBackgroundColor))
            .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 1)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
