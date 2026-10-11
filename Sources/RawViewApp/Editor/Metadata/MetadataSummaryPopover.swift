import SwiftUI

/// Model representing a discovered metadata line item.
public struct MetadataSummaryEntry: Identifiable, Sendable, Equatable {
    public let lineIndex: Int
    public var lineNum: Int { lineIndex + 1 }
    public let rawText: String
    public let key: String
    public let value: String
    public var id: Int { lineNum }

    public init(lineIndex: Int, rawText: String, key: String, value: String) {
        self.lineIndex = lineIndex
        self.rawText = rawText
        self.key = key
        self.value = value
    }
}

/// Popover content displaying searchable/toggleable active metadata items discovered before data rows.
public struct MetadataSummaryPopover: View {
    public let metadataEntries: [MetadataSummaryEntry]
    @Binding public var skippedMetadataLines: Set<Int>

    public init(
        metadataEntries: [MetadataSummaryEntry],
        skippedMetadataLines: Binding<Set<Int>>
    ) {
        self.metadataEntries = metadataEntries
        self._skippedMetadataLines = skippedMetadataLines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Metadata Selection", systemImage: "tag.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.purple)
                Spacer()
                Button("All") {
                    skippedMetadataLines.removeAll()
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)

                Button("None") {
                    skippedMetadataLines = Set(metadataEntries.map { $0.lineNum })
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
            }
            Text("Check items to include in profile metadata. Unchecked lines will be skipped.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Divider()

            if metadataEntries.isEmpty {
                Text("No metadata lines detected before data rows.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(metadataEntries) { item in
                            let isIncluded = !skippedMetadataLines.contains(item.lineNum)
                            Button {
                                if isIncluded {
                                    skippedMetadataLines.insert(item.lineNum)
                                } else {
                                    skippedMetadataLines.remove(item.lineNum)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(isIncluded ? Color.purple : Color.secondary)
                                    Text("L\(item.lineNum)")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .trailing)
                                    Text(item.key)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(isIncluded ? Color.primary : Color.secondary)
                                    if !item.value.isEmpty {
                                        Text(":")
                                            .foregroundStyle(.secondary)
                                        Text(item.value)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(isIncluded ? Color.primary : Color.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}
