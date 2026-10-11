import SwiftUI
import RawViewCore

struct EditorWorkspaceView: View {
    let project: ProjectContext
    let sources: [RawSource]
    var initialSelectedSource: RawSource? = nil
    enum SpecTab: String, CaseIterable, Identifiable {
        case identity = "Instrument & Files"
        case tokens = "Filename Tokens"
        case library = "Saved Profiles"
        var id: String { rawValue }
    }

    enum StudioTab: String, CaseIterable, Identifiable {
        case rawStream = "Raw Stream Studio"
        case liveSandbox = "Live Sandbox Studio"
        var id: String { rawValue }
    }

    @StateObject private var model = EditorWorkspaceViewModel()
    @State private var selectedStudioTab: StudioTab = .rawStream
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    var body: some View {
        HSplitView {
            // Panel 1 (Left): Unified Profile Specification & File Sources Sidebar
            specificationSidebar
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                .frame(maxHeight: .infinity)

            // Panel 2 (Right): Interactive Visual Studio (Data Matrix + Centered Floating Figure)
            visualCanvasWorkspace
                .frame(minWidth: 500)
                .frame(maxHeight: .infinity)
        }
        .onAppear {
            model.setup(project: project, sources: sources, initialSource: initialSelectedSource)
        }
        .onChange(of: initialSelectedSource) { _, newSource in
            if let newSource = newSource {
                model.selectSource(newSource)
            }
        }
    }

