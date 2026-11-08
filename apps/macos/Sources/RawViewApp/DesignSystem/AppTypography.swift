import SwiftUI

/// Centralized Dynamic Typography System for RawViewApp.
/// Dynamically scales fonts with `@AppStorage("uiFontSize")` (default baseline: 12.0 pt)
/// and `@AppStorage("uiFontFamily")` (default: "System").
public enum AppTypography {
    /// Baseline font size in points from which scaling ratio is derived.
    public static let baselineFontSize: Double = 12.0

    /// Minimum allowable font size point value.
    public static let minimumFontSize: CGFloat = 8.0

    /// Supported UI font family presets.
    public enum FontFamily: String, CaseIterable, Identifiable, Sendable {
        case system = "System"
        case rounded = "Rounded"
        case serif = "Serif"
        case monospaced = "Monospaced"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .system: return "System (Default)"
            case .rounded: return "Rounded"
            case .serif: return "Serif"
            case .monospaced: return "Monospaced"
            }
        }

        public var fontDesign: Font.Design {
            switch self {
            case .system: return .default
            case .rounded: return .rounded
            case .serif: return .serif
            case .monospaced: return .monospaced
            }
        }
    }

    /// Computes dynamic scale factor based on user's UI Font Size preference.
    public static func scale(for uiFontSize: Double = baselineFontSize) -> CGFloat {
        CGFloat(max(Double(minimumFontSize), uiFontSize) / baselineFontSize)
    }

    /// Primary font factory scaling linearly with `uiFontSize` and honoring `uiFontFamily`.
    public static func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design? = nil,
        uiFontSize: Double = baselineFontSize,
        fontFamily: String = "System"
    ) -> Font {
        let activeDesign = design ?? (FontFamily(rawValue: fontFamily)?.fontDesign ?? .default)
        return .system(size: max(minimumFontSize, size * scale(for: uiFontSize)), weight: weight, design: activeDesign)
    }

    /// Monospaced font factory scaling linearly with `uiFontSize`.
    public static func mono(
        size: CGFloat,
        weight: Font.Weight = .regular,
        uiFontSize: Double = baselineFontSize
    ) -> Font {
        .system(size: max(minimumFontSize, size * scale(for: uiFontSize)), weight: weight, design: .monospaced)
    }

    // MARK: - Semantic Roles

    /// Standard section/card title (size 13.0, bold).
    public static func title(uiFontSize: Double = baselineFontSize, fontFamily: String = "System") -> Font {
        font(size: 13.0, weight: .bold, uiFontSize: uiFontSize, fontFamily: fontFamily)
    }

    /// Section header / subtitle (size 12.0, semibold).
    public static func sectionHeadline(uiFontSize: Double = baselineFontSize, fontFamily: String = "System") -> Font {
        font(size: 12.0, weight: .semibold, uiFontSize: uiFontSize, fontFamily: fontFamily)
    }

    /// Standard body text (size 11.5, regular).
    public static func body(uiFontSize: Double = baselineFontSize, fontFamily: String = "System") -> Font {
        font(size: 11.5, weight: .regular, uiFontSize: uiFontSize, fontFamily: fontFamily)
    }

    /// Emphasized body text (size 11.5, semibold).
    public static func bodySemibold(uiFontSize: Double = baselineFontSize, fontFamily: String = "System") -> Font {
        font(size: 11.5, weight: .semibold, uiFontSize: uiFontSize, fontFamily: fontFamily)
    }

    /// Toolbar labels, buttons, and action text (size 11.0, semibold).
    public static func toolbarLabel(uiFontSize: Double = baselineFontSize, fontFamily: String = "System") -> Font {
        font(size: 11.0, weight: .semibold, uiFontSize: uiFontSize, fontFamily: fontFamily)
    }

    /// Descriptive helper text (size 10.5, regular).
    public static func description(uiFontSize: Double = baselineFontSize, fontFamily: String = "System") -> Font {
        font(size: 10.5, weight: .regular, uiFontSize: uiFontSize, fontFamily: fontFamily)
    }

    /// Secondary caption (size 10.0, regular).
    public static func caption(uiFontSize: Double = baselineFontSize, fontFamily: String = "System") -> Font {
        font(size: 10.0, weight: .regular, uiFontSize: uiFontSize, fontFamily: fontFamily)
    }

    /// Emphasized caption (size 10.0, bold).
    public static func captionBold(uiFontSize: Double = baselineFontSize, fontFamily: String = "System") -> Font {
        font(size: 10.0, weight: .bold, uiFontSize: uiFontSize, fontFamily: fontFamily)
    }

    /// Monospaced cell font for tabular and raw data rendering (size 11.0, regular, monospaced).
    public static func monoCell(uiFontSize: Double = baselineFontSize) -> Font {
        mono(size: 11.0, weight: .regular, uiFontSize: uiFontSize)
    }

    /// Monospaced badge font for line numbers and indexes (size 10.5, bold, monospaced).
    public static func monoBadge(uiFontSize: Double = baselineFontSize) -> Font {
        mono(size: 10.5, weight: .bold, uiFontSize: uiFontSize)
    }

    // MARK: - Compatibility Tokens

    /// Pill/badge font token (size 10.5, bold).
    public static func badgeFont(uiFontSize: Double = baselineFontSize, fontFamily: String = "System") -> Font {
        font(size: 10.5, weight: .bold, uiFontSize: uiFontSize, fontFamily: fontFamily)
    }

    /// Chevron icon sizing token (size 8.5, semibold).
    public static func chevron(uiFontSize: Double = baselineFontSize, fontFamily: String = "System") -> Font {
        font(size: 8.5, weight: .semibold, uiFontSize: uiFontSize, fontFamily: fontFamily)
    }
}
