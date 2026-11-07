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

struct InspectorCard<Content: View>: View {
    let title: String
    var badge: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.85))
                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                Spacer()
            }

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
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
    @Binding var customSeriesLabels: [String: String]
    @Binding var legendOffset: CGSize
    @Binding var comparisonTitle: String
    var onSaveSnapshot: (() -> Void)? = nil
    var activeSnapshotID: UUID? = nil
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
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            InspectorCard(title: "SERIES", badge: "\(selectedIDs.count)") {
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

                    ForEach(selectedIDs.sorted(), id: \.self) { id in
                        seriesRow(id)
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
            genericTableCard
        }

        axesCard
    }

    @ViewBuilder
    private var genericTableCard: some View {
        if let measurement, measurement.instrument.id == "generic-table" {
            let channels = measurement.channels
            let xCurrent = channels.firstIndex(where: { $0.name == measurement.view.x }) ?? 0
            let yCurrent = channels.firstIndex(where: { $0.name == measurement.view.y?.first }) ?? min(1, max(0, channels.count - 1))

            InspectorCard(title: "DATA MAPPING", badge: "Generic Table") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Auto-detected Delimited Table")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if channels.count >= 2 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("X AXIS COLUMN")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.secondary)
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

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Y AXIS COLUMN")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.secondary)
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

    private var axesCard: some View {
        InspectorCard(title: "AXES & SCALES") {
            VStack(alignment: .leading, spacing: 8) {
                if effectiveEligibleX.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("X CHANNEL")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.secondary)
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
                    }
                }
                if effectiveEligibleY.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Y CHANNEL")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.secondary)
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
                    }
                }

                axisControl("X", absolute: $xAbsolute, scale: $xScale)
                axisControl("Y", absolute: $yAbsolute, scale: $yScale)

                Text("Absolute applies before the scale; log needs positive values.")
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
        InspectorCard(title: "MARKS & CURVES") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mark Type")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Picker("Mark Type", selection: $markType) {
                        ForEach(PlotMarkType.allCases) { mark in
                            Text(mark.rawValue).tag(mark)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if markType != .dots {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connection")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Picker("Connection", selection: $interpolation) {
                            ForEach(PlotInterpolation.allCases) { interp in
                                Text(interp.rawValue).tag(interp)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Line width")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            TextField("1.4", value: $lineWidth, format: .number.precision(.fractionLength(1)))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 44)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: $lineWidth, in: 0.2...5.0, step: 0.1)
                                .labelsHidden()
                                .controlSize(.small)
                            Text("pt").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Slider(value: $lineWidth, in: 0.2...5.0, step: 0.1)
                            .controlSize(.small)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                }

                if markType != .line {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Dot size")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            TextField("4.5", value: $markerSize, format: .number.precision(.fractionLength(1)))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 44)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: $markerSize, in: 2.0...10.0, step: 0.5)
                                .labelsHidden()
                                .controlSize(.small)
                            Text("pt").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Slider(value: $markerSize, in: 2.0...10.0, step: 0.5)
                            .controlSize(.small)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                }

                Toggle(isOn: $colorBySweepProgress) {
                    Text("Color by Sweep Progress")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
        }

        progressionCard
    }

    @ViewBuilder
    private var progressionCard: some View {
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

                InspectorCard(title: "PROGRESSION & CYCLES", badge: activeChannel?.label) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $progressionFilterEnabled) {
                            Text("Enable Cycle / Progression Segmentation")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                        }

                        if progressionFilterEnabled {
                            if candidateChannels.count > 1 {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("PROGRESSION CHANNEL")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(.secondary)
                                    Picker("Progression Channel", selection: Binding(
                                        get: { activeChannel?.name ?? "" },
                                        set: { selectedProgressionChannel = $0 }
                                    )) {
                                        ForEach(candidateChannels, id: \.name) { ch in
                                            Text("\(ch.label) (\(ch.name))").tag(ch.name)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }
                            }

                            Toggle(isOn: $colorByCycle) {
                                Text("Color Segments by Cycle (Colormap)")
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

    // MARK: - Tab 3: Canvas & Legend

    private var canvasTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorCard(title: "LEGEND") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $showLegend) {
                        Text("Show Legend")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                    }

                    Text("Legends are automatically omitted for single-series plots with matching axis title. Custom labels or multi-series plots display authentic scientific glyphs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button("Reset Legend Position") {
                        legendOffset = .zero
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!showLegend || legendOffset == .zero)
                }
            }

            if let onSaveSnapshot {
                InspectorCard(title: "SNAPSHOT") {
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
        return measurement?.channels.map(\.name) ?? []
    }

    private var effectiveEligibleY: [String] {
        if !eligibleY.isEmpty { return eligibleY }
        return measurement?.channels.map(\.name) ?? []
    }

    private func seriesRow(_ id: String) -> some View {
        let isHidden = hidden.contains(id)
        let isFocused = focusedID == id
        let state = states[id]
        let filename = URL(fileURLWithPath: id).lastPathComponent
        let exclusionReason: String? = {
            if case .partial(let group) = overlay {
                return group.excluded.first(where: { $0.path == id })?.reason
            }
            return nil
        }()

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(seriesColor(id)).frame(width: 9, height: 9).accessibilityHidden(true)

                TextField(filename, text: Binding(
                    get: { customSeriesLabels[id] ?? "" },
                    set: { customSeriesLabels[id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .help("Custom legend label (leave empty to use default filename)")

                if customSeriesLabels[id]?.isEmpty == false {
                    Button {
                        customSeriesLabels.removeValue(forKey: id)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to original filename")
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

            if isFocused {
                Text("Focused source")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 17)
            }
            if let error = state?.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 17)
            } else if state?.isLoading == true {
                Text("Loading…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 17)
            } else if let exclusionReason {
                Text("Excluded: \(exclusionReason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.leading, 17)
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
        let order = selectedIDs.sorted()
        let index = order.firstIndex(of: id) ?? 0
        return NativeOverlayPalette.color(index)
    }
}
