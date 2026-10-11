import SwiftUI
import RawViewCore

/// Unified Semantic Colors and Stream Palette for RawViewApp.
public enum AppColors {
    // MARK: - Role Colors

    /// Semantic role color definitions for data columns, series, and tags.
    public enum RoleColor: CaseIterable {
        case x
        case y
        case progression
        case skip
        case data

        /// Background tint for cells, pills, and backgrounds.
        public var background: Color {
            switch self {
            case .x: return Color.blue.opacity(0.14)
            case .y: return Color.green.opacity(0.14)
            case .progression: return Color.purple.opacity(0.15)
            case .skip: return Color.secondary.opacity(0.12)
            case .data: return Color.primary.opacity(0.05)
            }
        }

        /// Foreground text and icon color.
        public var foreground: Color {
            switch self {
            case .x: return Color.blue
            case .y: return Color.green
            case .progression: return Color.purple
            case .skip: return Color.secondary
            case .data: return Color.secondary
            }
        }

        /// Outline border stroke color.
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

    /// Resolves semantic role color from boolean flags.
    public static func roleColor(isX: Bool, isY: Bool, isProg: Bool, isSkipped: Bool) -> RoleColor {
        if isSkipped { return .skip }
        if isProg { return .progression }
        if isX { return .x }
        if isY { return .y }
        return .data
    }

    /// Resolves semantic role color from ColumnDefinition.
    public static func roleColor(col: ColumnDefinition) -> RoleColor {
        if col.isSkipped || col.role == .skip { return .skip }
        if col.role == .progression { return .progression }
        if col.isXAxis || col.role == .x { return .x }
        if col.isYAxis || col.role == .y { return .y }
        return .data
    }

    // MARK: - 12 Harmonious Stream Palette Colors

    /// 12 harmonious pastel stream colors for distinguishing streams and columns.
    public static let palette: [Color] = [
        Color.blue,
        Color.green,
        Color.orange,
        Color.purple,
        Color.teal,
        Color.pink,
        Color.indigo,
        Color.mint,
        Color.cyan,
        Color.brown,
        Color.yellow,
        Color.red
    ]

    /// Accesses stream palette color safely cycling through 12 colors.
    public static func paletteColor(at index: Int) -> Color {
        guard !palette.isEmpty else { return Color.accentColor }
        let safeIndex = abs(index) % palette.count
        return palette[safeIndex]
    }
}
