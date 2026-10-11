import SwiftUI
import RawViewCore

/// Interactive popover for assigning or editing semantic metadata tags on raw data cells.
public struct MetadataCellPopoverView: View {
    public let target: CellTarget
    public let existingTag: MetadataCellTag?
    public let adjacentTokens: [String]
    public let onSave: (MetadataCellTag) -> Void
    public let onRemove: () -> Void
    public let onDismiss: () -> Void

    @State private var selectedEntity: MetadataCellTag.EntityType = .parameter
    @State private var parameterKeyText: String = ""
    @State private var customFormatText: String = ""

    public init(
        target: CellTarget,
        existingTag: MetadataCellTag?,
        adjacentTokens: [String],
        onSave: @escaping (MetadataCellTag) -> Void,
        onRemove: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.target = target
        self.existingTag = existingTag
        self.adjacentTokens = adjacentTokens
        self.onSave = onSave
        self.onRemove = onRemove
        self.onDismiss = onDismiss
        _selectedEntity = State(initialValue: existingTag?.entityType ?? .parameter)
        _parameterKeyText = State(initialValue: existingTag?.parameterKey ?? existingTag?.customKey ?? adjacentTokens.first ?? "")
        _customFormatText = State(initialValue: existingTag?.format ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(Color.purple)
                Text("Tag Metadata Cell")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("L\(target.lineIdx + 1), Col \(target.tokenIdx + 1)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Selected Value display
            VStack(alignment: .leading, spacing: 3) {
                Text("Selected Value:")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(target.token.isEmpty ? "— (empty)" : target.token)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2), lineWidth: 0.8))
            }

            // Entity Type Picker
            VStack(alignment: .leading, spacing: 3) {
                Text("Entity Type:")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedEntity) {
                    ForEach(MetadataCellTag.EntityType.allCases, id: \.self) { entity in
                        Text(entity.rawValue).tag(entity)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Parameter Key with Suggestions
            VStack(alignment: .leading, spacing: 4) {
                Text("Parameter Key / Name:")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("e.g. Scan Rate, Temperature, Date", text: $parameterKeyText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                if !adjacentTokens.isEmpty {
                    HStack(spacing: 4) {
                        Text("Suggested:")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                        ForEach(adjacentTokens.prefix(3), id: \.self) { sug in
                            Button(sug) {
                                parameterKeyText = sug
                            }
                            .font(.system(size: 8.5, weight: .medium))
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            // Optional Format (for Date/Time)
            if selectedEntity == .dateTime || selectedEntity == .dateOnly || selectedEntity == .timeOnly {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Format (Optional):")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("e.g. yyyy-MM-dd HH:mm:ss", text: $customFormatText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10.5, design: .monospaced))
                }
            }

            Divider()

            // Actions
            HStack(spacing: 8) {
                if existingTag != nil {
                    Button("Clear Tag", role: .destructive) {
                        onRemove()
                        onDismiss()
                    }
                    .font(.system(size: 10.5))
                    .controlSize(.small)
                }

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }
                .font(.system(size: 10.5))
                .controlSize(.small)

                Button("Assign Tag") {
                    let tag = MetadataCellTag(
                        lineIndex: target.lineIdx,
                        tokenIndex: target.tokenIdx,
                        rawValue: target.token,
                        entityType: selectedEntity,
                        customKey: parameterKeyText.isEmpty ? nil : parameterKeyText,
                        format: customFormatText.isEmpty ? nil : customFormatText,
                        parameterKey: parameterKeyText.isEmpty ? nil : parameterKeyText
                    )
                    onSave(tag)
                    onDismiss()
                }
                .font(.system(size: 10.5, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
