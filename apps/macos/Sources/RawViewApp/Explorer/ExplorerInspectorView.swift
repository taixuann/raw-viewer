import AppKit
import SwiftUI
import RawViewCore

enum InspectorTab: String, CaseIterable, Identifiable {
    case data = "Data"
    case style = "Style"
    case canvas = "Canvas"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .data: return "chart.xyaxis.line"
        case .style: return "paintpalette"
        case .canvas: return "aspectratio"
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    var badge: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                Spacer()
            }
            .padding(.bottom, 2)

            content()

            Divider()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InspectorPane: View {
    let measurement: NormalizedMeasurement?
    let inspection: SourceInspection?
    let source: URL?
    var sourceID: String? = nil
    let error: String?
    let states: [String: GallerySourceState]
    let selectedIDs: Set<String>
    @Binding var focusedID: String?
    @Binding var hidden: Set<String>
    @Binding var lineWidth: Double
    @Binding var renderStyle: PlotRenderStyle
    @Binding var markType: PlotMarkType
    @Binding var interpolation: PlotInterpolation
    @Binding var markerSize: Double
    @Binding var colorBySweepProgress: Bool
    @Binding var progressionFilterEnabled: Bool
    @Binding var selectedProgressionChannel: String?
    @Binding var selectedCycles: Set<String>
    @Binding var colorByCycle: Bool
    @Binding var xAbsolute: Bool
    @Binding var yAbsolute: Bool
    @Binding var xScale: AxisScale
    @Binding var yScale: AxisScale
    let overlay: OverlayEligibility?
    let onRetry: () -> Void
    @Binding var showLegend: Bool
    @Binding var legendScale: Double
    @Binding var customSeriesLabels: [String: String]
    @Binding var customSeriesColors: [String: Color]
    var orderedSelectedIDs: [String] = []
    var onMoveSeries: ((String, Int) -> Void)? = nil
    @Binding var legendOffset: CGSize
    @Binding var comparisonTitle: String
    var onSaveSnapshot: (() -> Void)? = nil
    var activeSnapshotID: UUID? = nil
    @Binding var axisConfig: PlotAxisConfig
    var liveMetrics: PlotLiveMetrics = PlotLiveMetrics()
    @Binding var snapshotDPI: Int
    var onSelectGenericColumns: ((Int, Int) -> Void)? = nil
    var eligibleX: [String] = []
    var eligibleY: [String] = []
    var defaultY: [String] = []
    var selectedX: String? = nil
    var selectedY: [String]? = nil
    var axisNote: String? = nil
    var onSelectX: ((String) -> Void)? = nil
    var onSelectY: (([String]?) -> Void)? = nil
    var onResetAxes: (() -> Void)? = nil

    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0
    @State private var selectedTab: InspectorTab = .data

    var body: some View {
        VStack(spacing: 0) {
            // Inspector Header
            HStack {
                Text("INSPECTOR")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let measurement {
                    Text(measurement.instrument.id)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            // SwiftPieces TrackingTabs Segmented Switcher
            tabSwitcher
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if measurement == nil && inspection == nil && source == nil && selectedIDs.isEmpty {
                        VStack(spacing: 12) {
                            Spacer(minLength: 60)
                            ContentUnavailableView("No Selection", systemImage: "sidebar.right",
                                description: Text("Select a measurement source to inspect metadata and plot settings."))
                            Spacer(minLength: 60)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        switch selectedTab {
                        case .data:
                            dataTabContent
                        case .style:
                            styleTabContent
                        case .canvas:
                            canvasTabContent
                        }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
                .padding(14)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background)
    }

    // MARK: - SwiftPieces TrackingTabs Switcher

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(InspectorTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 9.5 * AppTypography.scale(for: uiFontSize), weight: isSelected ? .semibold : .regular))
                        Text(tab.rawValue)
                            .font(AppTypography.font(size: 11, weight: isSelected ? .semibold : .regular, uiFontSize: uiFontSize))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                .accessibilityLabel("\(tab.rawValue) tab")
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Tab 1: Data & Axes

    @ViewBuilder
    private var dataTabContent: some View {
        if !selectedIDs.isEmpty {
            InspectorSection(title: "SERIES", badge: "\(selectedIDs.count)") {
                VStack(alignment: .leading, spacing: 8) {
                    if selectedIDs.count >= 2 || activeSnapshotID != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SNAPSHOT / COMPARISON TITLE")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                TextField("Comparison Title…", text: $comparisonTitle)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                if let onSaveSnapshot {
                                    Button {
                                        onSaveSnapshot()
                                    } label: {
                                        Image(systemName: "camera")
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help("Save snapshot with this title")
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }

                    let displayIDs = orderedSelectedIDs.isEmpty ? selectedIDs.sorted() : orderedSelectedIDs
                    ForEach(Array(displayIDs.enumerated()), id: \.element) { idx, id in
                        seriesRow(id, index: idx, totalCount: displayIDs.count)
                    }

                    if case .blocked(let reason) = overlay {
                        Text(reason).font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                    } else if case .eligible(let path) = overlay {
                        let label = (path == "Comparison" || path.isEmpty) ? "Multi-source comparison" : "Shared manifest \(URL(fileURLWithPath: path).lastPathComponent)"
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                    } else if case .partial(let group) = overlay {
                        let label = (group.manifestPath == "Comparison" || group.manifestPath.isEmpty) ? "Plotting compatible cohort" : "Shared manifest \(URL(fileURLWithPath: group.manifestPath).lastPathComponent)"
                        Text("\(label) (\(group.plottedPaths.count) of \(group.plottedPaths.count + group.excluded.count)). Selection unchanged.").font(.caption2).foregroundStyle(.secondary)
                        ForEach(group.excluded, id: \.path) { exclusion in
                            Text("Excluded \(URL(fileURLWithPath: exclusion.path).lastPathComponent): \(exclusion.reason)").font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                }
            }
        }

        if measurement?.instrument.id == "generic-table" {
            genericTableSection
        }

        axesSection

        progressionSection

        if let km = keithleyMetadata {
            keithleyMetadataSection(km)
        }

        metadataComparisonSection
    }

    @ViewBuilder
    private var genericTableSection: some View {
        if let measurement, measurement.instrument.id == "generic-table" {
            let channels = measurement.channels
            let xCurrent = channels.firstIndex(where: { $0.name == measurement.view.x }) ?? 0
            let yCurrent = channels.firstIndex(where: { $0.name == measurement.view.y?.first }) ?? min(1, max(0, channels.count - 1))

            InspectorSection(title: "DATA MAPPING", badge: "Generic Table") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-detected Delimited Table")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if channels.count >= 2 {
                        HStack {
                            Text("X Column")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("X Column", selection: Binding(
                                get: { xCurrent },
                                set: { newX in onSelectGenericColumns?(newX, yCurrent) }
                            )) {
                                ForEach(0..<channels.count, id: \.self) { idx in
                                    Text("[\(idx)] \(channels[idx].label)").tag(idx)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        HStack {
                            Text("Y Column")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("Y Column", selection: Binding(
                                get: { yCurrent },
                                set: { newY in onSelectGenericColumns?(xCurrent, newY) }
                            )) {
                                ForEach(0..<channels.count, id: \.self) { idx in
                                    Text("[\(idx)] \(channels[idx].label)").tag(idx)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                }
            }
        }
    }

    private var axesSection: some View {
        InspectorSection(title: "AXES & SCALES") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("X Axis")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if effectiveEligibleX.count >= 2 {
                        Picker("X Channel", selection: Binding(
                            get: { selectedX ?? measurement?.view.x ?? "" },
                            set: { onSelectX?($0) }
                        )) {
                            ForEach(effectiveEligibleX, id: \.self) { id in
                                Text(channelOptionLabel(id)).tag(id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    } else {
                        Text(channelOptionLabel(selectedX ?? measurement?.view.x ?? ""))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                HStack {
                    Text("Y Axis")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if effectiveEligibleY.count >= 2 {
                        Picker("Y Channel", selection: Binding(
                            get: { selectedY?.first ?? "default" },
                            set: { key in onSelectY?(key == "default" ? nil : [key]) }
                        )) {
                            Text(defaultSeriesLabel).tag("default")
                            ForEach(effectiveEligibleY, id: \.self) { id in
                                Text(channelOptionLabel(id)).tag(id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    } else {
                        Text(channelOptionLabel(selectedY?.first ?? measurement?.view.y?.first ?? "Default"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                axisControl("X", absolute: $xAbsolute, scale: $xScale)
                axisControl("Y", absolute: $yAbsolute, scale: $yScale)

                Text("Absolute applies before scale; log requires positive values.")
                    .font(.caption2).foregroundStyle(.secondary)

                if let axisNote {
                    Text(axisNote)
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Button("Reset to Variant Defaults") { onResetAxes?() }
                        .font(.caption2).buttonStyle(.bordered).controlSize(.small)
                } else if selectedX != nil || selectedY != nil {
                    Button("Reset to Variant Defaults") { onResetAxes?() }
                        .font(.caption2).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    // MARK: - Tab 2: Style & Curves

    @ViewBuilder
    private var styleTabContent: some View {
        InspectorSection(title: "LINES & MARKS") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Mark Type")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Mark Type", selection: $markType) {
                        ForEach(PlotMarkType.allCases) { mark in
                            Text(mark.rawValue).tag(mark)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }

                if markType != .dots {
                    HStack {
                        Text("Connection")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Connection", selection: $interpolation) {
                            ForEach(PlotInterpolation.allCases) { interp in
                                Text(interp.rawValue).tag(interp)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    HStack {
                        Text("Line Width")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Text(String(format: "%.1f pt", lineWidth))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(width: 48, alignment: .trailing)
                            Stepper("", value: $lineWidth, in: 0.2...5.0, step: 0.1)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                    }
                }

                if markType != .line {
                    HStack {
                        Text("Marker Size")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Text(String(format: "%.1f pt", markerSize))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(width: 48, alignment: .trailing)
                            Stepper("", value: $markerSize, in: 2.0...10.0, step: 0.5)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                    }
                }
            }
        }

        legendSection

        axesAndTicksSection

        interactionSection

        exportSection
    }

    private var axesAndTicksSection: some View {
        InspectorSection(title: "REGION, AXES & TICKS") {
            VStack(alignment: .leading, spacing: 10) {
                regionRow(
                    title: "X Region",
                    liveRange: liveMetrics.xRange,
                    minVal: $axisConfig.xRegionMin,
                    maxVal: $axisConfig.xRegionMax
                )

                paddingRow(title: "X Padding", percent: $axisConfig.xPaddingPercent)

                regionRow(
                    title: "Y Region",
                    liveRange: liveMetrics.yRange,
                    minVal: $axisConfig.yRegionMin,
                    maxVal: $axisConfig.yRegionMax
                )

                paddingRow(title: "Y Padding", percent: $axisConfig.yPaddingPercent)

                Divider()

                majorTickRow(
                    title: "X Major Ticks",
                    count: $axisConfig.xTickCount,
                    liveCount: liveMetrics.xTickCount
                )

                majorTickRow(
                    title: "Y Major Ticks",
                    count: $axisConfig.yTickCount,
                    liveCount: liveMetrics.yTickCount
                )

                minorTickRow(title: "X Minor Ticks", count: $axisConfig.xMinorTicks)
                minorTickRow(title: "Y Minor Ticks", count: $axisConfig.yMinorTicks)

                Divider()

                Toggle(isOn: $axisConfig.showMajorGrid) {
                    Text("Major Gridlines")
                        .font(AppTypography.body(uiFontSize: uiFontSize))
                }

                Toggle(isOn: $axisConfig.showMinorGrid) {
                    Text("Minor Gridlines")
                        .font(AppTypography.body(uiFontSize: uiFontSize))
                }

                Toggle(isOn: $axisConfig.showZeroLine) {
                    Text("Zero Reference Lines (y = 0 / x = 0)")
                        .font(AppTypography.body(uiFontSize: uiFontSize))
                }
            }
        }
    }

    @ViewBuilder
    private func regionRow(
        title: String,
        liveRange: ClosedRange<Double>?,
        minVal: Binding<Double?>,
        maxVal: Binding<Double?>
    ) -> some View {
        let isCustom = minVal.wrappedValue != nil || maxVal.wrappedValue != nil
        let autoMinStr = liveRange.map { formatRegionNumber($0.lowerBound) } ?? "Auto"
        let autoMaxStr = liveRange.map { formatRegionNumber($0.upperBound) } ?? "Auto"

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(AppTypography.body(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
                Spacer()
                if isCustom {
                    Button("Auto") {
                        minVal.wrappedValue = nil
                        maxVal.wrappedValue = nil
                    }
                    .font(AppTypography.badge(uiFontSize: uiFontSize))
                    .buttonStyle(.borderless)
                } else {
                    Text("Auto")
                        .font(AppTypography.badge(uiFontSize: uiFontSize))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                optionalNumberField(placeholder: autoMinStr, value: minVal)
                Text("to")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
                optionalNumberField(placeholder: autoMaxStr, value: maxVal)
            }
        }
    }

    @ViewBuilder
    private func paddingRow(title: String, percent: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AppTypography.body(uiFontSize: uiFontSize))
                .foregroundStyle(.secondary)
            Spacer()
            if percent.wrappedValue != 4.0 {
                Button("Default") {
                    percent.wrappedValue = 4.0
                }
                .font(AppTypography.badge(uiFontSize: uiFontSize))
                .buttonStyle(.borderless)
            }
            BufferedIntField(
                placeholder: "4",
                value: Int(percent.wrappedValue.rounded()),
                range: 0...30,
                font: AppTypography.tokenCode(uiFontSize: uiFontSize),
                onCommit: { newVal in percent.wrappedValue = Double(newVal) }
            )
            .frame(width: 40)
            Text("%")
                .font(AppTypography.helperText(uiFontSize: uiFontSize))
                .foregroundStyle(.secondary)
            Stepper("", value: Binding(
                get: { Int(percent.wrappedValue.rounded()) },
                set: { newVal in percent.wrappedValue = Double(min(max(newVal, 0), 30)) }
            ), in: 0...30)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func optionalNumberField(placeholder: String, value: Binding<Double?>) -> some View {
        BufferedOptionalDoubleField(
            placeholder: placeholder,
            value: value,
            font: AppTypography.tokenCode(uiFontSize: uiFontSize),
            formatter: formatRegionNumber
        )
    }

    private func formatRegionNumber(_ val: Double) -> String {
        if val == 0 { return "0" }
        let absVal = abs(val)
        if absVal >= 1000 || absVal < 0.001 {
            return String(format: "%.3g", val)
        }
        return String(format: "%.4g", val)
    }

    @ViewBuilder
    private func majorTickRow(title: String, count: Binding<Int>, liveCount: Int) -> some View {
        let isAuto = count.wrappedValue < 2
        HStack(spacing: 6) {
            Text(title)
                .font(AppTypography.body(uiFontSize: uiFontSize))
                .foregroundStyle(.secondary)
            Spacer()
            if !isAuto {
                Button("Auto") {
                    count.wrappedValue = 0
                }
                .font(AppTypography.badge(uiFontSize: uiFontSize))
                .buttonStyle(.borderless)
            } else {
                Text("Auto (\(liveCount))")
                    .font(AppTypography.badge(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
            }
            BufferedIntField(
                placeholder: "\(liveCount)",
                value: isAuto ? liveCount : count.wrappedValue,
                range: 2...25,
                font: AppTypography.tokenCode(uiFontSize: uiFontSize),
                onCommit: { newVal in count.wrappedValue = newVal }
            )
            .frame(width: 44)
            Stepper("", value: Binding(
                get: { isAuto ? liveCount : count.wrappedValue },
                set: { newVal in count.wrappedValue = min(max(newVal, 2), 25) }
            ), in: 2...25)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func minorTickRow(title: String, count: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AppTypography.body(uiFontSize: uiFontSize))
                .foregroundStyle(.secondary)
            Spacer()
            BufferedIntField(
                placeholder: "0",
                value: count.wrappedValue,
                range: 0...10,
                font: AppTypography.tokenCode(uiFontSize: uiFontSize),
                onCommit: { newVal in count.wrappedValue = newVal }
            )
            .frame(width: 44)
            Stepper("", value: Binding(
                get: { count.wrappedValue },
                set: { newVal in count.wrappedValue = min(max(newVal, 0), 10) }
            ), in: 0...10)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var interactionSection: some View {
        InspectorSection(title: "INTERACTION") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $axisConfig.showCursor) {
                    HStack(spacing: 4) {
                        Image(systemName: "cross.fill")
                            .font(.system(size: 10))
                        Text("Inspect Crosshair Cursor")
                            .font(AppTypography.body(uiFontSize: uiFontSize))
                    }
                }
                Text("Hover over curves to read exact (x, y) coordinates with scientific units.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exportSection: some View {
        InspectorSection(title: "HIGH-DPI SNAPSHOT EXPORT") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PNG Resolution")
                        .font(AppTypography.body(uiFontSize: uiFontSize))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("DPI", selection: $snapshotDPI) {
                        Text("300 DPI (Retina)").tag(300)
                        Text("600 DPI (Print)").tag(600)
                        Text("1200 DPI (Ultra)").tag(1200)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)
                }

                Text("Default export directory: data/snapshot/<name>/ (creates figure.png, vector figure.pdf, and list.yaml manifest).")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var legendSection: some View {
        InspectorSection(title: "LEGEND") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $showLegend) {
                    Text("Show Legend")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }

                if showLegend {
                    HStack {
                        Text("Legend Scale")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Text(String(format: "%.1fx", legendScale))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(width: 44, alignment: .trailing)
                            Stepper("", value: $legendScale, in: 0.6...2.5, step: 0.1)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                    }

                    Text("Legends are automatically omitted for single-series plots with matching axis title.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button("Reset Position") {
                            legendOffset = .zero
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .disabled(legendOffset == .zero)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var progressionSection: some View {
        if let measurement {
            let progChannel = measurement.progressionChannel
            let candidateChannels = measurement.channels.filter { ch in
                ch.quantity == "index" || ch.quantity == "time" ||
                ch.name.lowercased().contains("scan") || ch.name.lowercased().contains("cycle") ||
                ch.name.lowercased().contains("step") || ch.name.lowercased().contains("time")
            }
            if !candidateChannels.isEmpty || selectedProgressionChannel != nil {
                let activeChannel = selectedProgressionChannel.flatMap(measurement.channel(named:)) ?? progChannel
                let allCycles = ProgressionPlotReader.extractDiscreteKeys(from: activeChannel?.values)

                let isContinuous = activeChannel?.quantity == "time" && !(activeChannel?.name.lowercased().contains("scan") ?? false)

                InspectorSection(title: "PROGRESSION", badge: activeChannel?.label) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $progressionFilterEnabled) {
                            Text("Enable Progression Segmentation")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                        }

                        if progressionFilterEnabled {
                            HStack(spacing: 6) {
                                Text(isContinuous ? "Continuous" : "Discrete")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))

                                if !isContinuous {
                                    Text("\(allCycles.count) cycles detected")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                } else if let vals = activeChannel?.values.compactMap({ $0 }), let min = vals.min(), let max = vals.max() {
                                    Text(String(format: "%.1f – %.1f %@", min, max, activeChannel?.unit ?? ""))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if candidateChannels.count > 1 {
                                HStack {
                                    Text("Channel")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Picker("Progression Channel", selection: Binding(
                                        get: { activeChannel?.name ?? "" },
                                        set: { selectedProgressionChannel = $0 }
                                    )) {
                                        ForEach(candidateChannels, id: \.name) { ch in
                                            let isCont = ch.quantity == "time" && !ch.name.lowercased().contains("scan")
                                            Text("\(ch.label) (\(isCont ? "Continuous" : "Discrete"))").tag(ch.name)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }
                            }

                            if isContinuous {
                                Toggle(isOn: $colorBySweepProgress) {
                                    Text("Color by Sweep Progress (Colormap)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.primary)
                                }
                            } else {
                                Toggle(isOn: $colorByCycle) {
                                    Text("Color Segments by Cycle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.primary)
                                }

                            if !allCycles.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("CYCLES (\(selectedCycles.isEmpty ? allCycles.count : selectedCycles.count)/\(allCycles.count))")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button("All") {
                                            selectedCycles.removeAll()
                                        }
                                        .buttonStyle(.plain)
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)

                                        if allCycles.count > 1 {
                                            Button("First") {
                                                if let first = allCycles.first { selectedCycles = [first] }
                                            }
                                            .buttonStyle(.plain)
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)

                                            Button("Last") {
                                                if let last = allCycles.last { selectedCycles = [last] }
                                            }
                                            .buttonStyle(.plain)
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)

                                            if allCycles.count >= 5 {
                                                Button("Every 5th") {
                                                    selectedCycles = Set(stride(from: 0, to: allCycles.count, by: 5).map { allCycles[$0] })
                                                }
                                                .buttonStyle(.plain)
                                                .font(.caption2)
                                                .foregroundStyle(Color.accentColor)
                                            }
                                        }
                                    }

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 4) {
                                            ForEach(allCycles, id: \.self) { cycleKey in
                                                let isSelected = selectedCycles.isEmpty || selectedCycles.contains(cycleKey)
                                                Button {
                                                    if selectedCycles.isEmpty {
                                                        selectedCycles = [cycleKey]
                                                    } else if selectedCycles.contains(cycleKey) {
                                                        selectedCycles.remove(cycleKey)
                                                    } else {
                                                        selectedCycles.insert(cycleKey)
                                                    }
                                                } label: {
                                                    Text(cycleKey)
                                                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 3)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 4)
                                                                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                                                        )
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 4)
                                                                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 0.5)
                                                        )
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Keithley Programmed Sweep Metadata & Comparison

    private var keithleyMetadata: KeithleyMetadata? {
        if let source {
            return KeithleyMetadataParser.extract(from: source)
        }
        return nil
    }

    @ViewBuilder
    private func keithleyMetadataSection(_ meta: KeithleyMetadata) -> some View {
        InspectorSection(title: "PROGRAMMED SWEEP", badge: meta.isValid ? "Keithley 2400" : "Warning") {
            VStack(alignment: .leading, spacing: 8) {
                if let warning = meta.warning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 10))
                        Text(warning)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Text("Sweep Path")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(meta.sweepPath)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                HStack {
                    Text("Voltage Step")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(meta.voltageStep)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }

                HStack {
                    Text("Compliance Current")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(meta.compliance)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private var metadataComparisonSection: some View {
        if selectedIDs.count >= 2 {
            let items: [(id: String, meta: KeithleyMetadata?)] = selectedIDs.sorted().map { id in
                let url = URL(fileURLWithPath: id)
                return (id, KeithleyMetadataParser.extract(from: url))
            }
            let validMetas = items.compactMap(\.meta)
            if !validMetas.isEmpty {
                let allSamePath = Set(validMetas.map(\.sweepPath)).count <= 1
                let allSameStep = Set(validMetas.map(\.voltageStep)).count <= 1
                let allSameCompliance = Set(validMetas.map(\.compliance)).count <= 1

                InspectorSection(title: "METADATA COMPARISON", badge: "\(validMetas.count) files") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Sweep Path")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(allSamePath ? (validMetas.first?.sweepPath ?? "—") : "Varies across files")
                                .font(.system(size: 10.5, weight: allSamePath ? .medium : .bold, design: .monospaced))
                                .foregroundStyle(allSamePath ? Color.primary : Color.orange)
                        }

                        HStack {
                            Text("Voltage Step")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(allSameStep ? (validMetas.first?.voltageStep ?? "—") : "Varies across files")
                                .font(.system(size: 10.5, weight: allSameStep ? .medium : .bold))
                                .foregroundStyle(allSameStep ? Color.primary : Color.orange)
                        }

                        HStack {
                            Text("Compliance")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(allSameCompliance ? (validMetas.first?.compliance ?? "—") : "Varies across files")
                                .font(.system(size: 10.5, weight: allSameCompliance ? .medium : .bold))
                                .foregroundStyle(allSameCompliance ? Color.primary : Color.orange)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tab 3: Canvas

    private var canvasTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection(title: "PUBLICATION PRESET") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Publication presets specify exact column widths, font typography, and spine thicknesses matching journal guidelines (Nature, Science, ACS, IEEE).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let onSaveSnapshot {
                InspectorSection(title: "SNAPSHOT") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Save the current plot state, axis transforms, and styling into the project snapshot history.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Button {
                            onSaveSnapshot()
                        } label: {
                            Label("Save Plot Snapshot", systemImage: "camera")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Helper Views & Methods

    private var effectiveEligibleX: [String] {
        if !eligibleX.isEmpty { return eligibleX }
        guard let channels = measurement?.channels else { return [] }
        return channels.filter { ch in
            ch.quantity != "metadata" && ch.quantity != "index" && ch.quantity != "text"
        }.map(\.name)
    }

    private var effectiveEligibleY: [String] {
        if !eligibleY.isEmpty { return eligibleY }
        guard let channels = measurement?.channels else { return [] }
        return channels.filter { ch in
            ch.quantity != "metadata" && ch.quantity != "index" && ch.quantity != "text"
        }.map(\.name)
    }

    private func seriesRow(_ id: String, index: Int = 0, totalCount: Int = 1) -> some View {
        let isHidden = hidden.contains(id)
        let isFocused = focusedID == id
        let state = states[id]
        let filename = URL(fileURLWithPath: id).lastPathComponent
        let hasCustomColor = customSeriesColors[id] != nil
        let exclusionReason: String? = {
            if case .partial(let group) = overlay {
                return group.excluded.first(where: { $0.path == id })?.reason
            }
            return nil
        }()

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ColorPicker("", selection: Binding(
                    get: { seriesColor(id) },
                    set: { newColor in customSeriesColors[id] = newColor }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 20, height: 18)
                .help("Pick series color")

                TextField("Legend label…", text: Binding(
                    get: { customSeriesLabels[id] ?? "" },
                    set: { customSeriesLabels[id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .help("Custom legend label (leave empty to use filename)")

                if customSeriesLabels[id]?.isEmpty == false || hasCustomColor {
                    Button {
                        customSeriesLabels.removeValue(forKey: id)
                        customSeriesColors.removeValue(forKey: id)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset label and color to defaults")
                }

                if totalCount >= 2 {
                    HStack(spacing: 2) {
                        Button {
                            onMoveSeries?(id, -1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0)
                        .foregroundStyle(index == 0 ? Color.secondary.opacity(0.35) : Color.secondary)
                        .help("Move series up")

                        Button {
                            onMoveSeries?(id, 1)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(index >= totalCount - 1)
                        .foregroundStyle(index >= totalCount - 1 ? Color.secondary.opacity(0.35) : Color.secondary)
                        .help("Move series down")
                    }
                }

                if !isFocused {
                    Button {
                        focusedID = id
                        onRetry()
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Focus this source")
                }

                if exclusionReason == nil {
                    Toggle(isOn: Binding(get: { !isHidden }, set: { show in
                        if show { hidden.remove(id) } else { hidden.insert(id) }
                    })) {
                        Text("Show")
                    }
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(isHidden ? "Show this series" : "Hide this series")
                } else {
                    Text("Excluded")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 6) {
                Text(filename)
                    .font(AppTypography.tokenCode(uiFontSize: max(10, uiFontSize - 1)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(id)

                if isFocused {
                    Text("• Focused")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, 26)
            if let error = state?.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 26)
            } else if state?.isLoading == true {
                Text("Loading…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            } else if let exclusionReason {
                Text("Excluded: \(exclusionReason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
    }

    private func channelOptionLabel(_ id: String) -> String {
        guard let channel = measurement?.channel(named: id) else { return id }
        let unitSuffix = channel.unit.isEmpty ? "" : " (\(channel.unit))"
        let collisions = measurement?.channels.filter { $0.label == channel.label }.count ?? 0
        let baseLabel = collisions > 1 ? "\(channel.label) (\(id))" : channel.label
        return "\(baseLabel)\(unitSuffix)"
    }

    private var defaultSeriesLabel: String {
        let ids = defaultY.isEmpty ? (measurement?.view.y ?? []) : defaultY
        let labels = ids.map { measurement?.channel(named: $0)?.label ?? $0 }
        return labels.isEmpty ? "Default series" : "Default series (\(labels.joined(separator: " + ")))"
    }

    private func axisControl(_ name: String, absolute: Binding<Bool>, scale: Binding<AxisScale>) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 14, alignment: .leading)

            Button {
                absolute.wrappedValue.toggle()
            } label: {
                Text("|\(name.lowercased())|")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(absolute.wrappedValue ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(absolute.wrappedValue ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("Display absolute values |\(name.lowercased())| before applying the scale")
            .accessibilityLabel("\(name) absolute values")

            Picker(name + " scale", selection: scale) {
                Text("Lin").tag(AxisScale.linear)
                Text("Log").tag(AxisScale.logarithmic)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 96)
            .accessibilityLabel("\(name) axis scale")
        }
    }

    private func seriesColor(_ id: String) -> Color {
        if let custom = customSeriesColors[id] {
            return custom
        }
        let order = orderedSelectedIDs.isEmpty ? selectedIDs.sorted() : orderedSelectedIDs
        let index = order.firstIndex(of: id) ?? 0
        return NativeOverlayPalette.color(index)
    }
}

private struct BufferedOptionalDoubleField: View {
    let placeholder: String
    @Binding var value: Double?
    let font: Font
    let formatter: (Double) -> String

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(font)
            .frame(maxWidth: .infinity)
            .focused($isFocused)
            .onAppear { syncFromValue() }
            .onChange(of: value) { _, _ in
                if !isFocused { syncFromValue() }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit { commit() }
    }

    private func syncFromValue() {
        text = value.map(formatter) ?? ""
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            value = nil
        } else if let parsed = Double(trimmed), parsed.isFinite {
            value = parsed
        } else {
            syncFromValue()
        }
    }
}

private struct BufferedIntField: View {
    let placeholder: String
    let value: Int
    let range: ClosedRange<Int>
    let font: Font
    let onCommit: (Int) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(font)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onAppear { text = "\(value)" }
            .onChange(of: value) { _, newVal in
                if !isFocused { text = "\(newVal)" }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit { commit() }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Int(trimmed) {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            onCommit(clamped)
            text = "\(clamped)"
        } else {
            text = "\(value)"
        }
    }
}
