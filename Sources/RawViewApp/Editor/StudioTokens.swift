import SwiftUI
import RawViewCore

/// Centralized Design & Typography Tokens for Profile Studio & Live Sandbox.
/// Scales dynamically with `@AppStorage("uiFontSize")` from SettingsView.
/// Forwards and aliases to new centralized `AppTypography` and `AppColors` types.
public enum StudioTokens {
    // Typealias to AppColors.RoleColor to preserve 100% backward compatibility
    public typealias RoleColor = AppColors.RoleColor

    // Dynamic Scale Factor based on user's Font Size setting (baseline: 12.0 pt)
    public static func scale(for uiFontSize: Double) -> CGFloat {
        AppTypography.scale(for: uiFontSize)
    }

    // MARK: - Typography Tokens
    public static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, uiFontSize: Double = 12.0) -> Font {
        AppTypography.font(size: size, weight: weight, design: design, uiFontSize: uiFontSize)
    }

    public static func mono(size: CGFloat, weight: Font.Weight = .regular, uiFontSize: Double = 12.0) -> Font {
        AppTypography.mono(size: size, weight: weight, uiFontSize: uiFontSize)
    }

    // Semantic Text Styles
    public static func title(uiFontSize: Double = 12.0) -> Font {
        AppTypography.title(uiFontSize: uiFontSize)
    }

    public static func sectionHeadline(uiFontSize: Double = 12.0) -> Font {
        AppTypography.sectionHeadline(uiFontSize: uiFontSize)
    }

    public static func body(uiFontSize: Double = 12.0) -> Font {
        AppTypography.body(uiFontSize: uiFontSize)
    }

    public static func bodySemibold(uiFontSize: Double = 12.0) -> Font {
        AppTypography.bodySemibold(uiFontSize: uiFontSize)
    }

    public static func toolbarLabel(uiFontSize: Double = 12.0) -> Font {
        AppTypography.toolbarLabel(uiFontSize: uiFontSize)
    }

    public static func description(uiFontSize: Double = 12.0) -> Font {
        AppTypography.description(uiFontSize: uiFontSize)
    }

    public static func caption(uiFontSize: Double = 12.0) -> Font {
        AppTypography.caption(uiFontSize: uiFontSize)
    }

    public static func captionBold(uiFontSize: Double = 12.0) -> Font {
        AppTypography.captionBold(uiFontSize: uiFontSize)
    }

    public static func chevron(uiFontSize: Double = 12.0) -> Font {
        AppTypography.chevron(uiFontSize: uiFontSize)
    }

    public static func badgeFont(uiFontSize: Double = 12.0) -> Font {
        AppTypography.badgeFont(uiFontSize: uiFontSize)
    }

    public static func dataCellFont(uiFontSize: Double = 12.0) -> Font {
        AppTypography.monoCell(uiFontSize: uiFontSize)
    }

    // MARK: - Component Dimensions
    public static let badgeHeight: CGFloat = 20.0
    public static let badgeCornerRadius: CGFloat = 4.0
    public static let badgeHorizontalPadding: CGFloat = 6.0
    public static let inputHeight: CGFloat = 22.0

    // MARK: - Semantic Color Tokens
    public static func roleColor(isX: Bool, isY: Bool, isProg: Bool, isSkipped: Bool) -> RoleColor {
        AppColors.roleColor(isX: isX, isY: isY, isProg: isProg, isSkipped: isSkipped)
    }

    public static func roleColor(col: ColumnDefinition) -> RoleColor {
        AppColors.roleColor(col: col)
    }
}

/// Standardized Role Badge for columns ([X], [X ★], [Y], [Y ★], [Prog], [⊘ Skip], [Data]).
/// Strict uniform height (20pt), padding, corner radius, and font scaling.
/// Aliases to `StudioRolePill` for unified rendering.
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
        StudioRolePill(
            text: text,
            roleColor: roleColor,
            hasDropdown: hasDropdown,
            uiFontSize: uiFontSize
        )
    }
}
