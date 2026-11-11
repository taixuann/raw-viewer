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

/// Reusable grammar token pill with syntax tint and dynamic typography scaling.
public struct AppTokenPill: View {
    let name: String
    var isOptional: Bool = false
    var isHighlighted: Bool = false
    var uiFontSize: Double = 12.0

    public init(name: String, isOptional: Bool = false, isHighlighted: Bool = false, uiFontSize: Double = 12.0) {
        self.name = name
        self.isOptional = isOptional
        self.isHighlighted = isHighlighted
        self.uiFontSize = uiFontSize
    }

    private var tokenColor: Color {
        let lower = name.lowercased()
        if lower.contains("date") || lower.contains("time") {
            return .orange
        } else if lower.contains("device") || lower.contains("instrument") {
            return .blue
        } else if lower.contains("mode") || lower.contains("application") {
            return .teal
        } else if lower.contains("study") || lower.contains("batch") {
            return .purple
        } else if isOptional {
            return .secondary
        } else {
            return .primary
        }
    }

    public var body: some View {
        HStack(spacing: 2) {
            if isOptional {
                Text("[")
                    .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            Text("{\(name)}")
                .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                .foregroundStyle(isHighlighted ? Color.white : tokenColor)
            if isOptional {
                Text("]")
                    .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHighlighted ? Color.accentColor : tokenColor.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isHighlighted ? Color.accentColor : tokenColor.opacity(0.3), lineWidth: 0.8)
        )
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
