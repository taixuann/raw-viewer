import SwiftUI
import RawViewCore

struct DraggableLegendView: View {
    let items: [(color: Color, label: String)]
    @Binding var offset: CGSize
    @State private var dragStart: CGSize = .zero

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        Capsule()
                            .fill(item.color)
                            .frame(width: 14, height: 2.5)
                        Text(item.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(6)
            .background(Color.clear)
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
    @State private var groupDisplayLimits: [String: Int] = [:]
    @State private var flatListLimit = 100
    private let defaultPageSize = 100
    private let sourceIndex: [String: RawSource]

    init(
        sources: [RawSource],
        inspections: [String: SourceInspection],
        states: [String: GallerySourceState],
        focusedSourceID: Binding<String?>,
        selectedSourceIDs: Binding<Set<String>>
    ) {
        self.sources = sources
        self.inspections = inspections
        self.states = states
        self._focusedSourceID = focusedSourceID
        self._selectedSourceIDs = selectedSourceIDs
        var index: [String: RawSource] = [:]
        index.reserveCapacity(sources.count)
        for s in sources { index[s.id] = s }
        self.sourceIndex = index
    }

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
        let allowed = Set(filteredSources.map(\.id))
        return base.compactMap { group -> SourceGroup? in
            let ids = group.sourceIDs.filter { allowed.contains($0) && matches($0, label: group.label) }
            return ids.isEmpty ? nil : SourceGroup(label: group.label, sourceIDs: ids)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter sources…", text: $search)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !search.isEmpty {
                        Button(action: { search = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear filter")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

                Menu {
                    ForEach(Self.facets, id: \.0) { key, title in
                        Button {
                            facet = key
                            collapsed = []
                        } label: {
                            if facet == key {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text(Self.facetTitle(facet))
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6).padding(.vertical, 4.5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Group sources by \(Self.facetTitle(facet))")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

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
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .searchable(text: $search, prompt: "Find a source or metadata")
        // Verified: the sidebar is created inside `if let project`, so opening another project
        // while one is open keeps its identity and @State; clearing on a new source list is the guard.
        .onChange(of: sources.count) { _, _ in filter.clear() }
    }

    private func visibleIDs(for group: SourceGroup) -> (ids: [String], totalCount: Int, isTruncated: Bool, currentLimit: Int) {
        let total = group.sourceIDs.count
        guard total > defaultPageSize else {
            return (group.sourceIDs, total, false, total)
        }
        let limit = groupDisplayLimits[group.label] ?? defaultPageSize
        if limit >= total {
            return (group.sourceIDs, total, false, limit)
        }
        // Ensure focused item is included if it belongs to this group
        var effectiveLimit = limit
        if let focused = focusedSourceID, let idx = group.sourceIDs.firstIndex(of: focused), idx >= effectiveLimit {
            effectiveLimit = min(total, idx + 1)
        }
        return (Array(group.sourceIDs.prefix(effectiveLimit)), total, effectiveLimit < total, effectiveLimit)
    }

    private func groupSection(_ group: SourceGroup) -> some View {
        let (visible, total, isTruncated, currentLimit) = visibleIDs(for: group)
        let isExpanded = !collapsed.contains(group.label)
        return Section {
            if isExpanded {
                sourceRows(ids: visible)
                if isTruncated {
                    HStack(spacing: 8) {
                        Text("Showing \(visible.count) of \(total)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show +250") {
                            groupDisplayLimits[group.label] = currentLimit + 250
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        Button("Show all") {
                            groupDisplayLimits[group.label] = total
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            groupHeaderView(group, isExpanded: isExpanded)
        }
    }

    private func groupHeaderView(_ group: SourceGroup, isExpanded: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                if isExpanded { collapsed.insert(group.label) } else { collapsed.remove(group.label) }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text(group.label)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text("\(group.sourceIDs.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))

            filterToggle(for: group.label)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded { collapsed.insert(group.label) } else { collapsed.remove(group.label) }
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
        ForEach(ids, id: \.self) { id in
            if let source = sourceIndex[id] { sourceRow(source) }
        }
    }

    private var flatList: some View {
        let total = filteredSources.count
        let limit = min(total, max(flatListLimit, (focusedSourceID.flatMap { id in filteredSources.firstIndex(where: { $0.id == id }) } ?? 0) + 1))
        let visible = filteredSources.prefix(limit)
        return DisclosureGroup(isExpanded: .constant(true)) {
            ForEach(visible) { source in sourceRow(source) }
            if limit < total {
                HStack(spacing: 8) {
                    Text("Showing \(limit) of \(total)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show +250") { flatListLimit += 250 }
                        .font(.caption2).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    Button("Show all") { flatListLimit = total }
                        .font(.caption2).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                .padding(.vertical, 4)
            }
        } label: { Text("All files · \(filteredSources.count)").font(.subheadline.bold()) }
    }

    private var filteredSources: [RawSource] {
        if search.isEmpty && filter.isEmpty {
            return sources
        }
        let instrumentLabels = filter.selections["instrument"]?.isEmpty == false ? instrumentLabelsBySourceID() : [:]
        return sources.filter { matches($0.id, label: $0.url.lastPathComponent) && matchesFilter(for: $0, instrumentLabels: instrumentLabels) }
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

    /// Direct matching against active filter selections without generating intermediate Set collections.
    private func matchesFilter(for source: RawSource, instrumentLabels: [String: String]) -> Bool {
        if filter.isEmpty { return true }
        guard let inspection = inspections[source.id] else { return false }
        for (facet, selected) in filter.selections where !selected.isEmpty {
            switch facet {
            case "sample":
                guard let val = Self.clean(inspection.deviceID), selected.contains(val) else { return false }
            case "instrument":
                guard let val = instrumentLabels[source.id], selected.contains(val) else { return false }
            case "category":
                guard let val = Self.clean(inspection.category), selected.contains(val) else { return false }
            case "mode":
                guard let val = Self.clean(inspection.applicationMode), selected.contains(val) else { return false }
            case "date":
                guard let val = SourceGrouping.date(from: inspection.timestamp), selected.contains(val) else { return false }
            case "status":
                var matched = false
                if let value = Self.clean(inspection.supportStatus), selected.contains("Support: \(value)") { matched = true }
                if let value = Self.clean(inspection.validationState), selected.contains("Validation: \(value)") { matched = true }
                if let error = states[source.id]?.error, selected.contains("Error: \(error)") { matched = true }
                if !matched { return false }
            default:
                break
            }
        }
        return true
    }

    private func matches(_ id: String, label: String) -> Bool {
        search.isEmpty || id.localizedCaseInsensitiveContains(search) || label.localizedCaseInsensitiveContains(search)
    }

    private struct DisplayableSourceInfo {
        let title: String
        let subtitle: String
        let badge: String?
    }

    private func displayInfo(for source: RawSource) -> DisplayableSourceInfo {
        let inspection = inspections[source.id]
        let rawFilename = source.url.deletingPathExtension().lastPathComponent

        // 1. Detect sample / device ID
        var sampleID: String? = nil
        if let dev = inspection?.deviceID, !dev.isEmpty, dev != "Unknown" {
            sampleID = dev
        } else if let openBracket = rawFilename.firstIndex(of: "["),
                  let closeBracket = rawFilename[openBracket...].firstIndex(of: "]"),
                  openBracket < closeBracket {
            let extracted = String(rawFilename[rawFilename.index(after: openBracket)..<closeBracket])
            if !extracted.isEmpty { sampleID = extracted }
        }

        // 2. Detect timestamp / run date
        var timestampStr: String? = nil
        if let ts = inspection?.timestamp, !ts.isEmpty {
            timestampStr = ts
        } else {
            let parts = rawFilename.split(separator: "_")
            if let first = parts.first, first.count >= 6, first.allSatisfy({ $0.isNumber || $0 == "-" }) {
                timestampStr = String(first)
            }
        }

        // 3. Detect mode or category
        var modeBadge: String? = nil
        if let mode = inspection?.applicationMode, !mode.isEmpty, mode != "Unknown" {
            modeBadge = mode.replacingOccurrences(of: "_", with: " ")
                            .replacingOccurrences(of: ".", with: " ")
                            .capitalized
        }

        // 4. Extract sequence index (e.g. 001, run_01)
        let seq = rawFilename.split(separator: "_").last.map(String.init) ?? ""
        let isSeq = seq.count <= 4 && seq.allSatisfy({ $0.isNumber })

        let primaryTitle: String
        let secondaryTitle: String

        if let sample = sampleID {
            primaryTitle = sample
            var subParts: [String] = []
            if let ts = timestampStr { subParts.append(ts) }
            if isSeq && !subParts.contains(seq) { subParts.append("#\(seq)") }
            if subParts.isEmpty { subParts.append(rawFilename) }
            secondaryTitle = subParts.joined(separator: " · ")
        } else {
            var clean = rawFilename
            let patternsToStrip = [
                "horiba-labram.raman_", "horiba-labram_hr_evolution_", "horiba-labram_",
                "keithley-2400_", "keithley_2400_", "keithley_",
                "renishaw_invia_", "renishaw_", "agilent_"
            ]
            for pat in patternsToStrip {
                if clean.lowercased().contains(pat) {
                    clean = clean.replacingOccurrences(of: pat, with: "", options: .caseInsensitive)
                }
            }
            primaryTitle = clean
            var subParts: [String] = []
            if let ts = timestampStr { subParts.append(ts) }
            if isSeq && !subParts.contains(seq) { subParts.append("#\(seq)") }
            secondaryTitle = subParts.isEmpty ? (inspection?.instrumentName ?? "") : subParts.joined(separator: " · ")
        }

        return DisplayableSourceInfo(title: primaryTitle, subtitle: secondaryTitle, badge: modeBadge)
    }

    private func sourceRow(_ source: RawSource) -> some View {
        let info = displayInfo(for: source)
        let isFocused = focusedSourceID == source.id
        return HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(isFocused ? Color.accentColor : stateColor(states[source.id]))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.title)
                        .font(.system(size: 12, weight: isFocused ? .bold : .medium))
                        .foregroundStyle(isFocused ? Color.primary : Color.primary.opacity(0.95))
                        .lineLimit(1)
                    if let badge = info.badge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(.quaternary))
                    }
                    Spacer(minLength: 0)
                }
                if !info.subtitle.isEmpty {
                    Text(info.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if isFocused {
                Text("Focused")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.12)))
            }
        }
        .padding(.vertical, 3)
        .tag(source.id)
        .help(source.url.lastPathComponent)
        .accessibilityLabel("\(info.title), \(info.subtitle)\(isFocused ? ", focused" : "")")
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
    var comparisonTitle: String = ""
    @Binding var showLegend: Bool
    var customSeriesLabels: [String: String] = [:]
    @Binding var legendOffset: CGSize

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
                    Button {
                        onSaveSnapshot?()
                    } label: {
                        Label("Save Current View as Snapshot", systemImage: "camera.badge.ellipsis")
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
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(showInspector ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Toggle Inspector (⌘I)")
                .keyboardShortcut("i", modifiers: .command)
                .accessibilityLabel("Toggle Inspector")
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            Divider()
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
                CenteredFigureView {
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
                    CenteredFigureView {
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
                CenteredFigureView {
                    NativePlot(measurement: measurement, xAbsolute: xAbsolute,
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            sourceStatus(source, symbol: "chart.xyaxis.line")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct CenteredFigureView<Content: View>: View {
        @ViewBuilder let content: () -> Content

        private let targetRatio: CGFloat = 59.1 / 50.0

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
    var showLegend: Bool = true
    var customSeriesLabels: [String: String] = [:]
    @Binding var legendOffset: CGSize
    @State private var zoom = 1.0
    @State private var gestureZoomStart = 1.0
    @State private var pan = CGSize.zero
    @State private var dragStart = CGSize.zero
    @AppStorage("plotFontSerif") private var plotFontSerif: Bool = false
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    private func plotFont(size: CGFloat, bold: Bool = false) -> Font {
        if plotFontSerif {
            let f = Font.custom(NativeOverlayPalette.fontFamily, size: size)
            return bold ? f.bold() : f
        } else {
            return bold ? Font.system(size: size, weight: .bold) : Font.system(size: size)
        }
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
                        DraggableLegendView(items: legendItems, offset: $legendOffset)
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
        let targetRatio: CGFloat = 59.1 / 50.0
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

        // Canonical Nature-single closed 4-sided bounding box (1.0 pt)
        var frame = Path(); frame.addRect(plot); context.stroke(frame, with: .color(.primary), lineWidth: PlotRenderingEngine.spineLineWidth)
        let xRange = viewport(expanded(xBounds), pan: pan.width, dimension: plot.width, vertical: false)
        let yRange = viewport(expanded(yBounds), pan: pan.height, dimension: plot.height, vertical: true)
        let tickLen = PlotRenderingEngine.tickLength(fontScale: fontScale)
        for index in 0...4 {
            let t = Double(index) / 4
            let x = xRange.lowerBound + t * (xRange.upperBound - xRange.lowerBound)
            let px = plot.minX + t * plot.width
            let py = plot.maxY - t * plot.height

            // Canonical Nature outward ticks (1.0 pt thickness, visible scaled length)
            var xTick = Path(); xTick.move(to: CGPoint(x: px, y: plot.maxY)); xTick.addLine(to: CGPoint(x: px, y: plot.maxY + tickLen))
            var yTick = Path(); yTick.move(to: CGPoint(x: plot.minX, y: py)); yTick.addLine(to: CGPoint(x: plot.minX - tickLen, y: py))
            context.stroke(xTick, with: .color(.primary), lineWidth: PlotRenderingEngine.tickLineWidth)
            context.stroke(yTick, with: .color(.primary), lineWidth: PlotRenderingEngine.tickLineWidth)

            context.draw(Text(axisLabel(x, scale: xScale, scaleInfo: xScaleInfo)).font(plotFont(size: 11.5 * fontScale)), at: CGPoint(x: px, y: plot.maxY + tickLen + 3.0), anchor: .top)
            context.draw(Text(yLabels[index]).font(plotFont(size: 11.5 * fontScale)), at: CGPoint(x: plot.minX - tickLen - 3.0, y: py), anchor: .trailing)
        }
        let xTitle = axisTitle(xLabel, unit: xScaleInfo.displayUnit, absolute: xAbsolute, scale: xScale)
        let yTitle = axisTitle(yLabel, unit: yScaleInfo.displayUnit, absolute: yAbsolute, scale: yScale)

        // Axis titles: regular weight (not bold), matching standard scientific publishing
        context.draw(Text(xTitle).font(plotFont(size: 12.5 * fontScale, bold: false)), at: CGPoint(x: plot.midX, y: plot.maxY + tickLen + 3.0 + (11.5 * fontScale) + 6.0), anchor: .top)
        let yTitleX = max(14 * fontScale, plot.minX - tickLen - 3.0 - maxLabelWidth - (12 * fontScale))
        var yLabelContext = context
        yLabelContext.translateBy(x: yTitleX, y: plot.midY)
        yLabelContext.rotate(by: .degrees(-90))
        yLabelContext.draw(Text(yTitle).font(plotFont(size: 12.5 * fontScale, bold: false)), at: .zero, anchor: .center)

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
