import SwiftUI
import RawViewCore

/// Unified metadata pill component representing a token with an optional semantic metadata badge.
public struct MetadataCellPillView: View {
    public let token: String
    public let tag: MetadataCellTag?
    public let isSkipped: Bool
    public let style: Style

    public enum Style {
        /// Used in token stream rows (StreamRowView) with middle truncation and subtle borders.
        case streamRow(columnColor: Color, width: CGFloat)
        /// Used in structural boxes canvas (StructuralBoxesCanvasView) with compact horizontal padding.
        case structuralBox
    }

    public init(
        token: String,
        tag: MetadataCellTag?,
        isSkipped: Bool = false,
        style: Style = .structuralBox
    ) {
        self.token = token
        self.tag = tag
        self.isSkipped = isSkipped
        self.style = style
    }

    public var body: some View {
        switch style {
        case .streamRow(let colColor, let colWidth):
            HStack(spacing: 4) {
                Text(token.isEmpty ? "—" : token)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(isSkipped ? Color.secondary.opacity(0.4) : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if let t = tag {
                    HStack(spacing: 2) {
                        Self.tagIcon(for: t.entityType)
                            .font(.system(size: 7))
                        Text(Self.tagBadgeText(t))
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Self.tagColor(for: t.entityType))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Self.tagColor(for: t.entityType).opacity(0.14)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(width: colWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(tag != nil ? Self.tagColor(for: tag!.entityType).opacity(0.08) : colColor.opacity(isSkipped ? 0.015 : 0.03))
            )

        case .structuralBox:
            HStack(spacing: 4) {
                if let tag = tag {
                    Self.tagIcon(for: tag.entityType)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Self.tagColor(for: tag.entityType))
                }

                Text(token)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tag != nil ? Self.tagColor(for: tag!.entityType) : Color.primary)
                    .lineLimit(1)

                if let tag = tag {
                    Text(Self.tagBadgeText(tag))
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(Self.tagColor(for: tag.entityType).opacity(0.15))
                        .foregroundStyle(Self.tagColor(for: tag.entityType))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 4.5)
                    .fill(tag != nil ? Self.tagColor(for: tag!.entityType).opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4.5)
                    .stroke(tag != nil ? Self.tagColor(for: tag!.entityType).opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 0.8)
            )
        }
    }

    // MARK: - Shared Tag Visual Helpers

    public static func tagBadgeText(_ tag: MetadataCellTag) -> String {
        if let param = tag.parameterKey, !param.isEmpty {
            return param
        }
        switch tag.entityType {
        case .instrumentName: return "Model"
        case .instrumentID: return "ID"
        case .dateTime: return "DateTime"
        case .dateOnly: return "Date"
        case .timeOnly: return "Time"
        case .operatorName: return "Operator"
        case .sampleName: return "Sample"
        case .technique: return "Technique"
        case .parameter: return tag.customKey ?? "Param"
        case .ignore: return "Skip"
        }
    }

    public static func tagIcon(for type: MetadataCellTag.EntityType) -> Image {
        switch type {
        case .instrumentName, .instrumentID:
            return Image(systemName: "cpu")
        case .dateTime, .dateOnly, .timeOnly:
            return Image(systemName: "clock")
        case .parameter:
            return Image(systemName: "slider.horizontal.3")
        case .operatorName, .sampleName, .technique:
            return Image(systemName: "person.crop.circle")
        case .ignore:
            return Image(systemName: "slash.circle")
        }
    }

    public static func tagColor(for type: MetadataCellTag.EntityType) -> Color {
        switch type {
        case .instrumentName, .instrumentID:
            return Color.purple
        case .dateTime, .dateOnly, .timeOnly:
            return Color.blue
        case .parameter:
            return Color.orange
        case .operatorName, .sampleName, .technique:
            return Color.teal
        case .ignore:
            return Color.secondary
        }
    }
}
