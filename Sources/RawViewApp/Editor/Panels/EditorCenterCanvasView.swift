import SwiftUI
import RawViewCore

/// Panel 2 (Center Canvas / Visual Studio): Full-width interactive workspace
/// - Shared Header: the single Profile selector (+ New, Import, Refresh), the
///   single Grammar selector, the compact Sample picker with match status and
///   Retry. Task 7: no saves, no Variant picker, no Keys row, no Validate
///   menu in the shared header.
/// - Tab 1 (Raw Stream Studio): Dedicated Raw Stream Studio with ParserSettingsCanvasView (100% canvas height) + Save Profile.
/// - Tab 2 (Live Sandbox Studio): Dedicated Live Sandbox Studio with LiveSandboxPlotView (100% canvas height).
/// - Tab 3 (Filename Grammar): Dedicated Filename Tokens & Grammar Studio for custom delimiters, segment chips, and cohort preview + Save Grammar.
struct EditorCenterCanvasView: View {
    @ObservedObject var model: EditorWorkspaceViewModel
    @Binding var selectedStudioTab: EditorWorkspaceView.StudioTab
    var availableTabs: [EditorWorkspaceView.StudioTab] = [.rawStream, .liveSandbox, .tokens]
    var sources: [RawSource] = []

    @State private var showingNewProfilePopover = false
    @State private var newProfileID = ""
    @State private var newProfileName = ""
    @State private var showingChooseSample = false
    @State private var chooseSampleFilter = ""

    init(
        model: EditorWorkspaceViewModel,
        selectedStudioTab: Binding<EditorWorkspaceView.StudioTab>,
        availableTabs: [EditorWorkspaceView.StudioTab] = [.rawStream, .liveSandbox, .tokens],
        sources: [RawSource] = []
    ) {
        self.model = model
        self._selectedStudioTab = selectedStudioTab
        self.availableTabs = availableTabs
        self.sources = sources
    }

