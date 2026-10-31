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
            .frame(height: 24)
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
