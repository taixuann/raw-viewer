import SwiftUI
import RawViewCore

struct ProjectSourcesSidebar: View {
    let sources: [RawSource]
    let inspections: [String: SourceInspection]
    let states: [String: GallerySourceState]
    @Binding var focusedSourceID: String?
    @Binding var selectedSourceIDs: Set<String>
    @State private var search = ""
    @State private var facet = "instrument"
    @State private var collapsed = Set<String>()
    @State private var filter = SourceFilter()

    static let facets: [(String, String)] = [
        ("", "None"), ("sample", "Sample / Device"), ("instrument", "Instrument"),
        ("category", "Category"), ("mode", "Mode"), ("date", "Date / Batch"), ("status", "Status"),
    ]

    static func facetTitle(_ key: String) -> String {
        facets.first(where: { $0.0 == key })?.1 ?? key
    }

    static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func groups(for key: String) -> [SourceGroup] {
        let grouping = SourceGrouping(inspections: Array(inspections.values))
        var base: [SourceGroup]
        switch key {
        case "sample": base = grouping.sampleDevice
        case "instrument": base = grouping.instrument
        case "category": base = grouping.category
        case "mode": base = grouping.measurementMode
        case "date": base = grouping.dateBatch.sorted { $0.label > $1.label }
        case "status":
            var errorsByMessage: [String: [String]] = [:]
            for (id, state) in states {
                if let error = state.error { errorsByMessage[error, default: []].append(id) }
            }
            base = grouping.status + errorsByMessage.keys.sorted().map { message in
                SourceGroup(label: "Error: \(message)", sourceIDs: errorsByMessage[message, default: []].sorted())
            }
        default: base = []
        }
        return base.compactMap { group -> SourceGroup? in
            let allowed = Set(filteredSources.map(\.id))
            let ids = group.sourceIDs.filter { allowed.contains($0) && matches($0, label: group.label) }
            return ids.isEmpty ? nil : SourceGroup(label: group.label, sourceIDs: ids)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Group by", selection: $facet) {
                ForEach(Self.facets, id: \.0) { key, title in Text(title).tag(key) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 8)
            .onChange(of: facet) { _, _ in collapsed = [] }
            Divider()
            filterChips
            Text("Select multiple with Shift or Command for comparison.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
                .accessibilityLabel("Multi-select hint for comparison")
            List(selection: $selectedSourceIDs) {
                if filteredSources.isEmpty {
                    ContentUnavailableView("No Matching Sources", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Adjust the search field or remove filter chips."))
                } else if facet.isEmpty {
                    flatList
                } else {
                    ForEach(groups(for: facet), id: \.label) { group in
                        groupSection(group)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .searchable(text: $search, prompt: "Find a source or metadata")
        // Verified: the sidebar is created inside `if let project`, so opening another project
        // while one is open keeps its identity and @State; clearing on a new source list is the guard.
        .onChange(of: sources.count) { _, _ in filter.clear() }
    }

    private var sourceIndex: [String: RawSource] {
        Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func groupSection(_ group: SourceGroup) -> some View {
        DisclosureGroup(isExpanded: expansion(group.label)) {
            sourceRows(ids: group.sourceIDs)
        } label: {
            HStack {
                Text(group.label).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(group.sourceIDs.count)").font(.caption).foregroundStyle(.secondary)
                filterToggle(for: group.label)
            }
        }
    }

    private func filterToggle(for label: String) -> some View {
        let selected = filter.selections[facet]?.contains(label) == true
        return Button {
            filter.toggle(facet: facet, value: label)
        } label: {
            Text(selected ? "●" : "○").font(.caption)
        }
        .buttonStyle(.plain)
        .help("Filter by this \(Self.facetTitle(facet))")
    }

    private var filterChips: some View {
        let chips = filter.selections
            .sorted { $0.key < $1.key }
            .flatMap { facet, labels in labels.sorted().map { (facet, $0) } }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    Button {
                        filter.remove(facet: chip.0, value: chip.1)
                    } label: {
                        Text("\(Self.facetTitle(chip.0)): \(chip.1) ✕")
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                }
                Button("Clear filters") { filter.clear() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(key) }, set: { if $0 { collapsed.remove(key) } else { collapsed.insert(key) } })
    }

    private func sourceRows(ids: [String]) -> some View {
        let index = sourceIndex
        return ForEach(ids, id: \.self) { id in
            if let source = index[id] { sourceRow(source) }
        }
    }

    private var flatList: some View {
        DisclosureGroup(isExpanded: .constant(true)) {
            ForEach(filteredSources) { source in sourceRow(source) }
        } label: { Text("All files · \(filteredSources.count)").font(.subheadline.bold()) }
    }

    private var filteredSources: [RawSource] {
        // The instrument label per source is resolved once per filtering pass
        // from the same stable-ID grouping the sidebar displays, instead of
        // scanning all inspections separately for every source row.
        let instrumentLabels = instrumentLabelsBySourceID()
        return sources.filter { matches($0.id, label: $0.url.lastPathComponent) && filter.matches(labelsByFacet(for: $0, instrumentLabels: instrumentLabels)) }
    }

    /// SourceID-to-instrument-label map reused from `SourceGrouping`'s existing
    /// group output, so a filter chip's label always equals the displayed group
    /// label — including the ID-qualified label when display names collide.
    private func instrumentLabelsBySourceID() -> [String: String] {
        let grouping = SourceGrouping(inspections: Array(inspections.values))
        var map: [String: String] = [:]
        map.reserveCapacity(inspections.count)
        for group in grouping.instrument {
            for id in group.sourceIDs { map[id] = group.label }
        }
        return map
    }

    /// Facet labels for one source, matching the group labels `SourceGrouping` produces so a
    /// filter chip's label always equals the displayed group label.
    private func labelsByFacet(for source: RawSource, instrumentLabels: [String: String]) -> [String: Set<String>] {
        guard let inspection = inspections[source.id] else { return [:] }
        var labels: [String: Set<String>] = [
            "sample": Set([Self.clean(inspection.deviceID)].compactMap { $0 }),
            "instrument": Set([instrumentLabels[source.id]].compactMap { $0 }),
            "category": Set([Self.clean(inspection.category)].compactMap { $0 }),
            "mode": Set([Self.clean(inspection.applicationMode)].compactMap { $0 }),
            "date": Set([SourceGrouping.date(from: inspection.timestamp)].compactMap { $0 }),
        ]
        var status: Set<String> = []
        if let value = Self.clean(inspection.supportStatus) { status.insert("Support: \(value)") }
        if let value = Self.clean(inspection.validationState) { status.insert("Validation: \(value)") }
        if let error = states[source.id]?.error { status.insert("Error: \(error)") }
        labels["status"] = status
        return labels
    }

    private func matches(_ id: String, label: String) -> Bool {
        search.isEmpty || id.localizedCaseInsensitiveContains(search) || label.localizedCaseInsensitiveContains(search)
    }

    private func sourceRow(_ source: RawSource) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(focusedSourceID == source.id ? Color.accentColor : stateColor(states[source.id]))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(source.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if focusedSourceID == source.id {
                Text("Focused").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Focused source")
            }
        }
        .tag(source.id)
        .help(source.id)
        .accessibilityLabel("\(source.url.lastPathComponent)\(focusedSourceID == source.id ? ", focused" : "")")
    }

    private func stateColor(_ state: GallerySourceState?) -> Color {
        if state?.error != nil { return .orange }
        return .secondary
    }
}

struct ProjectGallery: View {
    let sources: [RawSource]
    let states: [String: GallerySourceState]
    @Binding var focusedSourceID: String?
    let selectedIDs: Set<String>
    let hidden: Set<String>
    let lineWidth: Double
    let overlay: OverlayEligibility?
    @Binding var tab: String
    @Binding var xAbsolute: Bool
    @Binding var yAbsolute: Bool
    @Binding var xScale: AxisScale
    @Binding var yScale: AxisScale
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $tab) {
                    Text("Plot").tag("Plot")
                    Text("Data").tag("Data")
                }
                .pickerStyle(.segmented).frame(width: 180)
                .accessibilityLabel("Plot or Data view")
                Spacer()
                if selectedIDs.count >= 2 {
                    Text("\(selectedIDs.count) selected\(overlayLabel)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel("Selection comparison status")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            pane
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
            ContentUnavailableView("No Sources", systemImage: "waveform.path.ecg",
                description: Text("Open a project containing files under data/raw."))
        } else if let source = sources.first(where: { $0.id == focusedSourceID }) {
            if tab == "Data" {
                focusedDataPane(source)
            } else {
                plotPane(focused: source)
            }
        } else {
            ContentUnavailableView("Select a Source", systemImage: "waveform.path.ecg",
                description: Text("Choose a source in the sidebar to view it here."))
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        floatingCard {
                            OverlayPlot(measurements: visible, selectedSourceIDs: selectedIDs,
                                        focused: states[focused.id]?.measurement,
                                        lineWidth: lineWidth,
                                        xAbsolute: xAbsolute, yAbsolute: yAbsolute,
                                        xScale: xScale, yScale: yScale)
                        }
                    }.padding(20)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            floatingCard {
                                OverlayPlot(measurements: visible, selectedSourceIDs: plottedIDs,
                                            focused: visible.first(where: { $0.source.path == focused.id }),
                                            lineWidth: lineWidth,
                                            xAbsolute: xAbsolute, yAbsolute: yAbsolute,
                                            xScale: xScale, yScale: yScale)
                            }
                        }.padding(20)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                ScrollView {
                    floatingCard {
                        NativePlot(measurement: measurement, xAbsolute: xAbsolute,
                                   yAbsolute: yAbsolute, xScale: xScale,
                                   yScale: yScale, lineWidth: lineWidth)
                    }.padding(20)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            sourceStatus(source, symbol: "chart.xyaxis.line")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func floatingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
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

private enum OverlayPlotFailure: Error { case message(String) }

/// Multi-source overlay: every visible measurement draws its full arrays in
/// acquisition order. No sorting, interpolation, or transforms; visibility
/// only changes presentation.
struct OverlayPlot: View {
    let measurements: [NormalizedMeasurement]
    let selectedSourceIDs: Set<String>
    let focused: NormalizedMeasurement?
    var lineWidth: Double = 1.4
    let xAbsolute: Bool
    let yAbsolute: Bool
    let xScale: AxisScale
    let yScale: AxisScale
    @State private var zoom = 1.0
    @State private var gestureZoomStart = 1.0
    @State private var pan = CGSize.zero
    @State private var dragStart = CGSize.zero

    private struct Series: Identifiable {
        let sourcePath: String
        let label: String
        let x: [Double?]
        let y: [Double?]
        var id: String { sourcePath + "|" + label }
    }

    private var transformed: Result<(xTitle: String, yTitle: String, [Series]), OverlayPlotFailure> {
        guard !measurements.isEmpty else { return .failure(.message("No measurements selected")) }
        var series: [Series] = []
        var xTitle = "X"
        var yTitle = "Y"
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
                xTitle = axisTitle(xChannel.label, unit: xChannel.unit, absolute: xAbsolute, scale: xScale)
                if let y0 = yChannels.first {
                    yTitle = axisTitle(y0.label, unit: y0.unit, absolute: yAbsolute, scale: yScale)
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
        return .success((xTitle, yTitle, series))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(measurements.count) sources · overlay in acquisition order")
                .font(.headline).lineLimit(1).truncationMode(.middle)
                .accessibilityLabel("\(measurements.count) sources overlaid")
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
                                       yScale: yScale, lineWidth: lineWidth)
                        }
                    }
                }
            case .success(let data):
                let sourceOrder = selectedSourceIDs.sorted()
                let accessibleSummary = data.2.map {
                    "\($0.label): \($0.x.count) points, \(gapCount($0)) gaps"
                }.joined(separator: ". ")
                Canvas { context, size in draw(data.2, xTitle: data.0, yTitle: data.1, in: &context, size: size) }
                    .frame(maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture().onChanged { pan = CGSize(width: dragStart.width + $0.translation.width, height: dragStart.height + $0.translation.height) }.onEnded { _ in dragStart = pan })
                    .simultaneousGesture(MagnifyGesture().onChanged { zoom = min(max(gestureZoomStart * $0.magnification, 0.5), 12) }.onEnded { _ in gestureZoomStart = zoom })
                    .overlay(alignment: .topTrailing) {
                        Button("Reset plot") { zoom = 1; gestureZoomStart = 1; pan = .zero; dragStart = .zero }.buttonStyle(.bordered).padding(8)
                            .accessibilityLabel("Reset plot zoom and pan")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Overlay plot with \(data.2.count) series")
                    .accessibilityValue(accessibleSummary)
                VStack(alignment: .leading, spacing: 4) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], alignment: .leading, spacing: 4) {
                        ForEach(data.2) { item in
                            Label(item.label, systemImage: "line.diagonal")
                                .foregroundStyle(palette(item.sourcePath, order: sourceOrder))
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(pointCount(data.2)) points across visible series · \(gapCount(data.2)) gaps")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func draw(_ series: [Series], xTitle: String, yTitle: String, in context: inout GraphicsContext, size: CGSize) {
        guard let xBounds = extrema(series, isX: true), let yBounds = extrema(series, isX: false) else { return }
        let leftGutter = min(100, max(68, size.width * 0.16))
        let topGutter: CGFloat = 16
        let bottomGutter: CGFloat = 54
        let rightGutter: CGFloat = 20
        let plotWidth = max(10, size.width - leftGutter - rightGutter)
        let plotHeight = max(10, size.height - topGutter - bottomGutter)
        let plot = CGRect(x: leftGutter, y: topGutter, width: plotWidth, height: plotHeight)
        var frame = Path(); frame.addRect(plot); context.stroke(frame, with: .color(.primary), lineWidth: 0.8)
        let xRange = viewport(expanded(xBounds), pan: pan.width, dimension: plot.width, vertical: false)
        let yRange = viewport(expanded(yBounds), pan: pan.height, dimension: plot.height, vertical: true)
        for index in 0...4 {
            let t = Double(index) / 4
            let x = xRange.lowerBound + t * (xRange.upperBound - xRange.lowerBound)
            let y = yRange.lowerBound + t * (yRange.upperBound - yRange.lowerBound)
            let px = plot.minX + t * plot.width
            let py = plot.maxY - t * plot.height
            var tick = Path(); tick.move(to: CGPoint(x: px, y: plot.maxY)); tick.addLine(to: CGPoint(x: px, y: plot.maxY + 4))
            tick.move(to: CGPoint(x: plot.minX, y: py)); tick.addLine(to: CGPoint(x: plot.minX - 4, y: py))
            context.stroke(tick, with: .color(.primary), lineWidth: 0.7)
            context.draw(Text(axisLabel(x, scale: xScale)).font(.custom(NativeOverlayPalette.fontFamily, size: 9.5)), at: CGPoint(x: px, y: plot.maxY + 15))
            context.draw(Text(axisLabel(y, scale: yScale)).font(.custom(NativeOverlayPalette.fontFamily, size: 9.5)), at: CGPoint(x: plot.minX - 32, y: py))
        }
        context.draw(Text(xTitle).font(.custom(NativeOverlayPalette.fontFamily, size: 11)), at: CGPoint(x: plot.midX, y: plot.maxY + 36))
        var yLabelContext = context
        yLabelContext.translateBy(x: max(10, plot.minX - 48), y: plot.midY)
        yLabelContext.rotate(by: .degrees(-90))
        yLabelContext.draw(Text(yTitle).font(.custom(NativeOverlayPalette.fontFamily, size: 11)), at: .zero)
        var plotContext = context
        plotContext.clip(to: Path(plot))
        let sourceOrder = selectedSourceIDs.sorted()
        for item in series {
            let color = palette(item.sourcePath, order: sourceOrder)
            var line = Path()
            var runCount = 0
            var lastPoint: CGPoint?
            for index in item.x.indices {
                guard index < item.y.count, let rawX = item.x[index], let rawY = item.y[index] else {
                    if runCount == 1, let point = lastPoint {
                        plotContext.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(color))
                    } else if runCount > 1 {
                        plotContext.stroke(line, with: .color(color), lineWidth: lineWidth)
                    }
                    line = Path()
                    runCount = 0
                    lastPoint = nil
                    continue
                }
                let x = transformedValue(rawX, absolute: xAbsolute, scale: xScale)
                let y = transformedValue(rawY, absolute: yAbsolute, scale: yScale)
                let tx = (x - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
                let ty = (y - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
                let point = CGPoint(x: plot.minX + tx * plot.width, y: plot.maxY - ty * plot.height)
                if runCount == 0 { line.move(to: point) } else { line.addLine(to: point) }
                runCount += 1
                lastPoint = point
            }
            if runCount == 1, let point = lastPoint {
                plotContext.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(color))
            } else if runCount > 1 {
                plotContext.stroke(line, with: .color(color), lineWidth: lineWidth)
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
    private func axisLabel(_ value: Double, scale: AxisScale) -> String {
        scale == .logarithmic ? "10^\(NumberLabel.format(value))" : NumberLabel.format(value)
    }
    private func palette(_ sourcePath: String, order: [String]) -> Color {
        NativeOverlayPalette.color(order.firstIndex(of: sourcePath) ?? 0)
    }
}

enum NativeOverlayPalette {
    static let values: [[Int]] = {
        if let url = Bundle.main.url(forResource: "NativePlotStyle", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(OverlayPalettePayload.self, from: data),
           !payload.paletteRGB.isEmpty {
            return payload.paletteRGB
        }
        return [[0, 64, 255], [225, 38, 0], [0, 158, 115], [230, 159, 0], [123, 44, 191], [102, 102, 102], [0, 0, 0]]
    }()
    static let fontFamily: String = {
        if let url = Bundle.main.url(forResource: "NativePlotStyle", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(OverlayPalettePayload.self, from: data) {
            return payload.fontFamily
        }
        return "Helvetica Neue"
    }()

    static func color(_ index: Int) -> Color {
        guard !values.isEmpty else { return .blue }
        let color = values[index % values.count]
        return Color(.sRGB, red: Double(color[0]) / 255, green: Double(color[1]) / 255,
                    blue: Double(color[2]) / 255, opacity: 1)
    }
}

private struct OverlayPalettePayload: Decodable {
    enum CodingKeys: String, CodingKey { case paletteRGB = "palette_rgb", fontFamily = "font_family" }
    let paletteRGB: [[Int]]
    let fontFamily: String
}
