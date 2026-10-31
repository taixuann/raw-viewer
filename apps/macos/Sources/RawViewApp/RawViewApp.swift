import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RawViewCore

@main
struct RawViewApp: App {
    @StateObject private var model = RawViewModel()
    @AppStorage("appTheme") private var appTheme: String = "System"
    @NSApplicationDelegateAdaptor(RawViewAppDelegate.self) private var appDelegate

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
                .task {
                    _ = await NodeBackend.shared.ensureRunning()
                    await AIProviderCatalog.shared.refresh()
                }
        }
        .defaultSize(width: 1320, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            ExplorerToolbarCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(preferredScheme)
        }
    }
}

final class RawViewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
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
    /// Task 7: session axis overrides captured with the snapshot so a
    /// restored comparison replots the effective selection.
    var axisOverrides: [String: AxisOverride] = [:]

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
    @Published var recentProjects: [URL] = []
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
    /// Project-scoped Developer Mode (Task 6): read from the active
    /// project's setting.yaml, never from a global default. Older settings
    /// default to false.
    @Published var developerMode: Bool = false

    /// Project-scoped toggle with rollback: the visible state reverts when
    /// the settings write fails, and every other setting is preserved.
    func setDeveloperMode(_ enabled: Bool) {
        guard let project else { return }
        let previous = developerMode
        developerMode = enabled
        do {
            let current = try ProjectSettingsStore.load(projectRoot: project.root)
            let updated = ProjectSettings(
                dataRoot: current?.dataRoot ?? project.dataRootRelativePath,
                defaultView: current?.defaultView ?? "tree",
                defaultPreset: current?.defaultPreset ?? selectedPreset.id,
                developerMode: enabled,
                explorerViews: current?.explorerViews ?? [],
                sourceLabels: current?.sourceLabels ?? [])
            try ProjectSettingsStore.save(updated, projectRoot: project.root)
        } catch {
            developerMode = previous
            self.error = "Failed to save Developer Mode: \(error.localizedDescription)"
        }
    }
    @Published var showAIAssistant = false
    @Published var aiChatSessionId: UUID = UUID()
    @Published var aiChatTurns: [ChatTurn] = []
    func toggleAIAssistant() { showAIAssistant.toggle() }
    @Published var showInspector = true
    func toggleInspector() { showInspector.toggle() }

    // MARK: - Task 7: session axis overrides (display-only, never profile writes).

    /// Per-source axis override, keyed by the loaded measurement's
    /// profile/variant provenance plus stable column IDs. A nil x/y keeps
    /// the variant default. Session-only: cleared on project change.
    @Published var axisOverrides: [String: AxisOverride] = [:]

    /// Measurement with the session override applied when its provenance
    /// still matches; otherwise the variant defaults. New sources have no
    /// override and use their own defaults.
    func effectiveMeasurement(for id: String) -> NormalizedMeasurement? {
        guard let base = sourceStates[id]?.measurement else { return nil }
        guard let override = axisOverrides[id],
              override.profileID == base.provenance["profile_id"],
              override.variantID == base.provenance["variant_id"] else { return base }
        return base.withAxisView(x: override.x, y: override.y)
    }

    /// Override IDs no longer declared for this source. Kept (never
    /// substituted); the inspector requires an explicit reset.
    func staleAxisIDs(for id: String) -> [String] {
        guard let base = sourceStates[id]?.measurement, let override = axisOverrides[id],
              override.profileID == base.provenance["profile_id"],
              override.variantID == base.provenance["variant_id"] else { return [] }
        let names = Set(base.channels.map(\.name))
        var stale: [String] = []
        if let x = override.x, !names.contains(x) { stale.append(x) }
        for y in override.y ?? [] where !names.contains(y) { stale.append(y) }
        return stale
    }

    func axisNote(for id: String) -> String? {
        let stale = staleAxisIDs(for: id)
        guard !stale.isEmpty else { return nil }
        return "Axis selection \(stale.joined(separator: ", ")) is not declared for this source. Reset to the variant defaults to continue."
    }

    func setAxisX(_ x: String, for id: String) {
        guard let base = sourceStates[id]?.measurement else { return }
        var override = activeOverride(for: base, id: id)
        override.x = x
        axisOverrides[id] = override
    }

    /// A nil y restores the Default series (variant multi-Y defaults).
    func setAxisY(_ y: [String]?, for id: String) {
        guard let base = sourceStates[id]?.measurement else { return }
        var override = activeOverride(for: base, id: id)
        override.y = y
        axisOverrides[id] = override
    }

    /// Reset restores the selected variant defaults for this source.
    func resetAxes(for id: String) { axisOverrides.removeValue(forKey: id) }

    /// The session override currently in effect for this source, or nil when
    /// none exists or its provenance no longer matches the loaded variant.
    func activeAxisOverride(for id: String) -> AxisOverride? {
        guard let base = sourceStates[id]?.measurement, let override = axisOverrides[id],
              override.profileID == base.provenance["profile_id"],
              override.variantID == base.provenance["variant_id"] else { return nil }
        return override
    }

    private func activeOverride(for base: NormalizedMeasurement, id: String) -> AxisOverride {
        var override = axisOverrides[id]
        // A re-resolved variant retires the old selection instead of
        // misapplying its column IDs.
        if override?.profileID != base.provenance["profile_id"] || override?.variantID != base.provenance["variant_id"] {
            override = nil
        }
        return override ?? AxisOverride(
            profileID: base.provenance["profile_id"] ?? "",
            variantID: base.provenance["variant_id"] ?? "",
            x: nil, y: nil)
    }

    /// Display states with effective measurements. Loading and error state
    /// pass through untouched.
    var displayStates: [String: GallerySourceState] {
        var out = sourceStates
        for id in out.keys where out[id]?.measurement != nil {
            out[id]?.measurement = effectiveMeasurement(for: id)
        }
        return out
    }

    // MARK: - Task 7: grammar-driven Explorer views (settings-owned references).

    /// Discriminated selection identity: "tree", "" (None), or a qualified
    /// grammar-variable reference. Never a bare variable name.
    @Published var selectedExplorerView = "tree"
    @Published var explorerViews: [ExplorerViewDefinition] = []
    @Published var explorerCatalog: FilenameGrammarCatalog? = nil
    @Published var explorerViewError: String? = nil
    @Published var sourceLabelLayouts: [SourceLabelLayout] = []

    static func explorerViewKey(grammarID: String, variable: String) -> String {
        "view\0\(grammarID)\0\(variable)"
    }

    static func explorerViewReference(forKey key: String) -> ExplorerViewDefinition? {
        guard key.hasPrefix("view\0") else { return nil }
        let parts = key.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return ExplorerViewDefinition(grammarID: parts[1], variable: parts[2])
    }

    /// Reloads view references and the grammar catalog after project open and
    /// after every view save. An unresolvable selection returns to Tree with
    /// a visible explanation; the menu otherwise stays intact.
    func refreshExplorerViews() {
        guard let project else {
            explorerViews = []
            explorerCatalog = nil
            explorerViewError = nil
            sourceLabelLayouts = []
            return
        }
        let saved = try? ProjectSettingsStore.load(projectRoot: project.root)
        explorerViews = saved?.explorerViews ?? []
        sourceLabelLayouts = saved?.sourceLabels ?? []
        do {
            explorerCatalog = try FilenameGrammarEngine.load(project: project)
            if explorerViewError?.hasPrefix("Filename grammar") == true { explorerViewError = nil }
        } catch {
            explorerCatalog = nil
            explorerViewError = "Filename grammar unavailable (\(error.localizedDescription)). Explorer views are unavailable; Tree remains."
            selectedExplorerView = "tree"
            return
        }
        validateExplorerSelection()
    }

    /// Adds one grammar-variable view reference. Settings save first; the
    /// visible menu only changes on success. Grammar saves never touch this.
    func addExplorerView(grammarID: String, variable: String) {
        guard let project else { return }
        let ref = ExplorerViewDefinition(grammarID: grammarID, variable: variable)
        do {
            let current = try ProjectSettingsStore.load(projectRoot: project.root)
            var views = current?.explorerViews ?? []
            guard !views.contains(ref) else { return }
            views.append(ref)
            try ProjectSettingsStore.save(ProjectSettings(
                dataRoot: current?.dataRoot ?? project.dataRootRelativePath,
                defaultView: current?.defaultView ?? "tree",
                defaultPreset: current?.defaultPreset ?? selectedPreset.id,
                developerMode: current?.developerMode ?? developerMode,
                explorerViews: views,
                sourceLabels: current?.sourceLabels ?? []), projectRoot: project.root)
            explorerViews = views
            selectedExplorerView = Self.explorerViewKey(grammarID: grammarID, variable: variable)
            validateExplorerSelection()
        } catch {
            self.error = "Failed to save Explorer view: \(error.localizedDescription)"
        }
    }

    func removeExplorerView(_ ref: ExplorerViewDefinition) {
        guard let project else { return }
        do {
            let current = try ProjectSettingsStore.load(projectRoot: project.root)
            let views = (current?.explorerViews ?? []).filter { $0 != ref }
            try ProjectSettingsStore.save(ProjectSettings(
                dataRoot: current?.dataRoot ?? project.dataRootRelativePath,
                defaultView: current?.defaultView ?? "tree",
                defaultPreset: current?.defaultPreset ?? selectedPreset.id,
                developerMode: current?.developerMode ?? developerMode,
                explorerViews: views,
                sourceLabels: current?.sourceLabels ?? []), projectRoot: project.root)
            explorerViews = views
            if Self.explorerViewReference(forKey: selectedExplorerView) == ref {
                selectedExplorerView = "tree"
            }
            validateExplorerSelection()
        } catch {
            self.error = "Failed to remove Explorer view: \(error.localizedDescription)"
        }
    }

    /// Saves source-label layouts. Settings write first; the visible
    /// configuration only changes on success. Returns nil on success, or
    /// the failure message so the customizer can report it without
    /// claiming a save.
    func saveSourceLabels(_ layouts: [SourceLabelLayout]) -> String? {
        guard let project else { return "No project is open." }
        do {
            let current = try ProjectSettingsStore.load(projectRoot: project.root)
            try ProjectSettingsStore.save(ProjectSettings(
                dataRoot: current?.dataRoot ?? project.dataRootRelativePath,
                defaultView: current?.defaultView ?? "tree",
                defaultPreset: current?.defaultPreset ?? selectedPreset.id,
                developerMode: current?.developerMode ?? developerMode,
                explorerViews: current?.explorerViews ?? [],
                sourceLabels: layouts), projectRoot: project.root)
            sourceLabelLayouts = layouts
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func validateExplorerSelection() {
        guard let ref = Self.explorerViewReference(forKey: selectedExplorerView) else { return }
        guard explorerViews.contains(ref),
              let grammar = explorerCatalog?.grammars.first(where: { $0.id == ref.grammarID }),
              grammar.fields.contains(where: { $0.name == ref.variable }) else {
            selectedExplorerView = "tree"
            explorerViewError = "Explorer view “\(ref.variable)” is unavailable (renamed or deleted grammar reference). Returned to Tree."
            return
        }
        if explorerViewError?.hasPrefix("Explorer view") == true { explorerViewError = nil }
    }
    @Published var showLegend = true
    @Published var customSeriesLabels: [String: String] = [:]
    @Published var legendOffset: CGSize = .zero

    @Published var availablePresets: [ScientificPreset] = ScientificPreset.allCases
    @Published var selectedPreset: ScientificPreset = .natureSingle
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
        var snap = PlotSnapshot(
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
        snap.axisOverrides = axisOverrides
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
        axisOverrides = snap.axisOverrides
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

        let exportSize = CGSize(width: 800, height: 800 / selectedPreset.aspectRatio)
        if selectedSourceIDs.count >= 2 {
            let cohort = selectedSourceIDs.sorted().compactMap { effectiveMeasurement(for: $0) }
            let visible = cohort.filter { !hiddenSeries.contains($0.source.path) }
            let exportView = OverlayPlot(
                measurements: visible,
                selectedSourceIDs: selectedSourceIDs,
                focused: focusedSourceID.flatMap { effectiveMeasurement(for: $0) },
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
                preset: selectedPreset,
                showLegend: showLegend,
                customSeriesLabels: customSeriesLabels,
                legendOffset: .constant(.zero)
            )
            FigureExporter.promptExportFigure(view: exportView, defaultName: name, size: exportSize)
        } else if let focused = focusedSourceID, let measurement = effectiveMeasurement(for: focused) {
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
                preset: selectedPreset,
                showLegend: showLegend,
                customSeriesLabels: customSeriesLabels,
                legendOffset: .constant(.zero)
            )
            FigureExporter.promptExportFigure(view: exportView, defaultName: name, size: exportSize)
        }
    }

    func exportCurrentData() {
        let name: String
        if let focused = focusedSourceID {
            name = URL(fileURLWithPath: focused).deletingPathExtension().lastPathComponent + ".csv"
        } else {
            name = "data_export.csv"
        }
        let measurement = focusedSourceID.flatMap { effectiveMeasurement(for: $0) }
        FigureExporter.promptExportData(measurement: measurement, defaultName: name)
    }

    struct ProjectSnapshotPackage: Identifiable, Sendable {
        let id: String
        let name: String
        let sources: [String]
        let directoryURL: URL
    }
    @Published var projectSnapshotPackages: [ProjectSnapshotPackage] = []

    func saveSnapshotPackage() {
        guard let project = project else { return }
        let defaultName: String
        let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        if selectedSourceIDs.count >= 2 {
            defaultName = "overlay_\(selectedSourceIDs.count)_\(timeStr)"
        } else if let focused = focusedSourceID {
            let base = URL(fileURLWithPath: focused).deletingPathExtension().lastPathComponent
            defaultName = "\(base)_\(timeStr)"
        } else {
            defaultName = "snapshot_\(timeStr)"
        }

        let alert = NSAlert()
        alert.messageText = "Save Snapshot Package"
        alert.informativeText = "Saves list.yaml, high-resolution PNG (300 DPI Retina), and vector PDF to data/snapshot/<name>/"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = defaultName
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let cleanName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !cleanName.isEmpty else { return }

        do {
            let exportSize = CGSize(width: 800, height: 800 / selectedPreset.aspectRatio)
            if selectedSourceIDs.count >= 2 {
                let cohort = selectedSourceIDs.sorted().compactMap { effectiveMeasurement(for: $0) }
                let visible = cohort.filter { !hiddenSeries.contains($0.source.path) }
                let exportView = OverlayPlot(
                    measurements: visible,
                    selectedSourceIDs: selectedSourceIDs,
                    focused: focusedSourceID.flatMap { effectiveMeasurement(for: $0) },
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
                    preset: selectedPreset,
                    showLegend: showLegend,
                    customSeriesLabels: customSeriesLabels,
                    legendOffset: .constant(.zero)
                )
                let savedDir = try FigureExporter.exportSnapshotPackage(
                    projectRoot: project.root,
                    packageName: cleanName,
                    sourcePaths: visible.map(\.source.path),
                    view: exportView,
                    size: exportSize
                )
                refreshProjectSnapshotPackages()
                NSWorkspace.shared.activateFileViewerSelecting([savedDir])
            } else if let focused = focusedSourceID, let measurement = effectiveMeasurement(for: focused) {
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
                    preset: selectedPreset,
                    showLegend: showLegend,
                    customSeriesLabels: customSeriesLabels,
                    legendOffset: .constant(.zero)
                )
                let savedDir = try FigureExporter.exportSnapshotPackage(
                    projectRoot: project.root,
                    packageName: cleanName,
                    sourcePaths: [measurement.source.path],
                    view: exportView,
                    size: exportSize
                )
                refreshProjectSnapshotPackages()
                NSWorkspace.shared.activateFileViewerSelecting([savedDir])
            }
        } catch {
            self.error = "Failed to save snapshot package: \(error.localizedDescription)"
        }
    }

    func refreshProjectSnapshotPackages() {
        guard let project = project else {
            projectSnapshotPackages = []
            return
        }
        let snapshotsRoot = project.root.appendingPathComponent("data/snapshot")
        guard let items = try? FileManager.default.contentsOfDirectory(at: snapshotsRoot, includingPropertiesForKeys: nil) else {
            projectSnapshotPackages = []
            return
        }
        var packages: [ProjectSnapshotPackage] = []
        for item in items where item.hasDirectoryPath {
            let listYAML = item.appendingPathComponent("list.yaml")
            guard let content = try? String(contentsOf: listYAML, encoding: .utf8) else { continue }
            var sources: [String] = []
            var inSources = false
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.starts(with: "sources:") {
                    inSources = true
                    continue
                }
                if inSources {
                    if trimmed.starts(with: "- ") {
                        let path = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        if !path.isEmpty { sources.append(path) }
                    } else if !trimmed.isEmpty && !trimmed.starts(with: "#") {
                        inSources = false
                    }
                }
            }
            let name = item.lastPathComponent
            packages.append(ProjectSnapshotPackage(id: name, name: name, sources: sources, directoryURL: item))
        }
        projectSnapshotPackages = packages.sorted(by: { $0.name < $1.name })
    }

    func loadSnapshotPackage(_ pkg: ProjectSnapshotPackage) {
        let matchingIDs = pkg.sources.compactMap { relPath in
            sources.first(where: { $0.relativePath == relPath || $0.id == relPath || $0.url.path.hasSuffix(relPath) })?.id
        }
        if !matchingIDs.isEmpty {
            updateSelection(Set(matchingIDs))
            comparisonTitle = pkg.name
            ensureSelectedLoaded()
        }
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
    @Published var inventory: SourceInventory?
    @Published var inventoryIssues: [InventoryIssue] = []
    @Published var sourceTree: SourceTree?
    @Published var expandedDirectoryIDs: Set<String> = []
    @Published var activeNavigationMode: String = "tree"
    @Published var sessionState = ProjectSessionState()
    @Published var isProjectSetupPresented: Bool = false
    @Published var pendingSetupProjectURL: URL?
    @Published var pendingSetupDiagnostic: String?

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
        return DatabaseStats(
            path: dbURL.path,
            fileSizeBytes: size,
            indexedCount: inspectedSources,
            totalSources: sources.count
        )
    }

    func reindexAllSources() {
        guard let project else { return }
        inspectionTask?.cancel()
        inspectionTask = nil

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

        inspectSources(sources, project: project, requestID: requestID, baseCompleted: 0, rebuild: true)
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
        if let savedRecent = UserDefaults.standard.stringArray(forKey: "rawView.recentProjects.v1") {
            recentProjects = savedRecent.compactMap { URL(fileURLWithPath: $0) }
        }
        if let firstArg = CommandLine.arguments.dropFirst().first(where: { !$0.starts(with: "-") }),
           FileManager.default.fileExists(atPath: firstArg) {
            let argURL = URL(fileURLWithPath: firstArg)
            openRecentProject(url: argURL)
        } else if let firstRecent = recentProjects.first, FileManager.default.fileExists(atPath: firstRecent.path) {
            openRecentProject(url: firstRecent)
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Research Project"
        panel.message = "Choose the project folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            if let settings = try ProjectSettingsStore.load(projectRoot: url) {
                let openedProject = try ProjectContext.open(url, dataRootRelativePath: settings.dataRoot)
                _ = url.startAccessingSecurityScopedResource()
                activeScopeURL?.stopAccessingSecurityScopedResource()
                activeScopeURL = url
                install(openedProject)
                return
            }
        } catch {
            pendingSetupProjectURL = url
            pendingSetupDiagnostic = "Existing settings are invalid: \(error.localizedDescription)"
            isProjectSetupPresented = true
            return
        }

        pendingSetupProjectURL = url
        pendingSetupDiagnostic = nil
        isProjectSetupPresented = true
    }

    func recordRecentProject(url: URL) {
        var list = recentProjects.filter { $0.path != url.path }
        list.insert(url, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        recentProjects = list
        UserDefaults.standard.set(list.map { $0.path }, forKey: "rawView.recentProjects.v1")
    }

    func clearRecentProjects() {
        recentProjects.removeAll()
        UserDefaults.standard.removeObject(forKey: "rawView.recentProjects.v1")
    }

    func openRecentProject(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            recentProjects.removeAll { $0.path == url.path }
            UserDefaults.standard.set(recentProjects.map { $0.path }, forKey: "rawView.recentProjects.v1")
            error = "Project folder not found: \(url.path)"
            return
        }
        do {
            if let settings = try ProjectSettingsStore.load(projectRoot: url) {
                let openedProject = try ProjectContext.open(url, dataRootRelativePath: settings.dataRoot)
                _ = url.startAccessingSecurityScopedResource()
                activeScopeURL?.stopAccessingSecurityScopedResource()
                activeScopeURL = url
                install(openedProject)
                return
            }
        } catch {
            pendingSetupProjectURL = url
            pendingSetupDiagnostic = "Existing settings are invalid: \(error.localizedDescription)"
            isProjectSetupPresented = true
            return
        }
        pendingSetupProjectURL = url
        pendingSetupDiagnostic = nil
        isProjectSetupPresented = true
    }

    func configureProject(root: URL, dataRoot: String, persist: Bool) async throws {
        cancelLoad()
        let token = sessionState.beginRootChange()
        if persist {
            // Read-modify-write: a configure preserves Developer Mode,
            // Explorer views and the preset instead of resetting them.
            let current = try? ProjectSettingsStore.load(projectRoot: root)
            let settings = ProjectSettings(
                dataRoot: dataRoot, defaultView: current?.defaultView ?? "tree",
                defaultPreset: current?.defaultPreset ?? selectedPreset.id,
                developerMode: current?.developerMode ?? false,
                explorerViews: current?.explorerViews ?? [],
                sourceLabels: current?.sourceLabels ?? [])
            try ProjectSettingsStore.save(settings, projectRoot: root)
        }
        let opened = try ProjectContext.open(root, dataRootRelativePath: dataRoot)
        guard sessionState.accepts(generation: token) else { return }
        _ = root.startAccessingSecurityScopedResource()
        activeScopeURL?.stopAccessingSecurityScopedResource()
        activeScopeURL = root
        install(opened)
    }

    func changeDataRoot(to relativePath: String, persist: Bool) async throws {
        guard let currentProj = project else { return }
        cancelLoad()
        let token = sessionState.beginRootChange()
        if persist {
            // Read-modify-write: only the root moves; Developer Mode,
            // Explorer views and the preset survive the change.
            let current = try? ProjectSettingsStore.load(projectRoot: currentProj.root)
            let settings = ProjectSettings(
                dataRoot: relativePath, defaultView: current?.defaultView ?? "tree",
                defaultPreset: current?.defaultPreset ?? selectedPreset.id,
                developerMode: current?.developerMode ?? developerMode,
                explorerViews: current?.explorerViews ?? [],
                sourceLabels: current?.sourceLabels ?? [])
            try ProjectSettingsStore.save(settings, projectRoot: currentProj.root)
        }
        let updated = try ProjectContext.open(currentProj.root, dataRootRelativePath: relativePath)
        guard sessionState.accepts(generation: token) else { return }
        install(updated)
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
        let measurements = ids.compactMap { effectiveMeasurement(for: $0) }
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
                            Task.detached(priority: .utility) {
                                if let store = try? await ProjectIndexStore.open(project: project) {
                                    try? await store.withWriterJob {
                                        try? await store.record(result, source: source, project: project)
                                    }
                                }
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
        _ = sessionState.beginRootChange()
        recordRecentProject(url: context.root)
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
        inventory = nil
        inventoryIssues = []
        sourceTree = nil
        expandedDirectoryIDs.removeAll()
        inspectionCancelled = false
        axisOverrides = [:]
        selectedExplorerView = "tree"
        explorerViewError = nil
        rebuildCache()
        let loadedPresets = PresetCatalog.load(project: context)
        availablePresets = loadedPresets
        if let settings = try? ProjectSettingsStore.load(projectRoot: context.root) {
            developerMode = settings.developerMode
            if let matched = loadedPresets.first(where: { $0.id == settings.defaultPreset }) {
                selectedPreset = matched
            } else if let defaultNature = loadedPresets.first(where: { $0.id == "nature-single" }) {
                selectedPreset = defaultNature
            }
        } else {
            developerMode = false
            if let defaultNature = loadedPresets.first(where: { $0.id == "nature-single" }) {
                selectedPreset = defaultNature
            }
        }
        refreshExplorerViews()
        refreshProjectSnapshotPackages()
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
            let inv: SourceInventory
            do {
                inv = try await context.discoverInventoryAsync()
            } catch is CancellationError {
                return
            } catch {
                guard requestID == self.activeLoadID, await self.discoveryGate.isCurrent(generation) else { return }
                self.sources = []
                self.sourceStates = [:]
                self.inventory = nil
                self.inventoryIssues = []
                self.sourceTree = nil
                self.error = "Could not inventory \(context.dataRootRelativePath): \(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled, requestID == self.activeLoadID,
                  await self.discoveryGate.isCurrent(generation) else { return }
            self.inventory = inv
            self.inventoryIssues = inv.issues
            self.sourceTree = SourceTree(inventory: inv, project: context)
            let discovered = inv.sources
            self.sources = discovered
            self.sourceStates = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, GallerySourceState()) })
            self.studyManifests = []
            self.manifestIssues = []
            if discovered.isEmpty {
                self.error = "No readable regular files were found under \(context.dataRootRelativePath)."
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
                let store = try? await ProjectIndexStore.open(project: context)

                var initialStates: [String: GallerySourceState] = [:]
                var cachedCount = 0

                for source in capturedSources {
                    if Task.isCancelled { return }
                    if let restored = try? await store?.validatedInspection(for: source, project: context) {
                        var state = GallerySourceState()
                        state.inspection = restored.inspection
                        state.error = restored.error
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

        // Perform fast Cache Restoration off the MainActor:
        inspectionTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let store = try? await ProjectIndexStore.open(project: context)

            var uninspected: [RawSource] = []
            var initialStates: [String: GallerySourceState] = [:]
            var cachedCount = 0

            for source in capturedSources {
                if Task.isCancelled { return }
                if let restored = try? await store?.validatedInspection(for: source, project: context) {
                    var state = GallerySourceState()
                    state.inspection = restored.inspection
                    state.error = restored.error
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

                self.inspectSources(finalUninspected, project: context, requestID: requestID, baseCompleted: finalCached)
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
        inspectSources(pending, project: project, requestID: requestID, baseCompleted: sources.count - pending.count)
        return true
    }

    private func inspectSources(_ targets: [RawSource], project: ProjectContext, requestID: UUID, baseCompleted: Int, rebuild: Bool = false) {
        inspectionTask = Task {
            let accumulator = InspectionProgressAccumulator()
            let store = try? await ProjectIndexStore.open(project: project)

            let report = await InstrumentReader.inspectMany(targets, project: project, cache: cache,
                onProgress: { results, completed in
                    if let store {
                        Task.detached(priority: .utility) {
                            try? await store.withWriterJob {
                                try? await store.recordBatch(results, project: project)
                            }
                        }
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

// MARK: - Task 7: per-source session axis override (display-only).

/// Display-only axis selection for one source: variant defaults when x/y are
/// nil, an explicit channel otherwise. Keyed by loaded profile/variant
/// provenance plus stable column IDs; never written to profiles.
struct AxisOverride: Equatable {
    var profileID: String
    var variantID: String
    var x: String?
    var y: [String]?
}

struct RawViewShell: View {
    @ObservedObject var model: RawViewModel

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                sidebarPane
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                    }

                Group {
                    galleryPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.showInspector {
                    inspector
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 450)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                        }
                }
            }

            if model.showAIAssistant {
                AIAssistantPane(model: model)
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                    }
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.showAIAssistant.toggle()
                    }
                }) {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(model.showAIAssistant ? Color.accentColor : Color.primary)
                }
                .help("Toggle AI Assistant (⌘⌥A)")
                .keyboardShortcut("a", modifiers: [.command, .option])
            }
        }
        .sheet(isPresented: $model.isProjectSetupPresented) {
            if let rootURL = model.pendingSetupProjectURL {
                ProjectSetupView(
                    projectRoot: rootURL,
                    initialDiagnostic: model.pendingSetupDiagnostic,
                    onOpen: { dataRoot, persist in
                        model.isProjectSetupPresented = false
                        Task {
                            do {
                                try await model.configureProject(root: rootURL, dataRoot: dataRoot, persist: persist)
                            } catch {
                                model.error = error.localizedDescription
                            }
                        }
                    },
                    onCancel: {
                        model.isProjectSetupPresented = false
                        model.pendingSetupProjectURL = nil
                        model.pendingSetupDiagnostic = nil
                    }
                )
            }
        }
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

    @ViewBuilder
    private var galleryPane: some View {
        ProjectGallery(sources: model.sources, states: model.displayStates,
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
                       onExportFigure: { model.exportCurrentFigure() },
                       onExportData: { model.exportCurrentData() },
                       onSaveSnapshotPackage: { model.saveSnapshotPackage() },
                       projectSnapshotPackages: model.projectSnapshotPackages,
                       onSelectSnapshotPackage: { model.loadSnapshotPackage($0) },
                       comparisonTitle: model.comparisonTitle,
                       availablePresets: model.availablePresets,
                       selectedPreset: $model.selectedPreset,
                       showLegend: $model.showLegend,
                       customSeriesLabels: model.customSeriesLabels,
                       legendOffset: $model.legendOffset)
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project header (open / recent)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("PROJECT")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(nsColor: .labelColor).opacity(0.55))
                        .tracking(0.5)

                    Spacer()

                    if !model.recentProjects.isEmpty {
                        Menu {
                            ForEach(model.recentProjects, id: \.self) { url in
                                Button(url.lastPathComponent) {
                                    model.openRecentProject(url: url)
                                }
                            }
                            Divider()
                            Button("Clear Recent", action: model.clearRecentProjects)
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .help("Recent projects")
                    }

                    Button(action: model.openProject) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Open project (⌘O)")
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }

            Spacer().frame(height: 12)

            if let project = model.project {
                // Section switcher: [ Sources ]  [ Categories ]
                sectionSwitcher

                if model.isInspecting {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(model.inspectedSources), total: Double(max(1, model.inspectionTotal))) {
                            HStack {
                                Text("Inspecting \(model.inspectedSources) of \(model.inspectionTotal)")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Cancel", action: model.cancelLoad)
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                }

                ProjectSourcesSidebar(
                    sources: model.sources,
                    inspections: model.inspections,
                    states: model.sourceStates,
                    focusedSourceID: $model.focusedSourceID,
                    selectedSourceIDs: $model.selectedSourceIDs,
                    sourceTree: model.sourceTree,
                    inventoryIssues: model.inventoryIssues,
                    dataRoot: project.dataRootRelativePath,
                    expandedDirectoryIDs: $model.expandedDirectoryIDs,
                    facet: $model.selectedExplorerView,
                    explorerViews: model.explorerViews,
                    catalog: model.explorerCatalog,
                    viewError: model.explorerViewError,
                    onAddView: { model.addExplorerView(grammarID: $0, variable: $1) },
                    onRemoveView: { model.removeExplorerView($0) },
                    sourceLabels: model.sourceLabelLayouts,
                    onSaveSourceLabels: { model.saveSourceLabels($0) }
                )
                .id("\(project.root.path):\(project.dataRootRelativePath)")

                if !model.profileIssues.isEmpty {
                    profileIssueList
                        .padding(.horizontal, 12)
                }

                Text("Built-in readers parse sources. Raw files are strictly read-only.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding([.bottom, .horizontal], 12)
            } else {
                noProjectSidebarContent
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sectionSwitcher: some View {
        HStack(spacing: 2) {
            let isTree = model.selectedExplorerView == "tree"
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.selectedExplorerView = "tree"
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text("Tree")
                        .font(.system(size: 11, weight: isTree ? .semibold : .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .foregroundStyle(isTree ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isTree ? Color(nsColor: .textBackgroundColor) : .clear)
                        .shadow(color: isTree ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            let isCategories = model.selectedExplorerView != "tree"
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if let firstView = model.explorerViews.first {
                        model.selectedExplorerView = RawViewModel.explorerViewKey(grammarID: firstView.grammarID, variable: firstView.variable)
                    } else {
                        model.selectedExplorerView = ""
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "tag")
                        .font(.system(size: 11))
                    Text("Categories")
                        .font(.system(size: 11, weight: isCategories ? .semibold : .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .foregroundStyle(isCategories ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isCategories ? Color(nsColor: .textBackgroundColor) : .clear)
                        .shadow(color: isCategories ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var noProjectSidebarContent: some View {
        VStack(spacing: 16) {
            Spacer()
            ContentUnavailableView("No Project", systemImage: "folder", description: Text("Open the research project that owns the raw files."))
            Button(action: model.openProject) {
                HStack(spacing: 6) {
                    Text("Open Project…")
                    ShortcutBadge("openProject")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            if !model.recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("RECENT PROJECTS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear", action: model.clearRecentProjects)
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)

                    VStack(spacing: 4) {
                        ForEach(model.recentProjects.prefix(5), id: \.self) { url in
                            Button {
                                model.openRecentProject(url: url)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(Color.accentColor)
                                        .font(.system(size: 12))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(url.path)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 280)
                .padding(.top, 10)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
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
        if let focusedID { currentState = model.displayStates[focusedID] }
        var currentSource: RawSource? = nil
        if let focusedID {
            currentSource = model.sources.first(where: { $0.id == focusedID })
        }
        let baseMeasurement = focusedID.flatMap { model.sourceStates[$0]?.measurement }
        let override = focusedID.flatMap { model.activeAxisOverride(for: $0) }
        return InspectorPane(measurement: currentState?.measurement, inspection: currentState?.inspection,
                             source: currentSource?.url, sourceID: currentSource?.id, error: currentState?.error ?? model.error,
                             states: model.displayStates,
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
                             eligibleX: currentState?.measurement?.eligibleXIDs ?? [],
                             eligibleY: currentState?.measurement?.eligibleYIDs ?? [],
                             defaultY: baseMeasurement?.view.y ?? [],
                             selectedX: override?.x,
                             selectedY: override?.y,
                             axisNote: focusedID.flatMap { model.axisNote(for: $0) },
                             onSelectX: { x in
                                 if let id = model.focusedSourceID { model.setAxisX(x, for: id) }
                             },
                             onSelectY: { y in
                                 if let id = model.focusedSourceID { model.setAxisY(y, for: id) }
                             },
                             onResetAxes: {
                                 if let id = model.focusedSourceID { model.resetAxes(for: id) }
                             })
    }
}
