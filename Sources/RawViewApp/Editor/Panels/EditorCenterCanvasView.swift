import SwiftUI
import RawViewCore

/// Panel 2 (Center Canvas / Visual Studio): Full-width interactive workspace
/// - Top Command Bar: Studio Tab switcher (`[Filename Tokens | Raw Stream Studio | Live Sandbox Studio]`) and Save status capsule.
/// - Tab 1 (Filename Tokens): Dedicated Filename Tokens Studio for custom delimiters, segment chips, and cohort preview.
/// - Tab 2 (Raw Stream Studio): Dedicated Raw Stream Studio with ParserSettingsCanvasView (100% canvas height).
/// - Tab 3 (Live Sandbox Studio): Dedicated Live Sandbox Studio with LiveSandboxPlotView (100% canvas height).
struct EditorCenterCanvasView: View {
    @ObservedObject var model: EditorWorkspaceViewModel
    @Binding var selectedStudioTab: EditorWorkspaceView.StudioTab

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
            case .tokens:
                // Dedicated Filename Tokens Studio
                FilenameTokensStudioView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

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
            }
        }
    }

    // MARK: - Top Command Bar
    private var commandBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedStudioTab) {
                Label("Filename Tokens", systemImage: "text.word.spacing")
                    .tag(EditorWorkspaceView.StudioTab.tokens)
                Label("Raw Stream Studio", systemImage: "waveform.path.ecg")
                    .tag(EditorWorkspaceView.StudioTab.rawStream)
                Label("Live Sandbox Studio", systemImage: "chart.xyaxis.line")
                    .tag(EditorWorkspaceView.StudioTab.liveSandbox)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
