import AppKit
import SwiftUI
import RawViewCore

struct ProjectSourcesSidebar: View {
    let sources: [RawSource]
    let inspections: [String: SourceInspection]
    let states: [String: GallerySourceState]
    @Binding var focusedSourceID: String?
    @Binding var selectedSourceIDs: Set<String>
    var sourceTree: SourceTree? = nil
    var inventoryIssues: [InventoryIssue] = []
    var dataRoot: String = "data/raw"
    @Binding var expandedDirectoryIDs: Set<String>
    var onBuildProfile: ((String?) -> Void)? = nil

    @State private var search = ""
    @State private var facet = "tree"
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
        selectedSourceIDs: Binding<Set<String>>,
        sourceTree: SourceTree? = nil,
        inventoryIssues: [InventoryIssue] = [],
        dataRoot: String = "data/raw",
        expandedDirectoryIDs: Binding<Set<String>> = .constant([]),
        onBuildProfile: ((String?) -> Void)? = nil
    ) {
        self.sources = sources
        self.inspections = inspections
        self.states = states
        self._focusedSourceID = focusedSourceID
        self._selectedSourceIDs = selectedSourceIDs
        self.sourceTree = sourceTree
        self.inventoryIssues = inventoryIssues
        self.dataRoot = dataRoot
        self._expandedDirectoryIDs = expandedDirectoryIDs
        self.onBuildProfile = onBuildProfile
        var index: [String: RawSource] = [:]
        index.reserveCapacity(sources.count)
        for s in sources { index[s.id] = s }
        self.sourceIndex = index
    }

    static let facets: [(String, String)] = [
        ("tree", "Tree"), ("", "None"), ("sample", "Sample / Device"), ("instrument", "Instrument"),
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
            if !inventoryIssues.isEmpty {
                inventoryIssuesBanner
                Divider()
            }
            filterChips
            Text("Select multiple with Shift or Command for comparison.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
                .accessibilityLabel("Multi-select hint for comparison")
            List(selection: $selectedSourceIDs) {
                if filteredSources.isEmpty {
                    ContentUnavailableView("No Matching Sources", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Adjust the search field or remove filter chips under '\(dataRoot)'."))
                } else if facet == "tree" {
                    treeView
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

    @ViewBuilder
    private var treeView: some View {
        if let tree = sourceTree {
            let activeNodes: [SourceTreeNode] = {
                if search.isEmpty && filter.isEmpty {
                    return tree.root.children
                } else {
                    let allowed = Set(filteredSources.map(\.id))
                    return tree.filtered(sourceIDs: allowed)
                }
            }()
            let items = tree.flatten(expandedIDs: expandedDirectoryIDs, activeNodes: activeNodes)
            if items.isEmpty {
                ContentUnavailableView("No Matching Files", systemImage: "folder",
                    description: Text("No sources match the active filter under '\(dataRoot)'."))
            } else {
                ForEach(items) { item in
                    treeItemRow(item)
                }
            }
        } else {
            flatList
        }
    }

    @ViewBuilder
    private func treeItemRow(_ item: FlattenedTreeItem) -> some View {
        if item.isDirectory {
            let isExpanded = expandedDirectoryIDs.contains(item.node.id)
            HStack(spacing: 5) {
                if item.depth > 0 {
                    Spacer().frame(width: CGFloat(item.depth * 14))
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                Text(item.node.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 3.5)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded {
                    expandedDirectoryIDs.remove(item.node.id)
                } else {
                    expandedDirectoryIDs.insert(item.node.id)
                }
            }
        } else if let sourceID = item.node.sourceID, let source = sourceIndex[sourceID] {
            HStack(spacing: 0) {
                if item.depth > 0 {
                    Spacer().frame(width: CGFloat(item.depth * 14))
                }
                sourceRow(source)
            }
            .tag(source.id)
            .contentShape(Rectangle())
            .onTapGesture {
                focusedSourceID = source.id
                selectedSourceIDs = [source.id]
            }
        }
    }

    private var inventoryIssuesBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 10))
                Text("Partial inventory (\(inventoryIssues.count) issues)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            ForEach(Array(inventoryIssues.prefix(3).enumerated()), id: \.offset) { _, issue in
                Text(issueDescription(issue))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.orange.opacity(0.08))
    }

    private func issueDescription(_ issue: InventoryIssue) -> String {
        switch issue {
        case .enumeration(let path, let detail):
            return "Folder \(path): \(detail)"
        case .metadata(let path, let detail):
            return "File \(path): \(detail)"
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
        .contextMenu {
            Button {
                onBuildProfile?(source.id)
            } label: {
                Label("Build Profile from This File", systemImage: "sparkles.rectangle.stack")
            }
        }
        .help(source.url.lastPathComponent)
        .accessibilityLabel("\(info.title), \(info.subtitle)\(isFocused ? ", focused" : "")")
    }

    private func stateColor(_ state: GallerySourceState?) -> Color {
        if state?.error != nil { return .orange }
        return .secondary
    }
}
