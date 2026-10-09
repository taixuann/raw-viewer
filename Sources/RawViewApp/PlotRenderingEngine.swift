import SwiftUI
import RawViewCore

/// Unified 2D rendering and geometry engine for Nature-compliant scientific plots.
enum PlotRenderingEngine {

    /// Standard line widths and tick lengths for Nature-compliant scientific plots
    static let spineLineWidth: CGFloat = 1.0
    static let tickLineWidth: CGFloat = 1.0

    /// Outward tick length scaled to viewport readability on Retina monitors
    static func tickLength(fontScale: CGFloat) -> CGFloat {
        max(6.0, 5.2 * fontScale)
    }

    /// Compute dynamic font scale from viewport width and user preferences.
    static func fontScale(plotWidth: CGFloat, uiFontSize: Double) -> CGFloat {
        let baseScale = max(1.0, min(1.6, plotWidth / 480.0))
        return baseScale * (CGFloat(uiFontSize) / 12.0)
    }

    /// Convert a sequence of 2D data points into a smooth Catmull-Rom cubic Bezier path.
    /// Passes directly through all sample points without runaway oscillations.
    static func catmullRomPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard !points.isEmpty else { return path }
        if points.count == 1 {
            path.move(to: points[0])
            return path
        }
        if points.count == 2 {
            path.move(to: points[0])
            path.addLine(to: points[1])
            return path
        }

        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = i > 0 ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = (i + 2 < points.count) ? points[i + 2] : p2

            // Monotone slope protection: if segment is vertical or flat, avoid overshoot
            let dx1 = (p2.x - p0.x) / 6.0
            let dy1 = (p2.y - p0.y) / 6.0
            let dx2 = (p3.x - p1.x) / 6.0
            let dy2 = (p3.y - p1.y) / 6.0

            let segmentMinY = min(p1.y, p2.y)
            let segmentMaxY = max(p1.y, p2.y)

            let cp1Y = min(segmentMaxY, max(segmentMinY, p1.y + dy1))
            let cp2Y = min(segmentMaxY, max(segmentMinY, p2.y - dy2))

            let cp1 = CGPoint(x: p1.x + dx1, y: cp1Y)
            let cp2 = CGPoint(x: p2.x - dx2, y: cp2Y)
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        return path
    }

    /// Render circular markers for scatter points.
    static func drawMarkers(points: [CGPoint], markerSize: CGFloat, color: Color, in context: inout GraphicsContext) {
        let r = markerSize / 2.0
        for p in points {
            let rect = CGRect(x: p.x - r, y: p.y - r, width: markerSize, height: markerSize)
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    /// Render a contiguous run of points with the selected PlotRenderStyle.
    static func renderRun(
        points: [CGPoint],
        style: PlotRenderStyle,
        color: Color,
        lineWidth: CGFloat,
        markerSize: CGFloat,
        in context: inout GraphicsContext
    ) {
        guard !points.isEmpty else { return }

        // Singleton run: always render as a visible dot
        if points.count == 1 {
            let p = points[0]
            let r = max(2.5, markerSize / 2.0)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color))
            return
        }

        switch style {
        case .line:
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .color(color), lineWidth: lineWidth)

        case .spline:
            let path = catmullRomPath(points: points)
            context.stroke(path, with: .color(color), lineWidth: lineWidth)

        case .scatter:
            drawMarkers(points: points, markerSize: markerSize, color: color, in: &context)

        case .lineAndScatter:
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .color(color), lineWidth: lineWidth)
            drawMarkers(points: points, markerSize: markerSize, color: color, in: &context)
        }
    }
}
