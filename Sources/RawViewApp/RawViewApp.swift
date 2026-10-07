import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RawViewCore

@main
struct RawViewApp: App {
    var body: some Scene {
        WindowGroup("RawView") { RawViewShell() }
            .defaultSize(width: 1320, height: 820)
            .windowToolbarStyle(.unified)
    }
}

@MainActor
final class RawViewModel: ObservableObject {
    @Published var project: ProjectContext?
    @Published var sources: [RawSource] = []
    @Published var sourceStates: [String: GallerySourceState] = [:]
    @Published var focusedSourceID: String?
    @Published var selectedSourceIDs: Set<String> = []
    @Published var hiddenSeries: Set<String> = []
    @Published var lineWidth: Double = 1.4
    @Published var studyManifests: [StudyManifest] = []
    @Published var manifestIssues: [String] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var profileIssues: [String] = []
    @Published var inspectedSources = 0
    @Published var inspectionTotal = 0
    @Published var loadingPhase = "Idle"
    @Published var inspectionCancelled = false
    @Published var tab = "Plot"
    @Published var xAbsolute = false
    @Published var yAbsolute = false
    @Published var xScale: AxisScale = .linear
    @Published var yScale: AxisScale = .linear
    // Independent cancellation identities: inventory, bulk inspection, and the
    // focused-source load each own their task slot, so changing focus cancels
    // only the focused load and never drops in-flight inspection results.
    private var discoveryTask: Task<Void, Never>?
    private var inspectionTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var overlayLoadTask: Task<Void, Never>?
    private var overlayLoadingIDs = Set<String>()
    private var activeLoadID = UUID()
    private var overlayGeneration = UUID()
    private var inspectionID = UUID()
    private var activeScopeURL: URL?
    private let discoveryGate = DiscoveryGate()
    // Content-verified per-project cache (Issues 6–7). The limit is user
    // configurable; 0 disables storing and lookups for this project.
    @Published var cacheLimitBytes: Int64 = MeasurementCache.defaultLimitBytes {
        didSet {
            UserDefaults.standard.set(cacheLimitBytes, forKey: "rawView.cacheLimitBytes.v1")
            rebuildCache()
        }
    }
    /// The displayed limit is the user's own setting, not the storage
    /// implementation's clamped value, so "Off" round-trips through the picker.
    @Published private(set) var cacheUsage: MeasurementCache.Usage?
    private var cacheStorage: MeasurementCache?

    /// The active cache for reader paths: nil when the user disabled caching.
    private var cache: MeasurementCache? {
        guard cacheLimitBytes > 0 else { return nil }
        return cacheStorage
    }

    private func rebuildCache() {
        guard let project else { cacheStorage = nil; cacheUsage = nil; return }
        cacheStorage = MeasurementCache(project: project, limitBytes: max(1, cacheLimitBytes))
        refreshCacheUsage()
    }

    func refreshCacheUsage() {
        // The user-chosen limit is displayed; the storage side clamps internally.
        cacheUsage = try? cacheStorage?.usage()
    }

    func clearCacheFiles() {
        try? cacheStorage?.clear()
        refreshCacheUsage()
    }

