import SwiftUI
import RawViewCore

/// Panel 2 (Center Canvas / Visual Studio): Full-width interactive workspace
/// - Top Command Bar: Studio Tab switcher (`[Raw Stream Studio | Live Sandbox Studio | Filename Grammar]`), Headbar Profile Management, and Save status capsule.
/// - Tab 1 (Raw Stream Studio): Dedicated Raw Stream Studio with ParserSettingsCanvasView (100% canvas height).
/// - Tab 2 (Live Sandbox Studio): Dedicated Live Sandbox Studio with LiveSandboxPlotView (100% canvas height).
/// - Tab 3 (Filename Grammar): Dedicated Filename Tokens & Grammar Studio for custom delimiters, segment chips, and cohort preview.
struct EditorCenterCanvasView: View {
    @ObservedObject var model: EditorWorkspaceViewModel
    @Binding var selectedStudioTab: EditorWorkspaceView.StudioTab

    @State private var showingNewProfilePopover = false
    @State private var showingProfileInfoPopover = false
    @State private var newProfileID = ""
    @State private var newProfileName = ""

    init(
        model: EditorWorkspaceViewModel,
        selectedStudioTab: Binding<EditorWorkspaceView.StudioTab>
    ) {
        self.model = model
        self._selectedStudioTab = selectedStudioTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            commandBar
            Divider()

            switch selectedStudioTab {
            case .rawStream:
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
                    }
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
                    selectedYCol: $model.sandboxYCol
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .tokens:
                // Dedicated Filename Grammar Studio
                FilenameTokensStudioView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Top Command Bar
    private var commandBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedStudioTab) {
                Label("Raw Stream Studio", systemImage: "waveform.path.ecg")
                    .tag(EditorWorkspaceView.StudioTab.rawStream)
                Label("Live Sandbox Studio", systemImage: "chart.xyaxis.line")
                    .tag(EditorWorkspaceView.StudioTab.liveSandbox)
                Label("Filename Grammar", systemImage: "text.word.spacing")
                    .tag(EditorWorkspaceView.StudioTab.tokens)
            }
            .pickerStyle(.segmented)
            .frame(width: 440)

            Spacer()

            if !((model.saveStatusMessage ?? "").isEmpty) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(model.saveStatusMessage ?? "")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.08))
                .clipShape(Capsule())
            }

            profileManagementBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Top-Right Profile Management Bar
    private var profileManagementBar: some View {
        HStack(spacing: 6) {
            Text("Profile:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Menu {
                if model.savedProfiles.isEmpty {
                    Text("No saved profiles")
                } else {
                    ForEach(model.savedProfiles, id: \.self) { profileURL in
                        let profileBaseName = profileURL.deletingPathExtension().lastPathComponent
                        let isCurrent = (model.editor.instrumentID == profileBaseName || model.editor.instrumentName == profileBaseName)
                        Button {
                            model.loadSavedProfile(url: profileURL)
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
                HStack(spacing: 4) {
                    Text("🎛️")
                    let activeName = !model.editor.instrumentName.isEmpty
                        ? model.editor.instrumentName
                        : (!model.editor.instrumentID.isEmpty ? model.editor.instrumentID : "Untitled")
                    Text(activeName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .help("Switch active instrument profile")

            Button {
                newProfileID = model.editor.instrumentID.isEmpty ? "new-profile" : "\(model.editor.instrumentID)-copy"
                newProfileName = model.editor.instrumentName.isEmpty ? "New Profile" : "\(model.editor.instrumentName) (Copy)"
                showingNewProfilePopover = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                    Text("New")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Create a new profile by duplicating current setup (non-destructive)")
            .popover(isPresented: $showingNewProfilePopover) {
                newProfilePopoverView
            }

            Button {
                showingProfileInfoPopover.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Edit Profile ID and Display Name")
            .popover(isPresented: $showingProfileInfoPopover) {
                profileInfoPopoverView
            }
        }
    }

    // MARK: - New Profile Popover
    private var newProfilePopoverView: some View {
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
                        model.duplicateProfileFromCurrent(newID: cleanID, newName: cleanName)
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

    // MARK: - Profile Info Popover
    private var profileInfoPopoverView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile Identity")
                .font(.system(size: 12, weight: .bold))

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
                                Text("From Token…")
                            }
                            .font(.system(size: 9))
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

            HStack {
                Spacer()
                Button("Done") {
                    showingProfileInfoPopover = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
