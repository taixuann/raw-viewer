import SwiftUI
import RawViewCore

/// Unified 2D rendering and geometry engine for Nature-compliant scientific plots.
enum PlotRenderingEngine {

    /// Standard line widths and tick lengths for scientific plots
    static let spineLineWidth: CGFloat = 1.0
    static let tickLineWidth: CGFloat = 1.0

    /// Outward tick length scaled to viewport readability on Retina monitors
    static func tickLength(fontScale: CGFloat, preset: ScientificPreset = .natureSingle) -> CGFloat {
        max(3.5, CGFloat(preset.tickLengthPt) * fontScale)
    }

    /// Spine and tick thickness in pt for a given scientific preset
    static func spineThickness(preset: ScientificPreset = .natureSingle) -> CGFloat {
        CGFloat(preset.spineThicknessPt)
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

    /// Convert a sequence of 2D data points into a staircase step path (horizontal then vertical step).
    static func stepPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard !points.isEmpty else { return path }
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let pCurrent = points[i]
            let pNext = points[i + 1]
            path.addLine(to: CGPoint(x: pNext.x, y: pCurrent.y))
            path.addLine(to: pNext)
        }
        return path
    }

    /// Viridis-inspired smooth scientific gradient for acquisition sequence / time progress (0.0 to 1.0)
    static func sweepColor(at progress: Double) -> Color {
        let t = min(max(progress, 0.0), 1.0)
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (30.0 / 255.0, 64.0 / 255.0, 175.0 / 255.0)),   // Deep Blue (start)
            (0.25, (2.0 / 255.0, 132.0 / 255.0, 199.0 / 255.0)),  // Cyan / Sky
            (0.50, (16.0 / 255.0, 185.0 / 255.0, 129.0 / 255.0)), // Emerald Green
            (0.75, (245.0 / 255.0, 158.0 / 255.0, 11.0 / 255.0)), // Amber
            (1.00, (239.0 / 255.0, 68.0 / 255.0, 68.0 / 255.0))   // Coral Red (end)
        ]
        for i in 0..<(stops.count - 1) {
            let (t0, c0) = stops[i]
            let (t1, c1) = stops[i + 1]
            if t >= t0 && t <= t1 {
                let frac = (t - t0) / (t1 - t0)
                let r = c0.0 + frac * (c1.0 - c0.0)
                let g = c0.1 + frac * (c1.1 - c0.1)
                let b = c0.2 + frac * (c1.2 - c0.2)
                return Color(red: r, green: g, blue: b)
            }
        }
        return Color(red: 239.0 / 255.0, green: 68.0 / 255.0, blue: 68.0 / 255.0)
    }

    /// Render circular markers for scatter points.
    static func drawMarkers(points: [CGPoint], markerSize: CGFloat, color: Color, colorBySweepProgress: Bool = false, in context: inout GraphicsContext) {
        let r = markerSize / 2.0
        let total = max(1, points.count - 1)
        for (i, p) in points.enumerated() {
            let markColor = colorBySweepProgress ? sweepColor(at: Double(i) / Double(total)) : color
            let rect = CGRect(x: p.x - r, y: p.y - r, width: markerSize, height: markerSize)
            context.fill(Path(ellipseIn: rect), with: .color(markColor))
        }
    }

    /// Render a contiguous run of points with the selected mark type and interpolation.
    static func renderRun(
        points: [CGPoint],
        mark: PlotMarkType,
        interpolation: PlotInterpolation,
        color: Color,
        lineWidth: CGFloat,
        markerSize: CGFloat,
        colorBySweepProgress: Bool = false,
        in context: inout GraphicsContext
    ) {
        guard !points.isEmpty else { return }

        // Singleton run: always render as a visible dot
        if points.count == 1 {
            let p = points[0]
            let r = max(2.5, markerSize / 2.0)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            let dotColor = colorBySweepProgress ? sweepColor(at: 0.0) : color
            context.fill(Path(ellipseIn: rect), with: .color(dotColor))
            return
        }

        // Draw line if mark is .line or .lineAndDots
        if mark == .line || mark == .lineAndDots {
            if colorBySweepProgress {
                let total = max(1, points.count - 1)
                switch interpolation {
                case .linear:
                    for i in 0..<(points.count - 1) {
                        var p = Path()
                        p.move(to: points[i])
                        p.addLine(to: points[i + 1])
                        let segColor = sweepColor(at: Double(i) / Double(total))
                        context.stroke(p, with: .color(segColor), lineWidth: lineWidth)
                    }
                case .step:
                    for i in 0..<(points.count - 1) {
                        var p = Path()
                        p.move(to: points[i])
                        p.addLine(to: CGPoint(x: points[i + 1].x, y: points[i].y))
                        p.addLine(to: points[i + 1])
                        let segColor = sweepColor(at: Double(i) / Double(total))
                        context.stroke(p, with: .color(segColor), lineWidth: lineWidth)
                    }
                case .spline:
                    for i in 0..<(points.count - 1) {
                        let p0 = i > 0 ? points[i - 1] : points[i]
                        let p1 = points[i]
                        let p2 = points[i + 1]
                        let p3 = (i + 2 < points.count) ? points[i + 2] : p2
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
                        var p = Path()
                        p.move(to: p1)
                        p.addCurve(to: p2, control1: cp1, control2: cp2)
                        let segColor = sweepColor(at: Double(i) / Double(total))
                        context.stroke(p, with: .color(segColor), lineWidth: lineWidth)
                    }
                }
            } else {
                let path: Path
                switch interpolation {
                case .linear:
                    var p = Path()
                    p.addLines(points)
                    path = p
                case .spline:
                    path = catmullRomPath(points: points)
                case .step:
                    path = stepPath(points: points)
                }
                context.stroke(path, with: .color(color), lineWidth: lineWidth)
            }
        }

        // Draw markers if mark is .dots or .lineAndDots
        if mark == .dots || mark == .lineAndDots {
            drawMarkers(points: points, markerSize: markerSize, color: color, colorBySweepProgress: colorBySweepProgress, in: &context)
        }
    }

    /// Compatibility wrapper for legacy PlotRenderStyle
    static func renderRun(
        points: [CGPoint],
        style: PlotRenderStyle,
        color: Color,
        lineWidth: CGFloat,
        markerSize: CGFloat,
        in context: inout GraphicsContext
    ) {
        renderRun(
            points: points,
            mark: style.markType,
            interpolation: style.interpolation,
            color: color,
            lineWidth: lineWidth,
            markerSize: markerSize,
            colorBySweepProgress: false,
            in: &context
        )
    }
}

/// Compact gradient indicator showing acquisition start to end.
struct SweepColorbarView: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Start (t = 0)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            LinearGradient(
                colors: [
                    Color(red: 30.0 / 255.0, green: 64.0 / 255.0, blue: 175.0 / 255.0),
                    Color(red: 2.0 / 255.0, green: 132.0 / 255.0, blue: 199.0 / 255.0),
                    Color(red: 16.0 / 255.0, green: 185.0 / 255.0, blue: 129.0 / 255.0),
                    Color(red: 245.0 / 255.0, green: 158.0 / 255.0, blue: 11.0 / 255.0),
                    Color(red: 239.0 / 255.0, green: 68.0 / 255.0, blue: 68.0 / 255.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 130, height: 7)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            Text("End (t = N)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