    init() {
        let savedLimit = UserDefaults.standard.object(forKey: "rawView.cacheLimitBytes.v1") as? Int64
        cacheLimitBytes = savedLimit ?? MeasurementCache.defaultLimitBytes
        if let bookmark = UserDefaults.standard.data(forKey: "rawView.projectBookmark.v1") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let scoped = url.startAccessingSecurityScopedResource()
                if scoped { activeScopeURL = url }
                do {
                    install(try ProjectContext.open(url))
                } catch {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                        activeScopeURL = nil
                    }
                    self.error = "The previously selected project could not be reopened: \(error.localizedDescription)"
                }
            } else if UserDefaults.standard.string(forKey: "rawView.lastProjectPath.v1") != nil {
                restoreSavedPathIfPresent()
            } else {
                self.error = "The previously selected project could not be reopened. Choose a project containing a readable data/raw directory."
            }
            return
        }
        // No bookmark (openProject persists the path even when bookmark
        // creation returns nil): the saved path is still tried. Silence only
        // when both saved values are absent.
        restoreSavedPathIfPresent()
    }

    /// Installs the project at the saved `lastProjectPath`, if any. Silent
    /// when absent (first launch); otherwise installs or reports the same
    /// actionable saved-project error as the bookmark path.
    private func restoreSavedPathIfPresent() {
        guard let path = UserDefaults.standard.string(forKey: "rawView.lastProjectPath.v1") else { return }
        do {
            install(try ProjectContext.open(URL(fileURLWithPath: path)))
        } catch {
            self.error = "The previously selected project could not be reopened: \(error.localizedDescription)"
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Research Project"
        panel.message = "Choose the project folder containing data/raw."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let openedProject = try ProjectContext.open(url)
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            _ = url.startAccessingSecurityScopedResource()
            activeScopeURL?.stopAccessingSecurityScopedResource()
            activeScopeURL = url
            install(openedProject)
            if let bookmark { UserDefaults.standard.set(bookmark, forKey: "rawView.projectBookmark.v1") }
            UserDefaults.standard.set(url.path, forKey: "rawView.lastProjectPath.v1")
        } catch { self.error = error.localizedDescription }
    }

    func cancelLoad() {
        if inspectionTask != nil { inspectionCancelled = true }
        discoveryTask?.cancel()
        discoveryTask = nil
        inspectionTask?.cancel()
        inspectionTask = nil
        loadTask?.cancel()
        loadTask = nil
        cancelOverlayLoad()
        activeLoadID = UUID()
        inspectionID = UUID()
        isLoading = false
        loadingPhase = "Idle"
        if let id = focusedSourceID { sourceStates[id]?.isLoading = false }
    }

    private func refreshLoading() {
        isLoading = discoveryTask != nil || inspectionTask != nil || loadTask != nil || overlayLoadTask != nil
        if !isLoading { loadingPhase = "Idle" }
    }

    /// Deterministic multi-source selection: keep focus while selected,
    /// otherwise take the sorted first. Loads all selected without stale results.
    func updateSelection(_ ids: Set<String>) {
        cancelOverlayLoad()
        selectedSourceIDs = ids
        focusedSourceID = OverlaySelection.focused(selected: ids, current: focusedSourceID)
        hiddenSeries = hiddenSeries.intersection(ids)
        loadFocused()
        ensureSelectedLoaded()
    }

    func selectedMeasurementsSorted() -> [NormalizedMeasurement] {
        selectedSourceIDs.sorted().compactMap { sourceStates[$0]?.measurement }
    }

    /// Overlay state for the current selection: nil when fewer than two are
    /// selected (single-source display), otherwise eligible, focused-cohort
    /// partial, or blocked. A load failure or missing measurement blocks the
    /// whole comparison; the caller keeps the focused single-source plot when
    /// blocked. Quantity/unit differences exclude non-matching selections
    /// from the plotted cohort but never drop the focus.
    func overlayResult() -> OverlayEligibility? {
        guard selectedSourceIDs.count >= 2 else { return nil }
        let ids = selectedSourceIDs.sorted()
        for id in ids {
            if let state = sourceStates[id] {
                if state.isLoading { return .blocked(reason: "Loading \(ids.count) selected sources… The focused source remains shown until all finish.") }
                if let error = state.error { return .blocked(reason: "Source \(id): \(error) Comparison needs every selected source loaded.") }
                if state.measurement == nil { return .blocked(reason: "Source \(id) is not loaded yet. The focused source remains shown until all finish.") }
            } else {
                return .blocked(reason: "Source \(id) is not loaded yet. The focused source remains shown until all finish.")
            }
        }
        let measurements = ids.compactMap { sourceStates[$0]?.measurement }
        guard measurements.count == ids.count else {
            return .blocked(reason: "Not every selected source finished loading. The focused source remains shown.")
        }
        return OverlayEvaluator.evaluateFocused(measurements: measurements, manifests: studyManifests, focusedSourceID: focusedSourceID)
    }

    func ensureSelectedLoaded() {
        guard let project, !selectedSourceIDs.isEmpty else { return }
        let ids = selectedSourceIDs.sorted()
        let pending = ids.filter { sourceStates[$0]?.measurement == nil && sourceStates[$0]?.isLoading != true }
        guard !pending.isEmpty else { return }
        overlayLoadTask?.cancel()
        overlayLoadTask = nil
        overlayGeneration = UUID()
        let generation = overlayGeneration
        overlayLoadingIDs = Set(pending)
        isLoading = true
        for id in pending {
            var state = sourceStates[id] ?? GallerySourceState()
            state.isLoading = true
            state.error = nil
            sourceStates[id] = state
        }
        let loadCache = cache
        overlayLoadTask = Task { [weak self] in
            defer {
                if generation == self?.overlayGeneration, let self {
                    self.overlayLoadTask = nil
                    for id in self.overlayLoadingIDs {
                        var state = self.sourceStates[id] ?? GallerySourceState()
                        state.isLoading = false
                        self.sourceStates[id] = state
                    }
                    self.overlayLoadingIDs.removeAll()
                }
                self?.refreshLoading()
            }
            guard let self else { return }
            let byID = Dictionary(uniqueKeysWithValues: self.sources.map { ($0.id, $0) })
            for id in pending {
                if Task.isCancelled { break }
                guard generation == self.overlayGeneration else { break }
                guard let source = byID[id] else { continue }
                do {
                    let measurement = try await InstrumentReader.load(source.url, project: project, cache: loadCache)
                    guard generation == self.overlayGeneration else { break }
                    var state = self.sourceStates[id] ?? GallerySourceState()
                    state.measurement = measurement
                    state.isLoading = false
                    state.error = nil
                    self.sourceStates[id] = state
                    self.overlayLoadingIDs.remove(id)
                } catch {
                    guard generation == self.overlayGeneration else { break }
                    // Cancelled loads stay retryable without an error banner.
                    if (error as? ReaderError) == .cancelled {
                        var state = self.sourceStates[id] ?? GallerySourceState()
                        state.isLoading = false
                        self.sourceStates[id] = state
                        self.overlayLoadingIDs.remove(id)
                    } else {
                        var state = self.sourceStates[id] ?? GallerySourceState()
                        state.isLoading = false
                        state.error = error.localizedDescription
                        self.sourceStates[id] = state
                        self.overlayLoadingIDs.remove(id)
                    }
                }
            }
        }
    }

    /// Cancels the previous selection's reads and releases its pending states
    /// before a new selection starts. Generation checks keep cancelled results
    /// from installing after this reset.
    private func cancelOverlayLoad() {
        overlayLoadTask?.cancel()
        overlayLoadTask = nil
        overlayGeneration = UUID()
        for id in overlayLoadingIDs {
            guard var state = sourceStates[id] else { continue }
            if state.measurement == nil { state.isLoading = false }
            sourceStates[id] = state
        }
        overlayLoadingIDs.removeAll()
        refreshLoading()
    }

    func loadFocused() {
        guard let project, let id = focusedSourceID,
              let source = sources.first(where: { $0.id == id }) else { return }
        // Multi-source comparison owns loading: one generation loads every
        // selected source so stale results never install.
        if selectedSourceIDs.contains(id), selectedSourceIDs.count >= 2 {
            ensureSelectedLoaded()
            return
        }
        guard sourceStates[id]?.measurement == nil, sourceStates[id]?.isLoading != true else { return }
        // Cancels only the focused load: bulk inspection keeps running and its
        // results are never lost by a focus change.
        loadTask?.cancel()
        loadTask = nil
        for (previousID, var previousState) in sourceStates where previousState.isLoading {
            previousState.isLoading = false
            sourceStates[previousID] = previousState
        }
        activeLoadID = UUID()
        let taskID = activeLoadID
        let focusCache = cache
        isLoading = true
        sourceStates[id]?.isLoading = true
        sourceStates[id]?.error = nil
        loadTask = Task { [weak self] in
            defer {
                if taskID == self?.activeLoadID { self?.loadTask = nil }
                self?.refreshLoading()
            }
            do {
                let measurement = try await InstrumentReader.load(source.url, project: project, cache: focusCache)
                guard taskID == self?.activeLoadID, let self else { return }
                var state = self.sourceStates[id] ?? GallerySourceState()
                state.measurement = measurement
                state.isLoading = false
                state.error = nil
                self.sourceStates[id] = state
            } catch {
                guard taskID == self?.activeLoadID, let self else { return }
                var state = self.sourceStates[id] ?? GallerySourceState()
                state.isLoading = false
                state.error = error.localizedDescription
                self.sourceStates[id] = state
            }
        }
    }

    private func install(_ context: ProjectContext) {
        cancelLoad()
        project = context
        focusedSourceID = nil
        selectedSourceIDs = []
        hiddenSeries = []
        studyManifests = []
        manifestIssues = []
        tab = "Plot"
        error = nil
        profileIssues = []
        sources = []
        sourceStates = [:]
        inspectionCancelled = false
        rebuildCache()
        // Discovery runs through the cancellable core seam off the main actor so
        // large raw directories never block the UI. Cancellation propagates to
        // the worker; the gate token drops stale results when the user reselects.
        let requestID = UUID()
        activeLoadID = requestID
        isLoading = true
        loadingPhase = "Discovering"
        inspectedSources = 0
        inspectionTotal = 0
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestID == self.activeLoadID { self.discoveryTask = nil }
                self.refreshLoading()
            }
            let generation = await self.discoveryGate.begin()
            let discovered: [RawSource]
            do {
                discovered = try await context.discoverSourcesAsync()
            } catch is CancellationError {
                return
            } catch {
                guard requestID == self.activeLoadID, await self.discoveryGate.isCurrent(generation) else { return }
                self.sources = []
                self.sourceStates = [:]
                self.error = "Could not inventory data/raw: \(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled, requestID == self.activeLoadID,
                  await self.discoveryGate.isCurrent(generation) else { return }
            self.sources = discovered
            self.sourceStates = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, GallerySourceState()) })
            // Manifests are existing project YAML (study_id + sources); loaded
            // off-main so large projects never block the UI.
            let loaded = await Task.detached(priority: .userInitiated) { ManifestIndex.load(project: context) }.value
            guard !Task.isCancelled, requestID == self.activeLoadID,
                  await self.discoveryGate.isCurrent(generation) else { return }
            self.studyManifests = loaded.manifests
            self.manifestIssues = loaded.issues
            if discovered.isEmpty {
                self.error = "No readable regular files were found under data/raw."
            } else {
                self.startInspection(context)
            }
        }
        refreshCacheUsage()
    }

    private func startInspection(_ context: ProjectContext) {
        // Cancels only bulk inspection: discovery already finished and any
        // focused load keeps its own slot and state.
        inspectionTask?.cancel()
        inspectionTask = nil
        inspectionID = UUID()
        let requestID = inspectionID
        isLoading = true
        error = nil
        loadingPhase = "Inspecting"
        inspectedSources = 0
        inspectionTotal = sources.count
        profileIssues = []
        inspectionCancelled = false
        sourceStates = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, GallerySourceState()) })
        inspectSources(sources, project: context, requestID: requestID, baseCompleted: 0)
    }

    /// Resumes a cancelled inspection for the sources still lacking results,
    /// keeping everything already inspected. Returns false when nothing is pending.
    @discardableResult
    func resumeInspection() -> Bool {
        guard let project, inspectionTask == nil else { return false }
        let pending = sources.filter { sourceStates[$0.id]?.inspection == nil }
        guard !pending.isEmpty else { return false }
        inspectionID = UUID()
        let requestID = inspectionID
        inspectionCancelled = false
        isLoading = true
        loadingPhase = "Inspecting"
        inspectionTotal = sources.count
        inspectedSources = sources.count - pending.count
        inspectSources(pending, project: project, requestID: requestID, baseCompleted: sources.count - pending.count)
        return true
    }

    private func inspectSources(_ targets: [RawSource], project: ProjectContext, requestID: UUID, baseCompleted: Int) {
        inspectionTask = Task {
            let report = await InstrumentReader.inspectMany(targets, project: project, cache: cache,
                onProgress: { results, completed in
                    await MainActor.run {
                        guard requestID == self.inspectionID else { return }
                        for result in results {
                            var state = self.sourceStates[result.id] ?? GallerySourceState()
                            state.inspection = result.inspection
                            state.error = result.error
                            self.sourceStates[result.id] = state
                        }
                        self.inspectedSources = baseCompleted + completed
                    }
                })
            await MainActor.run { self.refreshCacheUsage() }
            guard !Task.isCancelled, requestID == self.inspectionID else {
                // Superseded runs must not touch the new run's slot or flag.
                if Task.isCancelled, requestID == self.inspectionID {
                    self.inspectionCancelled = true
                    self.inspectionTask = nil
                }
                self.refreshLoading()
                return
            }
            self.profileIssues = report.profileIssues
            self.inspectionTask = nil
            self.refreshLoading()
            if self.focusedSourceID == nil { self.focusedSourceID = self.sources.first?.id }
            if self.selectedSourceIDs.isEmpty, let first = self.sources.first?.id {
                self.selectedSourceIDs = [first]
                self.focusedSourceID = OverlaySelection.focused(selected: self.selectedSourceIDs, current: self.focusedSourceID)
            }
            self.loadFocused()
            self.ensureSelectedLoaded()
        }
    }
}

