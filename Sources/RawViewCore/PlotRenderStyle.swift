import Foundation

public enum PlotRenderStyle: String, CaseIterable, Identifiable, Sendable {
    case line = "Line"
    case scatter = "Scatter"
    case lineAndScatter = "Line + Dots"
    case spline = "Spline"

    public var id: String { rawValue }
}