    public var body: some View {
        VStack(spacing: 0) {
            commandBar
            profileManagementBar
            sampleStatusBar
            schemaBadge
            Divider()

            switch selectedStudioTab {
            case .rawStream:
                // Task 7: Save Profile lives in Raw Stream Studio only.
                rawStreamSaveBar
                // Dedicated Raw Stream Studio with Column Multi-Selection & Header Title Cards (100% Canvas Height)
                ParserSettingsCanvasView(
                    lines: model.editor.lines,
                    delimiter: $model.editor.delimiter,
                    decimalSeparator: $model.editor.decimalDelimiter,
                    columns: $model.editor.columns,
                    lineTags: model.editor.lineTags,
                    metadataCellTags: model.editor.metadataCellTags,
                    onTagMetadataCell: { tag in
                        model.tagMetadataCell(tag)
                    },
                    onRemoveMetadataTag: { lineIdx, tokIdx in
                        model.removeMetadataTag(lineIndex: lineIdx, tokenIndex: tokIdx)
                    },
                    onUpdateColumn: { idx, col in
                        model.updateColumn(index: idx, column: col)
                    },
                    onRunAutoDetect: {
                        model.runAutoDetect()
                    },
                    onApplyCustomStructure: { delim, decimal, headerLine, dataStart, skippedLines in
                        model.applyCustomStructure(delimiter: delim, decimalSeparator: decimal, headerLine: headerLine, dataStartLine: dataStart, skippedMetadataLines: skippedLines)
                    },
                    variantRows: model.selectedVariantRows,
                    variantMatch: model.selectedVariantMatch,
                    variantExtensions: model.selectedVariantExtensions,
                    variantEncodings: model.selectedVariantEncodings,
                    variantColumns: model.selectedVariantColumns,
                    onSetVariantHeader: { model.setVariantHeader($0) },
                    onSetVariantDataStart: { model.setVariantDataStart($0) },
                    onSetVariantPrefixes: { model.setVariantPrefixes(dataPrefix: $0, commentPrefix: $1) },
                    onSetVariantStream: { model.setVariantStream(extensions: $0, encodings: $1) },
                    onSetVariantMatch: { model.setVariantMatch(filenameContainsAll: $0, contentContainsAny: $1) },
                    onSetVariantExcluded: { model.setVariantExcludedMetadata($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .liveSandbox:
                // Dedicated Live Sandbox Studio with 100% Canvas Height
                LiveSandboxPlotView(
                    lines: model.editor.lines,
                    delimiter: model.editor.delimiter,
                    columns: model.editor.columns,
                    lineTags: model.editor.lineTags,
                    selectedXCol: $model.sandboxXCol,
                    selectedYCol: $model.sandboxYCol,
                    variantName: model.selectedVariantID,
                    onUseAsProfileDefaults: {
                        model.useSandboxAsProfileDefaults()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .tokens:
                // Dedicated Filename Grammar Studio
                FilenameTokensStudioView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .profileYAML:
                // Task 6: whole-variants-document source tab (Developer Mode).
                ProfileYAMLSourceView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Task 4: explicit confirmation naming the exact delete target.
        .alert(model.deleteConfirmTitle, isPresented: $model.showDeleteConfirm) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: {
            Text(model.deleteConfirmMessage)
        }
    }

    private func tabLabel(_ tab: EditorWorkspaceView.StudioTab) -> Label<Text, Image> {
        switch tab {
        case .rawStream:
            return Label("Raw Stream Studio", systemImage: "waveform.path.ecg")
        case .liveSandbox:
            return Label("Live Sandbox Studio", systemImage: "chart.xyaxis.line")
        case .tokens:
            return Label("Filename Grammar", systemImage: "text.word.spacing")
        case .profileYAML:
            return Label("Profile YAML", systemImage: "curlybraces")
        }
    }

    // MARK: - Top Command Bar
    private var commandBar: some View {
        HStack(spacing: 12) {
            // Segmented while the tabs fit; the native menu picker takes
            // over in narrow windows (long names never shrink to fit).
            ViewThatFits(in: .horizontal) {
                Picker("", selection: $selectedStudioTab) {
                    ForEach(availableTabs) { tab in
                        tabLabel(tab).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 440)

                Picker("Studio Tab", selection: $selectedStudioTab) {
                    ForEach(availableTabs) { tab in
                        tabLabel(tab).tag(tab)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
            }

            Spacer()

            if model.profileDirty {
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 7))
                    Text("Unsaved changes")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.08))
                .clipShape(Capsule())
            }

            if !((model.saveStatusMessage ?? "").isEmpty) {
                let isError = isErrorStatusMessage(model.saveStatusMessage)
                HStack(spacing: 4) {
                    Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? .red : .green)
                    Text(model.saveStatusMessage ?? "")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((isError ? Color.red : Color.green).opacity(0.08))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Task 7: per-tab Save Profile (Raw Stream Studio only)

    private var rawStreamSaveBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                model.saveProfileDocument()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Save Profile")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Writes the whole profile document to .rawviewer/instrument/<profileID>.yaml")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Shared Document Bar (the single Profile/Grammar selectors)
    private var profileManagementBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Profile:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Menu {
                if model.savedProfiles.isEmpty && model.excludedProfiles.isEmpty {
                    Text("No saved profiles")
                } else {
                    ForEach(model.savedProfiles, id: \.self) { profileURL in
                        let profileBaseName = profileURL.deletingPathExtension().lastPathComponent
                        let isCurrent = (model.editor.instrumentID == profileBaseName || model.editor.instrumentName == profileBaseName)
                        Button {
                            model.requestProfileSwitch(to: profileURL)
                        } label: {
                            if isCurrent {
                                Label(profileBaseName, systemImage: "checkmark")
                            } else {
                                Text(profileBaseName)
                            }
                        }
                    }
                    if !model.excludedProfiles.isEmpty {
                        Divider()
                        Text(excludedSummary)
                    }
                }
                Divider()
                Button("Import YAML Profile…") {
                    model.importProfile()
                }
                Button("Refresh Saved Profiles") {
                    model.refreshSavedProfiles()
                }
            } label: {
                HStack(spacing: 4) {
                    let activeName = model.hasProfileDocument
                        ? model.profileDisplayName
                        : (!model.editor.instrumentName.isEmpty
                            ? model.editor.instrumentName
                            : (!model.editor.instrumentID.isEmpty ? model.editor.instrumentID : "Untitled"))
                    Text(activeName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .help("Switch active instrument profile")

            Button {
                newProfileID = "new-profile"
                newProfileName = "New Profile"
                showingNewProfilePopover = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("New")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Create a blank v3 profile from the current sample (unsaved)")
            .popover(isPresented: $showingNewProfilePopover) {
                newProfilePopoverView
            }

            Button(role: .destructive) {
                model.requestDeleteProfile()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text("Delete")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.canDeleteProfile)
            .help("Delete the selected profile file from .rawviewer/instrument/")
            .accessibilityLabel("Delete Profile")

            Text("Grammar:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            grammarSelectorMenu

            Button(role: .destructive) {
                model.requestDeleteGrammar()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text("Delete")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.canDeleteGrammar)
            .help("Delete the active grammar entry from .rawviewer/grammar.yaml")
            .accessibilityLabel("Delete Grammar")

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    /// The single Grammar selector. Creation stays in the Filename Grammar tab.
    private var grammarSelectorMenu: some View {
        Menu {
            let grammars = model.grammarCatalog.grammars
            if grammars.isEmpty {
                Text("No grammars")
            } else {
                let projectGrammars = grammars.filter { $0.scope == .project }
                let globalGrammars = grammars.filter { $0.scope == .global || ($0.scope == nil && $0.isDefault) }
                let otherGrammars = grammars.filter { $0.scope != .project && !globalGrammars.contains($0) }

                if !projectGrammars.isEmpty {
                    Section("Project Grammars") {
                        ForEach(projectGrammars) { g in
                            Button {
                                model.selectGrammar(id: g.id)
                            } label: {
                                if g.id == model.activeGrammarID {
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
                                model.selectGrammar(id: g.id)
                            } label: {
                                if g.id == model.activeGrammarID {
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
                                model.selectGrammar(id: g.id)
                            } label: {
                                if g.id == model.activeGrammarID {
                                    Label(g.name, systemImage: "checkmark")
                                } else {
                                    Text(g.name)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                let active = model.grammarCatalog.grammars.first(where: { $0.id == model.activeGrammarID })
                let name = active?.name ?? "Standard Filename Pattern"
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderedButton)
        .controlSize(.small)
        .help("Switch active filename grammar")
    }

    // MARK: - Shared Sample Row (compact picker, match status, Retry)

    /// Compact sample picker with match status and contextual Retry.
    /// Manual picks preserve drafts and stay
    /// unconfirmed until the exact profile/variant check confirms them.
    private var sampleStatusBar: some View {
        HStack(spacing: 8) {
            Text("Sample:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Button {
                chooseSampleFilter = ""
                showingChooseSample = true
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedSource?.url.lastPathComponent ?? "Choose…")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Search every source; manual picks stay unconfirmed until checked.")
            .popover(isPresented: $showingChooseSample) {
                chooseSampleView
            }

            sampleMatchStatus

            if needsSampleRetry {
                Button("Retry") { model.retryPreviewMatch() }
                    .controlSize(.small)
                    .help("Re-run the preview match for the active profile and variant.")
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var needsSampleRetry: Bool {
        switch model.previewMatch {
        case .noMatch, .ambiguous, .ioError:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var sampleMatchStatus: some View {
        switch model.previewMatch {
        case .idle:
            Text("No profile")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        case .searching:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Searching for a matching sample")
        case .confirmed(let id):
            Label("Match: \(Self.sampleDisplayName(id))", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        case .unconfirmed(let id):
            Label("Unconfirmed: \(Self.sampleDisplayName(id))", systemImage: "questionmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .noMatch:
            Text("No match — preview unconfirmed")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .ambiguous(let note):
            Label("Ambiguous — refine keys", systemImage: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help(note)
        case .ioError(let note):
            Label("Sample check I/O error", systemImage: "xmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .help(note)
        }
    }

    private static func sampleDisplayName(_ relativePath: String) -> String {
        URL(fileURLWithPath: relativePath).lastPathComponent
    }

    /// Searchable list over every source (no prefix cap). Picking switches
    /// the preview immediately; the match row marks it unconfirmed until
    /// the exact profile/variant check confirms it.
    private var chooseSampleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose Sample")
                .font(.system(size: 12, weight: .bold))
            Text("Every source is listed. A manual pick stays unconfirmed until checked.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Filter sources", text: $chooseSampleFilter)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))
            if filteredSamples.isEmpty {
                Text("No sources match the filter.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                List(filteredSamples) { src in
                    Button {
                        model.chooseSamplePreview(src)
                        showingChooseSample = false
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(src.url.lastPathComponent)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                            Text(src.relativePath)
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 220)
            }
            HStack {
                Button("Cancel") { showingChooseSample = false }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var filteredSamples: [RawSource] {
        let all = sources.isEmpty ? model.sources : sources
        let query = chooseSampleFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter {
            ($0.url.lastPathComponent + " " + $0.relativePath).lowercased().contains(query)
        }
    }

    // MARK: - Task 1: schema badge + excluded-count diagnostic

    /// Read-only schema badge plus the small excluded-count diagnostic with
    /// reasons. Excluded files are never selectable entries.
    private var schemaBadge: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Schema:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.schemaBadgeText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Read-only: the active profile's schema version.")
                    .accessibilityLabel("Profile schema: \(model.schemaBadgeText)")
                Spacer()
            }
            if !model.excludedProfiles.isEmpty {
                Text(excludedSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(excludedDetails)
                    .accessibilityLabel(excludedDetails)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var excludedSummary: String {
        let count = model.excludedProfiles.count
        return "\(count) incompatible profile\(count == 1 ? "" : "s") excluded (valid v3 only)."
    }

    private var excludedDetails: String {
        model.excludedProfiles.map { "\($0.fileName): \($0.reason)" }.joined(separator: "\n")
    }

    // MARK: - New Profile Popover (Task 7: blank v3 from the current sample)

    private var newProfilePopoverView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Profile")
                .font(.system(size: 12, weight: .bold))

            Text("Creates a blank v3 profile from the current sample (unsaved). Save it from Raw Stream Studio.")
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
                        model.createBlankProfileFromSample(newID: cleanID, newName: cleanName)
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
