import AppKit
import SwiftUI
import RawViewCore

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
    /// Task 7: variant-declared axis choices for the focused source. Menus
    /// appear only when multiple choices exist; a nil selectedY means the
    /// Default series (variant multi-Y defaults). Missing IDs surface via
    /// axisNote with an explicit reset; never substituted.
    var eligibleX: [String] = []
    var eligibleY: [String] = []
    var defaultY: [String] = []
    var selectedX: String? = nil
    var selectedY: [String]? = nil
    var axisNote: String? = nil
    var onSelectX: ((String) -> Void)? = nil
    var onSelectY: (([String]?) -> Void)? = nil
    var onResetAxes: (() -> Void)? = nil

    @State private var isSeriesExpanded = true
    @State private var isDataMappingExpanded = true
    @State private var isStyleExpanded = true
    @State private var isAxesExpanded = false
    @State private var isMetadataExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("INSPECTOR")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

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
                        if !selectedIDs.isEmpty {
                            seriesSection
                        }
                        if measurement?.instrument.id == "generic-table" {
                            dataMappingSection
                        }
                        styleSection
                        axesSection
                        metadataSection
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
                .padding(14)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background)
    }

    private var dataMappingSection: some View {
        guard let measurement, measurement.instrument.id == "generic-table" else {
            return AnyView(EmptyView())
        }
        let channels = measurement.channels
        let xCurrent = channels.firstIndex(where: { $0.name == measurement.view.x }) ?? 0
        let yCurrent = channels.firstIndex(where: { $0.name == measurement.view.y?.first }) ?? min(1, max(0, channels.count - 1))

        return AnyView(
            DisclosureGroup(isExpanded: $isDataMappingExpanded) {
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
                .padding(.top, 4)
            } label: {
                HStack {
                    Text("DATA MAPPING")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Generic Table")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
        )
    }

    private var seriesSection: some View {
        DisclosureGroup(isExpanded: $isSeriesExpanded) {
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

                if selectedIDs.isEmpty {
                    Text("No sources selected.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(selectedIDs.sorted(), id: \.self) { id in
                        seriesRow(id)
                    }
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
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text("SERIES")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.85))
                Text("\(selectedIDs.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
        }
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

    private var styleSection: some View {
        DisclosureGroup(isExpanded: $isStyleExpanded) {
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

                Toggle(isOn: $showLegend) {
                    Text("Show Legend")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }

                Button("Reset Legend Position") {
                    legendOffset = .zero
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!showLegend || legendOffset == .zero)
            }
            .padding(.top, 4)
        } label: {
            Text("PLOT STYLING")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    private var axesSection: some View {
        DisclosureGroup(isExpanded: $isAxesExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if eligibleX.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("X CHANNEL")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.secondary)
                        Picker("X Channel", selection: Binding(
                            get: { selectedX ?? measurement?.view.x ?? "" },
                            set: { onSelectX?($0) }
                        )) {
                            ForEach(eligibleX, id: \.self) { id in
                                Text(channelOptionLabel(id)).tag(id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                if eligibleY.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Y CHANNEL")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.secondary)
                        Picker("Y Channel", selection: Binding(
                            get: { selectedY?.first ?? "default" },
                            set: { key in onSelectY?(key == "default" ? nil : [key]) }
                        )) {
                            Text(defaultSeriesLabel).tag("default")
                            ForEach(eligibleY, id: \.self) { id in
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
            .padding(.top, 4)
        } label: {
            Text("AXES")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    /// Channel menu label. Stable duplicate labels (same text, distinct IDs)
    /// stay selectable via the ID qualifier.
    private func channelOptionLabel(_ id: String) -> String {
        guard let channel = measurement?.channel(named: id) else { return id }
        let collisions = measurement?.channels.filter { $0.label == channel.label }.count ?? 0
        return collisions > 1 ? "\(channel.label) (\(id))" : channel.label
    }

    /// The preserved multi-Y defaults, shown as one Default-series choice.
    private var defaultSeriesLabel: String {
        let ids = defaultY.isEmpty ? (measurement?.view.y ?? []) : defaultY
        let labels = ids.map { measurement?.channel(named: $0)?.label ?? $0 }
        return labels.isEmpty ? "Default series" : "Default series (\(labels.joined(separator: " + ")))"
    }

    private func axisControl(_ name: String, absolute: Binding<Bool>, scale: Binding<AxisScale>) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 14, alignment: .leading)
            Toggle("Absolute", isOn: absolute).labelsHidden()
                .help("Display absolute values before applying the scale")
                .accessibilityLabel("\(name) absolute values")
            Picker(name + " scale", selection: scale) {
                Text("Lin").tag(AxisScale.linear)
                Text("Log").tag(AxisScale.logarithmic)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 96)
                .accessibilityLabel("\(name) axis scale")
        }
    }

    private var metadataSection: some View {
        DisclosureGroup(isExpanded: $isMetadataExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let measurement {
                    field("Instrument", measurement.instrument.name)
                    field("Mode", measurement.applicationMode ?? "Unknown")
                    field("Channels / Points", "\(measurement.channels.count) / \(measurement.channels.first?.values.count ?? 0)")
                    field("Gaps", "\(measurement.channels.reduce(0) { $0 + $1.gapCount })")
                    ForEach(measurement.channels) { channel in
                        Text("\(channel.label) (\(channel.unit)) · \(channel.quantity ?? "no quantity")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if !measurement.warnings.isEmpty {
                        Text("\(measurement.warnings.count) gap warnings").font(.caption).foregroundStyle(.orange)
                    }
                    field("Path", measurement.source.path)
                } else if let inspection {
                    field("Instrument", inspection.instrumentName ?? inspection.instrumentID ?? "Unknown")
                    field("Mode", inspection.applicationMode ?? "Unknown")
                    field("Path", inspection.source)
                } else if let source {
                    field("Selected", source.lastPathComponent)
                    Text("Waiting for source inspection.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Select one source to inspect it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("SOURCE METADATA")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    private func seriesColor(_ id: String) -> Color {
        let order = selectedIDs.sorted()
        let index = order.firstIndex(of: id) ?? 0
        return NativeOverlayPalette.color(index)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11)).foregroundStyle(.primary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
