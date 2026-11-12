import AppKit
import SwiftUI
import RawViewCore

struct PlotAxisConfig: Equatable {
    var xTickCount: Int = 0
    var yTickCount: Int = 0
    var xMinorTicks: Int = 0
    var yMinorTicks: Int = 0
    var showMajorGrid: Bool = false
    var showMinorGrid: Bool = false
    var showZeroLine: Bool = false
    var showCursor: Bool = false
    var xRegionMin: Double? = nil
    var xRegionMax: Double? = nil
    var yRegionMin: Double? = nil
    var yRegionMax: Double? = nil
    var xPaddingPercent: Double = 4.0
    var yPaddingPercent: Double = 4.0
}

struct PlotLiveMetrics: Equatable {
    var xRange: ClosedRange<Double>? = nil
    var yRange: ClosedRange<Double>? = nil
    var xTickCount: Int = 5
    var yTickCount: Int = 5
}

enum PlotAxisDrawHelper {
    static func dataRegion(
        bounds: (lower: Double, upper: Double),
        minOverride: Double?,
        maxOverride: Double?
    ) -> ClosedRange<Double> {
        let lo = minOverride ?? bounds.lower
        let hi = maxOverride ?? bounds.upper
        if lo.isFinite && hi.isFinite && lo < hi {
            return lo...hi
        }
        if bounds.lower.isFinite && bounds.upper.isFinite && bounds.lower < bounds.upper {
            return bounds.lower...bounds.upper
        }
        let center = bounds.lower.isFinite ? bounds.lower : 0.0
        let delta = max(abs(center) * 0.05, 1.0)
        return (center - delta)...(center + delta)
    }

    static func paddedViewport(_ region: ClosedRange<Double>, paddingPercent: Double) -> ClosedRange<Double> {
        let pct = max(0.0, min(50.0, paddingPercent)) / 100.0
        let span = region.upperBound - region.lowerBound
        let delta = span > 0 ? span * pct : max(abs(region.lowerBound) * 0.05, 1.0)
        return (region.lowerBound - delta)...(region.upperBound + delta)
    }

    static func curveClipRect(
        plot: CGRect,
        xRegion: ClosedRange<Double>,
        yRegion: ClosedRange<Double>,
        xViewport: ClosedRange<Double>,
        yViewport: ClosedRange<Double>,
        clipToXRegion: Bool,
        clipToYRegion: Bool
    ) -> CGRect {
        let xSpan = xViewport.upperBound - xViewport.lowerBound
        let ySpan = yViewport.upperBound - yViewport.lowerBound
        var minX = plot.minX
        var maxX = plot.maxX
        var minY = plot.minY
        var maxY = plot.maxY

        if clipToXRegion && xSpan > 0 {
            let t0 = (xRegion.lowerBound - xViewport.lowerBound) / xSpan
            let t1 = (xRegion.upperBound - xViewport.lowerBound) / xSpan
            minX = plot.minX + CGFloat(t0) * plot.width
            maxX = plot.minX + CGFloat(t1) * plot.width
        }
        if clipToYRegion && ySpan > 0 {
            let t0 = (yRegion.lowerBound - yViewport.lowerBound) / ySpan
            let t1 = (yRegion.upperBound - yViewport.lowerBound) / ySpan
            maxY = plot.maxY - CGFloat(t0) * plot.height
            minY = plot.maxY - CGFloat(t1) * plot.height
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY)).intersection(plot)
    }

    static func effectiveMinorSubdivisions(minorCount: Int, showMinorGrid: Bool) -> Int {
        if minorCount > 0 { return minorCount + 1 }
        return showMinorGrid ? 5 : 0
    }

    static func drawGridTicksAndCursor(
        context: inout GraphicsContext,
        plot: CGRect,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        xRegion: ClosedRange<Double>,
        yRegion: ClosedRange<Double>,
        xNice: AxisFormatter.NiceTicksResult,
        yNice: AxisFormatter.NiceTicksResult,
        xScaleInfo: AxisFormatter.ScaleInfo,
        yScaleInfo: AxisFormatter.ScaleInfo,
        xScale: AxisScale,
        yScale: AxisScale,
        xTitle: String,
        yTitle: String,
        axisConfig: PlotAxisConfig,
        preset: ScientificPreset,
        fontScale: CGFloat,
        maxLabelWidth: CGFloat,
        yLabels: [String],
        hoverLocation: CGPoint?,
        formatLabel: (Double, AxisScale, AxisFormatter.ScaleInfo, Int?) -> String
    ) {
        let tickLen = PlotRenderingEngine.tickLength(fontScale: fontScale, preset: preset)
        let tickLabelSize = PlotRenderingEngine.tickLabelFontSize(preset: preset, fontScale: fontScale)
        let spineWidth = PlotRenderingEngine.spineThickness(preset: preset)
        let xSpan = xRange.upperBound - xRange.lowerBound
        let ySpan = yRange.upperBound - yRange.lowerBound
        let plotFont = { (size: CGFloat, bold: Bool) in
            PlotRenderingEngine.plotFont(preset: preset, size: size, bold: bold)
        }

        if axisConfig.showZeroLine {
            if yRange.lowerBound <= 0 && yRange.upperBound >= 0, ySpan > 0 {
                let zeroT = (0.0 - yRange.lowerBound) / ySpan
                let zeroY = plot.maxY - CGFloat(zeroT) * plot.height
                var zeroH = Path()
                zeroH.move(to: CGPoint(x: plot.minX, y: zeroY))
                zeroH.addLine(to: CGPoint(x: plot.maxX, y: zeroY))
                context.stroke(zeroH, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: spineWidth, dash: [4, 4]))
            }
            if xRange.lowerBound <= 0 && xRange.upperBound >= 0, xSpan > 0 {
                let zeroT = (0.0 - xRange.lowerBound) / xSpan
                let zeroX = plot.minX + CGFloat(zeroT) * plot.width
                var zeroV = Path()
                zeroV.move(to: CGPoint(x: zeroX, y: plot.minY))
                zeroV.addLine(to: CGPoint(x: zeroX, y: plot.maxY))
                context.stroke(zeroV, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: spineWidth, dash: [4, 4]))
            }
        }

        if axisConfig.showMajorGrid {
            for val in xNice.tickValues where xSpan > 0 {
                let t = (val - xRange.lowerBound) / xSpan
                guard t >= 0.001 && t <= 0.999 else { continue }
                let px = plot.minX + CGFloat(t) * plot.width
                var gridLine = Path()
                gridLine.move(to: CGPoint(x: px, y: plot.minY))
                gridLine.addLine(to: CGPoint(x: px, y: plot.maxY))
                context.stroke(gridLine, with: .color(.secondary.opacity(0.26)), style: StrokeStyle(lineWidth: 0.85, dash: [2, 3]))
            }
            for val in yNice.tickValues where ySpan > 0 {
                let t = (val - yRange.lowerBound) / ySpan
                guard t >= 0.001 && t <= 0.999 else { continue }
                let py = plot.maxY - CGFloat(t) * plot.height
                var gridLine = Path()
                gridLine.move(to: CGPoint(x: plot.minX, y: py))
                gridLine.addLine(to: CGPoint(x: plot.maxX, y: py))
                context.stroke(gridLine, with: .color(.secondary.opacity(0.26)), style: StrokeStyle(lineWidth: 0.85, dash: [2, 3]))
            }
        }

        let xSub = effectiveMinorSubdivisions(minorCount: axisConfig.xMinorTicks, showMinorGrid: axisConfig.showMinorGrid)
        if xSub > 1 && xSpan > 0 {
            let xMinors = AxisFormatter.minorTicks(
                majorTicks: xNice.tickValues,
                step: xNice.step,
                subdivisions: xSub,
                lower: xRegion.lowerBound,
                upper: xRegion.upperBound
            )
            for val in xMinors {
                let t = (val - xRange.lowerBound) / xSpan
                guard t >= -0.001 && t <= 1.001 else { continue }
                let px = plot.minX + CGFloat(t) * plot.width
                if axisConfig.xMinorTicks > 0 {
                    var minorTick = Path()
                    minorTick.move(to: CGPoint(x: px, y: plot.maxY))
                    minorTick.addLine(to: CGPoint(x: px, y: plot.maxY + tickLen * 0.55))
                    context.stroke(minorTick, with: .color(.primary), lineWidth: spineWidth * 0.8)
                }
                if axisConfig.showMinorGrid && t >= 0.001 && t <= 0.999 {
                    var mGrid = Path()
                    mGrid.move(to: CGPoint(x: px, y: plot.minY))
                    mGrid.addLine(to: CGPoint(x: px, y: plot.maxY))
                    context.stroke(mGrid, with: .color(.secondary.opacity(0.16)), style: StrokeStyle(lineWidth: 0.6, dash: [1, 2]))
                }
            }
        }

        let ySub = effectiveMinorSubdivisions(minorCount: axisConfig.yMinorTicks, showMinorGrid: axisConfig.showMinorGrid)
        if ySub > 1 && ySpan > 0 {
            let yMinors = AxisFormatter.minorTicks(
                majorTicks: yNice.tickValues,
                step: yNice.step,
                subdivisions: ySub,
                lower: yRegion.lowerBound,
                upper: yRegion.upperBound
            )
            for val in yMinors {
                let t = (val - yRange.lowerBound) / ySpan
                guard t >= -0.001 && t <= 1.001 else { continue }
                let py = plot.maxY - CGFloat(t) * plot.height
                if axisConfig.yMinorTicks > 0 {
                    var minorTick = Path()
                    minorTick.move(to: CGPoint(x: plot.minX, y: py))
                    minorTick.addLine(to: CGPoint(x: plot.minX - tickLen * 0.55, y: py))
                    context.stroke(minorTick, with: .color(.primary), lineWidth: spineWidth * 0.8)
                }
                if axisConfig.showMinorGrid && t >= 0.001 && t <= 0.999 {
                    var mGrid = Path()
                    mGrid.move(to: CGPoint(x: plot.minX, y: py))
                    mGrid.addLine(to: CGPoint(x: plot.maxX, y: py))
                    context.stroke(mGrid, with: .color(.secondary.opacity(0.16)), style: StrokeStyle(lineWidth: 0.6, dash: [1, 2]))
                }
            }
        }

        for val in xNice.tickValues where xSpan > 0 {
            let t = (val - xRange.lowerBound) / xSpan
            guard t >= -0.001 && t <= 1.001 else { continue }
            let px = plot.minX + CGFloat(t) * plot.width
            var xTick = Path()
            xTick.move(to: CGPoint(x: px, y: plot.maxY))
            xTick.addLine(to: CGPoint(x: px, y: plot.maxY + tickLen))
            context.stroke(xTick, with: .color(.primary), lineWidth: spineWidth)
            let label = formatLabel(val, xScale, xScaleInfo, xNice.precision)
            context.draw(Text(label).font(plotFont(tickLabelSize, false)), at: CGPoint(x: px, y: plot.maxY + tickLen + 3.0), anchor: .top)
        }

        for (idx, val) in yNice.tickValues.enumerated() where ySpan > 0 {
            let t = (val - yRange.lowerBound) / ySpan
            guard t >= -0.001 && t <= 1.001 else { continue }
            let py = plot.maxY - CGFloat(t) * plot.height
            var yTick = Path()
            yTick.move(to: CGPoint(x: plot.minX, y: py))
            yTick.addLine(to: CGPoint(x: plot.minX - tickLen, y: py))
            context.stroke(yTick, with: .color(.primary), lineWidth: spineWidth)
            let label = idx < yLabels.count ? yLabels[idx] : formatLabel(val, yScale, yScaleInfo, yNice.precision)
            context.draw(Text(label).font(plotFont(tickLabelSize, false)), at: CGPoint(x: plot.minX - tickLen - 3.0, y: py), anchor: .trailing)
        }

        let axisLabelSize = PlotRenderingEngine.axisLabelFontSize(preset: preset, fontScale: fontScale)
        context.draw(Text(xTitle).font(plotFont(axisLabelSize, false)), at: CGPoint(x: plot.midX, y: plot.maxY + tickLen + 3.0 + tickLabelSize + 6.0), anchor: .top)
        let yTitleX = max(14 * fontScale, plot.minX - tickLen - 3.0 - maxLabelWidth - (12 * fontScale))
        var yLabelContext = context
        yLabelContext.translateBy(x: yTitleX, y: plot.midY)
        yLabelContext.rotate(by: .degrees(-90))
        yLabelContext.draw(Text(yTitle).font(plotFont(axisLabelSize, false)), at: .zero, anchor: .center)

        if axisConfig.showCursor, let loc = hoverLocation, plot.contains(loc), xSpan > 0, ySpan > 0 {
            var hLine = Path()
            hLine.move(to: CGPoint(x: plot.minX, y: loc.y))
            hLine.addLine(to: CGPoint(x: plot.maxX, y: loc.y))
            context.stroke(hLine, with: .color(Color.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1.0, dash: [3, 3]))

            var vLine = Path()
            vLine.move(to: CGPoint(x: loc.x, y: plot.minY))
            vLine.addLine(to: CGPoint(x: loc.x, y: plot.maxY))
            context.stroke(vLine, with: .color(Color.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1.0, dash: [3, 3]))

            let tX = Double((loc.x - plot.minX) / plot.width)
            let tY = Double((plot.maxY - loc.y) / plot.height)
            let dataX = xRange.lowerBound + tX * xSpan
            let dataY = yRange.lowerBound + tY * ySpan

            let xStr = AxisFormatter.formatTick(dataX, factor: xScaleInfo.factor, precision: max(2, xNice.precision))
            let yStr = AxisFormatter.formatTick(dataY, factor: yScaleInfo.factor, precision: max(2, yNice.precision))
            let xUnitStr = xScaleInfo.displayUnit.isEmpty ? "" : " \(xScaleInfo.displayUnit)"
            let yUnitStr = yScaleInfo.displayUnit.isEmpty ? "" : " \(yScaleInfo.displayUnit)"
            let tooltipText = "X: \(xStr)\(xUnitStr)\nY: \(yStr)\(yUnitStr)"

            let tooltipFont = plotFont(max(9.5, 10.5 * fontScale), true)
            let tooltipPos = CGPoint(x: min(loc.x + 12, plot.maxX - 90), y: max(loc.y - 25, plot.minY + 20))
            context.draw(Text(tooltipText).font(tooltipFont).foregroundStyle(.primary), at: tooltipPos, anchor: .leading)
        }
    }
}

