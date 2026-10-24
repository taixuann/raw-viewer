import AppKit
import SwiftUI
import RawViewCore

struct DraggableLegendView: View {
    let items: [(color: Color, label: String)]
    var fontSize: CGFloat = 10.0
    var lineWidth: CGFloat = 1.4
    @Binding var offset: CGSize
    @State private var dragStart: CGSize = .zero

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        Capsule()
                            .fill(item.color)
                            .frame(width: 14, height: max(1.5, min(3.0, lineWidth)))
                        Text(item.label)
                            .font(.system(size: fontSize, weight: .regular))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.ultraThinMaterial.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
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
    var preset: ScientificPreset = .natureSingle
    var showLegend: Bool = true
    var customSeriesLabels: [String: String] = [:]
    @Binding var legendOffset: CGSize
    @State private var zoom = 1.0
    @State private var gestureZoomStart = 1.0
    @State private var pan = CGSize.zero
    @State private var dragStart = CGSize.zero
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    private func plotFont(size: CGFloat, bold: Bool = false) -> Font {
        PlotRenderingEngine.plotFont(preset: preset, size: size, bold: bold)
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
        let headerFontScale = PlotRenderingEngine.fontScale(plotWidth: 500, uiFontSize: uiFontSize)
        let defaultTitle = measurement.instrument.name + (measurement.applicationMode.map { " · \($0)" } ?? "")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(defaultTitle)
                    .font(plotFont(size: PlotRenderingEngine.titleFontSize(preset: preset, fontScale: headerFontScale), bold: true))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    zoom = 1; gestureZoomStart = 1; pan = .zero; dragStart = .zero
                } label: {
                    Label("Reset plot", systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reset plot zoom and pan")
            }
            switch transformed {
            case .failure(let failure):
                if case .message(let message) = failure { ContentUnavailableView("Invalid Plot Domain", systemImage: "chart.xyaxis.line", description: Text(message)) }
            case .success(let data):
                ZStack(alignment: .topTrailing) {
                    Canvas { context, size in draw(data, in: &context, size: size) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .simultaneousGesture(DragGesture().onChanged { pan = CGSize(width: dragStart.width + $0.translation.width, height: dragStart.height + $0.translation.height) }.onEnded { _ in dragStart = pan })
                        .simultaneousGesture(MagnifyGesture().onChanged { zoom = min(max(gestureZoomStart * $0.magnification, 0.5), 12) }.onEnded { _ in gestureZoomStart = zoom })

                    if colorBySweepProgress {
                        SweepColorbarView()
                            .padding(.leading, 64)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    if showLegend {
                        let legendItems: [(color: Color, label: String)] = data.1.enumerated().map { index, item in
                            let custom = customSeriesLabels[item.0]?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let name = (custom != nil && !custom!.isEmpty) ? custom! : item.0
                            return (palette(index), name)
                        }
                        DraggableLegendView(
                            items: legendItems,
                            fontSize: PlotRenderingEngine.legendFontSize(preset: preset, fontScale: headerFontScale),
                            lineWidth: CGFloat(lineWidth),
                            offset: $legendOffset
                        )
                        .padding(.trailing, 28)
                        .padding(.top, 24)
                    }
                }
                HStack(spacing: 14) {
                    Spacer()
                    Text("Drag to pan · Pinch to zoom · \(data.0.count) rows")
                        .font(plotFont(size: 10.5 * headerFontScale)).foregroundStyle(.secondary)
                }
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

        let yRangeTemp = viewport(expanded(finiteY), pan: pan.height, dimension: size.height, vertical: true)
        let yLabels: [String] = (0...4).map { index in
            let t = Double(index) / 4
            let y = yRangeTemp.lowerBound + t * (yRangeTemp.upperBound - yRangeTemp.lowerBound)
            return axisLabel(y, scale: yScale, scaleInfo: yScaleInfo)
        }
        let targetRatio: CGFloat = CGFloat(preset.aspectRatio)
        let approxPlotWidth = max(200, size.width - 120)
        let fontScale = PlotRenderingEngine.fontScale(plotWidth: approxPlotWidth, uiFontSize: uiFontSize)

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

        let xRange = viewport(expanded(finiteX), pan: pan.width, dimension: plot.width, vertical: false)
        let yRange = viewport(expanded(finiteY), pan: pan.height, dimension: plot.height, vertical: true)
        let tickLen = PlotRenderingEngine.tickLength(fontScale: fontScale, preset: preset)
        let tickLabelSize = PlotRenderingEngine.tickLabelFontSize(preset: preset, fontScale: fontScale)
        let spineWidth = PlotRenderingEngine.spineThickness(preset: preset)

        for index in 0...4 {
            let t = Double(index) / 4
            let x = xRange.lowerBound + t * (xRange.upperBound - xRange.lowerBound)
            let px = plot.minX + t * plot.width
            let py = plot.maxY - t * plot.height

            var xTick = Path(); xTick.move(to: CGPoint(x: px, y: plot.maxY)); xTick.addLine(to: CGPoint(x: px, y: plot.maxY + tickLen))
            var yTick = Path(); yTick.move(to: CGPoint(x: plot.minX, y: py)); yTick.addLine(to: CGPoint(x: plot.minX - tickLen, y: py))
            context.stroke(xTick, with: .color(.primary), lineWidth: spineWidth)
            context.stroke(yTick, with: .color(.primary), lineWidth: spineWidth)

            context.draw(Text(axisLabel(x, scale: xScale, scaleInfo: xScaleInfo)).font(plotFont(size: tickLabelSize)), at: CGPoint(x: px, y: plot.maxY + tickLen + 3.0), anchor: .top)
            context.draw(Text(yLabels[index]).font(plotFont(size: tickLabelSize)), at: CGPoint(x: plot.minX - tickLen - 3.0, y: py), anchor: .trailing)
        }
        let xTitle = axisTitle(xChannel?.label ?? "X", unit: xScaleInfo.displayUnit, absolute: xAbsolute, scale: xScale)
        let yTitle = axisTitle(yChannel?.label ?? "Y", unit: yScaleInfo.displayUnit, absolute: yAbsolute, scale: yScale)

        let axisLabelSize = PlotRenderingEngine.axisLabelFontSize(preset: preset, fontScale: fontScale)
        context.draw(Text(xTitle).font(plotFont(size: axisLabelSize, bold: false)), at: CGPoint(x: plot.midX, y: plot.maxY + tickLen + 3.0 + tickLabelSize + 6.0), anchor: .top)
        let yTitleX = max(14 * fontScale, plot.minX - tickLen - 3.0 - maxLabelWidth - (12 * fontScale))
        var yLabelContext = context
        yLabelContext.translateBy(x: yTitleX, y: plot.midY)
        yLabelContext.rotate(by: .degrees(-90))
        yLabelContext.draw(Text(yTitle).font(plotFont(size: axisLabelSize, bold: false)), at: .zero, anchor: .center)

        var plotContext = context
        plotContext.clip(to: Path(plot))
        for (seriesIndex, item) in data.1.enumerated() {
            guard item.1.count == data.0.count else { continue }
            let color = palette(seriesIndex)
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
    private func axisLabel(_ value: Double, scale: AxisScale, scaleInfo: AxisFormatter.ScaleInfo) -> String {
        scale == .logarithmic ? "10^\(AxisFormatter.formatTick(value, factor: 1.0))" : AxisFormatter.formatTick(value, factor: scaleInfo.factor)
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
    var customSeriesLabels: [String: String] = [:]
    @Binding var legendOffset: CGSize
    @State private var zoom = 1.0
    @State private var gestureZoomStart = 1.0
    @State private var pan = CGSize.zero
    @State private var dragStart = CGSize.zero
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

    private var transformed: Result<(xChannel: (label: String, unit: String), yChannel: (label: String, unit: String), series: [Series]), OverlayPlotFailure> {
        guard !measurements.isEmpty else { return .failure(.message("No measurements selected")) }
        var series: [Series] = []
        var xChannelInfo = ("", "")
        var yChannelInfo = ("", "")
        var first = true
        let sortedMeasurements = measurements.sorted(by: { $0.source.path < $1.source.path })
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
        let headerFontScale = PlotRenderingEngine.fontScale(plotWidth: 500, uiFontSize: uiFontSize)
        let defaultTitle = "\(measurements.count) sources · overlay in acquisition order"
        let displayTitle = comparisonTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTitle : comparisonTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(displayTitle)
                    .font(plotFont(size: 14.0 * headerFontScale, bold: true))
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel(displayTitle)
                Spacer()
                Button {
                    zoom = 1; gestureZoomStart = 1; pan = .zero; dragStart = .zero
                } label: {
                    Label("Reset plot", systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reset plot zoom and pan")
            }
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
                                       showLegend: showLegend,
                                       customSeriesLabels: customSeriesLabels,
                                       legendOffset: $legendOffset)
                        }
                    }
                }
            case .success(let data):
                let sourceOrder = selectedSourceIDs.sorted()
                let accessibleSummary = data.series.map {
                    "\($0.label): \($0.x.count) points, \(gapCount($0)) gaps"
                }.joined(separator: ". ")
                ZStack(alignment: .topTrailing) {
                    Canvas { context, size in
                        draw(data.series, xLabel: data.xChannel.label, xUnit: data.xChannel.unit, yLabel: data.yChannel.label, yUnit: data.yChannel.unit, in: &context, size: size)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture().onChanged { pan = CGSize(width: dragStart.width + $0.translation.width, height: dragStart.height + $0.translation.height) }.onEnded { _ in dragStart = pan })
                    .simultaneousGesture(MagnifyGesture().onChanged { zoom = min(max(gestureZoomStart * $0.magnification, 0.5), 12) }.onEnded { _ in gestureZoomStart = zoom })
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
                        let legendItems: [(color: Color, label: String)] = data.series.map { item in
                            let custom = customSeriesLabels[item.sourcePath]?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let name = (custom != nil && !custom!.isEmpty) ? custom! : item.label
                            return (palette(item.sourcePath, order: sourceOrder), name)
                        }
                        DraggableLegendView(
                            items: legendItems,
                            fontSize: max(8.5, CGFloat(preset.legendPt) * 1.35 * headerFontScale),
                            lineWidth: CGFloat(lineWidth),
                            offset: $legendOffset
                        )
                        .padding(.trailing, 28)
                        .padding(.top, 24)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(pointCount(data.series)) points across visible series · \(gapCount(data.series)) gaps")
                        .font(plotFont(size: 10.5 * headerFontScale)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func draw(_ series: [Series], xLabel: String, xUnit: String, yLabel: String, yUnit: String, in context: inout GraphicsContext, size: CGSize) {
        guard let xBounds = extrema(series, isX: true), let yBounds = extrema(series, isX: false) else { return }

        let allX = series.flatMap { $0.x.compactMap { $0 } }
        let allY = series.flatMap { $0.y.compactMap { $0 } }
        let xScaleInfo = AxisFormatter.scaleInfo(for: allX, baseUnit: xUnit)
        let yScaleInfo = AxisFormatter.scaleInfo(for: allY, baseUnit: yUnit)

        let yRangeTemp = viewport(expanded(yBounds), pan: pan.height, dimension: size.height, vertical: true)
        let yLabels: [String] = (0...4).map { index in
            let t = Double(index) / 4
            let y = yRangeTemp.lowerBound + t * (yRangeTemp.upperBound - yRangeTemp.lowerBound)
            return axisLabel(y, scale: yScale, scaleInfo: yScaleInfo)
        }
        let targetRatio: CGFloat = CGFloat(preset.aspectRatio)
        let approxPlotWidth = max(200, size.width - 120)
        let fontScale = PlotRenderingEngine.fontScale(plotWidth: approxPlotWidth, uiFontSize: uiFontSize)

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

        let xRange = viewport(expanded(xBounds), pan: pan.width, dimension: plot.width, vertical: false)
        let yRange = viewport(expanded(yBounds), pan: pan.height, dimension: plot.height, vertical: true)
        let tickLen = PlotRenderingEngine.tickLength(fontScale: fontScale, preset: preset)
        let tickLabelSize = PlotRenderingEngine.tickLabelFontSize(preset: preset, fontScale: fontScale)
        let spineWidth = PlotRenderingEngine.spineThickness(preset: preset)

        for index in 0...4 {
            let t = Double(index) / 4
            let x = xRange.lowerBound + t * (xRange.upperBound - xRange.lowerBound)
            let px = plot.minX + t * plot.width
            let py = plot.maxY - t * plot.height

            var xTick = Path(); xTick.move(to: CGPoint(x: px, y: plot.maxY)); xTick.addLine(to: CGPoint(x: px, y: plot.maxY + tickLen))
            var yTick = Path(); yTick.move(to: CGPoint(x: plot.minX, y: py)); yTick.addLine(to: CGPoint(x: plot.minX - tickLen, y: py))
            context.stroke(xTick, with: .color(.primary), lineWidth: spineWidth)
            context.stroke(yTick, with: .color(.primary), lineWidth: spineWidth)

            context.draw(Text(axisLabel(x, scale: xScale, scaleInfo: xScaleInfo)).font(plotFont(size: tickLabelSize)), at: CGPoint(x: px, y: plot.maxY + tickLen + 3.0), anchor: .top)
            context.draw(Text(yLabels[index]).font(plotFont(size: tickLabelSize)), at: CGPoint(x: plot.minX - tickLen - 3.0, y: py), anchor: .trailing)
        }
        let xTitle = axisTitle(xLabel, unit: xScaleInfo.displayUnit, absolute: xAbsolute, scale: xScale)
        let yTitle = axisTitle(yLabel, unit: yScaleInfo.displayUnit, absolute: yAbsolute, scale: yScale)

        let axisLabelSize = PlotRenderingEngine.axisLabelFontSize(preset: preset, fontScale: fontScale)
        context.draw(Text(xTitle).font(plotFont(size: axisLabelSize, bold: false)), at: CGPoint(x: plot.midX, y: plot.maxY + tickLen + 3.0 + tickLabelSize + 6.0), anchor: .top)
        let yTitleX = max(14 * fontScale, plot.minX - tickLen - 3.0 - maxLabelWidth - (12 * fontScale))
        var yLabelContext = context
        yLabelContext.translateBy(x: yTitleX, y: plot.midY)
        yLabelContext.rotate(by: .degrees(-90))
        yLabelContext.draw(Text(yTitle).font(plotFont(size: axisLabelSize, bold: false)), at: .zero, anchor: .center)

        var plotContext = context
        plotContext.clip(to: Path(plot))
        let sourceOrder = selectedSourceIDs.sorted()
        for item in series {
            let color = palette(item.sourcePath, order: sourceOrder)
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
    private func axisLabel(_ value: Double, scale: AxisScale, scaleInfo: AxisFormatter.ScaleInfo) -> String {
        scale == .logarithmic ? "10^\(AxisFormatter.formatTick(value, factor: 1.0))" : AxisFormatter.formatTick(value, factor: scaleInfo.factor)
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
    var onBuildProfile: ((String) -> Void)? = nil
    var comparisonTitle: String = ""
    var availablePresets: [ScientificPreset] = ScientificPreset.allCases
    @Binding var selectedPreset: ScientificPreset
    @Binding var showLegend: Bool
    var customSeriesLabels: [String: String] = [:]
    @Binding var legendOffset: CGSize

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

                Divider().frame(height: 16)

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
                Spacer()
                if selectedIDs.count >= 2 {
                    Text("\(selectedIDs.count) selected\(overlayLabel)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel("Selection comparison status")
                }
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
            HStack {
                if let source = sources.first(where: { $0.id == focusedSourceID }) {
                    Text(source.url.lastPathComponent).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
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
                CenteredFigureView(targetRatio: CGFloat(selectedPreset.aspectRatio)) {
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
                                customSeriesLabels: customSeriesLabels,
                                legendOffset: $legendOffset)
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
                    CenteredFigureView(targetRatio: CGFloat(selectedPreset.aspectRatio)) {
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
                                    customSeriesLabels: customSeriesLabels,
                                    legendOffset: $legendOffset)
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
                CenteredFigureView(targetRatio: CGFloat(selectedPreset.aspectRatio)) {
                    NativePlot(measurement: measurement, xAbsolute: xAbsolute,
                               yAbsolute: yAbsolute, xScale: xScale,
                               yScale: yScale, lineWidth: lineWidth,
                               renderStyle: renderStyle,
                               markType: markType, interpolation: interpolation,
                               markerSize: markerSize,
                               colorBySweepProgress: colorBySweepProgress,
                               preset: selectedPreset,
                               showLegend: showLegend,
                               customSeriesLabels: customSeriesLabels,
                               legendOffset: $legendOffset)
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
        @ViewBuilder let content: () -> Content

        private func cardSize(in geoSize: CGSize) -> CGSize {
            let availW = max(100, geoSize.width - 48)
            let availH = max(100, geoSize.height - 48)
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
            return CGSize(width: max(280, cardW), height: max(240, cardH))
        }

        var body: some View {
            GeometryReader { geo in
                let size = cardSize(in: geo.size)
                ZStack(alignment: .center) {
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