    // MARK: - Panel 1: Unified Specification Sidebar
    private var specificationSidebar: some View {
        VStack(spacing: 0) {
            // Sidebar Header
            HStack {
                Text("Profile Specification")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshSavedProfiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Refresh saved profiles")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // SECTION A: Compact File & Profile Sources
                    compactSourceCard

                    // SECTION B: Instrument Identity
                    instrumentIdentitySection

                    // SECTION C: Filename Semantic Elements
                    filenameSemanticSection
                }
                .padding(12)
            }

            Divider()

            // Sticky Bottom Actions
            sidebarActionFooter
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Section A: Compact Source Card (Active File & Saved Profiles Menu)
    private var compactSourceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Target Sample & Profile", systemImage: "doc.text")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.selectedSource != nil {
                        Text("\(model.editor.lines.count) lines")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(.quaternary))
                    }
                }

                if let src = model.selectedSource {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(src.url.lastPathComponent)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Text(src.relativePath)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                } else {
                    Text("No file selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Sample Actions Bar: Switch File & Quick Saved Profiles Menu
                HStack(spacing: 6) {
                    // Switch Sample File Dropdown Menu
                    Menu {
                        ForEach(sources) { s in
                            Button(s.url.lastPathComponent) {
                                model.selectSource(s)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Switch…")
                        }
                        .font(.system(size: 10))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)

                    // Saved Profiles Dropdown Menu
                    Menu {
                        if model.savedProfiles.isEmpty {
                            Text("No saved profiles").foregroundStyle(.secondary)
                        } else {
                            ForEach(model.savedProfiles, id: \.self) { profileURL in
                                Button(profileURL.lastPathComponent) {
                                    model.loadSavedProfile(url: profileURL)
                                }
                            }
                        }
                        Divider()
                        Button("Import YAML…") {
                            model.importProfile()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "slider.horizontal.3")
                            Text("Saved (\(model.savedProfiles.count))")
                        }
                        .font(.system(size: 10))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)

                    Spacer(minLength: 0)

                    // Pin Example Button
                    Button {
                        model.pinCurrentAsExample()
                    } label: {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.selectedSource == nil)
                    .help("Saves a copy of this sample file to .rawviewer/instrument/examples/ as canonical reference")
                }
            }
            .padding(4)
        }
    }

    // MARK: - Section B: Instrument Identity Section
    private var instrumentIdentitySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Instrument Identity", systemImage: "cpu")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Profile ID").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if !model.tokens.isEmpty {
                            Menu {
                                ForEach(model.tokens, id: \.self) { tok in
                                    Button(tok) {
                                        model.editor.instrumentID = tok
                                        if model.editor.instrumentName.isEmpty {
                                            model.editor.instrumentName = tok
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "wand.and.stars")
                                    Text("Pick from Token…")
                                }
                                .font(.system(size: 9.5))
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                    TextField("e.g. autolab-pgstat", text: $model.editor.instrumentID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Display Name").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("e.g. Autolab PGSTAT302N", text: $model.editor.instrumentName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                HStack {
                    Text("Delimiter:")
                        .font(.system(size: 11))
                    Spacer()
                    Picker("", selection: $model.editor.delimiter) {
                        Text("Comma (,)").tag(",")
                        Text("Tab (\\t)").tag("\t")
                        Text("Semicolon (;)").tag(";")
                        Text("Space").tag(" ")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Section C: Filename Semantic Elements Section
    private var filenameSemanticSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Filename Semantic Elements", systemImage: "text.word.spacing")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.tokens.count) tokens")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Detected Token Segments - Quick chips to define element or set identity
                if !model.tokens.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detected Segments (Click to define):")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(model.tokens, id: \.self) { tok in
                                    Menu {
                                        Button("Add as Element") {
                                            model.addElement(token: tok)
                                        }
                                        Button("Use as Profile ID") {
                                            model.editor.instrumentID = tok
                                        }
                                        Button("Use as Display Name") {
                                            model.editor.instrumentName = tok
                                        }
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.blue)
                                            Text(tok)
                                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.blue.opacity(0.3), lineWidth: 1))
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                            }
                        }
                    }
                }

                // Add / Clear Controls
                HStack {
                    Button {
                        model.addElement(token: "")
                    } label: {
                        Label("Add Element", systemImage: "plus")
                            .font(.system(size: 10))
                    }
                    .controlSize(.small)

                    Spacer()

                    if !model.semanticElements.isEmpty {
                        Button(role: .destructive) {
                            model.clearAllElements()
                        } label: {
                            Text("Clear All")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                // Dynamic Elements Cards List
                if model.semanticElements.isEmpty {
                    VStack(spacing: 4) {
                        Text("No elements defined yet.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Click a token segment above or 'Add Element' to define your custom rules.")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary.opacity(0.25)))
                } else {
                    VStack(spacing: 8) {
                        ForEach($model.semanticElements) { $el in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    TextField("Token", text: $el.token)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .frame(maxWidth: 105)

                                    TextField("Tag (e.g. Date)", text: $el.tagName)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 10))

                                    Picker("", selection: $el.role) {
                                        ForEach(SemanticTokenElement.standardRoles + ["Custom..."], id: \.self) { role in
                                            Text(role).tag(role)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .font(.system(size: 9.5))
                                    .controlSize(.mini)
                                    .frame(width: 90)

                                    Button {
                                        model.removeElement(id: el.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                if el.role == "Custom..." || (!SemanticTokenElement.standardRoles.contains(el.role) && el.role != "Remarks") {
                                    HStack(spacing: 6) {
                                        Text("Custom Role:").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                        TextField("e.g. Concentration, Cell, Operator", text: $el.role)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 9.5))
                                    }
                                    .padding(.leading, 4)
                                }

                                if el.role == "Date & Time" {
                                    HStack(spacing: 6) {
                                        Text("Format:").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                        TextField("DDMMYYYY-HHmmSS", text: $el.formatHint)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 9.5, design: .monospaced))
                                        Menu("Presets") {
                                            ForEach(SemanticTokenElement.standardDateFormats, id: \.self) { fmt in
                                                Button(fmt) { el.formatHint = fmt }
                                            }
                                        }
                                        .menuStyle(.borderlessButton)
                                        .font(.system(size: 9))
                                    }
                                    .padding(.leading, 6)
                                }
                            }
                            .padding(6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }

                if !model.siblingPreviews.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Live Sibling Match:")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.siblingPreviews) { sib in
                            HStack(spacing: 4) {
                                Text(sib.filename)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                if let cat = sib.category {
                                    Text(cat)
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.purple)
                                        .padding(.horizontal, 3).padding(.vertical, 1)
                                        .background(Color.purple.opacity(0.12)).cornerRadius(3)
                                }
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Sidebar Action Footer (Cohort & Build Actions)
    private var sidebarActionFooter: some View {
        VStack(spacing: 8) {
            Button {
                model.testAgainstCohort()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal")
                    Text("Test Against Cohort")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)

            if let status = model.cohortTestResult {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(model.cohortTestSuccess ? .green : .orange)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
            }

            Button {
                model.saveProfileAndRules()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 11))
                    Text("Build Profile")
                        .font(.system(size: 11, weight: .semibold))
                    ShortcutBadge("buildProfile")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(model.editor.instrumentID.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut("s", modifiers: [.command])
            .help("Builds and saves this instrument profile & category rules to .rawviewer/ (Cmd+S)")
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Panel 2: Right Visual Studio Workspace
    private var visualCanvasWorkspace: some View {
        VStack(spacing: 0) {
            commandBar
            Divider()

            switch selectedStudioTab {
            case .rawStream:
                // Dedicated Raw Stream Studio with Column Multi-Selection & Header Title Cards (100% Canvas Height)
                ParserSettingsCanvasView(
                    lines: model.editor.lines,
                    delimiter: $model.editor.delimiter,
                    decimalSeparator: $model.editor.decimalDelimiter,
                    columns: $model.editor.columns,
                    lineTags: model.editor.lineTags,
                    metadataCellTags: model.editor.metadataCellTags,
                    onTagMetadataCell: { tag in
                        model.tagMetadataCell(tag)
                    },
                    onRemoveMetadataTag: { lineIdx, tokIdx in
                        model.removeMetadataTag(lineIndex: lineIdx, tokenIndex: tokIdx)
                    },
                    onUpdateColumn: { idx, col in
                        model.updateColumn(index: idx, column: col)
                    },
                    onRunAutoDetect: {
                        model.runAutoDetect()
                    },
                    onApplyCustomStructure: { delim, decimal, headerLine, dataStart, skippedLines in
                        model.applyCustomStructure(delimiter: delim, decimalSeparator: decimal, headerLine: headerLine, dataStartLine: dataStart, skippedMetadataLines: skippedLines)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .liveSandbox:
                // Dedicated Live Sandbox Studio with 100% Canvas Height
                LiveSandboxPlotView(
                    lines: model.editor.lines,
                    delimiter: model.editor.delimiter,
                    columns: model.editor.columns,
                    lineTags: model.editor.lineTags,
                    selectedXCol: $model.sandboxXCol,
                    selectedYCol: $model.sandboxYCol
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Top Command Bar
    private var commandBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedStudioTab) {
                Label("Raw Stream Studio", systemImage: "waveform.path.ecg")
                    .tag(StudioTab.rawStream)
                Label("Live Sandbox Studio", systemImage: "chart.xyaxis.line")
                    .tag(StudioTab.liveSandbox)
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .onChange(of: selectedStudioTab) { _, newTab in
                if newTab == .liveSandbox {
                    model.syncDefaultPlotChannels()
                }
            }

            Spacer()

            if let status = model.saveStatusMessage {
                HStack(spacing: 4) {
                    Image(systemName: (status.contains("error") || status.contains("Failed")) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 9.5))
                    Text(status)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle((status.contains("error") || status.contains("Failed")) ? Color.red : Color.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(((status.contains("error") || status.contains("Failed")) ? Color.red : Color.green).opacity(0.12))
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - ViewModel & Subviews
@MainActor
final class EditorWorkspaceViewModel: ObservableObject {
    @Published var project: ProjectContext?
    @Published var sources: [RawSource] = []
    @Published var selectedSource: RawSource?
    @Published var editor = EditorWorkspaceModel()
    @Published var selectedLineRange: ClosedRange<Int>?

    @Published var tokens: [String] = []
    @Published var semanticElements: [SemanticTokenElement] = []
    @Published var categoryTokenIndex: Int? {
        didSet { updateSiblingPreviews() }
    }
    @Published var deviceTokenIndex: Int? {
        didSet { updateSiblingPreviews() }
    }

    @Published var savedProfiles: [URL] = []
    @Published var sandboxXCol: String?
    @Published var sandboxYCol: String?

    @Published var cohortTestResult: String?
    @Published var cohortTestSuccess: Bool = false
    @Published var saveStatusMessage: String?

    struct SiblingPreview: Identifiable {
        var id: String { filename }
        let filename: String
        let category: String?
        let device: String?
    }

    @Published var siblingPreviews: [SiblingPreview] = []

    private var isInitialized = false

    func setup(project: ProjectContext, sources: [RawSource], initialSource: RawSource? = nil) {
        guard !isInitialized || self.project?.root != project.root else { return }
        isInitialized = true
        self.project = project
        self.sources = sources
        refreshSavedProfiles()
        if let initial = initialSource ?? sources.first {
            selectSource(initial)
        }
    }

    func refreshSavedProfiles() {
        guard let project = project else { return }
        var collectedURLs: [URL] = []
        var seenFilenames = Set<String>()

        let searchDirs: [URL] = [
            project.root.appendingPathComponent(".rawviewer/instrument", isDirectory: true),
            project.root.appendingPathComponent("data/.rawview/instrument", isDirectory: true),
            project.root.appendingPathComponent("data/instruments", isDirectory: true),
            project.root.appendingPathComponent("data/instruments/rawview", isDirectory: true),
            project.root.appendingPathComponent("Examples/rawview", isDirectory: true)
        ]

        for dir in searchDirs {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
               let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "yaml" || file.pathExtension.lowercased() == "yml" {
                    if seenFilenames.insert(file.lastPathComponent).inserted {
                        collectedURLs.append(file)
                    }
                }
            }
        }

        self.savedProfiles = collectedURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    func importProfile() {
        guard let project = project else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Instrument Profile YAML"
        panel.allowedContentTypes = [.yaml, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let selectedURL = panel.url {
            do {
                let content = try String(contentsOf: selectedURL, encoding: .utf8)
                let destDir = project.root.appendingPathComponent(".rawviewer/instrument", isDirectory: true)
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                let destURL = destDir.appendingPathComponent(selectedURL.lastPathComponent)
                try content.write(to: destURL, atomically: true, encoding: .utf8)

                refreshSavedProfiles()
                loadSavedProfile(url: destURL)
                saveStatusMessage = "Imported & loaded: \(selectedURL.lastPathComponent)"
            } catch {
                saveStatusMessage = "Import error: \(error.localizedDescription)"
            }
        }
    }

    func loadSavedProfile(url: URL) {
        do {
            try editor.loadSavedProfile(url: url)
            self.tokens = editor.tokens
            syncSemanticElementsFromTokens()
            syncDefaultPlotChannels()
            let delimDisplay = editor.delimiter == "\t" ? "\\t" : editor.delimiter
            self.saveStatusMessage = "Loaded '\(url.lastPathComponent)' (\(editor.columns.count) columns, delimiter '\(delimDisplay)')"
            updateSiblingPreviews()

            loadRepresentativeSampleForProfile(profileURL: url)
            objectWillChange.send()
        } catch {
            self.saveStatusMessage = "Failed to load profile: \(error.localizedDescription)"
        }
    }

    func syncDefaultPlotChannels() {
        if let primaryX = editor.primaryXColumn {
            self.sandboxXCol = primaryX.name
        }
        if let primaryY = editor.primaryYColumn {
            self.sandboxYCol = primaryY.name
        }
    }

    func loadRepresentativeSampleForProfile(profileURL: URL) {
        guard let project = project else { return }
        let profileBaseName = profileURL.deletingPathExtension().lastPathComponent
        let examplesDir = project.root.appendingPathComponent(".rawviewer/instrument/examples", isDirectory: true)

        var matchedURL: URL? = nil
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: examplesDir.path, isDirectory: &isDir), isDir.boolValue,
           let files = try? FileManager.default.contentsOfDirectory(at: examplesDir, includingPropertiesForKeys: nil) {
            matchedURL = files.first(where: {
                let name = $0.lastPathComponent
                return name.localizedCaseInsensitiveContains(profileBaseName) ||
                       (!editor.instrumentID.isEmpty && name.localizedCaseInsensitiveContains(editor.instrumentID))
            })
        }

        if matchedURL == nil {
            let id = editor.instrumentID.isEmpty ? profileBaseName : editor.instrumentID
            matchedURL = sources.first(where: {
                $0.url.lastPathComponent.localizedCaseInsensitiveContains(id) ||
                (!editor.instrumentName.isEmpty && $0.url.lastPathComponent.localizedCaseInsensitiveContains(editor.instrumentName))
            })?.url
        }

        if matchedURL == nil {
            matchedURL = sources.first?.url
        }

        if let targetURL = matchedURL {
            if let existing = sources.first(where: { $0.url == targetURL }) {
                selectSource(existing, preserveProfile: true)
            } else {
                let size = (try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                let synthetic = RawSource(
                    relativePath: targetURL.lastPathComponent,
                    url: targetURL,
                    byteSize: size,
                    mtime: 0
                )
                selectSource(synthetic, preserveProfile: true)
            }
        }
    }

    func pinCurrentAsExample() {
        guard let project = project, let current = selectedSource else { return }
        let id = editor.instrumentID.trimmingCharacters(in: .whitespaces).isEmpty
            ? current.url.deletingPathExtension().lastPathComponent
            : editor.instrumentID.trimmingCharacters(in: .whitespaces)
        let ext = current.url.pathExtension
        let examplesDir = project.root.appendingPathComponent(".rawviewer/instrument/examples", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: examplesDir, withIntermediateDirectories: true)
            let destURL = examplesDir.appendingPathComponent("\(id)-example.\(ext)")
            let data = try Data(contentsOf: current.url)
            try data.write(to: destURL, options: .atomic)
            saveStatusMessage = "Pinned sample as example: \(destURL.lastPathComponent)"
        } catch {
            saveStatusMessage = "Failed to pin example: \(error.localizedDescription)"
        }
    }

    func syncSemanticElementsFromTokens() {
        guard let project = project else {
            self.semanticElements = []
            return
        }
        if let saved = CategoryRuleEngine.load(project: project), !saved.elements.isEmpty {
            self.semanticElements = saved.elements
        } else {
            self.semanticElements = []
        }
    }

    func addElement(token: String = "", role: String = "Remarks", tagName: String = "", formatHint: String = "") {
        let isDate = token.contains("-") && token.count >= 6
        let effectiveRole = role == "Remarks" && isDate ? "Date & Time" : role
        let effectiveHint = effectiveRole == "Date & Time" ? (formatHint.isEmpty ? "DDMMYYYY-HHmmSS" : formatHint) : formatHint
        let newEl = SemanticTokenElement(
            id: UUID(),
            index: semanticElements.count,
            token: token,
            tagName: tagName,
            role: effectiveRole,
            formatHint: effectiveHint
        )
        semanticElements.append(newEl)
        updateSiblingPreviews()
        objectWillChange.send()
    }

    func removeElement(id: UUID) {
        semanticElements.removeAll(where: { $0.id == id })
        for i in 0..<semanticElements.count {
            semanticElements[i].index = i
        }
        updateSiblingPreviews()
        objectWillChange.send()
    }

    func clearAllElements() {
        semanticElements.removeAll()
        updateSiblingPreviews()
        objectWillChange.send()
    }

    func selectSource(_ source: RawSource, preserveProfile: Bool = false) {
        self.selectedSource = source
        if !preserveProfile {
            self.saveStatusMessage = nil
        }
        self.cohortTestResult = nil
        do {
            let savedID = editor.instrumentID
            let savedName = editor.instrumentName
            let savedDelim = editor.delimiter
            let savedCols = editor.columns
            try editor.loadSample(url: source.url)
            self.tokens = editor.tokens
            syncSemanticElementsFromTokens()
            if preserveProfile {
                if !savedID.isEmpty { editor.instrumentID = savedID }
                if !savedName.isEmpty { editor.instrumentName = savedName }
                if !savedDelim.isEmpty { editor.delimiter = savedDelim }
                if !savedCols.isEmpty {
                    editor.columns = savedCols
                }
            } else {
                editor.smartAutoDetect()
            }
            syncDefaultPlotChannels()
            updateSiblingPreviews()
        } catch {
            saveStatusMessage = "Error loading sample: \(error.localizedDescription)"
        }
    }

    func runAutoDetect() {
        editor.smartAutoDetect()
        syncDefaultPlotChannels()
        objectWillChange.send()
    }

    func updateColumn(index: Int, column: ColumnDefinition) {
        guard index < editor.columns.count else { return }
        editor.columns[index] = column
        if column.isDefaultX || column.isXAxis {
            sandboxXCol = editor.primaryXColumn?.name
        }
        if column.isDefaultY || column.isYAxis {
            sandboxYCol = editor.primaryYColumn?.name
        }
        objectWillChange.send()
    }

    func tagMetadataCell(_ tag: MetadataCellTag) {
        editor.tagMetadataCell(
            lineIndex: tag.lineIndex,
            tokenIndex: tag.tokenIndex,
            rawValue: tag.rawValue,
            entityType: tag.entityType,
            customKey: tag.customKey,
            format: tag.format
        )
        objectWillChange.send()
    }

    func removeMetadataTag(lineIndex: Int, tokenIndex: Int) {
        editor.removeMetadataCellTag(lineIndex: lineIndex, tokenIndex: tokenIndex)
        objectWillChange.send()
    }

    func tagRange(range: ClosedRange<Int>, tag: LineRegionType) {
        editor.tagRange(from: range.lowerBound, to: range.upperBound, as: tag)
        objectWillChange.send()
    }

    func updateSiblingPreviews() {
        guard project != nil else { return }
        let catIndex = semanticElements.first(where: { $0.role == "category" })?.index
        let devIndex = semanticElements.first(where: { $0.role == "legend" })?.index
        let rule = CategoryRule(
            delimiters: editor.tokenDelimiters,
            categoryIndex: catIndex,
            deviceIndex: devIndex,
            elements: semanticElements
        )
        let siblings = sources.prefix(5)
        self.siblingPreviews = siblings.map { src in
            let facts = CategoryRuleEngine.extract(from: src.url.lastPathComponent, rules: rule)
            return SiblingPreview(
                filename: src.url.lastPathComponent,
                category: facts.category,
                device: facts.deviceID
            )
        }
    }

    func testAgainstCohort() {
        let sampleSiblings = Array(sources.prefix(20))
        guard !sampleSiblings.isEmpty else {
            cohortTestSuccess = false
            cohortTestResult = "No files in project to test against."
            return
        }
        var matched = 0
        let delim = editor.delimiter == "\\t" ? "\t" : editor.delimiter
        for src in sampleSiblings {
            if let data = try? String(contentsOf: src.url, encoding: .utf8),
               data.contains(delim) {
                matched += 1
            }
        }
        cohortTestSuccess = matched > 0
        cohortTestResult = "Tested on \(sampleSiblings.count) files: \(matched)/\(sampleSiblings.count) match delimiter format."
    }

    func saveProfileAndRules() {
        guard let project = project else { return }
        do {
            let savedFile = try editor.saveProfile(project: project)
            
            // Save category token rules with custom semantic elements to .rawviewer/view/category.yaml
            let catIndex = semanticElements.first(where: { $0.role == "category" || $0.role == "Study" || $0.role == "Mode" })?.index
            let devIndex = semanticElements.first(where: { $0.role == "legend" || $0.role == "Device ID" || $0.role == "Library" })?.index
            let rule = CategoryRule(
                delimiters: editor.tokenDelimiters,
                categoryIndex: catIndex,
                deviceIndex: devIndex,
                elements: semanticElements
            )
            try CategoryRuleEngine.save(rules: rule, project: project)

            // Auto-pin reference example file to .rawviewer/instrument/examples/
            if let current = selectedSource {
                let id = editor.instrumentID.trimmingCharacters(in: .whitespaces).isEmpty
                    ? current.url.deletingPathExtension().lastPathComponent
                    : editor.instrumentID.trimmingCharacters(in: .whitespaces)
                let ext = current.url.pathExtension
                let examplesDir = project.root.appendingPathComponent(".rawviewer/instrument/examples", isDirectory: true)
                try? FileManager.default.createDirectory(at: examplesDir, withIntermediateDirectories: true)
                let destURL = examplesDir.appendingPathComponent("\(id)-example.\(ext)")
                if let data = try? Data(contentsOf: current.url) {
                    try? data.write(to: destURL, options: .atomic)
                }
            }

            refreshSavedProfiles()
            saveStatusMessage = "Saved profile (\(savedFile.lastPathComponent)) & rules."
        } catch {
            saveStatusMessage = "Save error: \(error.localizedDescription)"
        }
    }

    func applyCustomStructure(delimiter: String, decimalSeparator: String, headerLine: Int?, dataStartLine: Int, skippedMetadataLines: Set<Int> = []) {
        editor.delimiter = delimiter
        editor.decimalDelimiter = decimalSeparator
        editor.lineTags.removeAll()

        let lines = editor.lines
        let sep = delimiter == "\\t" ? "\t" : delimiter

        // 1. Tag headers if specified
        if let hLine = headerLine, hLine > 0, (hLine - 1) < lines.count {
            let hIdx = hLine - 1
            editor.lineTags[hIdx] = .columnHeaders
            let tokens = lines[hIdx].components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var newCols: [ColumnDefinition] = []
            var hasX = false
            for (idx, token) in tokens.enumerated() {
                var name = token
                var unit = ""
                if let parenStart = token.firstIndex(of: "("), let parenEnd = token.firstIndex(of: ")"), parenStart < parenEnd {
                    name = String(token[..<parenStart]).trimmingCharacters(in: .whitespaces)
                    unit = String(token[token.index(after: parenStart)..<parenEnd]).trimmingCharacters(in: .whitespaces)
                } else if let bStart = token.firstIndex(of: "["), let bEnd = token.firstIndex(of: "]"), bStart < bEnd {
                    name = String(token[..<bStart]).trimmingCharacters(in: .whitespaces)
                    unit = String(token[token.index(after: bStart)..<bEnd]).trimmingCharacters(in: .whitespaces)
                }
                let isX = !hasX && (name.localizedCaseInsensitiveContains("time") || name.localizedCaseInsensitiveContains("volt") || name.localizedCaseInsensitiveContains("potential") || idx == 0)
                if isX { hasX = true }
                newCols.append(ColumnDefinition(
                    name: token,
                    label: name,
                    quantity: "generic",
                    unit: unit,
                    isXAxis: isX,
                    isYAxis: !isX && idx == 1
                ))
            }
            editor.columns = newCols
        }

        // 2. Set boundaries directly (O(1) instead of 41,000 dictionary insertions)
        let startIdx = max(0, dataStartLine - 1)
        editor.headerLineIndex = headerLine.map { $0 - 1 }
        editor.dataStartLineIndex = startIdx
        editor.skippedMetadataLines = skippedMetadataLines
        editor.lineTags.removeAll()
        if let h = editor.headerLineIndex {
            editor.lineTags[h] = .columnHeaders
        }
        editor.lineTags[startIdx] = .dataMatrix

        self.sandboxXCol = editor.columns.first(where: { $0.isXAxis })?.name
        self.sandboxYCol = editor.columns.first(where: { $0.isYAxis })?.name
        let skippedCount = skippedMetadataLines.count
        self.saveStatusMessage = "Applied parser structure (delim: '\(delimiter)', header L\(headerLine.map { "\($0)" } ?? "none"), data L\(dataStartLine)\(skippedCount > 0 ? ", \(skippedCount) skipped" : ""))"
        objectWillChange.send()
    }
}