struct DraggableLegendView: View {
    let items: [(color: Color, label: String, markType: PlotMarkType)]
    var fontSize: CGFloat = 10.0
    var lineWidth: CGFloat = 1.4
    var markerSize: CGFloat = 4.5
    var legendScale: Double = 1.0
    var preset: ScientificPreset = .natureSingle
    @Binding var offset: CGSize
    @State private var dragStart: CGSize = .zero

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        legendGlyph(for: item)
                        Text(item.label)
                            .font(PlotRenderingEngine.plotFont(preset: preset, size: fontSize))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .offset(offset)
            .gesture(
                DragGesture()
                    .onChanged { gesture in
                        offset = CGSize(
                            width: dragStart.width + gesture.translation.width,
                            height: dragStart.height + gesture.translation.height
                        )
                    }
                    .onEnded { _ in
                        dragStart = offset
                    }
            )
            .help("Drag to reposition legend")
        }
    }

    @ViewBuilder
    private func legendGlyph(for item: (color: Color, label: String, markType: PlotMarkType)) -> some View {
        let scale = CGFloat(max(0.6, min(2.5, legendScale)))
        let strokeH = max(1.2, min(4.0, lineWidth * scale))
        let dotD = max(4.0, min(12.0, markerSize * scale))
        let lineW: CGFloat = 20.0 * scale
        Group {
            switch item.markType {
            case .line:
                Rectangle()
                    .fill(item.color)
                    .frame(width: lineW, height: strokeH)
            case .dots:
                Circle()
                    .fill(item.color)
                    .frame(width: dotD, height: dotD)
            case .lineAndDots:
                ZStack {
                    Rectangle()
                        .fill(item.color)
                        .frame(width: lineW, height: strokeH)
                    Circle()
                        .fill(item.color)
                        .frame(width: dotD, height: dotD)
                }
            }
        }
        .frame(width: lineW, height: max(strokeH, dotD))
    }
}

private enum PlotFailure: Error { case message(String) }

struct NativePlot: View {
    let measurement: NormalizedMeasurement
    let xAbsolute: Bool
    let yAbsolute: Bool
    let xScale: AxisScale
    let yScale: AxisScale
    var lineWidth: Double = 1.4
    var renderStyle: PlotRenderStyle = .line
    var markType: PlotMarkType = .line
    var interpolation: PlotInterpolation = .linear
    var markerSize: Double = 4.5
    var colorBySweepProgress: Bool = false
    var progressionFilterEnabled: Bool = false
    var selectedProgressionChannel: String? = nil
    var selectedCycles: Set<String> = []
    var colorByCycle: Bool = true
    var resetTrigger: Int = 0
    var preset: ScientificPreset = .natureSingle
    var showLegend: Bool = true
    var legendScale: Double = 1.0
    var customSeriesLabels: [String: String] = [:]
    var customSeriesColors: [String: Color] = [:]
    @Binding var legendOffset: CGSize
    var axisConfig: PlotAxisConfig = PlotAxisConfig()
    var onMetricsUpdate: ((PlotLiveMetrics) -> Void)? = nil
    @State private var hoverLocation: CGPoint? = nil
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    private func plotFont(size: CGFloat, bold: Bool = false) -> Font {
        PlotRenderingEngine.plotFont(preset: preset, size: size, bold: bold)
    }

    private var activeProgressionChannel: MeasurementChannel? {
        selectedProgressionChannel.flatMap(measurement.channel(named:)) ?? measurement.progressionChannel
    }

