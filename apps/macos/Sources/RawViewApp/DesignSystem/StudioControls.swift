import SwiftUI
import RawViewCore

// MARK: - StudioActionButton

/// Standard reusable action button (height 24pt, corner radius 5pt).
/// Supports dynamic illumination (`isIlluminated`, `isActive`), custom tint, and icon/title.
public struct StudioActionButton: View {
    let title: String
    var systemImage: String? = nil
    var customLeadingView: AnyView? = nil
    var isIlluminated: Bool = false
    var isActive: Bool = false
    var illuminatedColor: Color = Color.accentColor
    var uiFontSize: Double = 12.0
    let action: () -> Void

    public init(
        title: String,
        systemImage: String? = nil,
        customLeadingView: AnyView? = nil,
        isIlluminated: Bool = false,
        isActive: Bool = false,
        illuminatedColor: Color = Color.accentColor,
        uiFontSize: Double = 12.0,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.customLeadingView = customLeadingView
        self.isIlluminated = isIlluminated
        self.isActive = isActive
        self.illuminatedColor = illuminatedColor
        self.uiFontSize = uiFontSize
        self.action = action
    }

    private var effectiveIllumination: Bool {
        isIlluminated || isActive
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let leading = customLeadingView {
                    leading
                } else if let icon = systemImage {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                }

                Text(title)
                    .font(AppTypography.toolbarLabel(uiFontSize: uiFontSize))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minHeight: max(24, 20 * AppTypography.scale(for: uiFontSize)))
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(effectiveIllumination ? illuminatedColor.opacity(0.18) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        effectiveIllumination ? illuminatedColor : Color.secondary.opacity(0.25),
                        lineWidth: effectiveIllumination ? 1.2 : 0.8
                    )
            )
            .foregroundStyle(effectiveIllumination ? illuminatedColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - StudioSegmentPicker

/// Clean styled segmented picker for Studio mode toggling.
public struct StudioSegmentPicker<SelectionValue: Hashable, Content: View>: View {
    @Binding var selection: SelectionValue
    let content: Content

    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self._selection = selection
        self.content = content()
    }

    public var body: some View {
        Picker("", selection: $selection) {
            content
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - AppTokenPill

/// The one grammar token style, used by the Settings Grammar tab, the hierarchy editor
/// and the Explorer. Color comes from the token's family (type and role), never its name.
extension GrammarTokenFamily {
    /// One hue per role family. The label stays primary, so contrast holds in light and dark mode.
    var tint: Color {
        switch self {
        case .time: return .orange
        case .instrument: return .blue
        case .device: return .indigo
        case .mode: return .teal
        case .category: return .green
        case .batch: return .purple
        case .remarks: return .brown
        case .neutral: return .secondary
        }
    }
}

/// Grammar token chip. Shows `{name}`. An optional token gets a trailing `?` and a dashed
/// border, because square brackets are literal characters in a filename, not markers.
public struct AppTokenPill: View {
    let name: String
    var family: GrammarTokenFamily = .neutral
    var isOptional: Bool = false
    var isHighlighted: Bool = false
    var uiFontSize: Double = 12.0

    public init(
        name: String,
        role: String? = nil,
        type: GrammarFieldType? = nil,
        isOptional: Bool = false,
        isHighlighted: Bool = false,
        uiFontSize: Double = 12.0
    ) {
        self.name = name
        self.family = GrammarTokenFamily(role: role, type: type)
        self.isOptional = isOptional
        self.isHighlighted = isHighlighted
        self.uiFontSize = uiFontSize
    }

    public init(field: GrammarField, isHighlighted: Bool = false, uiFontSize: Double = 12.0) {
        self.init(
            name: field.name,
            role: field.role,
            type: field.type,
            isOptional: field.isOptional,
            isHighlighted: isHighlighted,
            uiFontSize: uiFontSize
        )
    }

    public var body: some View {
        HStack(spacing: 1) {
            Text("{\(name)}")
                .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                .lineLimit(1)
            if isOptional {
                Text("?")
                    .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                    .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHighlighted ? Color.accentColor : family.tint.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isHighlighted ? Color.accentColor : family.tint.opacity(0.55),
                    style: StrokeStyle(lineWidth: 0.75, dash: isOptional ? [3, 2] : [])
                )
        )
    }
}

// MARK: - AppFlowLayout

/// Wrapping horizontal layout that keeps child badges intact instead of crushing or mid-word wrapping.
public struct AppFlowLayout: Layout {
    public var horizontalSpacing: CGFloat = 6
    public var verticalSpacing: CGFloat = 6

    public init(horizontalSpacing: CGFloat = 6, verticalSpacing: CGFloat = 6) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                totalWidth = max(totalWidth, x - horizontalSpacing)
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, max(0, x - horizontalSpacing))
        return CGSize(width: proposal.width ?? totalWidth, height: y + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - AppCountBadge

/// Scaled count badge capsule.
public struct AppCountBadge: View {
    let count: Int
    var uiFontSize: Double = 12.0

    public init(count: Int, uiFontSize: Double = 12.0) {
        self.count = count
        self.uiFontSize = uiFontSize
    }

    public var body: some View {
        Text("\(count)")
            .font(AppTypography.badge(uiFontSize: uiFontSize))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.quaternary))
    }
}
