import SwiftUI
import RawViewCore

/// Live Sandbox Preview mini-plot: real-time curve rendering of parsed X/Y data.
enum ProgressionColorMode: String, CaseIterable {
    case multiColor = "Palette"
    case sweep = "Sweep"
}

struct SandboxSegment: Identifiable {
    var id: String { name }
    let name: String
    let points: [(x: Double, y: Double)]
}

struct LiveSandboxPlotView: View {
    let lines: [String]
    let delimiter: String
    let columns: [ColumnDefinition]
    var lineTags: [Int: LineRegionType] = [:]
    @Binding var selectedXCol: String?
    @Binding var selectedYCol: String?

    private var activeXIndex: Int {
        let plottable = columns.indices.filter { idx in
            let c = columns[idx]
            return !c.isSkipped && c.role != .progression && c.progressionType == nil
        }
        if let selX = selectedXCol, let idx = plottable.first(where: { columns[$0].name == selX }) {
            return idx
        }
        if let defX = plottable.first(where: { columns[$0].isDefaultX && (columns[$0].isXAxis || columns[$0].role == .x) }) {
            return defX
        }
        return plottable.first(where: { columns[$0].isXAxis || columns[$0].role == .x })
            ?? plottable.first ?? 0
    }

    private var activeYIndex: Int {
        let plottable = columns.indices.filter { idx in
            let c = columns[idx]
            return !c.isSkipped && c.role != .progression && c.progressionType == nil
        }
        if let selY = selectedYCol, let idx = plottable.first(where: { columns[$0].name == selY }) {
            return idx
        }
        if let defY = plottable.first(where: { columns[$0].isDefaultY && (columns[$0].isYAxis || columns[$0].role == .y) }) {
            return defY
        }
        let activeY = plottable.filter { columns[$0].isYAxis || columns[$0].role == .y }
        if let firstY = activeY.first {
            return firstY
        }
        return plottable.count > 1 ? plottable[1] : (plottable.first ?? 0)
    }

    @State private var customProgressionColIndex: Int? = nil
    @State private var cachedSegments: [SandboxSegment] = []
    @State private var availableProgressionValues: [String] = []
    @State private var selectedProgressionValues: Set<String> = []
    @State private var continuousMinTime: Double = 0.0
    @State private var continuousMaxTime: Double = 1.0
    @State private var timeStartText: String = ""
    @State private var timeStopText: String = ""
    @State private var isContinuousMode: Bool = false
    @State private var discreteColorMode: ProgressionColorMode = .multiColor
    @State private var cachedBounds: (minX: Double, maxX: Double, minY: Double, maxY: Double) = (0, 1, 0, 1)
    @State private var legendOffset: CGSize = .zero
    @State private var legendDragBase: CGSize = .zero
    @State private var highlightedCycle: String? = nil
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    private var activeProgressionIndex: Int? {
        if let custom = customProgressionColIndex {
            return custom >= 0 ? custom : nil
        }
        if let explicit = columns.firstIndex(where: { $0.role == .progression && !$0.isSkipped }) {
            return explicit
        }
        return columns.firstIndex(where: {
            let n = $0.name.lowercased()
            let l = $0.label.lowercased()
            return !$0.isSkipped && (
                n.contains("scan") || n.contains("cycle") || n.contains("segment") ||
                l.contains("scan") || l.contains("cycle") || l.contains("segment")
            )
        })
    }

    private var activeProgressionColumn: ColumnDefinition? {
        guard let idx = activeProgressionIndex, idx < columns.count else { return nil }
        return columns[idx]
    }

    private var dataStartIndex: Int {
        var minData = Int.max
        for (idx, tag) in lineTags {
            if tag == .dataMatrix, idx < minData {
                minData = idx
            } else if tag == .columnHeaders, (idx + 1) < minData {
                minData = idx + 1
            }
        }
        return minData == Int.max ? 0 : minData
    }

    private var totalPointCount: Int {
        cachedSegments.reduce(0) { $0 + $1.points.count }
    }

    private var activeXLabel: String {
        guard activeXIndex < columns.count else { return "X Axis" }
        let c = columns[activeXIndex]
        let label = c.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? c.name : c.label
        let unit = c.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = unit.isEmpty ? label : "\(label) (\(unit))"
        return ScientificTypography.format(raw)
    }

    private var activeYLabel: String {
        guard activeYIndex < columns.count else { return "Y Axis" }
        let c = columns[activeYIndex]
        let label = c.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? c.name : c.label
        let unit = c.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = unit.isEmpty ? label : "\(label) (\(unit))"
        return ScientificTypography.format(raw)
    }

