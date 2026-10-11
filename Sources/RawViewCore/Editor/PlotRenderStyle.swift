import Foundation

/// Primary mark type to draw for a dataset series.
public enum PlotMarkType: String, CaseIterable, Identifiable, Sendable {
    case line = "Line"
    case dots = "Dots"
    case lineAndDots = "Both"

    public var id: String { rawValue }
}

/// Curve connection / interpolation style when drawing line segments.
public enum PlotInterpolation: String, CaseIterable, Identifiable, Sendable {
    case linear = "Linear"
    case spline = "Spline"
    case step = "Step"

    public var id: String { rawValue }
}

/// Legacy/composite render style maintained for compatibility.
public enum PlotRenderStyle: String, CaseIterable, Identifiable, Sendable {
    case line = "Line"
    case scatter = "Scatter"
    case lineAndScatter = "Line + Dots"
    case spline = "Spline"

    public var id: String { rawValue }

    public var markType: PlotMarkType {
        switch self {
        case .line, .spline: return .line
        case .scatter: return .dots
        case .lineAndScatter: return .lineAndDots
        }
    }

    public var interpolation: PlotInterpolation {
        switch self {
        case .spline: return .spline
        default: return .linear
        }
    }
}
