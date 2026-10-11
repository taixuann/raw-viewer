import SwiftUI
import RawViewCore

/// Clean high-level container shell assembling Profile Studio panels:
/// - Left Sidebar: `EditorLeftSidebarView` (Active Target File card, Saved Profiles library, Import YAML)
/// - Center Canvas: `EditorCenterCanvasView` (CanvasMode switcher, 50:50 table/live plot split)
/// - Right Inspector: `EditorRightInspectorView` (SpecTab switcher, Identity, Token rules, Column roles, Build action)
public struct EditorWorkspaceView: View {
    public let project: ProjectContext
    public let sources: [RawSource]
    public var initialSelectedSource: RawSource? = nil

    public enum SpecTab: String, CaseIterable, Identifiable {
        case identity = "Identity & Roles"
        case tokens = "Filename Tokens"
        case library = "Columns List"
        public var id: String { rawValue }
    }

    public enum StudioTab: String, CaseIterable, Identifiable {
        case rawStream = "Raw Stream Studio"
        case liveSandbox = "Live Sandbox Studio"
        public var id: String { rawValue }
    }

    @StateObject private var model = EditorWorkspaceViewModel()
    @State private var canvasMode: CanvasMode = .stream
    @State private var selectedSpecTab: SpecTab = .identity
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    public init(
        project: ProjectContext,
        sources: [RawSource],
        initialSelectedSource: RawSource? = nil
    ) {
        self.project = project
        self.sources = sources
        self.initialSelectedSource = initialSelectedSource
    }

    public var body: some View {
        HSplitView {
            // Panel 1 (Left): Active Target File & Saved Profiles Library
            EditorLeftSidebarView(model: model, sources: sources)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                .frame(maxHeight: .infinity)

            // Panel 2 (Center): Interactive Visual Studio (Dual Table & Live Plot Split)
            EditorCenterCanvasView(model: model, canvasMode: $canvasMode)
                .frame(minWidth: 460)
                .frame(maxHeight: .infinity)

            // Panel 3 (Right): Instrument Specification, Token Rules & Column Roles
            EditorRightInspectorView(model: model, selectedSpecTab: $selectedSpecTab)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
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
}

// MARK: - ViewModel & Subviews
@MainActor
public final class EditorWorkspaceViewModel: ObservableObject {
    @Published public var project: ProjectContext?
    @Published public var sources: [RawSource] = []
    @Published public var selectedSource: RawSource?
    @Published public var editor = EditorWorkspaceModel()
    @Published public var selectedLineRange: ClosedRange<Int>?

    @Published public var tokens: [String] = []
    @Published public var semanticElements: [SemanticTokenElement] = []
    @Published public var categoryTokenIndex: Int? {
        didSet { updateSiblingPreviews() }
    }
    @Published public var deviceTokenIndex: Int? {
        didSet { updateSiblingPreviews() }
    }

    @Published public var savedProfiles: [URL] = []
    @Published public var sandboxXCol: String?
    @Published public var sandboxYCol: String?

    @Published public var cohortTestResult: String?
    @Published public var cohortTestSuccess: Bool = false
    @Published public var saveStatusMessage: String?

    public struct SiblingPreview: Identifiable {
        public var id: String { filename }
        public let filename: String
        public let category: String?
        public let device: String?
    }

    @Published public var siblingPreviews: [SiblingPreview] = []

    private var isInitialized = false

    public func setup(project: ProjectContext, sources: [RawSource], initialSource: RawSource? = nil) {
        guard !isInitialized || self.project?.root != project.root else { return }
        isInitialized = true
        self.project = project
        self.sources = sources
        refreshSavedProfiles()
        if let initial = initialSource ?? sources.first {
            selectSource(initial)
        }
    }

    public func refreshSavedProfiles() {
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

    public func importProfile() {
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

    public func loadSavedProfile(url: URL) {
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

    public func syncDefaultPlotChannels() {
        if let primaryX = editor.primaryXColumn {
            self.sandboxXCol = primaryX.name
        }
        if let primaryY = editor.primaryYColumn {
            self.sandboxYCol = primaryY.name
        }
    }

    public func loadRepresentativeSampleForProfile(profileURL: URL) {
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

    public func pinCurrentAsExample() {
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

    public func syncSemanticElementsFromTokens() {
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

    public func addElement(token: String = "", role: String = "Remarks", tagName: String = "", formatHint: String = "") {
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

    public func removeElement(id: UUID) {
        semanticElements.removeAll(where: { $0.id == id })
        for i in 0..<semanticElements.count {
            semanticElements[i].index = i
        }
        updateSiblingPreviews()
        objectWillChange.send()
    }

    public func clearAllElements() {
        semanticElements.removeAll()
        updateSiblingPreviews()
        objectWillChange.send()
    }

    public func selectSource(_ source: RawSource, preserveProfile: Bool = false) {
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

    public func runAutoDetect() {
        editor.smartAutoDetect()
        syncDefaultPlotChannels()
        objectWillChange.send()
    }

    public func updateColumn(index: Int, column: ColumnDefinition) {
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

    public func tagMetadataCell(_ tag: MetadataCellTag) {
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

    public func removeMetadataTag(lineIndex: Int, tokenIndex: Int) {
        editor.removeMetadataCellTag(lineIndex: lineIndex, tokenIndex: tokenIndex)
        objectWillChange.send()
    }

    public func tagRange(range: ClosedRange<Int>, tag: LineRegionType) {
        editor.tagRange(from: range.lowerBound, to: range.upperBound, as: tag)
        objectWillChange.send()
    }

    public func updateSiblingPreviews() {
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

    public func testAgainstCohort() {
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

    public func saveProfileAndRules() {
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

    public func applyCustomStructure(delimiter: String, decimalSeparator: String, headerLine: Int?, dataStartLine: Int, skippedMetadataLines: Set<Int> = []) {
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