    private var isProgressionContinuous: Bool {
        activeProgressionChannel?.quantity == "time" && !(activeProgressionChannel?.name.lowercased().contains("scan") ?? false)
    }

    private func progressionSegments(data: ([Double?], [(String, [Double?])])) -> [ProgressionPlotSegment] {
        guard progressionFilterEnabled, let progChannel = activeProgressionChannel else { return [] }
        guard let firstSeriesY = data.1.first?.1 else { return [] }
        return ProgressionPlotReader.segments(
            x: data.0,
            y: firstSeriesY,
            progression: progChannel.values,
            isContinuous: isProgressionContinuous,
            selectedDiscreteKeys: selectedCycles
        )
    }

    private var transformed: Result<([Double?], [(String, [Double?])]), PlotFailure> {
        guard let xName = measurement.view.x, let yNames = measurement.view.y,
              let x = measurement.channel(named: xName) else { return .failure(.message("No plottable channels were declared")) }
        let yChannels = yNames.compactMap(measurement.channel(named:))
        guard yChannels.count == yNames.count else { return .failure(.message("A declared Y channel is missing")) }
        guard Set(yChannels.map(\.unit)).count <= 1 else {
            return .failure(.message("Selected Y channels use different units and cannot share one axis."))
        }
        switch AxisTransform.values(x.values, absolute: xAbsolute, scale: xScale) {
        case .failure(let message): return .failure(.message("X: \(message.message)"))
        case .success(let xs):
            var series: [(String, [Double?])] = []
            for name in yNames {
                guard let channel = measurement.channel(named: name) else { return .failure(.message("Y channel \(name) is missing")) }
                switch AxisTransform.values(channel.values, absolute: yAbsolute, scale: yScale) {
                case .failure(let message): return .failure(.message("\(channel.label): \(message.message)"))
                case .success(let ys): series.append((axisTitle(channel.label, unit: channel.unit, absolute: yAbsolute, scale: yScale), ys))
                }
            }
            return .success((xs, series))
        }
    }