struct GallerySourceState {
    var inspection: SourceInspection?
    var measurement: NormalizedMeasurement?
    var error: String?
    var isLoading = false
}

struct RawViewShell: View {
    @StateObject private var model = RawViewModel()

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("PROJECT SOURCES").font(.headline)
                    Spacer()
                    Button(action: model.openProject) { Image(systemName: "folder.badge.plus") }
                        .help("Open project")
                }
                if let project = model.project {
                    Text(project.root.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if model.isLoading && model.loadingPhase == "Discovering" {
                        ProgressView {
                            Text("Discovering sources under data/raw…")
                        }
                        Button("Cancel Discovery", action: model.cancelLoad).buttonStyle(.bordered)
                    } else if model.isLoading && model.loadingPhase == "Inspecting" {
                        ProgressView(value: Double(model.inspectedSources), total: Double(max(1, model.inspectionTotal))) {
                            Text("Inspecting \(model.inspectedSources) of \(model.inspectionTotal) sources")
                        }
                        Button("Cancel Inspection", action: model.cancelLoad).buttonStyle(.bordered)
                    } else if model.inspectionCancelled {
                        let remaining = model.sources.filter { model.sourceStates[$0.id]?.inspection == nil }.count
                        if remaining > 0 {
                            Text("Inspection cancelled · \(remaining) remaining")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Resume Inspection", action: { _ = model.resumeInspection() }).buttonStyle(.bordered)
                        }
                    }
                    ProjectSourcesSidebar(sources: model.sources,
                        inspections: Dictionary(uniqueKeysWithValues: model.sourceStates.compactMap { id, state in state.inspection.map { (id, $0) } }),
                        states: model.sourceStates, focusedSourceID: $model.focusedSourceID,
                        selectedSourceIDs: $model.selectedSourceIDs)
                    if !model.profileIssues.isEmpty || !model.manifestIssues.isEmpty {
                        profileIssueList
                    }
                    Spacer()
                    Text("RawView's built-in readers parse sources. Raw files and instrument profiles are never modified.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("No Project", systemImage: "folder", description: Text("Open the research project that owns the raw files."))
                }
            }
            .padding(14)
            .navigationSplitViewColumnWidth(min: 220, ideal: 265)
        } detail: {
            RawDetailView(model: model)
                .overlay(alignment: .top) {
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .padding(10).frame(maxWidth: .infinity).background(.regularMaterial)
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                }
        }
        .onChange(of: model.focusedSourceID) { _, _ in model.loadFocused() }
        .onChange(of: model.selectedSourceIDs) { _, new in model.updateSelection(new) }
    }

    private var profileIssueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.profileIssues.isEmpty {
                Text("PROFILE ISSUES").font(.caption2.bold()).foregroundStyle(.orange)
                ForEach(Array(model.profileIssues.enumerated()), id: \.offset) { _, issue in
                    Text(issue).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !model.manifestIssues.isEmpty {
                Text("STUDY MANIFESTS").font(.caption2.bold()).foregroundStyle(.orange)
                ForEach(Array(model.manifestIssues.enumerated()), id: \.offset) { _, issue in
                    Text(issue).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }
}

struct RawDetailView: View {
    @ObservedObject var model: RawViewModel

    var body: some View {
        HStack(spacing: 0) {
            ProjectGallery(sources: model.sources, states: model.sourceStates,
                           focusedSourceID: $model.focusedSourceID,
                           selectedIDs: model.selectedSourceIDs, hidden: model.hiddenSeries,
                           lineWidth: model.lineWidth, overlay: model.overlayResult(),
                           tab: $model.tab,
                           xAbsolute: $model.xAbsolute, yAbsolute: $model.yAbsolute,
                           xScale: $model.xScale, yScale: $model.yScale, retry: model.loadFocused)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inspector
                .frame(width: 300)
        }
    }

    private var inspector: some View {
        let focusedID = model.focusedSourceID
        var currentState: GallerySourceState? = nil
        if let focusedID { currentState = model.sourceStates[focusedID] }
        var currentSource: RawSource? = nil
        if let focusedID {
            currentSource = model.sources.first(where: { $0.id == focusedID })
        }
        return InspectorPane(measurement: currentState?.measurement, inspection: currentState?.inspection,
                             source: currentSource?.url, error: currentState?.error ?? model.error,
                             states: model.sourceStates,
                             selectedIDs: model.selectedSourceIDs, focusedID: $model.focusedSourceID,
                             hidden: $model.hiddenSeries, lineWidth: $model.lineWidth,
                             xAbsolute: $model.xAbsolute, yAbsolute: $model.yAbsolute,
                             xScale: $model.xScale, yScale: $model.yScale,
                             overlay: model.overlayResult(),
                             onRetry: model.loadFocused,
                             cacheStatus: cacheStatus,
                             onClearCache: { model.clearCacheFiles(); model.loadFocused() },
                             onLimitChange: { model.cacheLimitBytes = $0 })
    }

    private var cacheStatus: InspectorPane.CacheStatus? {
        guard model.project != nil else { return nil }
        let usage = model.cacheUsage ?? MeasurementCache.Usage(usedBytes: 0, entryCount: 0,
                                                               limitBytes: model.cacheLimitBytes, root: "")
        return InspectorPane.CacheStatus(usedBytes: usage.usedBytes, entryCount: usage.entryCount,
                                         limitBytes: model.cacheLimitBytes)
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
    @State private var zoom = 1.0
    @State private var gestureZoomStart = 1.0
    @State private var pan = CGSize.zero
    @State private var dragStart = CGSize.zero

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
        VStack(alignment: .leading, spacing: 8) {
            Text(measurement.instrument.name + (measurement.applicationMode.map { " · \($0)" } ?? ""))
                .font(.headline)
            switch transformed {
            case .failure(let failure):
                if case .message(let message) = failure { ContentUnavailableView("Invalid Plot Domain", systemImage: "chart.xyaxis.line", description: Text(message)) }
            case .success(let data):
                Canvas { context, size in draw(data, in: &context, size: size) }
                    .frame(maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture().onChanged { pan = CGSize(width: dragStart.width + $0.translation.width, height: dragStart.height + $0.translation.height) }.onEnded { _ in dragStart = pan })
                    .simultaneousGesture(MagnifyGesture().onChanged { zoom = min(max(gestureZoomStart * $0.magnification, 0.5), 12) }.onEnded { _ in gestureZoomStart = zoom })
                    .overlay(alignment: .topTrailing) {
                        Button("Reset plot") { zoom = 1; gestureZoomStart = 1; pan = .zero; dragStart = .zero }.buttonStyle(.bordered).padding(8)
                    }
                HStack(spacing: 14) {
                    ForEach(Array(data.1.enumerated()), id: \.offset) { index, item in
                        Label(item.0, systemImage: "line.diagonal")
                            .foregroundStyle(palette(index)).font(.caption)
                    }
                    Spacer()
                    Text("Drag to pan · Pinch to zoom · \(data.0.count) ordered rows · \(gapCount(data)) gaps")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func draw(_ data: ([Double?], [(String, [Double?])]), in context: inout GraphicsContext, size: CGSize) {
        let finiteX = data.0.compactMap { $0 }
        let finiteY = data.1.flatMap { $0.1.compactMap { $0 } }
        guard !finiteX.isEmpty, !finiteY.isEmpty else { return }
        let leftGutter = min(112, max(66, size.width * 0.24))
        let plot = CGRect(x: leftGutter, y: 12, width: max(1, size.width - leftGutter - 18), height: max(1, size.height - 58))
        var frame = Path(); frame.addRect(plot); context.stroke(frame, with: .color(.primary), lineWidth: 0.8)
        let xRange = viewport(expanded(finiteX), pan: pan.width, dimension: plot.width, vertical: false)
        let yRange = viewport(expanded(finiteY), pan: pan.height, dimension: plot.height, vertical: true)
        for index in 0...4 {
            let t = Double(index) / 4
            let x = xRange.lowerBound + t * (xRange.upperBound - xRange.lowerBound)
            let y = yRange.lowerBound + t * (yRange.upperBound - yRange.lowerBound)
            let px = plot.minX + t * plot.width
            let py = plot.maxY - t * plot.height
            var tick = Path(); tick.move(to: CGPoint(x: px, y: plot.maxY)); tick.addLine(to: CGPoint(x: px, y: plot.maxY + 4))
            tick.move(to: CGPoint(x: plot.minX, y: py)); tick.addLine(to: CGPoint(x: plot.minX - 4, y: py))
            context.stroke(tick, with: .color(.primary), lineWidth: 0.7)
            context.draw(Text(axisLabel(x, scale: xScale)).font(.custom(NativePlotStyle.fontFamily, size: 10)), at: CGPoint(x: px, y: plot.maxY + 17))
            context.draw(Text(axisLabel(y, scale: yScale)).font(.custom(NativePlotStyle.fontFamily, size: 10)), at: CGPoint(x: plot.minX - 36, y: py))
        }
        let xChannel = measurement.channel(named: measurement.view.x ?? "")
        let xTitle = axisTitle(xChannel?.label ?? "X", unit: xChannel?.unit ?? "", absolute: xAbsolute, scale: xScale)
        let yChannel = measurement.view.y?.first.flatMap(measurement.channel(named:))
        let yTitle = axisTitle(yChannel?.label ?? "Y", unit: yChannel?.unit ?? "", absolute: yAbsolute, scale: yScale)
        context.draw(Text(xTitle).font(.custom(NativePlotStyle.fontFamily, size: 11)), at: CGPoint(x: plot.midX, y: size.height - 4))
        var yLabelContext = context
        yLabelContext.translateBy(x: 10, y: plot.midY)
        yLabelContext.rotate(by: .degrees(-90))
        yLabelContext.draw(Text(yTitle).font(.custom(NativePlotStyle.fontFamily, size: 11)), at: .zero)
        var plotContext = context
        plotContext.clip(to: Path(plot))
        for (seriesIndex, item) in data.1.enumerated() {
            guard item.1.count == data.0.count else { continue }
            // Gap segmentation: a nil x or y breaks the line; rows stay in order.
            // A singleton run would stroke as an invisible zero-length line, so
            // it is drawn as a visible dot instead while gaps stay breaks.
            for run in AxisTransform.segments(x: data.0, y: item.1) {
                if run.count == 1, let index = run.first,
                   let xv = data.0[index], let yv = item.1[index] {
                    let tx = (xv - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
                    let ty = (yv - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
                    let point = CGPoint(x: plot.minX + tx * plot.width, y: plot.maxY - ty * plot.height)
                    plotContext.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(palette(seriesIndex)))
                    continue
                }
                var line = Path()
                for (pointIndex, index) in run.enumerated() {
                    guard let xv = data.0[index], let yv = item.1[index] else { continue }
                    let tx = (xv - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
                    let ty = (yv - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
                    let point = CGPoint(x: plot.minX + tx * plot.width, y: plot.maxY - ty * plot.height)
                    if pointIndex == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                plotContext.stroke(line, with: .color(palette(seriesIndex)), lineWidth: lineWidth)
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
    private func axisLabel(_ value: Double, scale: AxisScale) -> String {
        scale == .logarithmic ? "10^\(NumberLabel.format(value))" : NumberLabel.format(value)
    }
    private func palette(_ index: Int) -> Color {
        let colors = NativePlotStyle.palette
        guard !colors.isEmpty else { return .blue }
        let color = colors[index % colors.count]
        return Color(.sRGB, red: Double(color[0]) / 255, green: Double(color[1]) / 255, blue: Double(color[2]) / 255, opacity: 1)
    }
}

struct MeasurementTable: View {
    let measurement: NormalizedMeasurement
    private var rows: [Int] { Array(0..<(measurement.channels.first?.values.count ?? 0)) }

    var body: some View {
        if measurement.channels.isEmpty {
            ContentUnavailableView("Metadata Only", systemImage: "tablecells", description: Text("This source has no normalized numeric channels."))
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    rowHeader
                    ForEach(rows, id: \.self) { index in
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

struct InspectorPane: View {
    let measurement: NormalizedMeasurement?
    let inspection: SourceInspection?
    let source: URL?
    let error: String?
    let states: [String: GallerySourceState]
    let selectedIDs: Set<String>
    @Binding var focusedID: String?
    @Binding var hidden: Set<String>
    @Binding var lineWidth: Double
    @Binding var xAbsolute: Bool
    @Binding var yAbsolute: Bool
    @Binding var xScale: AxisScale
    @Binding var yScale: AxisScale
    let overlay: OverlayEligibility?
    let onRetry: () -> Void
    // Cache controls (Issues 6–7): usage/limit status, a clear action, and the
    // configurable per-project limit. Presentation only — the model owns state.
    var cacheStatus: CacheStatus? = nil
    var onClearCache: (() -> Void)? = nil
    var onLimitChange: ((Int64) -> Void)? = nil

    struct CacheStatus {
        var usedBytes: Int64
        var entryCount: Int
        var limitBytes: Int64
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("INSPECTOR").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                dataSection
                styleSection
                seriesSection
                axesSection
                cacheSection
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(14)
        }.background(.background)
    }

    private var cacheSection: some View {
        section("Cache") {
            if let cacheStatus, let onClearCache {
                usageRow(cacheStatus)
                HStack {
                    Button("Clear cache") { onClearCache() }
                        .help("Remove all RawView cache entries for this project. Raw files and profiles are never modified.")
                        .accessibilityLabel("Clear RawView cache")
                    Spacer()
                }
                Picker("Cache limit", selection: Binding(
                    get: { cacheStatus.limitBytes },
                    set: { newLimit in onLimitChange?(newLimit) }
                )) {
                    Text("Off").tag(Int64(0))
                    Text("128 MiB").tag(Int64(128 * 1024 * 1024))
                    Text("512 MiB").tag(Int64(512 * 1024 * 1024))
                    Text("2 GiB").tag(Int64(2 * 1024 * 1024 * 1024))
                }
                .labelsHidden()
                .accessibilityLabel("Cache disk limit")
                Text("Verified entries stay in a private app-local cache; RawView ignores project-controlled cache files. Entries are capped at 128 MiB. Inspection hits re-hash the bounded header; measurement hits verify a fresh full-file SHA-256.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("No project open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func usageRow(_ status: CacheStatus) -> some View {
        let used = ByteCountFormatter.string(fromByteCount: status.usedBytes, countStyle: .file)
        let limit = status.limitBytes <= 0 ? "Off" : ByteCountFormatter.string(fromByteCount: status.limitBytes, countStyle: .file)
        return HStack {
            Text("\(status.entryCount) entries · \(used) of \(limit)")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Cache usage: \(status.entryCount) entries, \(used) used of \(limit) limit")
            Spacer()
        }
    }

    private var dataSection: some View {        section("Data") {
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
    }

    private var styleSection: some View {
        section("Style") {
            HStack {
                Text("Line width").font(.caption)
                Slider(value: $lineWidth, in: 0.5...3.0, step: 0.1) {
                    EmptyView()
                }.labelsHidden().accessibilityLabel("Series line width")
            }
            Text("Colors follow the native plot palette and repeat after its configured colors; source labels stay distinct. Visibility only changes presentation.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var seriesSection: some View {
        section("Series") {
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
                Text("Shared manifest \(URL(fileURLWithPath: path).lastPathComponent)").font(.caption2).foregroundStyle(.secondary)
            } else if case .partial(let group) = overlay {
                Text("Shared manifest \(URL(fileURLWithPath: group.manifestPath).lastPathComponent): plotting focused cohort (\(group.plottedPaths.count) of \(group.plottedPaths.count + group.excluded.count)). Selection unchanged.").font(.caption2).foregroundStyle(.secondary)
                ForEach(group.excluded, id: \.path) { exclusion in
                    Text("Excluded \(URL(fileURLWithPath: exclusion.path).lastPathComponent): \(exclusion.reason)").font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }
    }

    private func seriesRow(_ id: String) -> some View {
        let isHidden = hidden.contains(id)
        let isFocused = focusedID == id
        let state = states[id]
        let label = URL(fileURLWithPath: id).lastPathComponent
        let exclusionReason: String? = {
            if case .partial(let group) = overlay {
                return group.excluded.first(where: { $0.path == id })?.reason
            }
            return nil
        }()
        return HStack(spacing: 8) {
            Circle().fill(seriesColor(id)).frame(width: 9, height: 9).accessibilityHidden(true)
            Button {
                focusedID = id
                onRetry()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.caption).lineLimit(1).truncationMode(.middle)
                    if let error = state?.error {
                        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    } else if state?.isLoading == true {
                        Text("Loading…").font(.caption2).foregroundStyle(.secondary)
                    } else if let exclusionReason {
                        Text("Excluded from comparison: \(exclusionReason)").font(.caption2).foregroundStyle(.orange).lineLimit(3)
                    } else if isFocused {
                        Text("Focused").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Focus this source")
            .accessibilityLabel("Focus \(label)")
            Spacer(minLength: 4)
            if exclusionReason == nil {
                Toggle(isOn: Binding(get: { !isHidden }, set: { show in
                    if show { hidden.remove(id) } else { hidden.insert(id) }
                })) { Text("Show \(label)") }.labelsHidden()
                    .help(isHidden ? "Show this series" : "Hide this series")
                    .accessibilityLabel("\(label) visibility")
            } else {
                Text("Not plotted").font(.caption2).foregroundStyle(.secondary)
                    .help("Excluded from the focused comparison cohort")
                    .accessibilityLabel("\(label) excluded from comparison")
            }
        }
        .contentShape(Rectangle())
    }

    private var axesSection: some View {
        section("Axes") {
            axisControl("X", absolute: $xAbsolute, scale: $xScale)
            axisControl("Y", absolute: $yAbsolute, scale: $yScale)
            Text("Absolute applies before the scale; log needs positive values.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func axisControl(_ name: String, absolute: Binding<Bool>, scale: Binding<AxisScale>) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.caption).bold().frame(width: 12, alignment: .leading)
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

    private func seriesColor(_ id: String) -> Color {
        let order = selectedIDs.sorted()
        let index = order.firstIndex(of: id) ?? 0
        return NativeOverlayPalette.color(index)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NativePlotStylePayload: Decodable {
    enum CodingKeys: String, CodingKey { case paletteRGB = "palette_rgb", fontFamily = "font_family" }
    let paletteRGB: [[Int]]
    let fontFamily: String
}
private enum NativePlotStyle {
    private static let value: NativePlotStylePayload? = {
        guard let url = Bundle.main.url(forResource: "NativePlotStyle", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NativePlotStylePayload.self, from: data)
    }()
    static let palette: [[Int]] = value?.paletteRGB ?? []
    static let fontFamily: String = value?.fontFamily ?? "Helvetica Neue"
}
