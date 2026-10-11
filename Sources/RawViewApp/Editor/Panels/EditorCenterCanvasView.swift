import SwiftUI
import RawViewCore

/// Panel 2 (Center Canvas): Header bar with Mode switcher (`CanvasMode`: Data Matrix vs Raw Stream & Parser),
/// and 50:50 vertical split layout between data table (`StructuralBoxesCanvasView` / `ParserSettingsCanvasView`)
/// and Live Sandbox Studio mini-plot (`LiveSandboxPlotView`).
public struct EditorCenterCanvasView: View {
    @ObservedObject public var model: EditorWorkspaceViewModel
    @Binding public var canvasMode: CanvasMode

    public init(
        model: EditorWorkspaceViewModel,
        canvasMode: Binding<CanvasMode>
    ) {
        self.model = model
        self._canvasMode = canvasMode
    }

    public var body: some View {
        VStack(spacing: 0) {
            commandBar
            Divider()

            VSplitView {
                // Upper half: Data Table View (Data Matrix vs Raw Stream & Parser)
                upperTableView
                    .frame(minHeight: 220)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Lower half: Live Sandbox Studio Plot
                lowerPlotView
                    .frame(minHeight: 220)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Upper Data Table View
    @ViewBuilder
    private var upperTableView: some View {
        switch canvasMode {
        case .matrix:
            StructuralBoxesCanvasView(
                lines: model.editor.lines,
                delimiter: model.editor.delimiter,
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
                onSelectDelimiter: { delim in
                    model.editor.delimiter = delim
                    model.runAutoDetect()
                }
            )

        case .stream:
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
        }
    }

    // MARK: - Lower Live Sandbox Plot View
    private var lowerPlotView: some View {
        LiveSandboxPlotView(
            lines: model.editor.lines,
            delimiter: model.editor.delimiter,
            columns: model.editor.columns,
            lineTags: model.editor.lineTags,
            selectedXCol: $model.sandboxXCol,
            selectedYCol: $model.sandboxYCol
        )
    }

    // MARK: - Header Command Bar
    private var commandBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $canvasMode) {
                ForEach(CanvasMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Button {
                model.runAutoDetect()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("Auto Detect")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if let status = model.saveStatusMessage {
                HStack(spacing: 4) {
                    Image(systemName: (status.contains("error") || status.contains("Failed")) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 9.5))
                    Text(status)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle((status.contains("error") || status.contains("Failed")) ? Color.red : Color.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(((status.contains("error") || status.contains("Failed")) ? Color.red : Color.green).opacity(0.12))
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