    private var progressionFilterSummary: String {
        if isContinuousMode {
            if let s = Double(timeStartText), let e = Double(timeStopText) {
                return String(format: "%.1f–%.1fs", s, e)
            }
            return "Time Window"
        }
        if selectedProgressionValues.isEmpty || selectedProgressionValues.count == availableProgressionValues.count {
            return "All (\(availableProgressionValues.count))"
        } else if selectedProgressionValues.count == 1, let first = selectedProgressionValues.first {
            return "Cycle \(first)"
        } else {
            return "\(selectedProgressionValues.count) Cycles"
        }
    }

    private var progressionButtonLabel: String {
        if let col = activeProgressionColumn, let idx = activeProgressionIndex {
            let name = col.label.isEmpty ? col.name : col.label
            return "#\(idx + 1) \(name)"
        }
        return "Prog: None"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // 1. X & Y Axis Pickers
                let plottableCols = columns.filter { !$0.isSkipped && $0.role != .progression && $0.progressionType == nil }
                if !plottableCols.isEmpty {
                    let activeXCount = plottableCols.filter { $0.isXAxis || $0.role == .x }.count
                    let activeYCount = plottableCols.filter { $0.isYAxis || $0.role == .y }.count

                    // X: Axis Picker (blue accent)
                    HStack(spacing: 4) {
                        Text("X:")
                            .font(AppTypography.toolbarLabel(uiFontSize: uiFontSize))
                            .foregroundStyle(.blue)
                        Picker("", selection: Binding(
                            get: { selectedXCol ?? (columns.indices.contains(activeXIndex) ? columns[activeXIndex].name : "") },
                            set: { selectedXCol = $0 }
                        )) {
                            ForEach(plottableCols) { col in
                                let isDef = col.isDefaultX || (activeXCount == 1 && (col.isXAxis || col.role == .x))
                                Text("\(col.unit.isEmpty ? col.label : "\(col.label) (\(col.unit))")\(isDef ? " ★" : "")").tag(col.name)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .font(AppTypography.toolbarLabel(uiFontSize: uiFontSize))
                        .frame(height: 24)
                        .frame(maxWidth: 140)
                    }

                    // Y: Axis Picker (green accent)
                    HStack(spacing: 4) {
                        Text("Y:")
                            .font(AppTypography.toolbarLabel(uiFontSize: uiFontSize))
                            .foregroundStyle(.green)
                        Picker("", selection: Binding(
                            get: { selectedYCol ?? (columns.indices.contains(activeYIndex) ? columns[activeYIndex].name : "") },
                            set: { selectedYCol = $0 }
                        )) {
                            ForEach(plottableCols) { col in
                                let isDef = col.isDefaultY || (activeYCount == 1 && (col.isYAxis || col.role == .y))
                                Text("\(col.unit.isEmpty ? col.label : "\(col.label) (\(col.unit))")\(isDef ? " ★" : "")").tag(col.name)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .font(AppTypography.toolbarLabel(uiFontSize: uiFontSize))
                        .frame(height: 24)
                        .frame(maxWidth: 140)
                    }
                }

                // 2. Progression Controls (purple accent)
                let progColumns = columns.enumerated().filter { !$0.element.isSkipped && ($0.element.role == .progression || $0.element.name.lowercased().contains("scan") || $0.element.name.lowercased().contains("cycle") || $0.element.name.lowercased().contains("time") || $0.element.label.lowercased().contains("scan") || $0.element.label.lowercased().contains("cycle") || $0.element.label.lowercased().contains("time")) }
                if !progColumns.isEmpty {
                    HStack(spacing: 6) {
                        // Dimension Menu: [ ⏱️ #5 Scan ▾ ]
                        Menu {
                            Button {
                                customProgressionColIndex = -1
                                recomputePlotPoints()
                            } label: {
                                HStack {
                                    Text("Progression: None")
                                    if customProgressionColIndex == -1 {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            Divider()
                            ForEach(progColumns, id: \.offset) { item in
                                let idx = item.offset
                                let c = item.element
                                Button {
                                    customProgressionColIndex = idx
                                    selectedProgressionValues.removeAll()
                                    timeStartText = ""
                                    timeStopText = ""
                                    if let beh = c.progressionBehavior {
                                        isContinuousMode = (beh == .continuous)
                                    }
                                    recomputePlotPoints()
                                } label: {
                                    HStack {
                                        Text("#\(idx + 1) \(c.label.isEmpty ? c.name : c.label)\(c.unit.isEmpty ? "" : " (\(c.unit))")")
                                        if activeProgressionIndex == idx {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isContinuousMode ? "timer" : "clock.arrow.circlepath")
                                    .font(AppTypography.caption(uiFontSize: uiFontSize))
                                Text(progressionButtonLabel)
                                    .font(AppTypography.captionBold(uiFontSize: uiFontSize))
                                Image(systemName: "chevron.down")
                                    .font(AppTypography.chevron(uiFontSize: uiFontSize))
                                    .foregroundStyle(Color.purple.opacity(0.8))
                            }
                            .foregroundStyle(Color.purple)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.purple.opacity(0.10)))
                            .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 0.8))
                        }
                        .menuStyle(.borderlessButton)

                        // 2. Behavior Switcher & Dual Filtering Controls
                        if activeProgressionColumn != nil {
                            // Behavior Switcher: [ Continuous | Discrete ]
                            Picker("", selection: Binding(
                                get: { isContinuousMode },
                                set: { newContinuous in
                                    isContinuousMode = newContinuous
                                    recomputePlotPoints(forceContinuous: newContinuous)
                                }
                            )) {
                                Text("Continuous").tag(true)
                                Text("Discrete").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .frame(height: 24)
                            .frame(width: 155)

                            if isContinuousMode {
                                // CONTINUOUS TIME RANGE MODE: Start & Stop Inputs + Presets
                                HStack(spacing: 4) {
                                    Text("From:")
                                        .font(AppTypography.caption(uiFontSize: uiFontSize))
                                        .foregroundStyle(.secondary)
                                    TextField("0", text: $timeStartText)
                                        .font(AppTypography.mono(size: 10, uiFontSize: uiFontSize))
                                        .textFieldStyle(.plain)
                                        .frame(width: 40, height: 24)
                                        .padding(.horizontal, 4)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.textBackgroundColor)))
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.purple.opacity(0.3), lineWidth: 0.8))
                                        .onSubmit { recomputePlotPoints() }

                                    Text("to:")
                                        .font(AppTypography.caption(uiFontSize: uiFontSize))
                                        .foregroundStyle(.secondary)
                                    TextField("End", text: $timeStopText)
                                        .font(AppTypography.mono(size: 10, uiFontSize: uiFontSize))
                                        .textFieldStyle(.plain)
                                        .frame(width: 40, height: 24)
                                        .padding(.horizontal, 4)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.textBackgroundColor)))
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.purple.opacity(0.3), lineWidth: 0.8))
                                        .onSubmit { recomputePlotPoints() }

                                    Menu {
                                        Button("Full Range (\(String(format: "%.1f", continuousMinTime))–\(String(format: "%.1f", continuousMaxTime))s)") {
                                            timeStartText = String(format: "%.1f", continuousMinTime)
                                            timeStopText = String(format: "%.1f", continuousMaxTime)
                                            recomputePlotPoints()
                                        }
                                        Button("First 20% (0–\(String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.2))s)") {
                                            timeStartText = String(format: "%.1f", continuousMinTime)
                                            timeStopText = String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.2)
                                            recomputePlotPoints()
                                        }
                                        Button("First 50% (0–\(String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.5))s)") {
                                            timeStartText = String(format: "%.1f", continuousMinTime)
                                            timeStopText = String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.5)
                                            recomputePlotPoints()
                                        }
                                        Button("Last 50% (\(String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.5))–\(String(format: "%.1f", continuousMaxTime))s)") {
                                            timeStartText = String(format: "%.1f", continuousMinTime + (continuousMaxTime - continuousMinTime) * 0.5)
                                            timeStopText = String(format: "%.1f", continuousMaxTime)
                                            recomputePlotPoints()
                                        }
                                    } label: {
                                        Image(systemName: "slider.horizontal.2.square")
                                            .font(AppTypography.caption(uiFontSize: uiFontSize))
                                            .foregroundStyle(Color.purple)
                                            .frame(height: 24)
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                                .frame(height: 24)
                            } else {
                                // DISCRETE CYCLE / SCAN MODE: Multi-Select Pill Menu + Palette/Sweep Toggle
                                if !availableProgressionValues.isEmpty {
                                    Menu {
                                        Button {
                                            selectedProgressionValues.removeAll()
                                            recomputePlotPoints()
                                        } label: {
                                            HStack {
                                                Text("Select All (\(availableProgressionValues.count))")
                                                if selectedProgressionValues.isEmpty || selectedProgressionValues.count == availableProgressionValues.count {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }

                                        if let first = availableProgressionValues.first {
                                            Button {
                                                selectedProgressionValues = [first]
                                                recomputePlotPoints()
                                            } label: {
                                                HStack {
                                                    Text("First Only (Cycle \(first))")
                                                    if selectedProgressionValues == [first] {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }

                                        if let last = availableProgressionValues.last, availableProgressionValues.count > 1 {
                                            Button {
                                                selectedProgressionValues = [last]
                                                recomputePlotPoints()
                                            } label: {
                                                HStack {
                                                    Text("Last Only (Cycle \(last))")
                                                    if selectedProgressionValues == [last] {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }

                                            if let first = availableProgressionValues.first {
                                                Button {
                                                    selectedProgressionValues = [first, last]
                                                    recomputePlotPoints()
                                                } label: {
                                                    HStack {
                                                        Text("First & Last Overlay (\(first), \(last))")
                                                        if selectedProgressionValues == [first, last] {
                                                            Image(systemName: "checkmark")
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        Divider()

                                        ForEach(availableProgressionValues, id: \.self) { val in
                                            Button {
                                                if selectedProgressionValues.isEmpty {
                                                    var all = Set(availableProgressionValues)
                                                    all.remove(val)
                                                    selectedProgressionValues = all
                                                } else if selectedProgressionValues.contains(val) {
                                                    selectedProgressionValues.remove(val)
                                                } else {
                                                    selectedProgressionValues.insert(val)
                                                    if selectedProgressionValues.count == availableProgressionValues.count {
                                                        selectedProgressionValues.removeAll()
                                                    }
                                                }
                                                recomputePlotPoints()
                                            } label: {
                                                HStack {
                                                    Text("Cycle \(val)")
                                                    if selectedProgressionValues.isEmpty || selectedProgressionValues.contains(val) {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(progressionFilterSummary)
                                                .font(AppTypography.mono(size: 10, weight: .semibold, uiFontSize: uiFontSize))
                                            Image(systemName: "chevron.down")
                                                .font(AppTypography.chevron(uiFontSize: uiFontSize))
                                        }
                                        .padding(.horizontal, 8)
                                        .frame(height: 24)
                                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                                        .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 0.8))
                                    }
                                    .menuStyle(.borderlessButton)
                                }

                                // Color Style: [ Palette | Sweep ]
                                Picker("", selection: $discreteColorMode) {
                                    Label("Palette", systemImage: "paintpalette").tag(ProgressionColorMode.multiColor)
                                    Label("Sweep", systemImage: "swatchpalette").tag(ProgressionColorMode.sweep)
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                                .frame(height: 24)
                                .frame(width: 150)
                            }
                        }
                    }
                }

                Spacer()

                Text("\(totalPointCount) pts")
                    .font(AppTypography.caption(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(Capsule().fill(.quaternary))
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Divider()

            if cachedSegments.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("No numeric curve detected for selected X/Y.\nPick different channels or progression cycles above.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            } else {
                GeometryReader { containerGeo in
                    let layout = computePlotLayout(for: containerGeo.size)
                    let plot = layout.plot
                    let fontScale = layout.fontScale

                    ZStack(alignment: .topLeading) {
                        // 1. Publication GraphicsContext Canvas - Nature Single Spine, Outward Ticks, Scaled Typography
                        Canvas { context, _ in
                            // Nature spine frame
                            PlotRenderingEngine.drawSpineFrame(plot: plot, preset: .natureSingle, in: &context)

                            let tickLen = PlotRenderingEngine.tickLength(fontScale: fontScale, preset: .natureSingle)
                            let tickLabelSize = PlotRenderingEngine.tickLabelFontSize(preset: .natureSingle, fontScale: fontScale)
                            let spineWidth = PlotRenderingEngine.spineThickness(preset: .natureSingle)
                            let axisLabelSize = PlotRenderingEngine.axisLabelFontSize(preset: .natureSingle, fontScale: fontScale)

                            // Outward ticks & tick values
                            for index in 0...4 {
                                let t = Double(index) / 4.0
                                let x = cachedBounds.minX + t * (cachedBounds.maxX - cachedBounds.minX)
                                let y = cachedBounds.minY + t * (cachedBounds.maxY - cachedBounds.minY)
                                let px = plot.minX + CGFloat(t) * plot.width
                                let py = plot.maxY - CGFloat(t) * plot.height

                                var xTick = Path(); xTick.move(to: CGPoint(x: px, y: plot.maxY)); xTick.addLine(to: CGPoint(x: px, y: plot.maxY + tickLen))
                                var yTick = Path(); yTick.move(to: CGPoint(x: plot.minX, y: py)); yTick.addLine(to: CGPoint(x: plot.minX - tickLen, y: py))
                                context.stroke(xTick, with: .color(.primary), lineWidth: spineWidth)
                                context.stroke(yTick, with: .color(.primary), lineWidth: spineWidth)

                                context.draw(
                                    Text(formatTick(x)).font(PlotRenderingEngine.plotFont(preset: .natureSingle, size: tickLabelSize)),
                                    at: CGPoint(x: px, y: plot.maxY + tickLen + 3.0),
                                    anchor: .top
                                )
                                context.draw(
                                    Text(formatTick(y)).font(PlotRenderingEngine.plotFont(preset: .natureSingle, size: tickLabelSize)),
                                    at: CGPoint(x: plot.minX - tickLen - 3.0, y: py),
                                    anchor: .trailing
                                )
                            }

                            // Dynamic Axis Titles formatted as <Title> (<Unit>) via ScientificTypography
                            context.draw(
                                Text(activeXLabel).font(PlotRenderingEngine.plotFont(preset: .natureSingle, size: axisLabelSize, bold: false)),
                                at: CGPoint(x: plot.midX, y: plot.maxY + tickLen + 3.0 + tickLabelSize + 6.0),
                                anchor: .top
                            )

                            let yTitleX = max(14 * fontScale, plot.minX - tickLen - 3.0 - layout.maxLabelWidth - (12 * fontScale))
                            var yLabelContext = context
                            yLabelContext.translateBy(x: yTitleX, y: plot.midY)
                            yLabelContext.rotate(by: .degrees(-90))
                            yLabelContext.draw(
                                Text(activeYLabel).font(PlotRenderingEngine.plotFont(preset: .natureSingle, size: axisLabelSize, bold: false)),
                                at: .zero,
                                anchor: .center
                            )

                            // Clipped Data Curves
                            var plotContext = context
                            plotContext.clip(to: Path(plot))

                            let spanX = max(1e-12, cachedBounds.maxX - cachedBounds.minX)
                            let spanY = max(1e-12, cachedBounds.maxY - cachedBounds.minY)
                            let totalSegs = cachedSegments.count

                            for (sIdx, seg) in cachedSegments.enumerated() {
                                let pts = seg.points
                                guard !pts.isEmpty else { continue }
                                let isHl = (highlightedCycle == seg.name)
                                let isDim = (highlightedCycle != nil && !isHl)
                                let cWidth: CGFloat = isHl ? 2.8 : (isDim ? 1.0 : 1.5)
                                let cAlpha: Double = isHl ? 1.0 : (isDim ? 0.22 : 0.9)

                                let strideStep = max(1, pts.count / 2000)
                                var canvasPoints: [CGPoint] = []
                                for i in stride(from: 0, to: pts.count, by: strideStep) {
                                    let p = pts[i]
                                    let dx: Double = p.x - cachedBounds.minX
                                    let dy: Double = p.y - cachedBounds.minY
                                    let normX = CGFloat(dx / spanX)
                                    let normY = CGFloat(dy / spanY)
                                    let px = plot.minX + normX * plot.width
                                    let py = plot.maxY - normY * plot.height
                                    canvasPoints.append(CGPoint(x: px, y: py))
                                }
                                if let last = pts.last, (pts.count - 1) % strideStep != 0 {
                                    let dx: Double = last.x - cachedBounds.minX
                                    let dy: Double = last.y - cachedBounds.minY
                                    let normX = CGFloat(dx / spanX)
                                    let normY = CGFloat(dy / spanY)
                                    let px = plot.minX + normX * plot.width
                                    let py = plot.maxY - normY * plot.height
                                    canvasPoints.append(CGPoint(x: px, y: py))
                                }

                                if isContinuousMode {
                                    PlotRenderingEngine.renderRun(
                                        points: canvasPoints,
                                        mark: .line,
                                        interpolation: .spline,
                                        color: .blue.opacity(cAlpha),
                                        lineWidth: cWidth,
                                        markerSize: 3.5,
                                        colorBySweepProgress: true,
                                        in: &plotContext
                                    )
                                } else if discreteColorMode == .sweep {
                                    let frac = Double(sIdx) / Double(max(1, totalSegs - 1))
                                    let sweepColor = PlotRenderingEngine.sweepColor(at: frac).opacity(cAlpha)
                                    PlotRenderingEngine.renderRun(
                                        points: canvasPoints,
                                        mark: .line,
                                        interpolation: .spline,
                                        color: sweepColor,
                                        lineWidth: cWidth,
                                        markerSize: 3.5,
                                        colorBySweepProgress: false,
                                        in: &plotContext
                                    )
                                } else {
                                    let paletteColor = NativeOverlayPalette.color(sIdx).opacity(cAlpha)
                                    PlotRenderingEngine.renderRun(
                                        points: canvasPoints,
                                        mark: .line,
                                        interpolation: .spline,
                                        color: paletteColor,
                                        lineWidth: cWidth,
                                        markerSize: 3.5,
                                        colorBySweepProgress: false,
                                        in: &plotContext
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // 2. Twin Overlays: Sweep Colorbar or Discrete Multi-Color Legend
                        if isContinuousMode {
                            continuousSweepOverlay(plot: plot)
                        } else if discreteColorMode == .sweep {
                            discreteSweepOverlay(plot: plot)
                        } else if cachedSegments.count > 1 {
                            discretePaletteOverlay(plot: plot)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    )
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .task(id: "\(lines.count):\(delimiter):\(activeXIndex):\(activeYIndex):\(activeProgressionIndex ?? -1):\(selectedProgressionValues.sorted().joined(separator: ",")):\(timeStartText):\(timeStopText)") {
            recomputePlotPoints()
        }
        .onAppear {
            recomputePlotPoints()
        }
    }

    private func recomputePlotPoints(forceContinuous: Bool? = nil) {
        let xIdx = activeXIndex
        let yIdx = activeYIndex
        let progIdx = activeProgressionIndex
        let sep = delimiter == "\\t" ? "\t" : delimiter
        let start = dataStartIndex
        let linesSnapshot = lines
        let tagsSnapshot = lineTags
        let currentSelectedProg = selectedProgressionValues
        let currentProgCol = activeProgressionColumn
        let startTimeFilter = Double(timeStartText)
        let stopTimeFilter = Double(timeStopText)
        let manualOverride = forceContinuous

        Task.detached(priority: .userInitiated) {
            var orderedProgressionKeys: [String] = []
            var progressionSegments: [String: [(Double, Double)]] = [:]
            var allDiscoveredProgVals: [String] = []
            var seenProgVals: Set<String> = []
            var continuousVals: [Double] = []

            for (lineIdx, line) in linesSnapshot.enumerated() {
                guard lineIdx >= start else { continue }
                if let tag = tagsSnapshot[lineIdx], tag == .metadata || tag == .columnHeaders { continue }

                let tokens = line.components(separatedBy: sep)
                guard xIdx < tokens.count && yIdx < tokens.count else { continue }

                let xStr = tokens[xIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
                let yStr = tokens[yIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")

                guard let xVal = Double(xStr), let yVal = Double(yStr), xVal.isFinite, yVal.isFinite else {
                    continue
                }

                let progVal: String
                if let pIdx = progIdx, pIdx < tokens.count {
                    let rawP = tokens[pIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedP = rawP.replacingOccurrences(of: ",", with: ".")
                    if let d = Double(normalizedP) {
                        continuousVals.append(d)
                        if d.truncatingRemainder(dividingBy: 1) == 0 {
                            progVal = "\(Int(d))"
                        } else {
                            progVal = String(format: "%.3f", d)
                        }
                    } else {
                        progVal = rawP.isEmpty ? "1" : rawP
                    }
                } else {
                    progVal = "default"
                }

                if !seenProgVals.contains(progVal) {
                    seenProgVals.insert(progVal)
                    allDiscoveredProgVals.append(progVal)
                    orderedProgressionKeys.append(progVal)
                }

                progressionSegments[progVal, default: []].append((xVal, yVal))
            }

            // Determine if column behaves as Continuous Time or Discrete Cycles
            let isTimeOrContinuous: Bool
            let minTime: Double
            let maxTime: Double
            if let override = manualOverride {
                isTimeOrContinuous = override
            } else if let pCol = currentProgCol {
                if let beh = pCol.progressionBehavior {
                    isTimeOrContinuous = (beh == .continuous)
                } else {
                    let nameLower = pCol.name.lowercased()
                    let labelLower = pCol.label.lowercased()
                    let isTimeNamed = pCol.progressionType == .time || nameLower.contains("time") || labelLower.contains("time")
                    let hasHighCardinality = seenProgVals.count > 50
                    isTimeOrContinuous = isTimeNamed || hasHighCardinality
                }
            } else {
                isTimeOrContinuous = false
            }

            if !continuousVals.isEmpty {
                minTime = continuousVals.min() ?? 0.0
                maxTime = continuousVals.max() ?? 1.0
            } else {
                minTime = 0.0
                maxTime = 1.0
            }

            var activeSegments: [SandboxSegment] = []
            var localMinX: Double = .greatestFiniteMagnitude
            var localMaxX: Double = -.greatestFiniteMagnitude
            var localMinY: Double = .greatestFiniteMagnitude
            var localMaxY: Double = -.greatestFiniteMagnitude

            if isTimeOrContinuous {
                // Continuous time slicing: filter points based on range [start, stop]
                let startLimit = startTimeFilter ?? minTime
                let stopLimit = stopTimeFilter ?? maxTime
                var slicePts: [(Double, Double)] = []

                for (lineIdx, line) in linesSnapshot.enumerated() {
                    guard lineIdx >= start else { continue }
                    if let tag = tagsSnapshot[lineIdx], tag == .metadata || tag == .columnHeaders { continue }

                    let tokens = line.components(separatedBy: sep)
                    guard xIdx < tokens.count && yIdx < tokens.count else { continue }

                    let xStr = tokens[xIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
                    let yStr = tokens[yIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")

                    guard let xVal = Double(xStr), let yVal = Double(yStr), xVal.isFinite, yVal.isFinite else {
                        continue
                    }

                    if let pIdx = progIdx, pIdx < tokens.count {
                        let rawP = tokens[pIdx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
                        if let tVal = Double(rawP) {
                            if tVal < startLimit || tVal > stopLimit {
                                continue
                            }
                        }
                    }

                    slicePts.append((xVal, yVal))
                    if xVal < localMinX { localMinX = xVal }
                    if xVal > localMaxX { localMaxX = xVal }
                    if yVal < localMinY { localMinY = yVal }
                    if yVal > localMaxY { localMaxY = yVal }
                }

                if !slicePts.isEmpty {
                    activeSegments.append(SandboxSegment(name: "Time Window", points: slicePts))
                }
            } else {
                // Discrete Cycles: Filter segments based on selectedProgressionValues
                for key in orderedProgressionKeys {
                    if !currentSelectedProg.isEmpty && !currentSelectedProg.contains(key) {
                        continue
                    }

                    if let pts = progressionSegments[key], !pts.isEmpty {
                        activeSegments.append(SandboxSegment(name: key == "default" ? "Data" : key, points: pts))
                        for p in pts {
                            if p.0 < localMinX { localMinX = p.0 }
                            if p.0 > localMaxX { localMaxX = p.0 }
                            if p.1 < localMinY { localMinY = p.1 }
                            if p.1 > localMaxY { localMaxY = p.1 }
                        }
                    }
                }
            }

            let bounds: (Double, Double, Double, Double) = activeSegments.isEmpty ? (0, 1, 0, 1) : (localMinX, localMaxX, localMinY, localMaxY)
            let finalSegments = activeSegments
            let finalDiscovered = (progIdx != nil && !isTimeOrContinuous) ? allDiscoveredProgVals : []

            await MainActor.run {
                self.isContinuousMode = isTimeOrContinuous
                self.continuousMinTime = minTime
                self.continuousMaxTime = maxTime
                if isTimeOrContinuous && self.timeStartText.isEmpty && self.timeStopText.isEmpty {
                    self.timeStartText = String(format: "%.1f", minTime)
                    self.timeStopText = String(format: "%.1f", maxTime)
                }
                self.availableProgressionValues = finalDiscovered
                self.cachedSegments = finalSegments
                self.cachedBounds = bounds
            }
        }
    }

    @ViewBuilder
    private func continuousSweepOverlay(plot: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progCol = activeProgressionColumn {
                let dimLabel = progCol.label.isEmpty ? progCol.name : progCol.label
                let unitPart = progCol.unit.isEmpty ? "" : " (\(progCol.unit))"
                let rangePart: String = {
                    if let s = Double(timeStartText), let e = Double(timeStopText) {
                        return String(format: "%.1f–%.1fs (Full: %.1f–%.1fs)", s, e, continuousMinTime, continuousMaxTime)
                    } else {
                        return String(format: "%.1f–%.1fs", continuousMinTime, continuousMaxTime)
                    }
                }()
                Text("\(dimLabel)\(unitPart): \(rangePart)")
                    .font(StudioTokens.captionBold(uiFontSize: uiFontSize))
                    .foregroundStyle(Color.purple)
            }
            SweepColorbarView()
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.purple.opacity(0.25), lineWidth: 0.8)
        )
        .offset(x: plot.minX + 8, y: plot.minY + 8)
    }

    @ViewBuilder
    private func discreteSweepOverlay(plot: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let firstVal = availableProgressionValues.first ?? "1"
            let lastVal = availableProgressionValues.last ?? "\(availableProgressionValues.count)"
            Text("Progression: Cycle \(firstVal) (Start) → Cycle \(lastVal) (End)")
                .font(StudioTokens.captionBold(uiFontSize: uiFontSize))
                .foregroundStyle(Color.purple)
            SweepColorbarView()
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.purple.opacity(0.25), lineWidth: 0.8)
        )
        .offset(x: plot.minX + 8, y: plot.minY + 8)
    }

    @ViewBuilder
    private func discretePaletteOverlay(plot: CGRect) -> some View {
        let legendItems = cachedSegments.enumerated().map { sIdx, seg in
            (color: NativeOverlayPalette.color(sIdx), label: seg.name)
        }
        let totalCount = cachedSegments.count
        let cardWidth: CGFloat = totalCount <= 6 ? 140 : 155
        let baseX = max(10, plot.maxX - cardWidth - 12)
        let baseY = plot.minY + 8

        VStack(alignment: .leading, spacing: 5) {
            // Header with cycle count, drag handle & optional Reset button
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 7.5))
                    .foregroundStyle(.tertiary)
                Text("Cycles (\(totalCount)):")
                    .font(StudioTokens.captionBold(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
                Spacer()
                if highlightedCycle != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            highlightedCycle = nil
                        }
                    } label: {
                        Text("Reset")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if totalCount <= 6 {
                VStack(alignment: .leading, spacing: 2.5) {
                    ForEach(Array(legendItems.enumerated()), id: \.offset) { _, item in
                        cycleLegendRow(item: item)
                    }
                }
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        ForEach(Array(legendItems.enumerated()), id: \.offset) { _, item in
                            cycleLegendRow(item: item)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 130)
            }
        }
        .padding(7)
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.ultraThinMaterial.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(highlightedCycle != nil ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        .offset(x: baseX + legendOffset.width, y: baseY + legendOffset.height)
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    legendOffset = CGSize(
                        width: legendDragBase.width + gesture.translation.width,
                        height: legendDragBase.height + gesture.translation.height
                    )
                }
                .onEnded { _ in
                    legendDragBase = legendOffset
                }
        )
    }

    @ViewBuilder
    private func cycleLegendRow(item: (color: Color, label: String)) -> some View {
        let isHl = (highlightedCycle == item.label)
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if highlightedCycle == item.label {
                    highlightedCycle = nil
                } else {
                    highlightedCycle = item.label
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(item.color)
                    .frame(width: isHl ? 8.5 : 7, height: isHl ? 8.5 : 7)
                    .overlay(
                        Circle().stroke(Color.primary.opacity(isHl ? 0.6 : 0), lineWidth: 1)
                    )
                Text(item.label)
                    .font(isHl ? StudioTokens.captionBold(uiFontSize: uiFontSize) : StudioTokens.caption(uiFontSize: uiFontSize))
                    .foregroundStyle(isHl ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
                if isHl {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(item.color)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHl ? item.color.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isHl ? item.color.opacity(0.4) : Color.clear, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private func formatTick(_ val: Double) -> String {
        if abs(val) >= 1000 || (abs(val) > 0 && abs(val) < 0.01) {
            return String(format: "%.1e", val)
        }
        return String(format: "%.2f", val)
    }

    private func computePlotLayout(for size: CGSize) -> (plot: CGRect, fontScale: CGFloat, maxLabelWidth: CGFloat, yLabels: [String]) {
        let minY = cachedBounds.minY
        let maxY = cachedBounds.maxY
        let yLabels: [String] = (0...4).map { idx in
            let t = Double(idx) / 4.0
            return formatTick(minY + t * (maxY - minY))
        }
        let targetRatio: CGFloat = 59.1 / 50.0 // Nature single column
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
        return (plot, fontScale, maxLabelWidth, yLabels)
    }
}
