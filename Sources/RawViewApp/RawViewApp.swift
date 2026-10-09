import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RawViewCore

@main
struct RawViewApp: App {
    @StateObject private var model = RawViewModel()
    @AppStorage("appTheme") private var appTheme: String = "System"

    private var preferredScheme: ColorScheme? {
        switch appTheme {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup("RawView") {
            RawViewShell(model: model)
                .preferredColorScheme(preferredScheme)
        }
        .defaultSize(width: 1320, height: 820)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(preferredScheme)
        }
    }
}

struct PlotSnapshot: Identifiable, Equatable {
    let id: UUID
    var name: String
    let timestamp: Date
    let selectedSourceIDs: Set<String>
    let focusedSourceID: String?
    let customSeriesLabels: [String: String]
    let legendOffset: CGSize
    let showLegend: Bool
    let xScale: AxisScale
    let yScale: AxisScale
    let xAbsolute: Bool
    let yAbsolute: Bool

    init(
        id: UUID = UUID(),
        name: String,
        timestamp: Date = Date(),
        selectedSourceIDs: Set<String>,
        focusedSourceID: String?,
        customSeriesLabels: [String: String],
        legendOffset: CGSize,
        showLegend: Bool,
        xScale: AxisScale,
        yScale: AxisScale,
        xAbsolute: Bool,
        yAbsolute: Bool
    ) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.selectedSourceIDs = selectedSourceIDs
        self.focusedSourceID = focusedSourceID
        self.customSeriesLabels = customSeriesLabels
        self.legendOffset = legendOffset
        self.showLegend = showLegend
        self.xScale = xScale
        self.yScale = yScale
        self.xAbsolute = xAbsolute
        self.yAbsolute = yAbsolute
    }
}

