import SwiftUI
import RawViewCore

/// Centralized Design & Typography Tokens for Profile Studio & Live Sandbox.
/// Scales dynamically with `@AppStorage("uiFontSize")` from SettingsView.
public enum StudioTokens {
    // Dynamic Scale Factor based on user's Font Size setting (baseline: 12.0 pt)
    public static func scale(for uiFontSize: Double) -> CGFloat {
        CGFloat(max(8.0, uiFontSize) / 12.0)
    }

    // MARK: - Typography Tokens
    public static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, uiFontSize: Double = 12.0) -> Font {
        .system(size: max(8.0, size * scale(for: uiFontSize)), weight: weight, design: design)
    }

    public static func mono(size: CGFloat, weight: Font.Weight = .regular, uiFontSize: Double = 12.0) -> Font {
        .system(size: max(8.0, size * scale(for: uiFontSize)), weight: weight, design: .monospaced)
    }

    // Semantic Text Styles
    public static func title(uiFontSize: Double = 12.0) -> Font {
        font(size: 13.0, weight: .bold, uiFontSize: uiFontSize)
    }

    public static func sectionHeadline(uiFontSize: Double = 12.0) -> Font {
        font(size: 12.0, weight: .semibold, uiFontSize: uiFontSize)
    }

    public static func body(uiFontSize: Double = 12.0) -> Font {
        font(size: 11.5, weight: .regular, uiFontSize: uiFontSize)
    }

    public static func bodySemibold(uiFontSize: Double = 12.0) -> Font {
        font(size: 11.5, weight: .semibold, uiFontSize: uiFontSize)
    }

    public static func toolbarLabel(uiFontSize: Double = 12.0) -> Font {
        font(size: 11.0, weight: .semibold, uiFontSize: uiFontSize)
    }

    public static func description(uiFontSize: Double = 12.0) -> Font {
        font(size: 10.5, weight: .regular, uiFontSize: uiFontSize)
    }

    public static func caption(uiFontSize: Double = 12.0) -> Font {
        font(size: 10.0, weight: .regular, uiFontSize: uiFontSize)
    }

    public static func captionBold(uiFontSize: Double = 12.0) -> Font {
        font(size: 10.0, weight: .bold, uiFontSize: uiFontSize)
    }

    public static func chevron(uiFontSize: Double = 12.0) -> Font {
        font(size: 8.5, weight: .semibold, uiFontSize: uiFontSize)
    }

    public static func badgeFont(uiFontSize: Double = 12.0) -> Font {
        font(size: 10.5, weight: .bold, uiFontSize: uiFontSize)
    }

    public static func dataCellFont(uiFontSize: Double = 12.0) -> Font {
        mono(size: 11.0, weight: .regular, uiFontSize: uiFontSize)
    }

    // MARK: - Component Dimensions
    public static let badgeHeight: CGFloat = 20.0
    public static let badgeCornerRadius: CGFloat = 4.0
    public static let badgeHorizontalPadding: CGFloat = 6.0
    public static let inputHeight: CGFloat = 22.0

    // MARK: - Semantic Color Tokens
    public enum RoleColor {
        case x
        case y
        case progression
        case skip
        case data

        public var background: Color {
            switch self {
            case .x: return Color.blue.opacity(0.14)
            case .y: return Color.green.opacity(0.14)
            case .progression: return Color.purple.opacity(0.15)
            case .skip: return Color.secondary.opacity(0.12)
            case .data: return Color.primary.opacity(0.05)
            }
        }

        public var foreground: Color {
            switch self {
            case .x: return Color.blue
            case .y: return Color.green
            case .progression: return Color.purple
            case .skip: return Color.secondary
            case .data: return Color.secondary
            }
        }

        public var border: Color {
            switch self {
            case .x: return Color.blue.opacity(0.35)
            case .y: return Color.green.opacity(0.35)
            case .progression: return Color.purple.opacity(0.35)
            case .skip: return Color.secondary.opacity(0.20)
            case .data: return Color.primary.opacity(0.10)
            }
        }
    }

    public static func roleColor(isX: Bool, isY: Bool, isProg: Bool, isSkipped: Bool) -> RoleColor {
        if isSkipped { return .skip }
        if isProg { return .progression }
        if isX { return .x }
        if isY { return .y }
        return .data
    }

    public static func roleColor(col: ColumnDefinition) -> RoleColor {
        if col.isSkipped || col.role == .skip { return .skip }
        if col.role == .progression { return .progression }
        if col.isXAxis || col.role == .x { return .x }
        if col.isYAxis || col.role == .y { return .y }
        return .data
    }
}

/// Standardized Role Badge for columns ([X], [X ★], [Y], [Y ★], [Prog], [⊘ Skip], [Data]).
/// Strict uniform height (20pt), padding, corner radius, and font scaling.
public struct StudioRoleBadgeView: View {
    let text: String
    let roleColor: StudioTokens.RoleColor
    var hasDropdown: Bool = true
    var uiFontSize: Double = 12.0

    public init(
        text: String,
        roleColor: StudioTokens.RoleColor,
        hasDropdown: Bool = true,
        uiFontSize: Double = 12.0
    ) {
        self.text = text
        self.roleColor = roleColor
        self.hasDropdown = hasDropdown
        self.uiFontSize = uiFontSize
    }

    public var body: some View {
        HStack(spacing: 3) {
            Text(text)
                .font(StudioTokens.badgeFont(uiFontSize: uiFontSize))
                .foregroundStyle(roleColor.foreground)

            if hasDropdown {
                Image(systemName: "chevron.down")
                    .font(StudioTokens.chevron(uiFontSize: uiFontSize))
                    .foregroundStyle(roleColor.foreground.opacity(0.8))
            }
        }
        .padding(.horizontal, StudioTokens.badgeHorizontalPadding)
        .frame(height: StudioTokens.badgeHeight)
        .background(
            RoundedRectangle(cornerRadius: StudioTokens.badgeCornerRadius)
                .fill(roleColor.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTokens.badgeCornerRadius)
                .stroke(roleColor.border, lineWidth: 0.8)
        )
    }
}
