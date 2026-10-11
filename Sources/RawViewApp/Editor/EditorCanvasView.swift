import SwiftUI
import RawViewCore

struct EditorCanvasView: View {
    let lines: [String]
    let lineTags: [Int: LineRegionType]
    @Binding var selectedLineRange: ClosedRange<Int>?
    var onTagRange: ((ClosedRange<Int>, LineRegionType) -> Void)?

    @State private var anchorLine: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Tag Selected:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button { applyTag(.metadata) } label: {
                    Label("Metadata", systemImage: "tag.fill")
                        .font(.caption2).foregroundStyle(.purple)
                }
                .disabled(selectedLineRange == nil)

                Button { applyTag(.columnHeaders) } label: {
                    Label("Column Names", systemImage: "tablecells")
                        .font(.caption2).foregroundStyle(.blue)
                }
                .disabled(selectedLineRange == nil)

                Button { applyTag(.dataMatrix) } label: {
                    Label("Data Matrix", systemImage: "chart.xyaxis.line")
                        .font(.caption2).foregroundStyle(.green)
                }
                .disabled(selectedLineRange == nil)

                Button("Clear") { applyTag(.unassigned) }
                    .font(.caption2)
                    .disabled(selectedLineRange == nil)

                Spacer()

                if let range = selectedLineRange {
                    Text("Lines \(range.lowerBound + 1)–\(range.upperBound + 1) selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            if lines.count > 2000 {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Showing first 2,000 lines of \(lines.count) for tagging.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
            }

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(0..<min(lines.count, 2000), id: \.self) { idx in
                        LineRowView(
                            lineNumber: idx + 1,
                            text: lines[idx],
                            tag: lineTags[idx] ?? .unassigned,
                            isSelected: selectedLineRange?.contains(idx) == true
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { handleLineClick(idx) }
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    private func handleLineClick(_ lineIndex: Int) {
        if NSEvent.modifierFlags.contains(.shift), let anchor = anchorLine {
            let start = min(anchor, lineIndex)
            let end = max(anchor, lineIndex)
            selectedLineRange = start...end
        } else {
            anchorLine = lineIndex
            selectedLineRange = lineIndex...lineIndex
        }
    }

    private func applyTag(_ tag: LineRegionType) {
        guard let range = selectedLineRange else { return }
        onTagRange?(range, tag)
    }
}

struct LineRowView: View {
    let lineNumber: Int
    let text: String
    let tag: LineRegionType
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(lineNumber)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Circle()
                .fill(tagColor)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(text.isEmpty ? " " : text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(rowBackground)
    }

    private var tagColor: Color {
        switch tag {
        case .unassigned: return .clear
        case .metadata: return .purple
        case .columnHeaders: return .blue
        case .dataMatrix: return .green
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor }
        switch tag {
        case .unassigned: return .clear
        case .metadata: return Color.purple.opacity(0.12)
        case .columnHeaders: return Color.blue.opacity(0.12)
        case .dataMatrix: return Color.green.opacity(0.08)
        }
    }
}