@MainActor
final class RawViewModel: ObservableObject {
    @Published var project: ProjectContext?
    @Published var sources: [RawSource] = []
    @Published var sourceStates: [String: GallerySourceState] = [:]
    @Published var inspections: [String: SourceInspection] = [:]
    @Published var focusedSourceID: String?
    @Published var selectedSourceIDs: Set<String> = []
    @Published var hiddenSeries: Set<String> = []
    @Published var lineWidth: Double = 1.4 {
        didSet {
            let clamped = min(max(lineWidth, 0.2), 10.0)
            if lineWidth != clamped {
                lineWidth = clamped
            }
        }
    }
    @Published var renderStyle: PlotRenderStyle = .line
    @Published var markType: PlotMarkType = .line {
        didSet { UserDefaults.standard.set(markType.rawValue, forKey: "defaultMarkType") }
    }
    @Published var interpolation: PlotInterpolation = .linear {
        didSet { UserDefaults.standard.set(interpolation.rawValue, forKey: "defaultInterpolation") }
    }
    @Published var colorBySweepProgress: Bool = false
    @Published var markerSize: Double = 4.5 {
        didSet {
            let clamped = min(max(markerSize, 1.0), 20.0)
            if markerSize != clamped {
                markerSize = clamped
            }
        }
    }
    @Published var studyManifests: [StudyManifest] = []
    @Published var manifestIssues: [String] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var profileIssues: [String] = []
    @Published var inspectedSources = 0
    @Published var inspectionTotal = 0
    @Published var loadingPhase = "Idle"
    @Published var inspectionCancelled = false
    var isLazyInspectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "isLazyInspectionEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "isLazyInspectionEnabled")
            objectWillChange.send()
        }
    }
    var maxComparisonAutoLoad: Int {
        get { UserDefaults.standard.object(forKey: "maxComparisonAutoLoad") as? Int ?? 15 }
        set {
            UserDefaults.standard.set(newValue, forKey: "maxComparisonAutoLoad")
            objectWillChange.send()
        }
    }
    var unindexedCount: Int {
        max(0, sources.count - inspections.count)
    }
    @Published var tab = "Plot"
    @Published var xAbsolute = false
    @Published var yAbsolute = false
    @Published var xScale: AxisScale = .linear
    @Published var yScale: AxisScale = .linear
    @Published var showInspector = true
    func toggleInspector() { showInspector.toggle() }
    @Published var showLegend = true
    @Published var customSeriesLabels: [String: String] = [:]
    @Published var legendOffset: CGSize = .zero
    @Published var snapshots: [PlotSnapshot] = []
    @Published var activeSnapshotID: UUID? = nil
    @Published var comparisonTitle: String = "" {
        didSet {
            if let activeID = activeSnapshotID, let idx = snapshots.firstIndex(where: { $0.id == activeID }) {
                let trimmed = comparisonTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    snapshots[idx].name = trimmed
                }
            }
        }
    }

    func toggleSnapshot(_ snap: PlotSnapshot) {
        if activeSnapshotID == snap.id {
            activeSnapshotID = nil
            comparisonTitle = ""
        } else {
            loadSnapshot(snap)
        }
    }

    func saveSnapshot() {
        guard !selectedSourceIDs.isEmpty || focusedSourceID != nil else { return }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: Date())
        let name: String
        let custom = comparisonTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            name = custom
        } else if selectedSourceIDs.count >= 2 {
            name = "Overlay (\(selectedSourceIDs.count)) · \(timeStr)"
        } else if let focused = focusedSourceID {
            let base = URL(fileURLWithPath: focused).deletingPathExtension().lastPathComponent
            let short = base.count > 16 ? String(base.prefix(14)) + "…" : base
            name = "\(short) · \(timeStr)"
        } else {
            name = "Snapshot \(snapshots.count + 1) · \(timeStr)"
        }
        let snap = PlotSnapshot(
            name: name,
            selectedSourceIDs: selectedSourceIDs,
            focusedSourceID: focusedSourceID,
            customSeriesLabels: customSeriesLabels,
            legendOffset: legendOffset,
            showLegend: showLegend,
            xScale: xScale,
            yScale: yScale,
            xAbsolute: xAbsolute,
            yAbsolute: yAbsolute
        )
        snapshots.append(snap)
        activeSnapshotID = snap.id
        comparisonTitle = name
    }

    func loadSnapshot(_ snap: PlotSnapshot) {
        activeSnapshotID = snap.id
        comparisonTitle = snap.name
        selectedSourceIDs = snap.selectedSourceIDs
        focusedSourceID = snap.focusedSourceID
        customSeriesLabels = snap.customSeriesLabels
        legendOffset = snap.legendOffset
        showLegend = snap.showLegend
        xScale = snap.xScale
        yScale = snap.yScale
        xAbsolute = snap.xAbsolute
        yAbsolute = snap.yAbsolute
        if selectedSourceIDs.count >= 2 {
            ensureSelectedLoaded()
        } else {
            loadFocused()
        }
    }

    func deleteSnapshot(_ snap: PlotSnapshot) {
        snapshots.removeAll { $0.id == snap.id }
        if activeSnapshotID == snap.id {
            activeSnapshotID = nil
            comparisonTitle = ""
        }
    }

    func exportCurrentFigure() {
        let name: String
        if selectedSourceIDs.count >= 2 {
            name = "Overlay_Export"
        } else if let focused = focusedSourceID {
            name = URL(fileURLWithPath: focused).deletingPathExtension().lastPathComponent
        } else {
            name = "Figure_Export"
        }

        if selectedSourceIDs.count >= 2 {
            let cohort = selectedSourceIDs.sorted().compactMap { sourceStates[$0]?.measurement }
            let visible = cohort.filter { !hiddenSeries.contains($0.source.path) }
            let exportView = OverlayPlot(
                measurements: visible,
                selectedSourceIDs: selectedSourceIDs,
                focused: focusedSourceID.flatMap { sourceStates[$0]?.measurement },
                lineWidth: lineWidth,
                renderStyle: renderStyle,
                markType: markType,
                interpolation: interpolation,
                markerSize: markerSize,
                colorBySweepProgress: colorBySweepProgress,
                xAbsolute: xAbsolute,
                yAbsolute: yAbsolute,
                xScale: xScale,
                yScale: yScale,
                comparisonTitle: comparisonTitle,
                showLegend: showLegend,
                customSeriesLabels: customSeriesLabels,
                legendOffset: .constant(.zero)
            )
            FigureExporter.promptExportFigure(view: exportView, defaultName: name)
        } else if let focused = focusedSourceID, let measurement = sourceStates[focused]?.measurement {
            let exportView = NativePlot(
                measurement: measurement,
                xAbsolute: xAbsolute,
                yAbsolute: yAbsolute,
                xScale: xScale,
                yScale: yScale,
                lineWidth: lineWidth,
                renderStyle: renderStyle,
                markType: markType,
                interpolation: interpolation,
                markerSize: markerSize,
                colorBySweepProgress: colorBySweepProgress,
                showLegend: showLegend,
                customSeriesLabels: customSeriesLabels,
                legendOffset: .constant(.zero)
            )
            FigureExporter.promptExportFigure(view: exportView, defaultName: name)
        }
    }

    func exportCurrentData() {
        let name: String
        if let focused = focusedSourceID {
            name = URL(fileURLWithPath: focused).deletingPathExtension().lastPathComponent + ".csv"
        } else {
            name = "data_export.csv"
        }
        let measurement = focusedSourceID.flatMap { sourceStates[$0]?.measurement }
        FigureExporter.promptExportData(measurement: measurement, defaultName: name)
    }
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

    func updateGenericColumnMapping(sourceID: String, xCol: Int, yCol: Int) {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        do {
            let updated = try GenericTableReader.loadMeasurement(
                url: source.url,
                sourceID: source.relativePath,
                xColumnIndex: xCol,
                yColumnIndex: yCol
            )
            sourceStates[sourceID]?.measurement = updated
            objectWillChange.send()
        } catch {
            self.error = "Failed to remap columns: \(error.localizedDescription)"
        }
    }

    struct DatabaseStats {
        let path: String
        let fileSizeBytes: Int64
        let indexedCount: Int
        let totalSources: Int
    }

    var databaseStats: DatabaseStats? {
        guard let project else { return nil }
        let dbURL = project.indexDatabaseURL
        let size = (try? dbURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let count = (try? IndexDatabase.open(at: dbURL))?.lookupAll().count ?? 0
        return DatabaseStats(
            path: dbURL.path,
            fileSizeBytes: size,
            indexedCount: count,
            totalSources: sources.count
        )
    }

    func reindexAllSources() {
        guard let project else { return }
        inspectionTask?.cancel()
        inspectionTask = nil

        if let db = try? IndexDatabase.open(at: project.indexDatabaseURL) {
            try? db.deleteAll()
        }

        for source in sources {
            var state = sourceStates[source.id] ?? GallerySourceState()
            state.inspection = nil
            state.error = nil
            sourceStates[source.id] = state
        }
        inspections.removeAll()

        inspectionID = UUID()
        let requestID = inspectionID
        inspectionCancelled = false
        isLoading = true
        loadingPhase = "Inspecting"
        inspectionTotal = sources.count
        inspectedSources = 0

        let indexDB = try? IndexDatabase.open(at: project.indexDatabaseURL)
        inspectSources(sources, project: project, requestID: requestID, baseCompleted: 0, indexDB: indexDB)
    }

    init() {
        let savedLimit = UserDefaults.standard.object(forKey: "rawView.cacheLimitBytes.v1") as? Int64
        cacheLimitBytes = savedLimit ?? MeasurementCache.defaultLimitBytes
        let savedLineWidth = UserDefaults.standard.double(forKey: "defaultLineWidth")
        if savedLineWidth > 0 {
            lineWidth = savedLineWidth
        }
        let savedMarkerSize = UserDefaults.standard.double(forKey: "defaultMarkerSize")
        if savedMarkerSize > 0 {
            markerSize = savedMarkerSize
        }
        if let savedStyleRaw = UserDefaults.standard.string(forKey: "defaultRenderStyle"),
           let savedStyle = PlotRenderStyle(rawValue: savedStyleRaw) {
            renderStyle = savedStyle
            markType = savedStyle.markType
            interpolation = savedStyle.interpolation
        }
        if let savedMarkRaw = UserDefaults.standard.string(forKey: "defaultMarkType"),
           let savedMark = PlotMarkType(rawValue: savedMarkRaw) {
            markType = savedMark
        }
        if let savedInterpRaw = UserDefaults.standard.string(forKey: "defaultInterpolation"),
           let savedInterp = PlotInterpolation(rawValue: savedInterpRaw) {
            interpolation = savedInterp
        }
        // Never auto-reopen previous project on launch.
        // User explicitly opens via the "Open Project" button.
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
            _ = url.startAccessingSecurityScopedResource()
            activeScopeURL?.stopAccessingSecurityScopedResource()
            activeScopeURL = url
            install(openedProject)
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

    var isInspecting: Bool {
        inspectionTask != nil && inspectedSources < max(1, inspectionTotal)
    }

    var isPlotLoading: Bool {
        overlayLoadTask != nil || (loadTask != nil && sourceStates[focusedSourceID ?? ""]?.measurement == nil)
    }

    var isOverlayLoading: Bool {
        overlayLoadTask != nil
    }

    private func refreshLoading() {
        let inspecting = isInspecting
        let discovering = discoveryTask != nil
        let loadingSingle = loadTask != nil
        let loadingOverlay = overlayLoadTask != nil
        isLoading = inspecting || discovering || loadingSingle || loadingOverlay
        if !inspecting && loadingPhase == "Inspecting" { loadingPhase = "Idle" }
        if !discovering && loadingPhase == "Discovering" { loadingPhase = "Idle" }
        if !isLoading { loadingPhase = "Idle" }
    }

    /// Deterministic multi-source selection: keep focus while selected,
    /// otherwise take the sorted first. Loads all selected without stale results.
    func updateSelection(_ ids: Set<String>) {
        if let activeID = activeSnapshotID, let snap = snapshots.first(where: { $0.id == activeID }) {
            if snap.selectedSourceIDs != ids {
                activeSnapshotID = nil
                comparisonTitle = ""
            }
        }
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
        return OverlayEvaluator.evaluateFocused(measurements: measurements, manifests: studyManifests, focusedSourceID: focusedSourceID, requireManifest: false)
    }

    func ensureSelectedLoaded() {
        guard let project, !selectedSourceIDs.isEmpty else { return }
        let ids = selectedSourceIDs.sorted()
        let pending = ids.filter { sourceStates[$0]?.measurement == nil && sourceStates[$0]?.isLoading != true }
        guard !pending.isEmpty else { return }
        let toLoad = Array(pending.prefix(maxComparisonAutoLoad))
        overlayLoadTask?.cancel()
        overlayLoadTask = nil
        overlayGeneration = UUID()
        let generation = overlayGeneration
        overlayLoadingIDs = Set(toLoad)
        isLoading = true
        for id in toLoad {
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
            for id in toLoad {
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
                guard let self else { return }
                if self.sourceStates[id]?.inspection == nil {
                    let singleReport = await InstrumentReader.inspectMany([source], project: project, cache: focusCache)
                    guard taskID == self.activeLoadID else { return }
                    if let result = singleReport.results.first {
                        var state = self.sourceStates[id] ?? GallerySourceState()
                        state.inspection = result.inspection
                        state.error = result.error
                        self.sourceStates[id] = state
                        if let inspection = result.inspection {
                            self.inspections[id] = inspection
                            let mtime: Int64 = source.mtime != 0 ? source.mtime : ((try? source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970).map { Int64($0) } ?? 0)
                            let record = IndexDatabase.Record(source: source, inspection: inspection, mtime: mtime)
                            if let indexDB = try? IndexDatabase.open(at: project.indexDatabaseURL) {
                                try? indexDB.upsertBatch([record])
                            }
                        }
                    }
                }
                let measurement = try await InstrumentReader.load(source.url, project: project, cache: focusCache)
                guard taskID == self.activeLoadID else { return }
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
            self.studyManifests = []
            self.manifestIssues = []
            if discovered.isEmpty {
                self.error = "No readable regular files were found under data/raw."
            } else {
                if self.focusedSourceID == nil { self.focusedSourceID = discovered.first?.id }
                if self.selectedSourceIDs.isEmpty, let first = discovered.first?.id {
                    self.selectedSourceIDs = [first]
                    self.focusedSourceID = OverlaySelection.focused(selected: self.selectedSourceIDs, current: self.focusedSourceID)
                }
                self.loadFocused()
                self.startInspection(context)
            }
        }
        refreshCacheUsage()
    }

    private func startInspection(_ context: ProjectContext) {
        inspectionTask?.cancel()
        inspectionTask = nil
        inspectionID = UUID()
        let requestID = inspectionID
        profileIssues = []
        inspectionCancelled = false

        let capturedSources = sources
        inspectionTotal = capturedSources.count

        if isLazyInspectionEnabled {
            // Lazy inspection mode: Do not bulk inspect or show ongoing progress bar.
            // Rapidly restore pre-indexed entries from SQLite cache off the main thread.
            isLoading = false
            loadingPhase = "Idle"
            inspectedSources = 0

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let indexDB = try? IndexDatabase.open(at: context.indexDatabaseURL)
                let cachedMap = indexDB?.lookupAll() ?? [:]

                var initialStates: [String: GallerySourceState] = [:]
                var cachedCount = 0

                for source in capturedSources {
                    if Task.isCancelled { return }
                    let mtime: Int64 = source.mtime != 0 ? source.mtime : ((try? source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970).map { Int64($0) } ?? 0)
                    if let record = cachedMap[source.id], record.mtime == mtime, record.byteSize == source.byteSize {
                        var state = GallerySourceState()
                        state.inspection = record.asInspection
                        state.error = record.error
                        initialStates[source.id] = state
                        cachedCount += 1
                    } else {
                        initialStates[source.id] = GallerySourceState()
                    }
                }

                let finalStates = initialStates
                let finalCached = cachedCount
                await MainActor.run {
                    guard requestID == self.inspectionID else { return }
                    self.sourceStates = finalStates
                    self.inspections = finalStates.compactMapValues(\.inspection)
                    self.inspectedSources = finalCached
                    self.refreshLoading()
                }
            }
            return
        }

        // Full non-lazy inspection mode:
        isLoading = true
        error = nil
        loadingPhase = "Inspecting"
        inspectedSources = 0

        // Perform fast SQLite Cache Restoration off the MainActor:
        inspectionTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let indexDB = try? IndexDatabase.open(at: context.indexDatabaseURL)
            let cachedMap = indexDB?.lookupAll() ?? [:]

            var uninspected: [RawSource] = []
            var initialStates: [String: GallerySourceState] = [:]
            var cachedCount = 0

            for source in capturedSources {
                if Task.isCancelled { return }
                let mtime: Int64 = source.mtime != 0 ? source.mtime : ((try? source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970).map { Int64($0) } ?? 0)
                if let record = cachedMap[source.id], record.mtime == mtime, record.byteSize == source.byteSize {
                    var state = GallerySourceState()
                    state.inspection = record.asInspection
                    state.error = record.error
                    initialStates[source.id] = state
                    cachedCount += 1
                } else {
                    initialStates[source.id] = GallerySourceState()
                    uninspected.append(source)
                }
            }

            let finalStates = initialStates
            let finalCached = cachedCount
            let finalUninspected = uninspected

            await MainActor.run {
                guard requestID == self.inspectionID else { return }
                self.sourceStates = finalStates
                self.inspections = finalStates.compactMapValues(\.inspection)
                self.inspectedSources = finalCached

                if finalUninspected.isEmpty {
                    self.inspectionTask = nil
                    self.isLoading = false
                    self.loadingPhase = "Idle"
                    self.refreshLoading()
                    return
                }

                self.inspectSources(finalUninspected, project: context, requestID: requestID, baseCompleted: finalCached, indexDB: indexDB)
            }
        }
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
        let indexDB = try? IndexDatabase.open(at: project.indexDatabaseURL)
        inspectSources(pending, project: project, requestID: requestID, baseCompleted: sources.count - pending.count, indexDB: indexDB)
        return true
    }

    private func inspectSources(_ targets: [RawSource], project: ProjectContext, requestID: UUID, baseCompleted: Int, indexDB: IndexDatabase? = nil) {
        inspectionTask = Task {
            let accumulator = InspectionProgressAccumulator()

            let report = await InstrumentReader.inspectMany(targets, project: project, cache: cache,
                onProgress: { results, completed in
                    var dbRecords: [IndexDatabase.Record] = []
                    for result in results {
                        if let inspection = result.inspection {
                            let mtime: Int64 = result.source.mtime != 0 ? result.source.mtime : ((try? result.source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970).map { Int64($0) } ?? 0)
                            dbRecords.append(IndexDatabase.Record(source: result.source, inspection: inspection, mtime: mtime))
                        }
                    }
                    if let indexDB, !dbRecords.isEmpty {
                        try? indexDB.upsertBatch(dbRecords)
                    }
                    let (shouldFlush, toFlush) = await accumulator.record(results: results, totalCompleted: completed, totalTarget: targets.count)
                    if shouldFlush {
                        await MainActor.run {
                            guard requestID == self.inspectionID else { return }
                            for result in toFlush {
                                var state = self.sourceStates[result.id] ?? GallerySourceState()
                                state.inspection = result.inspection
                                state.error = result.error
                                self.sourceStates[result.id] = state
                                if let insp = result.inspection {
                                    self.inspections[result.id] = insp
                                }
                            }
                            self.inspectedSources = baseCompleted + completed
                        }
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
            let remaining = await accumulator.flushRemaining()
            if !remaining.isEmpty {
                await MainActor.run {
                    guard requestID == self.inspectionID else { return }
                    for result in remaining {
                        var state = self.sourceStates[result.id] ?? GallerySourceState()
                        state.inspection = result.inspection
                        state.error = result.error
                        self.sourceStates[result.id] = state
                        if let insp = result.inspection {
                            self.inspections[result.id] = insp
                        }
                    }
                }
            }
            self.profileIssues = report.profileIssues
            self.inspectedSources = self.inspectionTotal
            self.inspectionTask = nil
            self.isLoading = false
            self.loadingPhase = "Idle"
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

private actor InspectionProgressAccumulator {
    private var pendingBuffer: [SourceInspectionResult] = []
    private var lastFlushTime = Date()

    func record(results: [SourceInspectionResult], totalCompleted: Int, totalTarget: Int) -> (shouldFlush: Bool, toFlush: [SourceInspectionResult]) {
        pendingBuffer.append(contentsOf: results)
        let now = Date()
        let shouldFlush = totalCompleted == totalTarget || now.timeIntervalSince(lastFlushTime) >= 1.0
        if shouldFlush {
            let toFlush = pendingBuffer
            pendingBuffer.removeAll(keepingCapacity: true)
            lastFlushTime = now
            return (true, toFlush)
        }
        return (false, [])
    }

    func flushRemaining() -> [SourceInspectionResult] {
        let remaining = pendingBuffer
        pendingBuffer.removeAll()
        return remaining
    }
}

struct GallerySourceState {
    var inspection: SourceInspection?
    var measurement: NormalizedMeasurement?
    var error: String?
    var isLoading = false
}

struct RawViewShell: View {
    @ObservedObject var model: RawViewModel

    var body: some View {
        HSplitView {
            sidebarPane
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                .frame(maxHeight: .infinity)
            ProjectGallery(sources: model.sources, states: model.sourceStates,
                           focusedSourceID: $model.focusedSourceID,
                           selectedIDs: model.selectedSourceIDs, hidden: model.hiddenSeries,
                           lineWidth: model.lineWidth,
                           renderStyle: model.renderStyle,
                           markType: model.markType,
                           interpolation: model.interpolation,
                           markerSize: model.markerSize,
                           colorBySweepProgress: model.colorBySweepProgress,
                           overlay: model.overlayResult(),
                           tab: $model.tab,
                           xAbsolute: $model.xAbsolute, yAbsolute: $model.yAbsolute,
                           xScale: $model.xScale, yScale: $model.yScale,
                           showInspector: $model.showInspector,
                           isLoading: model.isPlotLoading,
                           loadingStatus: model.isPlotLoading ? (model.isOverlayLoading ? "Loading comparison…" : "Loading plot…") : nil,
                           retry: model.loadFocused,
                           snapshots: model.snapshots,
                           activeSnapshotID: model.activeSnapshotID,
                           onSaveSnapshot: { model.saveSnapshot() },
                           onSelectSnapshot: { model.loadSnapshot($0) },
                           onToggleSnapshot: { model.toggleSnapshot($0) },
                           onDeleteSnapshot: { model.deleteSnapshot($0) },
                           comparisonTitle: model.comparisonTitle,
                           showLegend: $model.showLegend,
                           customSeriesLabels: model.customSeriesLabels,
                           legendOffset: $model.legendOffset)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            if model.showInspector {
                inspector
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 450)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 880, minHeight: 560)
        .overlay(alignment: .top) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .padding(10).frame(maxWidth: .infinity).background(.regularMaterial)
                    .foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onChange(of: model.focusedSourceID) { _, _ in model.loadFocused() }
        .onChange(of: model.selectedSourceIDs) { _, new in model.updateSelection(new) }
    }

    private var sidebarPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("PROJECT SOURCES")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: model.openProject) { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("Open project")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()

            if let project = model.project {
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.root.lastPathComponent).font(.caption).bold().foregroundStyle(.primary).lineLimit(1)
                    if model.isInspecting {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(model.inspectedSources), total: Double(max(1, model.inspectionTotal))) {
                                HStack {
                                    Text("Inspecting \(model.inspectedSources) of \(model.inspectionTotal) sources")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Cancel", action: model.cancelLoad)
                                        .buttonStyle(.plain)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } else if model.isLoading && model.loadingPhase == "Discovering" {
                        ProgressView {
                            Text("Discovering sources under data/raw…")
                                .font(.system(size: 11))
                        }
                        Button("Cancel Discovery", action: model.cancelLoad).buttonStyle(.bordered)
                    } else if model.inspectionCancelled {
                        let remaining = model.unindexedCount
                        if remaining > 0 {
                            Text("Inspection cancelled · \(remaining) remaining")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Resume Inspection", action: { _ = model.resumeInspection() }).buttonStyle(.bordered)
                        }
                    } else if !model.isLazyInspectionEnabled {
                        let remaining = model.unindexedCount
                        if remaining > 0, !model.isInspecting {
                            HStack {
                                Text("\(remaining) unindexed")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Index All") {
                                    _ = model.resumeInspection()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 8)

                ProjectSourcesSidebar(sources: model.sources,
                    inspections: model.inspections,
                    states: model.sourceStates, focusedSourceID: $model.focusedSourceID,
                    selectedSourceIDs: $model.selectedSourceIDs)
                if !model.profileIssues.isEmpty {
                    profileIssueList
                        .padding(.horizontal, 12)
                }
                Text("RawView's built-in readers parse sources. Raw files and instrument profiles are never modified.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding([.bottom, .horizontal], 12)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    ContentUnavailableView("No Project", systemImage: "folder", description: Text("Open the research project that owns the raw files."))
                    Button("Open Project…", action: model.openProject)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var profileIssueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.profileIssues.isEmpty {
                Text("PROFILE ISSUES").font(.caption2.bold()).foregroundStyle(.orange)
                ForEach(Array(model.profileIssues.enumerated()), id: \.offset) { _, issue in
                    Text(issue).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
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
                             renderStyle: $model.renderStyle,
                             markType: $model.markType,
                             interpolation: $model.interpolation,
                             markerSize: $model.markerSize,
                             colorBySweepProgress: $model.colorBySweepProgress,
                             xAbsolute: $model.xAbsolute, yAbsolute: $model.yAbsolute,
                             xScale: $model.xScale, yScale: $model.yScale,
                             overlay: model.overlayResult(),
                             onRetry: model.loadFocused,
                             cacheStatus: cacheStatus,
                             onClearCache: { model.clearCacheFiles(); model.loadFocused() },
                             onLimitChange: { model.cacheLimitBytes = $0 },
                             showLegend: $model.showLegend,
                             customSeriesLabels: $model.customSeriesLabels,
                             legendOffset: $model.legendOffset,
                             comparisonTitle: $model.comparisonTitle,
                             onSaveSnapshot: { model.saveSnapshot() },
                             activeSnapshotID: model.activeSnapshotID,
                             onSelectGenericColumns: { x, y in
                                 if let id = model.focusedSourceID {
                                     model.updateGenericColumnMapping(sourceID: id, xCol: x, yCol: y)
                                 }
                             },
                             onExportFigure: { model.exportCurrentFigure() },
                             onExportData: { model.exportCurrentData() })
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
    var renderStyle: PlotRenderStyle = .line
    var markType: PlotMarkType = .line
    var interpolation: PlotInterpolation = .linear
    var markerSize: Double = 4.5
    var colorBySweepProgress: Bool = false
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
            let f = Font.custom(NativePlotStyle.fontFamily, size: size)
            return bold ? f.bold() : f
        } else {
            return bold ? Font.system(size: size, weight: .bold) : Font.system(size: size)
        }
    }

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
        let headerFontScale = PlotRenderingEngine.fontScale(plotWidth: 500, uiFontSize: uiFontSize)
        let defaultTitle = measurement.instrument.name + (measurement.applicationMode.map { " · \($0)" } ?? "")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(defaultTitle)
                    .font(plotFont(size: 14.0 * headerFontScale, bold: true))
                    .lineLimit(1).truncationMode(.middle)
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
                if case .message(let message) = failure { ContentUnavailableView("Invalid Plot Domain", systemImage: "chart.xyaxis.line", description: Text(message)) }
            case .success(let data):
                ZStack(alignment: .topTrailing) {
                    Canvas { context, size in draw(data, in: &context, size: size) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .simultaneousGesture(DragGesture().onChanged { pan = CGSize(width: dragStart.width + $0.translation.width, height: dragStart.height + $0.translation.height) }.onEnded { _ in dragStart = pan })
                        .simultaneousGesture(MagnifyGesture().onChanged { zoom = min(max(gestureZoomStart * $0.magnification, 0.5), 12) }.onEnded { _ in gestureZoomStart = zoom })

                    if colorBySweepProgress {
                        SweepColorbarView()
                            .padding(.leading, 64)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    if showLegend {
                        let legendItems: [(color: Color, label: String)] = data.1.enumerated().map { index, item in
                            let custom = customSeriesLabels[item.0]?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let name = (custom != nil && !custom!.isEmpty) ? custom! : item.0
                            return (palette(index), name)
                        }
                        DraggableLegendView(items: legendItems, offset: $legendOffset)
                            .padding(.trailing, 28)
                            .padding(.top, 24)
                    }
                }
                HStack(spacing: 14) {
                    Spacer()
                    Text("Drag to pan · Pinch to zoom · \(data.0.count) rows")
                        .font(plotFont(size: 10.5 * headerFontScale)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func draw(_ data: ([Double?], [(String, [Double?])]), in context: inout GraphicsContext, size: CGSize) {
        let finiteX = data.0.compactMap { $0 }
        let finiteY = data.1.flatMap { $0.1.compactMap { $0 } }
        guard !finiteX.isEmpty, !finiteY.isEmpty else { return }

        let xChannel = measurement.channel(named: measurement.view.x ?? "")
        let yChannel = measurement.view.y?.first.flatMap(measurement.channel(named:))

        let xScaleInfo = AxisFormatter.scaleInfo(for: finiteX, baseUnit: xChannel?.unit ?? "")
        let yScaleInfo = AxisFormatter.scaleInfo(for: finiteY, baseUnit: yChannel?.unit ?? "")

        let yRangeTemp = viewport(expanded(finiteY), pan: pan.height, dimension: size.height, vertical: true)
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
        let xRange = viewport(expanded(finiteX), pan: pan.width, dimension: plot.width, vertical: false)
        let yRange = viewport(expanded(finiteY), pan: pan.height, dimension: plot.height, vertical: true)
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
        let xTitle = axisTitle(xChannel?.label ?? "X", unit: xScaleInfo.displayUnit, absolute: xAbsolute, scale: xScale)
        let yTitle = axisTitle(yChannel?.label ?? "Y", unit: yScaleInfo.displayUnit, absolute: yAbsolute, scale: yScale)

        // Axis titles: regular weight (not bold), matching standard scientific publishing
        context.draw(Text(xTitle).font(plotFont(size: 12.5 * fontScale, bold: false)), at: CGPoint(x: plot.midX, y: plot.maxY + tickLen + 3.0 + (11.5 * fontScale) + 6.0), anchor: .top)
        let yTitleX = max(14 * fontScale, plot.minX - tickLen - 3.0 - maxLabelWidth - (12 * fontScale))
        var yLabelContext = context
        yLabelContext.translateBy(x: yTitleX, y: plot.midY)
        yLabelContext.rotate(by: .degrees(-90))
        yLabelContext.draw(Text(yTitle).font(plotFont(size: 12.5 * fontScale, bold: false)), at: .zero, anchor: .center)

        var plotContext = context
        plotContext.clip(to: Path(plot))
        for (seriesIndex, item) in data.1.enumerated() {
            guard item.1.count == data.0.count else { continue }
            let color = palette(seriesIndex)
            // Gap segmentation: a nil x or y breaks the line; rows stay in order.
            for run in AxisTransform.segments(x: data.0, y: item.1) {
                var runPoints: [CGPoint] = []
                for index in run {
                    guard let xv = data.0[index], let yv = item.1[index] else { continue }
                    let tx = (xv - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
                    let ty = (yv - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
                    runPoints.append(CGPoint(x: plot.minX + tx * plot.width, y: plot.maxY - ty * plot.height))
                }
                PlotRenderingEngine.renderRun(
                    points: runPoints,
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
    private func axisLabel(_ value: Double, scale: AxisScale, scaleInfo: AxisFormatter.ScaleInfo) -> String {
        scale == .logarithmic ? "10^\(AxisFormatter.formatTick(value, factor: 1.0))" : AxisFormatter.formatTick(value, factor: scaleInfo.factor)
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
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var allRows: [Int] { Array(0..<(measurement.channels.first?.values.count ?? 0)) }

    private var filteredRows: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allRows }
        return allRows.filter { rowIndex in
            if String(rowIndex).contains(query) { return true }
            for channel in measurement.channels {
                if channel.text(at: rowIndex).lowercased().contains(query) {
                    return true
                }
            }
            return false
        }
    }

    var body: some View {
        if measurement.channels.isEmpty {
            ContentUnavailableView("Metadata Only", systemImage: "tablecells", description: Text("This source has no normalized numeric channels."))
        } else {
            VStack(spacing: 0) {
                searchBar
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        rowHeader
                        ForEach(filteredRows, id: \.self) { index in
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
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search data (⌘F)…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !searchText.isEmpty {
                Text("\(filteredRows.count) of \(allRows.count) rows")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("\(allRows.count) rows")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
        .overlay {
            Button("") {
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
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
    var cacheStatus: CacheStatus? = nil
    var onClearCache: (() -> Void)? = nil
    var onLimitChange: ((Int64) -> Void)? = nil
    @Binding var showLegend: Bool
    @Binding var customSeriesLabels: [String: String]
    @Binding var legendOffset: CGSize
    @Binding var comparisonTitle: String
    var onSaveSnapshot: (() -> Void)? = nil
    var activeSnapshotID: UUID? = nil
    var onSelectGenericColumns: ((Int, Int) -> Void)? = nil
    var onExportFigure: (() -> Void)? = nil
    var onExportData: (() -> Void)? = nil

    @State private var isSeriesExpanded = true
    @State private var isDataMappingExpanded = true
    @State private var isStyleExpanded = true
    @State private var isAxesExpanded = false
    @State private var isMetadataExpanded = false
    @State private var isExportExpanded = true
    @State private var isCacheExpanded = false

    struct CacheStatus {
        var usedBytes: Int64
        var entryCount: Int
        var limitBytes: Int64
    }

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
                        if cacheStatus != nil, onClearCache != nil {
                            cacheSection
                        }
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
                        exportSection
                        cacheSection
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

    private var exportSection: some View {
        DisclosureGroup(isExpanded: $isExportExpanded) {
            VStack(spacing: 8) {
                Button(action: { onExportFigure?() }) {
                    Label("Export Figure (PNG / PDF)…", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { onExportData?() }) {
                    Label("Export Clean Data (CSV)…", systemImage: "tablecells")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        } label: {
            Text("EXPORT")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    private var axesSection: some View {
        DisclosureGroup(isExpanded: $isAxesExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                axisControl("X", absolute: $xAbsolute, scale: $xScale)
                axisControl("Y", absolute: $yAbsolute, scale: $yScale)
                Text("Absolute applies before the scale; log needs positive values.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } label: {
            Text("AXES")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary.opacity(0.85))
        }
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

    private var cacheSection: some View {
        DisclosureGroup(isExpanded: $isCacheExpanded) {
            VStack(alignment: .leading, spacing: 8) {
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
                    Text("Verified entries stay in a private app-local cache; RawView ignores project-controlled cache files.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("No project open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("CACHE & STORAGE")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary.opacity(0.85))
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
