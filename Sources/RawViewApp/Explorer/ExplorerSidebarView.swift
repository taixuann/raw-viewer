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
    /// Task 7: settings-driven grammar-variable views. Tree/None stay
    /// structural; every other choice is a qualified (grammar, variable)
    /// reference owned by project settings, never the grammar catalog.
    @Binding var facet: String
    var explorerViews: [ExplorerViewDefinition] = []
    var catalog: FilenameGrammarCatalog? = nil
    var viewError: String? = nil
    var onAddView: ((String, String) -> Void)? = nil
    var onRemoveView: ((ExplorerViewDefinition) -> Void)? = nil
    /// Task 3: per-grammar source-label layouts shared across Tree, None
    /// and grouped views. Absence means exact filenames.
    var sourceLabels: [SourceLabelLayout] = []
    /// Validated settings save; nil on success, message on failure.
    var onSaveSourceLabels: (([SourceLabelLayout]) -> String?)? = nil

    @State private var search = ""
    @State private var collapsed = Set<String>()
    @State private var showAddView = false
    @State private var showLabelCustomizer = false
    @State private var showGrammarDetails = false
    @State private var addGrammarID = ""
    @State private var addVariable = ""
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
        onBuildProfile: ((String?) -> Void)? = nil,
        facet: Binding<String> = .constant("tree"),
        explorerViews: [ExplorerViewDefinition] = [],
        catalog: FilenameGrammarCatalog? = nil,
        viewError: String? = nil,
        onAddView: ((String, String) -> Void)? = nil,
        onRemoveView: ((ExplorerViewDefinition) -> Void)? = nil,
        sourceLabels: [SourceLabelLayout] = [],
        onSaveSourceLabels: (([SourceLabelLayout]) -> String?)? = nil
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
        self._facet = facet
        self.explorerViews = explorerViews
        self.catalog = catalog
        self.viewError = viewError
        self.onAddView = onAddView
        self.onRemoveView = onRemoveView
        self.sourceLabels = sourceLabels
        self.onSaveSourceLabels = onSaveSourceLabels
        var index: [String: RawSource] = [:]
        index.reserveCapacity(sources.count)
        for s in sources { index[s.id] = s }
        self.sourceIndex = index
    }

    /// Menu title for a discriminated view key. Identical variable names in
    /// different grammars stay distinct via the grammar ID.
    func viewTitle(_ key: String) -> String {
        if key == "tree" { return "Tree" }
        if key.isEmpty { return "None" }
        guard let ref = RawViewModel.explorerViewReference(forKey: key) else { return key }
        let collisions = explorerViews.filter { $0.variable == ref.variable }.count > 1
        return collisions ? "\(ref.variable) · \(ref.grammarID)" : ref.variable
    }

    static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Grammar-variable groups for one saved view reference. Tree/None never
    /// reach here; an unresolvable reference yields no groups (the banner
    /// explains) rather than a silent substitute.
    private func groups(for key: String) -> [SourceGroup] {
        guard let ref = RawViewModel.explorerViewReference(forKey: key),
              let grammar = catalog?.grammars.first(where: { $0.id == ref.grammarID }) else { return [] }
        let base = SourceGrouping.groups(sources: sources, grammar: grammar, variable: ref.variable)
        let allowed = Set(filteredSources.map(\.id))
        return base.compactMap { group -> SourceGroup? in
            let ids = group.sourceIDs.filter { allowed.contains($0) && matches($0, label: group.label) }
            return ids.isEmpty ? nil : SourceGroup(label: group.label, sourceIDs: ids)
        }
    }

    /// The current view reference, or nil for Tree/None.
    private var currentViewReference: ExplorerViewDefinition? {
        RawViewModel.explorerViewReference(forKey: facet)
    }

    /// True when the current view cannot resolve (grammar/variable gone).
    /// The model resets to Tree on refresh; this covers mid-session grammar
    /// edits between refreshes.
    private var currentViewUnavailable: Bool {
        guard let ref = currentViewReference else { return false }
        return !viewIsResolvable(ref)
    }

    private func viewIsResolvable(_ ref: ExplorerViewDefinition) -> Bool {
        guard explorerViews.contains(ref),
              let grammar = catalog?.grammars.first(where: { $0.id == ref.grammarID }),
              grammar.fields.contains(where: { $0.name == ref.variable }) else { return false }
        return true
    }

    /// Facet keys allowed to render chips or filter: Tree/None plus saved
    /// views. A removed view's key drops out, so its selections purge.
    // ponytail: linear map over a handful of views; no cache needed.
    private var liveFacetKeys: Set<String> {
        Set(["tree", ""]).union(explorerViews.map {
            RawViewModel.explorerViewKey(grammarID: $0.grammarID, variable: $0.variable)
        })
    }

    private func viewMenuButton(key: String, unavailable: Bool = false) -> some View {
        Button {
            facet = key
            collapsed = []
        } label: {
            if unavailable {
                Text("\(viewTitle(key)) (unavailable)")
            } else if facet == key {
                Label(viewTitle(key), systemImage: "checkmark")
            } else {
                Text(viewTitle(key))
            }
        }
        .disabled(unavailable)
    }

    private func beginAddView() {
        if addGrammarID.isEmpty || catalog?.grammars.contains(where: { $0.id == addGrammarID }) != true {
            addGrammarID = catalog?.grammars.first?.id ?? ""
        }
        let fields = catalog?.grammars.first(where: { $0.id == addGrammarID })?.fields ?? []
        if addVariable.isEmpty || !fields.contains(where: { $0.name == addVariable }) {
            addVariable = fields.first?.name ?? ""
        }
        showAddView = true
    }

    /// Add View from Filename…: pick a grammar variable, preview its group
    /// counts (Unmatched included), then save one view reference.
    private var addViewForm: some View {
        let grammars = catalog?.grammars ?? []
        let fields = grammars.first(where: { $0.id == addGrammarID })?.fields ?? []
        let duplicate = explorerViews.contains(where: { $0.grammarID == addGrammarID && $0.variable == addVariable })
        return VStack(alignment: .leading, spacing: 10) {
            Text("Add View from Filename…")
                .font(.system(size: 12, weight: .semibold))
            Picker("Grammar", selection: $addGrammarID) {
                ForEach(grammars) { grammar in Text(grammar.name).tag(grammar.id) }
            }
            .pickerStyle(.menu)
            Picker("Variable", selection: $addVariable) {
                ForEach(fields) { field in Text(field.name).tag(field.name) }
            }
            .pickerStyle(.menu)
            addViewPreview
            if duplicate {
                Text("This view is already added.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { showAddView = false }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Add View") {
                    onAddView?(addGrammarID, addVariable)
                    showAddView = false
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(addGrammarID.isEmpty || addVariable.isEmpty || duplicate)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onChange(of: addGrammarID) { _, newID in
            let next = grammars.first(where: { $0.id == newID })?.fields ?? []
            if !next.contains(where: { $0.name == addVariable }) {
                addVariable = next.first?.name ?? ""
            }
        }
    }

    private var addViewPreview: some View {
        guard let grammar = catalog?.grammars.first(where: { $0.id == addGrammarID }),
              !addVariable.isEmpty else {
            return AnyView(Text("Choose a grammar and variable to preview its groups.")
                .font(.caption).foregroundStyle(.secondary))
        }
        let groups = SourceGrouping.groups(sources: sources, grammar: grammar, variable: addVariable)
        guard !groups.isEmpty else {
            return AnyView(Text("No sources.").font(.caption).foregroundStyle(.secondary))
        }
        let summary = groups.map { "\($0.label) (\($0.sourceIDs.count))" }.joined(separator: ", ")
        return AnyView(VStack(alignment: .leading, spacing: 2) {
            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Text("\(groups.flatMap(\.sourceIDs).count) of \(sources.count) sources shown.")
                .font(.caption2).foregroundStyle(.tertiary)
        })
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

                if facet != "tree" {
                    HStack(spacing: 2) {
                        Menu {
                            viewMenuButton(key: "")
                            if !explorerViews.isEmpty {
                                Divider()
                                ForEach(Array(explorerViews.enumerated()), id: \.offset) { _, ref in
                                    let key = RawViewModel.explorerViewKey(grammarID: ref.grammarID, variable: ref.variable)
                                    viewMenuButton(key: key, unavailable: !viewIsResolvable(ref))
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                Text(viewTitle(facet))
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
                        .help("Group sources by \(viewTitle(facet))")

                        Button {
                            beginAddView()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Add View from Filename…")
                        .popover(isPresented: $showAddView) { addViewForm }

                        if currentViewReference != nil {
                            Button {
                                if let ref = currentViewReference { onRemoveView?(ref) }
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this Explorer view")
                        }

                        Button {
                            showLabelCustomizer = true
                        } label: {
                            Image(systemName: "tag")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Customize source labels…")
                        .disabled(catalog == nil)
                        .popover(isPresented: $showLabelCustomizer) {
                            SourceLabelCustomizerView(
                                grammars: catalog?.grammars ?? [],
                                catalog: catalog,
                                initialLayouts: sourceLabels,
                                focusedSource: focusedSourceID.flatMap({ sourceIndex[$0] }),
                                onSave: { onSaveSourceLabels?($0) },
                                onClose: { showLabelCustomizer = false }
                            )
                        }
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            if !inventoryIssues.isEmpty {
                inventoryIssuesBanner
                Divider()
            }
            filterChips
            if currentViewUnavailable, let ref = currentViewReference {
                Text("Explorer view “\(ref.variable)” is unavailable (renamed or deleted grammar reference).")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .textSelection(.enabled)
            } else if let viewError {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Grammar unavailable ·")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Details") {
                            showGrammarDetails.toggle()
                        }
                        .font(.caption).buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    if showGrammarDetails {
                        Text(viewError)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 2)
            }
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
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        // Verified: the sidebar is created inside `if let project`, so opening another project
        // while one is open keeps its identity and @State; clearing on a new source list is the guard.
        .onChange(of: sources.count) { _, _ in filter.clear() }
        .onChange(of: explorerViews) { _, _ in filter.removeFacets(notIn: liveFacetKeys) }
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
        .help("Filter by this \(viewTitle(facet))")
    }

    private var filterChips: some View {
        let chips = filter.selections
            .filter { liveFacetKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .flatMap { facet, labels in labels.sorted().map { (facet, $0) } }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    Button {
                        filter.remove(facet: chip.0, value: chip.1)
                    } label: {
                        Text("\(viewTitle(chip.0)): \(chip.1) ✕")
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
        return sources.filter { matches($0.id, label: $0.url.lastPathComponent) && matchesFilter(for: $0) }
    }

    /// View-aware filter matching, evaluated per source from its basename
    /// without opening raw files. Grouping stays independent: chips only
    /// narrow the same view's groups, never another view.
    private func matchesFilter(for source: RawSource) -> Bool {
        if filter.isEmpty { return true }
        for (facetKey, selected) in filter.selections where !selected.isEmpty {
            guard let ref = RawViewModel.explorerViewReference(forKey: facetKey),
                  explorerViews.contains(ref),
                  let grammar = catalog?.grammars.first(where: { $0.id == ref.grammarID }) else { continue }
            let facts = FilenameGrammarEngine.extract(from: source.url.lastPathComponent, grammar: grammar)
            if facts.isMatched {
                if let value = facts.extractedFields[ref.variable],
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard selected.contains(value) else { return false }
                } else {
                    guard selected.contains(SourceGrouping.missingValueBucketLabel) else { return false }
                }
            } else {
                guard selected.contains(SourceGrouping.unmatchedBucketLabel) else { return false }
            }
        }
        return true
    }

    private func matches(_ id: String, label: String) -> Bool {
        search.isEmpty || id.localizedCaseInsensitiveContains(search) || label.localizedCaseInsensitiveContains(search)
    }

    /// Resolved label rows for one source. The first matching grammar wins;
    /// a missing grammar, unmatched file, or stale reference falls back to
    /// the exact filename via the pure resolver. No bracket/underscore
    /// guessing, no inspection shortcuts.
    private func labelRows(for source: RawSource) -> [ResolvedSourceLabelRow] {
        let filename = source.url.lastPathComponent
        if let catalog {
            for grammar in catalog.grammars {
                let facts = FilenameGrammarEngine.extract(from: filename, grammar: grammar)
                if facts.isMatched {
                    return SourceLabelPresentation.resolve(
                        filename: filename,
                        layout: sourceLabels.first(where: { $0.grammarID == grammar.id }),
                        matchedGrammarID: grammar.id,
                        values: facts.extractedFields,
                        availableVariables: Set(grammar.fields.map(\.name)))
                }
            }
        }
        return SourceLabelPresentation.resolve(
            filename: filename, layout: nil, matchedGrammarID: nil,
            values: [:], availableVariables: [])
    }

    private func sourceRow(_ source: RawSource) -> some View {
        let filename = source.url.lastPathComponent
        let rows = labelRows(for: source)
        let isFocused = focusedSourceID == source.id
        return HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(isFocused ? Color.accentColor : stateColor(states[source.id]))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row.text)
                        .font(labelFont(for: row.style))
                        .foregroundStyle(row.style.emphasis == "secondary" ? .secondary : .primary)
                }
            }
            Spacer(minLength: 0)
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
        .help(filename)
        .accessibilityLabel("\(filename)\(isFocused ? ", focused" : "")")
    }

    private func stateColor(_ state: GallerySourceState?) -> Color {
        if state?.error != nil { return .orange }
        return .secondary
    }
}

/// Task 3: staged per-grammar source-label customization. Edits stay local
/// until Apply runs the validated settings save; Cancel discards them.
/// Reset removes this grammar's layout and restores exact filenames.
struct SourceLabelCustomizerView: View {
    struct DraftRow: Identifiable, Equatable {
        var id = UUID()
        var variables: [String] = []
        var fontSize = 12
        var weight = "regular"
        var font = "normal"
        var emphasis = "primary"
    }

    let grammars: [FilenameGrammar]
    let catalog: FilenameGrammarCatalog?
    let initialLayouts: [SourceLabelLayout]
    let focusedSource: RawSource?
    /// Validated save of the full layout list; nil on success.
    let onSave: (([SourceLabelLayout]) -> String?)?
    let onClose: () -> Void

    @State private var grammarID: String
    @State private var rows: [DraftRow]
    @State private var saveError: String? = nil

    init(grammars: [FilenameGrammar], catalog: FilenameGrammarCatalog?,
         initialLayouts: [SourceLabelLayout], focusedSource: RawSource?,
         onSave: (([SourceLabelLayout]) -> String?)?, onClose: @escaping () -> Void) {
        self.grammars = grammars
        self.catalog = catalog
        self.initialLayouts = initialLayouts
        self.focusedSource = focusedSource
        self.onSave = onSave
        self.onClose = onClose
        let first = grammars.first?.id ?? ""
        _grammarID = State(initialValue: first)
        _rows = State(initialValue: Self.draftRows(for: first, from: initialLayouts))
    }

    static func draftRows(for grammarID: String, from layouts: [SourceLabelLayout]) -> [DraftRow] {
        layouts.first(where: { $0.grammarID == grammarID })?.rows.map {
            DraftRow(variables: $0.variables, fontSize: $0.fontSize,
                     weight: $0.weight, font: $0.font, emphasis: $0.emphasis)
        } ?? []
    }

    private var grammar: FilenameGrammar? { grammars.first(where: { $0.id == grammarID }) }
    private var variables: [String] { grammar?.fields.map(\.name) ?? [] }
    private var hasLayout: Bool { initialLayouts.contains(where: { $0.grammarID == grammarID }) }
    private var stale: [String] {
        Array(Set(rows.flatMap(\.variables)).subtracting(variables)).sorted()
    }
    private var canApply: Bool { !grammarID.isEmpty && !rows.isEmpty && rows.allSatisfy({ !$0.variables.isEmpty }) }

    private var draftLayout: SourceLabelLayout {
        SourceLabelLayout(grammarID: grammarID, rows: rows.map {
            SourceLabelRow(variables: $0.variables, fontSize: $0.fontSize,
                           weight: $0.weight, font: $0.font, emphasis: $0.emphasis)
        })
    }

    private var preview: [ResolvedSourceLabelRow] {
        guard let focusedSource, let grammar else { return [] }
        let facts = FilenameGrammarEngine.extract(from: focusedSource.url.lastPathComponent, grammar: grammar)
        return SourceLabelPresentation.resolve(
            filename: focusedSource.url.lastPathComponent, layout: draftLayout,
            matchedGrammarID: facts.isMatched ? grammar.id : nil,
            values: facts.extractedFields, availableVariables: Set(variables))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Customize source labels…")
                .font(.system(size: 12, weight: .semibold))
            if grammars.isEmpty {
                Text("No filename grammar is available.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Grammar", selection: $grammarID) {
                    ForEach(grammars) { grammar in Text(grammar.name).tag(grammar.id) }
                }
                .pickerStyle(.menu)
                .onChange(of: grammarID) { _, next in
                    rows = Self.draftRows(for: next, from: initialLayouts)
                    saveError = nil
                }
                if !stale.isEmpty {
                    Text("Unknown variables (\(stale.joined(separator: ", "))) fall back to the exact filename.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if rows.isEmpty {
                    Text("No custom rows — files show exact filenames.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($rows) { $row in
                    rowEditor(row: $row)
                    Divider()
                }
                Button("Add row") {
                    let known = rows.flatMap(\.variables)
                    let seed = variables.first(where: { !known.contains($0) }) ?? variables.first ?? ""
                    rows.append(DraftRow(variables: seed.isEmpty ? [] : [seed]))
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                .disabled(variables.isEmpty)
                previewSection
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Reset") {
                    let kept = initialLayouts.filter({ $0.grammarID != grammarID })
                    if let message = onSave?(kept) { saveError = message } else { onClose() }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!hasLayout)
                .help("Remove this grammar's customization and restore filenames")
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Apply") {
                    let kept = initialLayouts.filter({ $0.grammarID != grammarID })
                    if let message = onSave?(kept + [draftLayout]) { saveError = message } else { onClose() }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!canApply)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func rowEditor(row: Binding<DraftRow>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 4) {
                ForEach(Array(row.variables.wrappedValue.enumerated()), id: \.offset) { _, name in
                    Button {
                        row.variables.wrappedValue.removeAll(where: { $0 == name })
                    } label: {
                        Text("\(name) ✕").font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(name)")
                }
            }
            HStack(spacing: 6) {
                Menu("Add variable") {
                    ForEach(variables.filter({ !row.variables.wrappedValue.contains($0) }), id: \.self) { name in
                        Button(name) { row.variables.wrappedValue.append(name) }
                    }
                }
                .menuStyle(.borderlessButton).font(.caption)
                .disabled(variables.allSatisfy({ row.variables.wrappedValue.contains($0) }))
                Spacer()
                Button("↑") { move(row, by: -1) }.buttonStyle(.plain).font(.caption)
                    .help("Move row up").disabled(!canMove(row, by: -1))
                Button("↓") { move(row, by: 1) }.buttonStyle(.plain).font(.caption)
                    .help("Move row down").disabled(!canMove(row, by: 1))
                Button("Remove row") { rows.removeAll(where: { $0.id == row.wrappedValue.id }) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Stepper("Size \(row.fontSize.wrappedValue)", value: row.fontSize, in: 10...18)
                    .font(.caption)
                Picker("", selection: row.weight) {
                    Text("Regular").tag("regular")
                    Text("Medium").tag("medium")
                    Text("Semibold").tag("semibold")
                }
                .pickerStyle(.segmented).frame(width: 190)
            }
            HStack(spacing: 8) {
                Picker("Font", selection: row.font) {
                    Text("Normal").tag("normal")
                    Text("Monospace").tag("monospace")
                }
                .pickerStyle(.segmented).frame(width: 170)
                Picker("Emphasis", selection: row.emphasis) {
                    Text("Primary").tag("primary")
                    Text("Secondary").tag("secondary")
                }
                .pickerStyle(.segmented)
            }
            .font(.caption)
        }
    }

    private func move(_ row: Binding<DraftRow>, by delta: Int) {
        guard let idx = rows.firstIndex(where: { $0.id == row.wrappedValue.id }) else { return }
        let target = idx + delta
        guard target >= 0 && target < rows.count else { return }
        rows.swapAt(idx, target)
    }

    private func canMove(_ row: Binding<DraftRow>, by delta: Int) -> Bool {
        guard let idx = rows.firstIndex(where: { $0.id == row.wrappedValue.id }) else { return false }
        return idx + delta >= 0 && idx + delta < rows.count
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            if focusedSource == nil {
                Text("Select a file to preview.").font(.caption).foregroundStyle(.tertiary)
            } else if preview.isEmpty {
                Text("No preview.").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(preview.enumerated()), id: \.offset) { _, row in
                    Text(row.text)
                        .font(labelFont(for: row.style))
                        .foregroundStyle(row.style.emphasis == "secondary" ? .secondary : .primary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// Shared source-label font so sidebar rows and customizer preview match.
private func labelFont(for style: SourceLabelRow) -> Font {
    let weight: Font.Weight = {
        switch style.weight {
        case "medium": return .medium
        case "semibold": return .semibold
        default: return .regular
        }
    }()
    return .system(size: CGFloat(style.fontSize), weight: weight,
                   design: style.font == "monospace" ? .monospaced : .default)
}

/// Minimal flow layout: native adaptive arrangement, no truncation.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(proposal: proposal, subviews: subviews)
        for (point, subview) in laid.points {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                          proposal: ProposedViewSize(width: point.width, height: point.height))
        }
    }
    private struct Point { var x, y, width, height: CGFloat }
    private struct Arranged { var size: CGSize; var points: [(Point, LayoutSubview)] }
    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> Arranged {
        let maxWidth = proposal.width ?? .infinity
        var points: [(Point, LayoutSubview)] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            points.append((Point(x: x, y: y, width: size.width, height: size.height), subview))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            width = max(width, x)
        }
        return Arranged(size: CGSize(width: min(width, maxWidth), height: y + lineHeight), points: points)
    }
}
