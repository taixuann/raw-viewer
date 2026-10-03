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
    private var activeLoadID = UUID()
    private var inspectionID = UUID()
    private var activeScopeURL: URL?
    private let discoveryGate = DiscoveryGate()

    init() {
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
        activeLoadID = UUID()
        inspectionID = UUID()
        isLoading = false
        loadingPhase = "Idle"
        if let id = focusedSourceID { sourceStates[id]?.isLoading = false }
    }

    private func refreshLoading() {
        isLoading = discoveryTask != nil || inspectionTask != nil || loadTask != nil
        if !isLoading { loadingPhase = "Idle" }
    }

    func loadFocused() {
        guard let project, let id = focusedSourceID,
              let source = sources.first(where: { $0.id == id }) else { return }
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
        isLoading = true
        sourceStates[id]?.isLoading = true
        sourceStates[id]?.error = nil
        loadTask = Task { [weak self] in
            defer {
                if taskID == self?.activeLoadID { self?.loadTask = nil }
                self?.refreshLoading()
            }
            do {
                let measurement = try await InstrumentReader.load(source.url, project: project)
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
        tab = "Plot"
        error = nil
        profileIssues = []
        sources = []
        sourceStates = [:]
        inspectionCancelled = false
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
            if discovered.isEmpty {
                self.error = "No readable regular files were found under data/raw."
            } else {
                self.startInspection(context)
            }
        }
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
            let report = await InstrumentReader.inspectMany(targets, project: project,
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
            self.loadFocused()
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
                        states: model.sourceStates, focusedSourceID: $model.focusedSourceID)
                    if !model.profileIssues.isEmpty {
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
            HStack(spacing: 0) {
                ProjectGallery(sources: model.sources, states: model.sourceStates,
                               focusedSourceID: $model.focusedSourceID, tab: $model.tab,
                               xAbsolute: $model.xAbsolute, yAbsolute: $model.yAbsolute,
                               xScale: $model.xScale, yScale: $model.yScale, retry: model.loadFocused)
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                let state = model.focusedSourceID.flatMap { model.sourceStates[$0] }
                let source = model.sources.first { $0.id == model.focusedSourceID }
                InspectorPane(measurement: state?.measurement, inspection: state?.inspection, source: source?.url,
                              error: state?.error ?? model.error)
                    .frame(width: 285)
            }
            .overlay(alignment: .top) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .padding(10).frame(maxWidth: .infinity).background(.regularMaterial)
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .onChange(of: model.focusedSourceID) { _, _ in model.loadFocused() }
    }

    private var profileIssueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROFILE ISSUES").font(.caption2.bold()).foregroundStyle(.orange)
            ForEach(Array(model.profileIssues.enumerated()), id: \.offset) { _, issue in
                Text(issue).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private enum PlotFailure: Error { case message(String) }

struct NativePlot: View {
    let measurement: NormalizedMeasurement
    let xAbsolute: Bool
    let yAbsolute: Bool
    let xScale: AxisScale
    let yScale: AxisScale
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
        let plot = CGRect(x: 66, y: 12, width: max(1, size.width - 84), height: max(1, size.height - 58))
        var frame = Path(); frame.addRect(plot); context.stroke(frame, with: .color(.black), lineWidth: 0.8)
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
            context.stroke(tick, with: .color(.black), lineWidth: 0.7)
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
                plotContext.stroke(line, with: .color(palette(seriesIndex)), lineWidth: 1.4)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("INSPECTOR").font(.headline)
                if let measurement {
                    section("Identity") {
                        field("Instrument", measurement.instrument.name)
                        field("Mode", measurement.applicationMode ?? "Unknown")
                        field("Channels / Points", "\(measurement.channels.count) / \(measurement.channels.first?.values.count ?? 0)")
                        field("Profile-reported support", measurement.supportStatus)
                    }
                    ForEach(measurement.metadataSections) { section in
                        self.section(section.title) {
                            ForEach(section.fields) { value in
                                field(value.label, value.value.displayText + (value.unit.map { " \($0)" } ?? ""))
                            }
                        }
                    }
                    if !measurement.warnings.isEmpty {
                        section("Validation") {
                            field("Profile-reported state", measurement.provenance["profile_schema_version"].map { "schema v\($0)" } ?? "Unknown")
                            ForEach(Array(measurement.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    section("Source") {
                        field("Path", measurement.source.path)
                    }
                } else if let inspection {
                    section("Identity") {
                        field("Instrument", inspection.instrumentName ?? inspection.instrumentID ?? "Unknown")
                        field("Mode", inspection.applicationMode ?? "Unknown")
                        field("Device", inspection.deviceID ?? "Unknown")
                        field("Category", inspection.category ?? "Unknown")
                    }
                    section("Status") {
                        field("Profile support", inspection.supportStatus ?? "Unknown")
                        field("Validation", inspection.validationState ?? "Unknown")
                    }
                    section("Source") {
                        field("Path", inspection.source)
                        field("Size", inspection.size.map { "\($0) bytes" } ?? "Unknown")
                        field("Timestamp", inspection.timestamp ?? "Unknown")
                    }
                    if let source { Text(source.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                } else if let source {
                    field("Selected", source.lastPathComponent)
                    Text(error == nil ? "Waiting for source inspection." : "Source inspection is unavailable for this source.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Select one source to inspect it.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(14)
        }.background(.background)
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
