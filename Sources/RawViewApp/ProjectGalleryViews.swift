import SwiftUI
import RawViewCore

struct ProjectSourcesSidebar: View {
    let sources: [RawSource]
    let inspections: [String: SourceInspection]
    let states: [String: GallerySourceState]
    @Binding var focusedSourceID: String?
    @State private var search = ""
    @State private var facet = "instrument"
    @State private var collapsed = Set<String>()
    @State private var filter = SourceFilter()

    static let facets: [(String, String)] = [
        ("", "None"), ("sample", "Sample / Device"), ("instrument", "Instrument"),
        ("study", "Study"), ("mode", "Mode"), ("date", "Date / Batch"), ("status", "Status"),
    ]

    static func facetTitle(_ key: String) -> String {
        facets.first(where: { $0.0 == key })?.1 ?? key
    }

    private func groups(for key: String) -> [SourceGroup] {
        let grouping = SourceGrouping(inspections: Array(inspections.values))
        var base: [SourceGroup]
        switch key {
        case "sample": base = grouping.sampleDevice
        case "study": base = grouping.study
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
            List(selection: $focusedSourceID) {
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
        sources.filter { matches($0.id, label: $0.url.lastPathComponent) && filter.matches(labelsByFacet(for: $0)) }
    }

    /// Facet labels for one source, matching the group labels `SourceGrouping` produces so a
    /// filter chip's label always equals the displayed group label.
    private func labelsByFacet(for source: RawSource) -> [String: Set<String>] {
        guard let inspection = inspections[source.id] else { return [:] }
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        var labels: [String: Set<String>] = [
            "sample": Set([clean(inspection.deviceID)].compactMap { $0 }),
            "instrument": Set([clean(inspection.instrumentName) ?? clean(inspection.instrumentID)].compactMap { $0 }),
            "study": Set([clean(inspection.studyToken)].compactMap { $0 }),
            "mode": Set([clean(inspection.applicationMode)].compactMap { $0 }),
            "date": Set([SourceGrouping.date(from: inspection.timestamp)].compactMap { $0 }),
        ]
        var status: Set<String> = []
        if let value = clean(inspection.supportStatus) { status.insert("Support: \(value)") }
        if let value = clean(inspection.validationState) { status.insert("Validation: \(value)") }
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
            Text(source.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .tag(source.id as String?)
        .help(source.id)
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
    @Binding var tab: String
    @Binding var xAbsolute: Bool
    @Binding var yAbsolute: Bool
    @Binding var xScale: AxisScale
    @Binding var yScale: AxisScale

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $tab) {
                    Text("Plot").tag("Plot")
                    Text("Data").tag("Data")
                }
                .pickerStyle(.segmented).frame(width: 180)
                Spacer()
                if let state = states[focusedSourceID ?? ""], state.measurement != nil, tab == "Plot" {
                    axisControl("X", absolute: $xAbsolute, scale: $xScale)
                    axisControl("Y", absolute: $yAbsolute, scale: $yScale)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            pane
            HStack {
                if let source = sources.first(where: { $0.id == focusedSourceID }) {
                    Text(source.url.lastPathComponent).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    if states[source.id]?.measurement != nil {
                        Text("Loaded · selected source hash verified before and after parsing")
                    }
                }
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var pane: some View {
        if sources.isEmpty {
            ContentUnavailableView("No Sources", systemImage: "waveform.path.ecg",
                description: Text("Open a project containing files under data/raw."))
        } else if let source = sources.first(where: { $0.id == focusedSourceID }) {
            focusedPane(source)
        } else {
            ContentUnavailableView("Select a Source", systemImage: "waveform.path.ecg",
                description: Text("Choose a source in the sidebar to view it here."))
        }
    }

    private func axisControl(_ name: String, absolute: Binding<Bool>, scale: Binding<AxisScale>) -> some View {
        HStack(spacing: 5) {
            Text(name).font(.caption).bold()
            Toggle("Absolute", isOn: absolute).labelsHidden().help("Display absolute values before applying the scale")
            Picker(name + " scale", selection: scale) {
                Text("Lin").tag(AxisScale.linear)
                Text("Log").tag(AxisScale.logarithmic)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 82)
        }
    }

    @ViewBuilder
    private func focusedPane(_ source: RawSource) -> some View {
        if tab == "Plot" {
            if let measurement = states[source.id]?.measurement {
                if measurement.supportStatus != "supported" {
                    ContentUnavailableView("Unsupported Source", systemImage: "exclamationmark.triangle",
                        description: Text("The reader reports: \(measurement.supportStatus). Its source remains available in the Data tab."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if measurement.view.kind == "metadata-only" {
                    ContentUnavailableView("No Figure for This Source", systemImage: "chart.xyaxis.line",
                        description: Text("The reader reports metadata only; its data remains available in the Data tab."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NativePlot(measurement: measurement, xAbsolute: xAbsolute, yAbsolute: yAbsolute,
                              xScale: xScale, yScale: yScale)
                        .padding(14)
                }
            } else {
                sourceStatus(source, symbol: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let measurement = states[source.id]?.measurement {
            MeasurementTable(measurement: measurement)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            sourceStatus(source, symbol: "tablecells")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sourceStatus(_ source: RawSource, symbol: String) -> some View {
        let state = states[source.id]
        let title: String
        let message: String
        if state?.isLoading == true {
            title = "Loading Source"
            message = "The project reader is processing this file."
        } else if let error = state?.error {
            title = "Source Unavailable"
            message = error
        } else if state?.inspection?.supportStatus != nil && state?.inspection?.supportStatus != "supported" {
            title = "Unsupported Source"
            message = "Reader support status: \(state?.inspection?.supportStatus ?? "Unknown")."
        } else if state?.inspection == nil {
            title = "Awaiting Reader Approval"
            message = "Approve the project reader to inspect this file."
        } else {
            title = "No Data Available"
            message = "The source did not produce a normalized measurement."
        }
        return ContentUnavailableView(title, systemImage: symbol, description: Text(message)).frame(minHeight: 180)
    }
}