    var body: some View {
        let headerFontScale = PlotRenderingEngine.fontScale(plotWidth: 500)
        switch transformed {
        case .failure(let failure):
            if case .message(let message) = failure { ContentUnavailableView("Invalid Plot Domain", systemImage: "chart.xyaxis.line", description: Text(message)) }
        case .success(let data):
            ZStack(alignment: .topTrailing) {
                Canvas { context, size in draw(data, in: &context, size: size) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if axisConfig.showCursor {
                            switch phase {
                            case .active(let loc): hoverLocation = loc
                            case .ended: hoverLocation = nil
                            }
                        } else {
                            hoverLocation = nil
                        }
                    }

                if isProgressionContinuous && colorBySweepProgress {
                    SweepColorbarView()
                        .padding(.leading, 64)
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                if showLegend {
                    let progSegments = progressionSegments(data: data)
                    let hasCustomLabel = data.1.first.flatMap { customSeriesLabels[$0.0] }?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    let hasProgressionSegmentation = progressionFilterEnabled && !progSegments.isEmpty
                    let isMultiSeries = data.1.count > 1

                    if isMultiSeries || hasCustomLabel || hasProgressionSegmentation {
                        let customColor = customSeriesColors[measurement.source.path]
                        let legendItems: [(color: Color, label: String, markType: PlotMarkType)] = {
                            if progressionFilterEnabled && !isProgressionContinuous && progSegments.count > 1 {
                                return progSegments.enumerated().map { segIndex, seg in
                                    let c = colorByCycle ? NativeOverlayPalette.color(segIndex) : (customColor ?? palette(0))
                                    return (c, "Cycle \(seg.name)", markType)
                                }
                            } else {
                                return data.1.enumerated().map { index, item in
                                    let custom = customSeriesLabels[item.0]?.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let name = (custom != nil && !custom!.isEmpty) ? custom! : item.0
                                    let c = (index == 0 ? customColor : nil) ?? palette(index)
                                    return (c, name, markType)
                                }
                            }
                        }()
                        DraggableLegendView(
                            items: legendItems,
                            fontSize: PlotRenderingEngine.legendFontSize(preset: preset, fontScale: headerFontScale, legendScale: legendScale),
                            lineWidth: CGFloat(lineWidth),
                            markerSize: CGFloat(markerSize),
                            legendScale: legendScale,
                            preset: preset,
                            offset: $legendOffset
                        )
                        .padding(.trailing, 28)
                        .padding(.top, 24)
                    }
                }
            }
            .onChange(of: resetTrigger) { _, _ in
                zoom = 1; pan = .zero
            }
        }
    }

    private func draw(_ data: ([Double?], [(String, [Double?])]), in context: inout GraphicsContext, size: CGSize) {
        let finiteX = data.0.compactMap { $0 }
        let finiteY = data.1.flatMap { $0.1.compactMap { $0 } }
        guard !finiteX.isEmpty, !finiteY.isEmpty else { return }

        let xChannel = measurement.channel(named: measurement.view.x ?? "")
        let yChannel = measurement.view.y?.first.flatMap(measurement.channel(named:))

        let xScaleInfo = AxisFormatter.scaleInfo(for: finiteX, baseUnit: xChannel?.unit ?? "")
        let yScaleInfo = AxisFormatter.scaleInfo(for: finiteY, baseUnit: yChannel?.unit ?? "")

        let xRawBounds = (lower: finiteX.min() ?? 0.0, upper: finiteX.max() ?? 1.0)
        let yRawBounds = (lower: finiteY.min() ?? 0.0, upper: finiteY.max() ?? 1.0)
        let xRegion = PlotAxisDrawHelper.dataRegion(bounds: xRawBounds, minOverride: axisConfig.xRegionMin, maxOverride: axisConfig.xRegionMax)
        let yRegion = PlotAxisDrawHelper.dataRegion(bounds: yRawBounds, minOverride: axisConfig.yRegionMin, maxOverride: axisConfig.yRegionMax)
        let xRange = PlotAxisDrawHelper.paddedViewport(xRegion, paddingPercent: axisConfig.xPaddingPercent)
        let yRange = PlotAxisDrawHelper.paddedViewport(yRegion, paddingPercent: axisConfig.yPaddingPercent)

        let yTickLo = axisConfig.yTickCount >= 2 ? yRegion.lowerBound : yRange.lowerBound
        let yTickHi = axisConfig.yTickCount >= 2 ? yRegion.upperBound : yRange.upperBound
        let yNice = AxisFormatter.ticks(lower: yTickLo, upper: yTickHi, factor: yScaleInfo.factor, requestedCount: axisConfig.yTickCount)
        let yLabels: [String] = yNice.tickValues.map { val in
            axisLabel(val, scale: yScale, scaleInfo: yScaleInfo, precision: yNice.precision)
        }
        let targetRatio: CGFloat = CGFloat(preset.aspectRatio)
        let approxPlotWidth = max(200, size.width - 120)
        let fontScale = PlotRenderingEngine.fontScale(plotWidth: approxPlotWidth)

        let maxChars = yLabels.map(\.count).max() ?? 1
        let maxLabelWidth = max(34 * fontScale, CGFloat(maxChars) * 8.0 * fontScale)
        let leftGutter = max(84 * fontScale, maxLabelWidth + 30 * fontScale)
        let topGutter: CGFloat = 20 * fontScale
        let bottomGutter: CGFloat = 54 * fontScale
        let rightGutter: CGFloat = 22 * fontScale

        let availWidth = max(10, size.width - leftGutter - rightGutter)
        let availHeight = max(10, size.height - topGutter - bottomGutter)
        var plotW = availWidth
        var plotH = plotW / targetRatio
        if plotH > availHeight {
            plotH = availHeight
            plotW = plotH * targetRatio
        }
        let plotX = leftGutter + (availWidth - plotW) / 2
        let plotY = topGutter + (availHeight - plotH) / 2
        let plot = CGRect(x: plotX, y: plotY, width: max(1, plotW), height: max(1, plotH))

        PlotRenderingEngine.drawSpineFrame(plot: plot, preset: preset, in: &context)

        let xTickLo = axisConfig.xTickCount >= 2 ? xRegion.lowerBound : xRange.lowerBound
        let xTickHi = axisConfig.xTickCount >= 2 ? xRegion.upperBound : xRange.upperBound
        let xNice = AxisFormatter.ticks(lower: xTickLo, upper: xTickHi, factor: xScaleInfo.factor, requestedCount: axisConfig.xTickCount)

        if let onMetricsUpdate {
            let latest = PlotLiveMetrics(
                xRange: xRegion,
                yRange: yRegion,
                xTickCount: xNice.tickValues.count,
                yTickCount: yNice.tickValues.count
            )
            DispatchQueue.main.async { onMetricsUpdate(latest) }
        }

        let xTitle = axisTitle(xChannel?.label ?? "X", unit: xScaleInfo.displayUnit, absolute: xAbsolute, scale: xScale)
        let yTitle = axisTitle(yChannel?.label ?? "Y", unit: yScaleInfo.displayUnit, absolute: yAbsolute, scale: yScale)

        PlotAxisDrawHelper.drawGridTicksAndCursor(
            context: &context,
            plot: plot,
            xRange: xRange,
            yRange: yRange,
            xRegion: xRegion,
            yRegion: yRegion,
            xNice: xNice,
            yNice: yNice,
            xScaleInfo: xScaleInfo,
            yScaleInfo: yScaleInfo,
            xScale: xScale,
            yScale: yScale,
            xTitle: xTitle,
            yTitle: yTitle,
            axisConfig: axisConfig,
            preset: preset,
            fontScale: fontScale,
            maxLabelWidth: maxLabelWidth,
            yLabels: yLabels,
            hoverLocation: hoverLocation,
            formatLabel: { val, scale, info, prec in axisLabel(val, scale: scale, scaleInfo: info, precision: prec) }
        )

        var plotContext = context
        let clipRect = PlotAxisDrawHelper.curveClipRect(
            plot: plot,
            xRegion: xRegion,
            yRegion: yRegion,
            xViewport: xRange,
            yViewport: yRange,
            clipToXRegion: axisConfig.xRegionMin != nil || axisConfig.xRegionMax != nil,
            clipToYRegion: axisConfig.yRegionMin != nil || axisConfig.yRegionMax != nil
        )
        plotContext.clip(to: Path(clipRect))
        let customColor = customSeriesColors[measurement.source.path]
        for (seriesIndex, item) in data.1.enumerated() {
            guard item.1.count == data.0.count else { continue }
            let color = (seriesIndex == 0 ? customColor : nil) ?? palette(seriesIndex)

            let progChannel = selectedProgressionChannel.flatMap(measurement.channel(named:)) ?? measurement.progressionChannel
            let isContinuous = progChannel?.quantity == "time" && !(progChannel?.name.lowercased().contains("scan") ?? false)
            let progSegments = (progressionFilterEnabled && progChannel != nil)
                ? ProgressionPlotReader.segments(
                    x: data.0,
                    y: item.1,
                    progression: progChannel?.values,
                    isContinuous: isContinuous,
                    selectedDiscreteKeys: selectedCycles
                  )
                : []

            if !progSegments.isEmpty {
                for (segIndex, seg) in progSegments.enumerated() {
                    var runPoints: [CGPoint] = []
                    for pt in seg.points {
                        let tx = (pt.0 - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
                        let ty = (pt.1 - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
                        runPoints.append(CGPoint(x: plot.minX + tx * plot.width, y: plot.maxY - ty * plot.height))
                    }
                    let segColor: Color = {
                        if colorByCycle && progSegments.count > 1 {
                            if isContinuous {
                                let t = Double(segIndex) / Double(max(1, progSegments.count - 1))
                                return PlotRenderingEngine.sweepColor(at: t)
                            } else {
                                return NativeOverlayPalette.color(segIndex)
                            }
                        } else {
                            return color
                        }
                    }()
                    PlotRenderingEngine.renderRun(
                        points: runPoints,
                        mark: markType,
                        interpolation: interpolation,
                        color: segColor,
                        lineWidth: lineWidth,
                        markerSize: markerSize,
                        colorBySweepProgress: false,
                        in: &plotContext
                    )
                }
            } else {
                // Gap segmentation: a nil x or y breaks the line; rows stay in order.
                for run in AxisTransform.segments(x: data.0, y: item.1) {
                    var runPoints: [CGPoint] = []
                    for index in run {
                        guard let xv = data.0[index], let yv = item.1[index] else { continue }
                        let tx = (xv - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
                        let ty = (yv - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
                        runPoints.append(CGPoint(x: plot.minX + tx * plot.width, y: plot.maxY - ty * plot.height))
                    }
                    PlotRenderingEngine.renderRun(
                        points: runPoints,
                        mark: markType,
                        interpolation: interpolation,
                        color: color,
                        lineWidth: lineWidth,
                        markerSize: markerSize,
                        colorBySweepProgress: colorBySweepProgress,
                        in: &plotContext
                    )
                }
            }
        }
    }

    private func gapCount(_ data: ([Double?], [(String, [Double?])])) -> Int {
        data.0.filter({ $0 == nil }).count + data.1.reduce(0) { $0 + $1.1.filter({ $0 == nil }).count }
    }

    private func expanded(_ values: [Double]) -> ClosedRange<Double> {
        let lo = values.min() ?? 0; let hi = values.max() ?? 1
        let delta = hi == lo ? max(abs(lo) * 0.05, 1) : (hi - lo) * 0.04
        return (lo - delta)...(hi + delta)
    }
    private func viewport(_ range: ClosedRange<Double>, pan: CGFloat, dimension: CGFloat, vertical: Bool) -> ClosedRange<Double> {
        let span = (range.upperBound - range.lowerBound) / zoom
        let signedPan = Double(pan / max(1, dimension)) * span * (vertical ? 1 : -1)
        let center = (range.lowerBound + range.upperBound) / 2 + signedPan
        return (center - span / 2)...(center + span / 2)
    }
    private func axisTitle(_ label: String, unit: String, absolute: Bool, scale: AxisScale) -> String {
        let physical = label + (unit.isEmpty ? "" : " (\(unit))")
        let magnitude = absolute ? "|\(physical)|" : physical
        return scale == .logarithmic ? "log₁₀(\(magnitude))" : magnitude
    }
    private func axisLabel(_ value: Double, scale: AxisScale, scaleInfo: AxisFormatter.ScaleInfo, precision: Int? = nil, span: Double = 1.0) -> String {
        if scale == .logarithmic {
            return "10^\(AxisFormatter.formatTick(value, factor: 1.0, precision: 1))"
        }
        let prec: Int = precision ?? {
            let scaledSpan = span / (scaleInfo.factor != 0 ? scaleInfo.factor : 1.0)
            if scaledSpan < 0.05 { return 3 }
            if scaledSpan < 0.5 { return 2 }
            return 1
        }()
        return AxisFormatter.formatTick(value, factor: scaleInfo.factor, precision: prec)
    }
    private func palette(_ index: Int) -> Color {
        NativeOverlayPalette.color(index)
    }
}

private enum OverlayPlotFailure: Error { case message(String) }

/// Multi-source overlay: every visible measurement draws its full arrays in
/// acquisition order. No sorting, interpolation, or transforms; visibility
/// only changes presentation.
struct OverlayPlot: View {
    let measurements: [NormalizedMeasurement]
    let selectedSourceIDs: Set<String>
    let focused: NormalizedMeasurement?
    var lineWidth: Double = 1.4
    var renderStyle: PlotRenderStyle = .line
    var markType: PlotMarkType = .line
    var interpolation: PlotInterpolation = .linear
    var markerSize: Double = 4.5
    var colorBySweepProgress: Bool = false
    let xAbsolute: Bool
    let yAbsolute: Bool
    let xScale: AxisScale
    let yScale: AxisScale
    var comparisonTitle: String = ""
    var preset: ScientificPreset = .natureSingle
    var showLegend: Bool = true
    var legendScale: Double = 1.0
    var customSeriesLabels: [String: String] = [:]
    var customSeriesColors: [String: Color] = [:]
    var orderedSourceIDs: [String] = []
    var resetTrigger: Int = 0
    @Binding var legendOffset: CGSize
    var axisConfig: PlotAxisConfig = PlotAxisConfig()
    var onMetricsUpdate: ((PlotLiveMetrics) -> Void)? = nil
    @State private var hoverLocation: CGPoint? = nil
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    private func plotFont(size: CGFloat, bold: Bool = false) -> Font {
        PlotRenderingEngine.plotFont(preset: preset, size: size, bold: bold)
    }

    private struct Series: Identifiable {
        let sourcePath: String
        let label: String
        let x: [Double?]
        let y: [Double?]
        var id: String { sourcePath + "|" + label }
    }

    private var effectiveOrder: [String] {
        let fallback = selectedSourceIDs.sorted()
        guard !orderedSourceIDs.isEmpty else { return fallback }
        let kept = orderedSourceIDs.filter { selectedSourceIDs.contains($0) }
        let missing = fallback.filter { !kept.contains($0) }
        return kept + missing
    }

    private var transformed: Result<(xChannel: (label: String, unit: String), yChannel: (label: String, unit: String), series: [Series]), OverlayPlotFailure> {
        guard !measurements.isEmpty else { return .failure(.message("No measurements selected")) }
        var series: [Series] = []
        var xChannelInfo = ("", "")
        var yChannelInfo = ("", "")
        var first = true
        let order = effectiveOrder
        let sortedMeasurements = measurements.sorted { a, b in
            let ia = order.firstIndex(of: a.source.path) ?? Int.max
            let ib = order.firstIndex(of: b.source.path) ?? Int.max
            return ia != ib ? ia < ib : a.source.path < b.source.path
        }
        let basenames = sortedMeasurements.reduce(into: [String: Int]()) { counts, item in
            counts[URL(fileURLWithPath: item.source.path).lastPathComponent, default: 0] += 1
        }
        for measurement in sortedMeasurements {
            guard let xName = measurement.view.x, let yNames = measurement.view.y,
                  let xChannel = measurement.channel(named: xName) else {
                return .failure(.message("Source \(measurement.source.path) has no plottable channels"))
            }
            let yChannels = yNames.compactMap { measurement.channel(named: $0) }
            guard yChannels.count == yNames.count else {
                return .failure(.message("Source \(measurement.source.path) is missing a Y channel"))
            }
            if let error = transformError(xChannel.values, absolute: xAbsolute, scale: xScale) {
                return .failure(.message("\(measurement.source.path) X: \(error.message)"))
            }
            if first {
                xChannelInfo = (xChannel.label, xChannel.unit)
                if let y0 = yChannels.first {
                    yChannelInfo = (y0.label, y0.unit)
                }
                first = false
            }
            for yChannel in yChannels {
                guard xChannel.values.count == yChannel.values.count else {
                    return .failure(.message("\(measurement.source.path) X and \(yChannel.label) have different row counts."))
                }
                if let error = transformError(yChannel.values, absolute: yAbsolute, scale: yScale) {
                    return .failure(.message("\(measurement.source.path) \(yChannel.label): \(error.message)"))
                }
                let base = URL(fileURLWithPath: measurement.source.path).lastPathComponent
                let sourceLabel = basenames[base, default: 0] > 1 ? measurement.source.path : base
                let label = yNames.count > 1 ? "\(sourceLabel) · \(yChannel.label)" : sourceLabel
                series.append(Series(sourcePath: measurement.source.path, label: label,
                                     x: xChannel.values, y: yChannel.values))
            }
        }
        return .success((xChannelInfo, yChannelInfo, series))
    }

    var body: some View {
        let headerFontScale = PlotRenderingEngine.fontScale(plotWidth: 500)
        switch transformed {
        case .failure(let failure):
            if case .message(let message) = failure {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Comparison blocked", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("\(message) The focused source remains shown.")
                        .font(.caption).textSelection(.enabled)
                    if let focused {
                        NativePlot(measurement: focused, xAbsolute: xAbsolute,
                                   yAbsolute: yAbsolute, xScale: xScale,
                                   yScale: yScale, lineWidth: lineWidth,
                                   renderStyle: renderStyle,
                                   markType: markType, interpolation: interpolation,
                                   markerSize: markerSize,
                                   colorBySweepProgress: colorBySweepProgress,
                                   resetTrigger: resetTrigger,
                                   preset: preset,
                                   showLegend: showLegend,
                                   legendScale: legendScale,
                                   customSeriesLabels: customSeriesLabels,
                                   customSeriesColors: customSeriesColors,
                                   legendOffset: $legendOffset,
                                   axisConfig: axisConfig,
                                   onMetricsUpdate: onMetricsUpdate)
                    }
                }
            }
        case .success(let data):
            let sourceOrder = effectiveOrder
            let accessibleSummary = data.series.map {
                "\($0.label): \($0.x.count) points, \(gapCount($0)) gaps"
            }.joined(separator: ". ")
            ZStack(alignment: .topTrailing) {
                Canvas { context, size in
                    draw(data.series, xLabel: data.xChannel.label, xUnit: data.xChannel.unit, yLabel: data.yChannel.label, yUnit: data.yChannel.unit, in: &context, size: size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if axisConfig.showCursor {
                        switch phase {
                        case .active(let loc): hoverLocation = loc
                        case .ended: hoverLocation = nil
                        }
                    } else {
                        hoverLocation = nil
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Overlay plot with \(data.series.count) series")
                .accessibilityValue(accessibleSummary)

                if colorBySweepProgress {
                    SweepColorbarView()
                        .padding(.leading, 64)
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                if showLegend {
                    let legendItems: [(color: Color, label: String, markType: PlotMarkType)] = data.series.map { item in
                        let custom = customSeriesLabels[item.sourcePath]?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = (custom != nil && !custom!.isEmpty) ? custom! : item.label
                        let color = customSeriesColors[item.sourcePath] ?? palette(item.sourcePath, order: sourceOrder)
                        return (color, name, markType)
                    }
                    DraggableLegendView(
                        items: legendItems,
                        fontSize: PlotRenderingEngine.legendFontSize(preset: preset, fontScale: headerFontScale, legendScale: legendScale),
                        lineWidth: CGFloat(lineWidth),
                        markerSize: CGFloat(markerSize),
                        legendScale: legendScale,
                        preset: preset,
                        offset: $legendOffset
                    )
                    .padding(.trailing, 28)
                    .padding(.top, 24)
                }
            }
            .onChange(of: resetTrigger) { _, _ in
                zoom = 1; pan = .zero
            }
        }
    }

    private func draw(_ series: [Series], xLabel: String, xUnit: String, yLabel: String, yUnit: String, in context: inout GraphicsContext, size: CGSize) {
        guard let xBounds = extrema(series, isX: true), let yBounds = extrema(series, isX: false) else { return }

        let allX = series.flatMap { $0.x.compactMap { $0 } }
        let allY = series.flatMap { $0.y.compactMap { $0 } }
        let xScaleInfo = AxisFormatter.scaleInfo(for: allX, baseUnit: xUnit)
        let yScaleInfo = AxisFormatter.scaleInfo(for: allY, baseUnit: yUnit)

        let xRegion = PlotAxisDrawHelper.dataRegion(bounds: xBounds, minOverride: axisConfig.xRegionMin, maxOverride: axisConfig.xRegionMax)
        let yRegion = PlotAxisDrawHelper.dataRegion(bounds: yBounds, minOverride: axisConfig.yRegionMin, maxOverride: axisConfig.yRegionMax)
        let xRange = PlotAxisDrawHelper.paddedViewport(xRegion, paddingPercent: axisConfig.xPaddingPercent)
        let yRange = PlotAxisDrawHelper.paddedViewport(yRegion, paddingPercent: axisConfig.yPaddingPercent)

        let yTickLo = axisConfig.yTickCount >= 2 ? yRegion.lowerBound : yRange.lowerBound
        let yTickHi = axisConfig.yTickCount >= 2 ? yRegion.upperBound : yRange.upperBound
        let yNice = AxisFormatter.ticks(lower: yTickLo, upper: yTickHi, factor: yScaleInfo.factor, requestedCount: axisConfig.yTickCount)
        let yLabels: [String] = yNice.tickValues.map { val in
            axisLabel(val, scale: yScale, scaleInfo: yScaleInfo, precision: yNice.precision)
        }
        let targetRatio: CGFloat = CGFloat(preset.aspectRatio)
        let approxPlotWidth = max(200, size.width - 120)
        let fontScale = PlotRenderingEngine.fontScale(plotWidth: approxPlotWidth)

        let maxChars = yLabels.map(\.count).max() ?? 1
        let maxLabelWidth = max(34 * fontScale, CGFloat(maxChars) * 8.0 * fontScale)
        let leftGutter = max(84 * fontScale, maxLabelWidth + 30 * fontScale)
        let topGutter: CGFloat = 20 * fontScale
        let bottomGutter: CGFloat = 54 * fontScale
        let rightGutter: CGFloat = 22 * fontScale

        let availWidth = max(10, size.width - leftGutter - rightGutter)
        let availHeight = max(10, size.height - topGutter - bottomGutter)
        var plotW = availWidth
        var plotH = plotW / targetRatio
        if plotH > availHeight {
            plotH = availHeight
            plotW = plotH * targetRatio
        }
        let plotX = leftGutter + (availWidth - plotW) / 2
        let plotY = topGutter + (availHeight - plotH) / 2
        let plot = CGRect(x: plotX, y: plotY, width: max(1, plotW), height: max(1, plotH))

        PlotRenderingEngine.drawSpineFrame(plot: plot, preset: preset, in: &context)

        let xTickLo = axisConfig.xTickCount >= 2 ? xRegion.lowerBound : xRange.lowerBound
        let xTickHi = axisConfig.xTickCount >= 2 ? xRegion.upperBound : xRange.upperBound
        let xNice = AxisFormatter.ticks(lower: xTickLo, upper: xTickHi, factor: xScaleInfo.factor, requestedCount: axisConfig.xTickCount)

        if let onMetricsUpdate {
            let latest = PlotLiveMetrics(
                xRange: xRegion,
                yRange: yRegion,
                xTickCount: xNice.tickValues.count,
                yTickCount: yNice.tickValues.count
            )
            DispatchQueue.main.async { onMetricsUpdate(latest) }
        }

        let xTitle = axisTitle(xLabel, unit: xScaleInfo.displayUnit, absolute: xAbsolute, scale: xScale)
        let yTitle = axisTitle(yLabel, unit: yScaleInfo.displayUnit, absolute: yAbsolute, scale: yScale)

        PlotAxisDrawHelper.drawGridTicksAndCursor(
            context: &context,
            plot: plot,
            xRange: xRange,
            yRange: yRange,
            xRegion: xRegion,
            yRegion: yRegion,
            xNice: xNice,
            yNice: yNice,
            xScaleInfo: xScaleInfo,
            yScaleInfo: yScaleInfo,
            xScale: xScale,
            yScale: yScale,
            xTitle: xTitle,
            yTitle: yTitle,
            axisConfig: axisConfig,
            preset: preset,
            fontScale: fontScale,
            maxLabelWidth: maxLabelWidth,
            yLabels: yLabels,
            hoverLocation: hoverLocation,
            formatLabel: { val, scale, info, prec in axisLabel(val, scale: scale, scaleInfo: info, precision: prec) }
        )

        var plotContext = context
        let clipRect = PlotAxisDrawHelper.curveClipRect(
            plot: plot,
            xRegion: xRegion,
            yRegion: yRegion,
            xViewport: xRange,
            yViewport: yRange,
            clipToXRegion: axisConfig.xRegionMin != nil || axisConfig.xRegionMax != nil,
            clipToYRegion: axisConfig.yRegionMin != nil || axisConfig.yRegionMax != nil
        )
        plotContext.clip(to: Path(clipRect))
        let sourceOrder = effectiveOrder
        for item in series {
            let color = customSeriesColors[item.sourcePath] ?? palette(item.sourcePath, order: sourceOrder)
            var currentRun: [CGPoint] = []
            for index in item.x.indices {
                guard index < item.y.count, let rawX = item.x[index], let rawY = item.y[index] else {
                    if !currentRun.isEmpty {
                        PlotRenderingEngine.renderRun(
                            points: currentRun,
                            mark: markType,
                            interpolation: interpolation,
                            color: color,
                            lineWidth: lineWidth,
                            markerSize: markerSize,
                            colorBySweepProgress: colorBySweepProgress,
                            in: &plotContext
                        )
                        currentRun.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                let x = transformedValue(rawX, absolute: xAbsolute, scale: xScale)
                let y = transformedValue(rawY, absolute: yAbsolute, scale: yScale)
                let tx = (x - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
                let ty = (y - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
                currentRun.append(CGPoint(x: plot.minX + tx * plot.width, y: plot.maxY - ty * plot.height))
            }
            if !currentRun.isEmpty {
                PlotRenderingEngine.renderRun(
                    points: currentRun,
                    mark: markType,
                    interpolation: interpolation,
                    color: color,
                    lineWidth: lineWidth,
                    markerSize: markerSize,
                    colorBySweepProgress: colorBySweepProgress,
                    in: &plotContext
                )
            }
        }
    }

    private func pointCount(_ series: [Series]) -> Int { series.reduce(0) { $0 + $1.x.count } }
    private func gapCount(_ item: Series) -> Int {
        item.x.indices.reduce(0) { count, index in
            count + ((item.x[index] == nil || index >= item.y.count || item.y[index] == nil) ? 1 : 0)
        }
    }
    private func gapCount(_ series: [Series]) -> Int { series.reduce(0) { $0 + gapCount($1) } }
    private func transformError(_ values: [Double?], absolute: Bool, scale: AxisScale) -> AxisTransformError? {
        for sample in values {
            guard let sample else { continue }
            let value = absolute ? abs(sample) : sample
            if !value.isFinite { return .nonFinite }
            if scale == .logarithmic && value <= 0 { return .invalidLogDomain }
        }
        return nil
    }
    private func transformedValue(_ value: Double, absolute: Bool, scale: AxisScale) -> Double {
        let magnitude = absolute ? abs(value) : value
        return scale == .logarithmic ? log10(magnitude) : magnitude
    }
    private func extrema(_ series: [Series], isX: Bool) -> (lower: Double, upper: Double)? {
        var lower = Double.infinity
        var upper = -Double.infinity
        for item in series {
            let values = isX ? item.x : item.y
            let absolute = isX ? xAbsolute : yAbsolute
            let scale = isX ? xScale : yScale
            for sample in values {
                guard let sample else { continue }
                let value = transformedValue(sample, absolute: absolute, scale: scale)
                lower = min(lower, value)
                upper = max(upper, value)
            }
        }
        return lower.isFinite && upper.isFinite ? (lower, upper) : nil
    }
    private func expanded(_ bounds: (lower: Double, upper: Double)) -> ClosedRange<Double> {
        let lo = bounds.lower; let hi = bounds.upper
        let delta = hi == lo ? max(abs(lo) * 0.05, 1) : (hi - lo) * 0.04
        return (lo - delta)...(hi + delta)
    }
    private func viewport(_ range: ClosedRange<Double>, pan: CGFloat, dimension: CGFloat, vertical: Bool) -> ClosedRange<Double> {
        let span = (range.upperBound - range.lowerBound) / zoom
        let signedPan = Double(pan / max(1, dimension)) * span * (vertical ? 1 : -1)
        let center = (range.lowerBound + range.upperBound) / 2 + signedPan
        return (center - span / 2)...(center + span / 2)
    }
    private func axisTitle(_ label: String, unit: String, absolute: Bool, scale: AxisScale) -> String {
        let physical = label + (unit.isEmpty ? "" : " (\(unit))")
        let magnitude = absolute ? "|\(physical)|" : physical
        return scale == .logarithmic ? "log₁₀(\(magnitude))" : magnitude
    }
    private func axisLabel(_ value: Double, scale: AxisScale, scaleInfo: AxisFormatter.ScaleInfo, precision: Int? = nil, span: Double = 1.0) -> String {
        if scale == .logarithmic {
            return "10^\(AxisFormatter.formatTick(value, factor: 1.0, precision: 1))"
        }
        let prec: Int = precision ?? {
            let scaledSpan = span / (scaleInfo.factor != 0 ? scaleInfo.factor : 1.0)
            if scaledSpan < 0.05 { return 3 }
            if scaledSpan < 0.5 { return 2 }
            return 1
        }()
        return AxisFormatter.formatTick(value, factor: scaleInfo.factor, precision: prec)
    }
    private func palette(_ sourcePath: String, order: [String]) -> Color {
        NativeOverlayPalette.color(order.firstIndex(of: sourcePath) ?? 0)
    }
}

struct MeasurementTable: View {
    let measurement: NormalizedMeasurement
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var allRows: [Int] { Array(0..<(measurement.channels.first?.values.count ?? 0)) }

    private var filteredRows: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allRows }
        return allRows.filter { rowIndex in
            if String(rowIndex).contains(query) { return true }
            for channel in measurement.channels {
                if channel.text(at: rowIndex).lowercased().contains(query) {
                    return true
                }
            }
            return false
        }
    }

    var body: some View {
        if measurement.channels.isEmpty {
            ContentUnavailableView("Metadata Only", systemImage: "tablecells", description: Text("This source has no normalized numeric channels."))
        } else {
            VStack(spacing: 0) {
                searchBar
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        rowHeader
                        ForEach(filteredRows, id: \.self) { index in
                            HStack(spacing: 0) {
                                cell(String(index), width: 64)
                                ForEach(measurement.channels) { channel in
                                    cell(channel.text(at: index), width: 150)
                                }
                            }
                            .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
                        }
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search data (⌘F)…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !searchText.isEmpty {
                Text("\(filteredRows.count) of \(allRows.count) rows")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("\(allRows.count) rows")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
        .overlay {
            Button("") {
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private var rowHeader: some View {
        HStack(spacing: 0) {
            cell("Index", width: 64, header: true)
            ForEach(measurement.channels) { channel in
                cell(channel.label + (channel.unit.isEmpty ? "" : " (\(channel.unit))"), width: 150, header: true)
            }
        }.background(.bar)
    }
    private func cell(_ text: String, width: CGFloat, header: Bool = false) -> some View {
        Text(text).font(header ? .caption.bold() : .system(.caption, design: .monospaced))
            .lineLimit(1).frame(width: width, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
    }
}

struct ProjectGallery: View {
    let sources: [RawSource]
    let states: [String: GallerySourceState]
    @Binding var focusedSourceID: String?
    let selectedIDs: Set<String>
    let hidden: Set<String>
    let lineWidth: Double
    var renderStyle: PlotRenderStyle = .line
    var markType: PlotMarkType = .line
    var interpolation: PlotInterpolation = .linear
    var markerSize: Double = 4.5
    var colorBySweepProgress: Bool = false
    var progressionFilterEnabled: Bool = false
    var selectedProgressionChannel: String? = nil
    var selectedCycles: Set<String> = []
    var colorByCycle: Bool = true
    let overlay: OverlayEligibility?
    @Binding var tab: String
    @Binding var xAbsolute: Bool
    @Binding var yAbsolute: Bool
    @Binding var xScale: AxisScale
    @Binding var yScale: AxisScale
    @Binding var showInspector: Bool
    var isLoading: Bool = false
    var loadingStatus: String? = nil
    let retry: () -> Void
    var snapshots: [PlotSnapshot] = []
    var activeSnapshotID: UUID? = nil
    var onSaveSnapshot: (() -> Void)? = nil
    var onSelectSnapshot: ((PlotSnapshot) -> Void)? = nil
    var onToggleSnapshot: ((PlotSnapshot) -> Void)? = nil
    var onDeleteSnapshot: ((PlotSnapshot) -> Void)? = nil
    var onExportFigure: (() -> Void)? = nil
    var onExportData: (() -> Void)? = nil
    var onSaveSnapshotPackage: (() -> Void)? = nil
    var projectSnapshotPackages: [RawViewModel.ProjectSnapshotPackage] = []
    var onSelectSnapshotPackage: ((RawViewModel.ProjectSnapshotPackage) -> Void)? = nil
    var comparisonTitle: String = ""
    var availablePresets: [ScientificPreset] = ScientificPreset.allCases
    @Binding var selectedPreset: ScientificPreset
    @Binding var showLegend: Bool
    @Binding var legendScale: Double
    var customSeriesLabels: [String: String] = [:]
    var customSeriesColors: [String: Color] = [:]
    var orderedSourceIDs: [String] = []
    @Binding var legendOffset: CGSize
    var axisConfig: PlotAxisConfig = PlotAxisConfig()
    @Binding var liveMetrics: PlotLiveMetrics
    var snapshotDPI: Int = 300
    @State private var plotResetTrigger: Int = 0
    @ObservedObject private var updateChecker = AppUpdateChecker.shared

    var customProjectPresets: [ScientificPreset] {
        availablePresets.filter { p in
            !ScientificPreset.allCases.contains(where: { $0.id == p.id })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("View", selection: $tab) {
                    Text("Plot").tag("Plot")
                    Text("Data").tag("Data")
                }
                .pickerStyle(.segmented).frame(width: 150)
                .accessibilityLabel("Plot or Data view")

                Divider().frame(height: 16)

                presetMenu

                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        if let loadingStatus {
                            Text(loadingStatus)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if selectedIDs.count >= 2 {
                    Text("\(selectedIDs.count) selected\(overlayLabel)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel("Selection comparison status")
                }

                Spacer()

                // Actions Group (Right Side)
                if updateChecker.updateAvailable {
                    Button {
                        Task {
                            await updateChecker.applyUpdateAndRestart()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            Text("Update & Restart (\(updateChecker.latestVersion))")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Download \(updateChecker.latestVersion) and restart RawView automatically")
                }

                snapshotMenu

                exportMenu

                Button {
                    plotResetTrigger += 1
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Reset plot zoom and pan")

                Button {
                    showInspector.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sidebar.right")
                            .foregroundStyle(showInspector ? .primary : .secondary)
                        ShortcutBadge("toggleInspector")
                    }
                }
                .buttonStyle(.borderless)
                .help("Toggle Inspector (⌘I)")
                .keyboardShortcut("i", modifiers: .command)
                .accessibilityLabel("Toggle Inspector")
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                if let source = sources.first(where: { $0.id == focusedSourceID }) {
                    Text(source.url.lastPathComponent).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([source.url])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    Spacer()
                    if let sha = states[source.id]?.measurement?.source.sha256 {
                        Text("Loaded · SHA-256 of parsed bytes \(String(sha.prefix(12)))…")
                    }
                }
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
    }

    private var overlayLabel: String {
        switch overlay {
        case .eligible(let path): " · shared \(URL(fileURLWithPath: path).lastPathComponent)"
        case .partial(let group): " · focused cohort \(group.plottedPaths.count) of \(group.plottedPaths.count + group.excluded.count)"
        case .blocked: " · comparison blocked"
        case nil: ""
        }
    }

    private func exclusionSummary(_ group: FocusedOverlayGroup) -> String {
        let names = group.excluded.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: ", ")
        let prefix = (group.manifestPath.isEmpty || group.manifestPath == "Comparison") ? "Compatible cohort" : "Shared \(URL(fileURLWithPath: group.manifestPath).lastPathComponent)"
        return "\(prefix): plotting the focused cohort (\(group.plottedPaths.count) of \(group.plottedPaths.count + group.excluded.count)); excluded \(names). See the inspector for reasons. Selection unchanged."
    }

    // MARK: - Top Bar Menus

    private var presetMenu: some View {
        Menu {
            if !customProjectPresets.isEmpty {
                Section("Project Presets (.rawviewer/preset)") {
                    ForEach(customProjectPresets) { p in
                        Button {
                            selectedPreset = p
                        } label: {
                            if selectedPreset.id == p.id {
                                Label(p.displayName, systemImage: "checkmark")
                            } else {
                                Text(p.displayName)
                            }
                        }
                    }
                }
            }

            Section("Standard Journals (Closed 4-Box)") {
                ForEach(ScientificPreset.standardPresets) { p in
                    Button {
                        selectedPreset = p
                    } label: {
                        if selectedPreset.id == p.id {
                            Label(p.displayName, systemImage: "checkmark")
                        } else {
                            Text(p.displayName)
                        }
                    }
                }
            }

            Section("Open L-Frames (2-Axis)") {
                ForEach(ScientificPreset.openFramePresets) { p in
                    Button {
                        selectedPreset = p
                    } label: {
                        if selectedPreset.id == p.id {
                            Label(p.displayName, systemImage: "checkmark")
                        } else {
                            Text(p.displayName)
                        }
                    }
                }
            }
        } label: {
            Label(selectedPreset.displayName, systemImage: "doc.richtext")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .help("Select scientific publication preset")
    }

    private var snapshotMenu: some View {
        Menu {
            Button {
                onSaveSnapshot?()
            } label: {
                Label("Save Current View as Memory Snapshot", systemImage: "camera.badge.ellipsis")
            }
            .disabled(selectedIDs.isEmpty && focusedSourceID == nil)

            Button {
                onSaveSnapshotPackage?()
            } label: {
                Label("Save Snapshot Package (data/snapshot/…)", systemImage: "shippingbox")
            }
            .disabled(selectedIDs.isEmpty && focusedSourceID == nil)

            if !snapshots.isEmpty {
                Divider()
                ForEach(snapshots) { snap in
                    let isActive = activeSnapshotID == snap.id
                    Button {
                        if isActive {
                            onToggleSnapshot?(snap)
                        } else {
                            onSelectSnapshot?(snap)
                        }
                    } label: {
                        if isActive {
                            Label("\(snap.name) (Active — click to toggle off)", systemImage: "checkmark.circle.fill")
                        } else {
                            Label(snap.name, systemImage: "photo")
                        }
                    }
                }

                Divider()
                Menu("Delete Snapshot") {
                    ForEach(snapshots) { snap in
                        Button(role: .destructive) {
                            onDeleteSnapshot?(snap)
                        } label: {
                            Text(snap.name)
                        }
                    }
                }
            }

            if !projectSnapshotPackages.isEmpty {
                Divider()
                Section("Project Packages (data/snapshot/)") {
                    ForEach(projectSnapshotPackages) { pkg in
                        Button {
                            onSelectSnapshotPackage?(pkg)
                        } label: {
                            Label(pkg.name, systemImage: "shippingbox.fill")
                        }
                    }
                }
            }
        } label: {
            let activeSnap = snapshots.first(where: { $0.id == activeSnapshotID })
            Label(
                activeSnap != nil ? activeSnap!.name : (snapshots.isEmpty ? "Snapshot" : "Snapshots (\(snapshots.count))"),
                systemImage: activeSnapshotID != nil ? "camera.fill" : "camera"
            )
            .font(.system(size: 11, weight: activeSnapshotID != nil ? .semibold : .medium))
            .foregroundStyle(activeSnapshotID != nil ? Color.accentColor : Color.primary)
        }
        .menuStyle(.borderedButton)
        .controlSize(.small)
        .help("Manage plot snapshots and comparisons")
    }

    private var exportMenu: some View {
        Menu {
            let isOverlay = selectedIDs.count >= 2
            Section(isOverlay ? "OVERLAY FIGURE (\(selectedIDs.count) SOURCES)" : "SINGLE FIGURE") {
                Button {
                    onExportFigure?()
                } label: {
                    HStack {
                        Label(isOverlay ? "Export Overlay Figure (PNG / PDF)…" : "Export Single Figure (PNG / PDF)…", systemImage: "arrow.down.doc")
                        Spacer()
                        ShortcutBadge("exportFigure")
                    }
                }
            }

            Section("DATA TABLE") {
                Button {
                    onExportData?()
                } label: {
                    HStack {
                        Label("Export Data Table (CSV)…", systemImage: "tablecells")
                        Spacer()
                        ShortcutBadge("exportData")
                    }
                }
            }

            Divider()

            Section("SNAPSHOT PACKAGE") {
                Button {
                    onSaveSnapshotPackage?()
                } label: {
                    Label("Save Snapshot Package (data/snapshot/…)", systemImage: "shippingbox")
                }
                .disabled(selectedIDs.isEmpty && focusedSourceID == nil)
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderedButton)
        .controlSize(.small)
        .help("Export figure, data table, or snapshot package")
    }

    @ViewBuilder
    private var pane: some View {
        if sources.isEmpty {
            VStack {
                Spacer()
                ContentUnavailableView("No Sources", systemImage: "waveform.path.ecg",
                    description: Text("Open a project containing files under data/raw."))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let source = sources.first(where: { $0.id == focusedSourceID }) {
            if tab == "Data" {
                focusedDataPane(source)
            } else {
                plotPane(focused: source)
            }
        } else {
            VStack {
                Spacer()
                ContentUnavailableView("Select a Source", systemImage: "waveform.path.ecg",
                    description: Text("Choose a source in the sidebar to view it here."))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func focusedDataPane(_ source: RawSource) -> some View {
        if let measurement = states[source.id]?.measurement {
            MeasurementTable(measurement: measurement)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            sourceStatus(source, symbol: "tablecells")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func plotPane(focused: RawSource) -> some View {
        switch overlay {
        case .eligible:
            let all = selectedIDs.sorted().compactMap { states[$0]?.measurement }
            let visible = all.filter { !hidden.contains($0.source.path) }
            if visible.isEmpty {
                ContentUnavailableView("All Series Hidden", systemImage: "eye.slash",
                    description: Text("Every selected series is hidden. Show at least one series in the inspector."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let defaultTitle = "\(visible.count) sources · overlay in acquisition order"
                let displayTitle = comparisonTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTitle : comparisonTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                CenteredFigureView(targetRatio: CGFloat(selectedPreset.aspectRatio), title: displayTitle, onResetPlot: { plotResetTrigger += 1 }) {
                    OverlayPlot(measurements: visible, selectedSourceIDs: selectedIDs,
                                focused: states[focused.id]?.measurement,
                                lineWidth: lineWidth,
                                renderStyle: renderStyle,
                                markType: markType, interpolation: interpolation,
                                markerSize: markerSize,
                                colorBySweepProgress: colorBySweepProgress,
                                xAbsolute: xAbsolute, yAbsolute: yAbsolute,
                                xScale: xScale, yScale: yScale,
                                comparisonTitle: comparisonTitle,
                                preset: selectedPreset,
                                showLegend: showLegend,
                                legendScale: legendScale,
                                customSeriesLabels: customSeriesLabels,
                                customSeriesColors: customSeriesColors,
                                orderedSourceIDs: orderedSourceIDs,
                                resetTrigger: plotResetTrigger,
                                legendOffset: $legendOffset,
                                axisConfig: axisConfig,
                                onMetricsUpdate: { next in
                                    if liveMetrics != next { liveMetrics = next }
                                })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .blocked(let reason):
            VStack(spacing: 0) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
                    .textSelection(.enabled)
                    .accessibilityLabel("Comparison blocked: \(reason)")
                focusedSinglePlot(focused)
            }
        case .partial(let group):
            let plottedIDs = Set(group.plottedPaths)
            let cohort = selectedIDs.sorted().compactMap { states[$0]?.measurement }
                .filter { plottedIDs.contains($0.source.path) }
            let visible = cohort.filter { !hidden.contains($0.source.path) }
            VStack(spacing: 0) {
                let summary = exclusionSummary(group)
                Label(summary, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
                    .textSelection(.enabled)
                    .accessibilityLabel("Comparison exclusions: \(summary)")
                if visible.isEmpty {
                    ContentUnavailableView("All Series Hidden", systemImage: "eye.slash",
                        description: Text("Every selected series is hidden. Show at least one series in the inspector."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let defaultTitle = "\(visible.count) sources · overlay in acquisition order"
                    let displayTitle = comparisonTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTitle : comparisonTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    CenteredFigureView(targetRatio: CGFloat(selectedPreset.aspectRatio), title: displayTitle, onResetPlot: { plotResetTrigger += 1 }) {
                        OverlayPlot(measurements: visible, selectedSourceIDs: plottedIDs,
                                    focused: visible.first(where: { $0.source.path == focused.id }),
                                    lineWidth: lineWidth,
                                    renderStyle: renderStyle,
                                    markType: markType, interpolation: interpolation,
                                    markerSize: markerSize,
                                    colorBySweepProgress: colorBySweepProgress,
                                    xAbsolute: xAbsolute, yAbsolute: yAbsolute,
                                    xScale: xScale, yScale: yScale,
                                    comparisonTitle: comparisonTitle,
                                    preset: selectedPreset,
                                    showLegend: showLegend,
                                    legendScale: legendScale,
                                    customSeriesLabels: customSeriesLabels,
                                    customSeriesColors: customSeriesColors,
                                    orderedSourceIDs: orderedSourceIDs,
                                    resetTrigger: plotResetTrigger,
                                    legendOffset: $legendOffset,
                                    axisConfig: axisConfig,
                                    onMetricsUpdate: { next in
                                        if liveMetrics != next { liveMetrics = next }
                                    })
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case nil:
            focusedSinglePlot(focused)
        }
    }

    @ViewBuilder
    private func focusedSinglePlot(_ source: RawSource) -> some View {
        if let measurement = states[source.id]?.measurement {
            if measurement.supportStatus != "supported" {
                ContentUnavailableView("Unsupported Source", systemImage: "exclamationmark.triangle",
                    description: Text("The profile reports: \(measurement.supportStatus). Its source remains available in the Data tab."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if measurement.view.kind == "metadata-only" {
                ContentUnavailableView("No Figure for This Source", systemImage: "chart.xyaxis.line",
                    description: Text("The profile reports metadata only; its data remains available in the Data tab."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let defaultTitle = measurement.instrument.name + (measurement.applicationMode.map { " · \($0)" } ?? "")
                CenteredFigureView(targetRatio: CGFloat(selectedPreset.aspectRatio), title: defaultTitle, onResetPlot: { plotResetTrigger += 1 }) {
                    NativePlot(measurement: measurement, xAbsolute: xAbsolute,
                               yAbsolute: yAbsolute, xScale: xScale,
                               yScale: yScale, lineWidth: lineWidth,
                               renderStyle: renderStyle,
                               markType: markType, interpolation: interpolation,
                               markerSize: markerSize,
                               colorBySweepProgress: colorBySweepProgress,
                               progressionFilterEnabled: progressionFilterEnabled,
                               selectedProgressionChannel: selectedProgressionChannel,
                               selectedCycles: selectedCycles,
                               colorByCycle: colorByCycle,
                               resetTrigger: plotResetTrigger,
                               preset: selectedPreset,
                               showLegend: showLegend,
                               legendScale: legendScale,
                               customSeriesLabels: customSeriesLabels,
                               customSeriesColors: customSeriesColors,
                               legendOffset: $legendOffset,
                               axisConfig: axisConfig,
                               onMetricsUpdate: { next in
                                   if liveMetrics != next { liveMetrics = next }
                               })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            sourceStatus(source, symbol: "chart.xyaxis.line")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct CenteredFigureView<Content: View>: View {
        var targetRatio: CGFloat = 59.1 / 50.0
        var title: String? = nil
        var onResetPlot: (() -> Void)? = nil
        @ViewBuilder let content: () -> Content

        private func cardSize(in geoSize: CGSize) -> CGSize {
            let titleReserve: CGFloat = title != nil ? 44 : 0
            let verticalMargin: CGFloat = 40
            let horizontalMargin: CGFloat = 48
            let availW = max(100, geoSize.width - horizontalMargin)
            let availH = max(100, geoSize.height - verticalMargin - titleReserve)
            let maxPlotW = max(100, availW - 145)
            let maxPlotH = max(80, availH - 145)
            var plotW = maxPlotW
            var plotH = plotW / targetRatio
            if plotH > maxPlotH {
                plotH = maxPlotH
                plotW = plotH * targetRatio
            }
            let cardW = plotW + 145
            let cardH = plotH + 145
            return CGSize(width: max(280, cardW), height: max(240, min(cardH, availH)))
        }

        var body: some View {
            GeometryReader { geo in
                let size = cardSize(in: geo.size)
                VStack(spacing: 8) {
                    if let title {
                        HStack(alignment: .center) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let onResetPlot {
                                Button {
                                    onResetPlot()
                                } label: {
                                    Label("Reset plot", systemImage: "arrow.counterclockwise")
                                        .font(.caption2)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Reset plot zoom and pan")
                            }
                        }
                        .frame(width: size.width)
                    }

                    floatingCard {
                        content()
                    }
                    .frame(width: size.width, height: size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }

        private func floatingCard<C: View>(@ViewBuilder cardContent: () -> C) -> some View {
            cardContent()
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
        }
    }

    private func sourceStatus(_ source: RawSource, symbol: String) -> some View {
        let state = states[source.id]
        let title: String
        let message: String
        if state?.isLoading == true {
            title = "Loading Source"
            message = "RawView's built-in reader is processing this file."
        } else if let error = state?.error {
            title = "Source Unavailable"
            message = error
        } else if state?.inspection?.supportStatus != nil && state?.inspection?.supportStatus != "supported" {
            title = "Unsupported Source"
            message = "Profile support status: \(state?.inspection?.supportStatus ?? "Unknown")."
        } else if state?.inspection == nil {
            title = "Awaiting Inspection"
            message = "This source is waiting to be inspected."
        } else {
            title = "No Data Available"
            message = "The source did not produce a normalized measurement."
        }
        return VStack(spacing: 12) {
            ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            if state?.error != nil {
                Button("Retry Load", action: retry).buttonStyle(.bordered)
            }
        }.frame(minHeight: 180)
    }
}
