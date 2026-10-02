import AppKit
import CryptoKit
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
    @Published var trustConfirmed = false
    @Published private(set) var hasReaderApproval = false
    @Published var inspectedSources = 0
    @Published var inspectionTotal = 0
    @Published var loadingPhase = "Idle"
    @Published var tab = "Plot"
    @Published var xAbsolute = false
    @Published var yAbsolute = false
    @Published var xScale: AxisScale = .linear
    @Published var yScale: AxisScale = .linear
    private var operationTask: Task<Void, Never>?
    private var activeLoadID = UUID()
    private var activeScopeURL: URL?
    private var pendingApproval: ReaderApproval?

    var pendingReaderFingerprint: String { pendingApproval.map { String($0.readerSHA256.prefix(12)) } ?? "unavailable" }

    init() {
        if let bookmark = UserDefaults.standard.data(forKey: "rawView.projectBookmark.v1") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                activeScopeURL = url
                if let restored = try? ProjectContext.open(url) { install(restored) }
            } else if let path = UserDefaults.standard.string(forKey: "rawView.lastProjectPath.v1"),
                      let opened = try? ProjectContext.open(URL(fileURLWithPath: path)) {
                install(opened)
            }
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

    func resumeOrRequestApproval() {
        guard let project, !sources.isEmpty else { return }
        guard let approval = savedApproval(for: project), approval.isCurrent(for: project) else {
            removeSavedApproval(for: project)
            hasReaderApproval = false
            requestReaderApproval()
            return
        }
        hasReaderApproval = true
        startInspection(project, approval: approval)
    }

    func requestReaderApproval() {
        guard let project else { return }
        guard let candidate = ReaderApproval.issue(afterUserReviewOf: project) else {
            pendingApproval = nil
            trustConfirmed = false
            error = "The project reader is missing, unreadable, or resolves outside data/instruments. Add a regular reader.py inside this project, then reopen it."
            return
        }
        pendingApproval = candidate
        trustConfirmed = true
    }

    func cancelApproval() {
        pendingApproval = nil
        trustConfirmed = false
    }

    func approveProjectReader() {
        guard let project, let approval = pendingApproval else { return }
        guard approval.isCurrent(for: project) else {
            error = "The project reader changed while its approval prompt was open. Review the current reader and approve again."
            requestReaderApproval()
            return
        }
        saveApproval(approval, for: project)
        cancelApproval()
        hasReaderApproval = true
        startInspection(project, approval: approval)
    }

    func cancelLoad() {
        operationTask?.cancel()
        operationTask = nil
        activeLoadID = UUID()
        isLoading = false
        if let id = focusedSourceID { sourceStates[id]?.isLoading = false }
    }

    func loadFocused() {
        guard let project, hasReaderApproval, let id = focusedSourceID,
              let source = sources.first(where: { $0.id == id }) else { return }
        guard let approval = savedApproval(for: project), approval.isCurrent(for: project) else {
            removeSavedApproval(for: project)
            hasReaderApproval = false
            requestReaderApproval()
            return
        }
        guard sourceStates[id]?.measurement == nil, sourceStates[id]?.isLoading != true else { return }
        operationTask?.cancel()
        for (previousID, var previousState) in sourceStates where previousState.isLoading {
            previousState.isLoading = false
            sourceStates[previousID] = previousState
        }
        activeLoadID = UUID()
        let taskID = activeLoadID
        isLoading = true
        sourceStates[id]?.isLoading = true
        sourceStates[id]?.error = nil
        operationTask = Task { [weak self] in
            defer { if taskID == self?.activeLoadID { self?.isLoading = false } }
            do {
                let result = try await ReaderClient.load(source.url, project: project, approval: approval)
                guard taskID == self?.activeLoadID, let self else { return }
                var state = self.sourceStates[id] ?? GallerySourceState()
                state.measurement = result.measurement
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
        cancelApproval()
        hasReaderApproval = false
        project = context
        focusedSourceID = nil
        tab = "Plot"
        error = nil
        do {
            sources = try context.discoverSources()
            sourceStates = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, GallerySourceState()) })
            if sources.isEmpty { error = "No readable regular files were found under data/raw." }
            else { resumeOrRequestApproval() }
        } catch {
            sources = []
            sourceStates = [:]
            self.error = "Could not inventory data/raw: \(error.localizedDescription)"
        }
    }

    private func startInspection(_ context: ProjectContext, approval: ReaderApproval) {
        operationTask?.cancel()
        let requestID = UUID()
        activeLoadID = requestID
        isLoading = true
        error = nil
        loadingPhase = "Inspecting"
        inspectedSources = 0
        inspectionTotal = sources.count
        sourceStates = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, GallerySourceState()) })
        operationTask = Task {
            _ = await ReaderClient.inspectMany(sources, project: context, approval: approval,
                onProgress: { results, completed in
                    await MainActor.run {
                        guard requestID == self.activeLoadID else { return }
                        for result in results {
                            var state = self.sourceStates[result.id] ?? GallerySourceState()
                            state.inspection = result.inspection
                            state.error = result.error
                            self.sourceStates[result.id] = state
                        }
                        self.inspectedSources = completed
                    }
                })
            guard !Task.isCancelled, requestID == activeLoadID else { return }
            isLoading = false
            loadingPhase = "Idle"
            if focusedSourceID == nil { focusedSourceID = sources.first?.id }
            loadFocused()
        }
    }

    private func approvalKey(for project: ProjectContext) -> String {
        let digest = SHA256.hash(data: Data(project.root.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "rawView.readerApproval.v1.\(digest)"
    }
    private func savedApproval(for project: ProjectContext) -> ReaderApproval? {
        guard let data = UserDefaults.standard.data(forKey: approvalKey(for: project)) else { return nil }
        return try? JSONDecoder().decode(ReaderApproval.self, from: data)
    }
    private func saveApproval(_ approval: ReaderApproval, for project: ProjectContext) {
        guard let data = try? JSONEncoder().encode(approval) else { return }
        UserDefaults.standard.set(data, forKey: approvalKey(for: project))
    }
    private func removeSavedApproval(for project: ProjectContext) {
        UserDefaults.standard.removeObject(forKey: approvalKey(for: project))
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
                    if model.isLoading && model.loadingPhase == "Inspecting" {
                        ProgressView(value: Double(model.inspectedSources), total: Double(max(1, model.inspectionTotal))) {
                            Text("Inspecting \(model.inspectedSources) of \(model.inspectionTotal) sources")
                        }
                        Button("Cancel Inspection", action: model.cancelLoad).buttonStyle(.bordered)
                    } else if !model.sources.isEmpty {
                        Button("Review and Approve Reader", action: model.requestReaderApproval)
                            .buttonStyle(.borderedProminent)
                    }
                    ProjectSourcesSidebar(sources: model.sources,
                        inspections: Dictionary(uniqueKeysWithValues: model.sourceStates.compactMap { id, state in state.inspection.map { (id, $0) } }),
                        states: model.sourceStates, focusedSourceID: $model.focusedSourceID)
                    Spacer()
                    Text("The approved reader and configured parser run with your permissions.")
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
                               xScale: $model.xScale, yScale: $model.yScale)
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
        .alert("Approve Project Reader?", isPresented: $model.trustConfirmed) {
            Button("Cancel", role: .cancel) { model.cancelApproval() }
            Button("Approve and Inspect Sources") { model.approveProjectReader() }
        } message: {
            Text("RawView discovered \(model.sources.count) files. Approval lets this project's data/instruments/reader.py and its configured shared instrument parser run with your permissions across every discovered source. They may access or change files your account can access. Approval is saved for this project and this exact reader version (SHA-256 \(model.pendingReaderFingerprint)); changing the reader requires approval again. Review the reader and configured parser before continuing.")
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

    private var transformed: Result<([Double], [(String, [Double])]), PlotFailure> {
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
            var series: [(String, [Double])] = []
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
                    Text("Drag to pan · Pinch to zoom · \(data.0.count) ordered points")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func draw(_ data: ([Double], [(String, [Double])]), in context: inout GraphicsContext, size: CGSize) {
        guard !data.0.isEmpty, let first = data.1.first?.1, !first.isEmpty else { return }
        let plot = CGRect(x: 66, y: 12, width: max(1, size.width - 84), height: max(1, size.height - 58))
        var frame = Path(); frame.addRect(plot); context.stroke(frame, with: .color(.black), lineWidth: 0.8)
        let xRange = viewport(expanded(data.0), pan: pan.width, dimension: plot.width, vertical: false)
        let allY = data.1.flatMap(\.1)
        let yRange = viewport(expanded(allY), pan: pan.height, dimension: plot.height, vertical: true)
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
            var line = Path()
            for index in data.0.indices {
                let tx = (data.0[index] - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
                let ty = (item.1[index] - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
                let point = CGPoint(x: plot.minX + tx * plot.width, y: plot.maxY - ty * plot.height)
                if index == data.0.startIndex { line.move(to: point) } else { line.addLine(to: point) }
            }
            plotContext.stroke(line, with: .color(palette(seriesIndex)), lineWidth: 1.4)
        }
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
                cell(String(channel.values[index]), width: 150)
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
                        field("Reader-reported support", measurement.supportStatus)
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
                            field("Reader-reported state", measurement.provenance["validation_state"] ?? "Unknown")
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
                        field("Study", inspection.studyToken ?? "Unknown")
                    }
                    section("Status") {
                        field("Reader support", inspection.supportStatus ?? "Unknown")
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
                    Text(error == nil ? "Waiting for project metadata inspection." : "Metadata inspection is unavailable for this source.")
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
