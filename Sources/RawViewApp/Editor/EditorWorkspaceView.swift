import SwiftUI
import RawViewCore

/// Clean high-level container shell assembling Profile Studio:
/// - Left Panel: `EditorLeftSidebarView` (Active Target File card, Profile Identity, Saved Profiles list, Import YAML, Test Cohort & Build Action)
/// - Right Panel: `EditorCenterCanvasView` (3 Dedicated Tabs: Filename Tokens | Raw Stream Studio | Live Sandbox Studio)
public struct EditorWorkspaceView: View {
    public let project: ProjectContext
    public let sources: [RawSource]
    public var initialSelectedSource: RawSource? = nil

    public enum StudioTab: String, CaseIterable, Identifiable {
        case tokens = "Filename Tokens"
        case rawStream = "Raw Stream Studio"
        case liveSandbox = "Live Sandbox Studio"
        public var id: String { rawValue }
    }

    @StateObject private var model = EditorWorkspaceViewModel()
    @State private var selectedStudioTab: StudioTab = .rawStream

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
            // Panel 1 (Left): Profile Specification (Active Sample, Identity, Saved Profiles, Build Actions)
            EditorLeftSidebarView(model: model, sources: sources)
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
                .frame(maxHeight: .infinity)

            // Panel 2 (Right): Full-width 3-Tab Interactive Workspace
            EditorCenterCanvasView(model: model, selectedStudioTab: $selectedStudioTab)
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
}
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

    // MARK: - Grammar Engine State
    @Published var grammarCatalog: FilenameGrammarCatalog = FilenameGrammarCatalog(grammars: FilenameGrammarCatalog.standardDefaults, activeGrammarID: "autolab-scientific")
    @Published var activeGrammarID: String = "autolab-scientific"
    @Published var activeTemplate: String = "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]"
    @Published var sampleExtractedFacts: ExtractedGrammarFacts = ExtractedGrammarFacts(isMatched: false)
    @Published var grammarMatchError: String? = nil

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
        loadGrammarCatalog()
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
            recalculateGrammarExtraction()
        } catch {
            saveStatusMessage = "Error loading sample: \(error.localizedDescription)"
        }
    }

    // MARK: - Grammar Catalog & Pattern Matching Actions

    func loadGrammarCatalog() {
        guard let project = project else { return }
        if let loaded = FilenameGrammarEngine.load(project: project) {
            self.grammarCatalog = loaded
            if let activeID = loaded.activeGrammarID, let match = loaded.grammars.first(where: { $0.id == activeID }) {
                self.activeGrammarID = match.id
                self.activeTemplate = match.template
            } else if let first = loaded.grammars.first {
                self.activeGrammarID = first.id
                self.activeTemplate = first.template
            }
        } else {
            self.grammarCatalog = FilenameGrammarCatalog(grammars: FilenameGrammarCatalog.standardDefaults, activeGrammarID: "autolab-scientific")
            if let first = grammarCatalog.grammars.first {
                self.activeGrammarID = first.id
                self.activeTemplate = first.template
            }
        }
        recalculateGrammarExtraction()
    }

    func saveGrammarCatalog() {
        guard let project = project else { return }
        syncCurrentTemplateToCatalog()
        grammarCatalog.activeGrammarID = activeGrammarID
        do {
            try FilenameGrammarEngine.save(catalog: grammarCatalog, project: project)
            saveStatusMessage = "Saved grammar catalog (.rawviewer/view/grammar.yaml)"
        } catch {
            saveStatusMessage = "Grammar save error: \(error.localizedDescription)"
        }
    }

    func syncCurrentTemplateToCatalog() {
        guard let idx = grammarCatalog.grammars.firstIndex(where: { $0.id == activeGrammarID }) else { return }
        grammarCatalog.grammars[idx].template = activeTemplate
    }

    func selectGrammar(id: String) {
        activeGrammarID = id
        grammarCatalog.activeGrammarID = id
        if let match = grammarCatalog.grammars.first(where: { $0.id == id }) {
            activeTemplate = match.template
        }
        recalculateGrammarExtraction()
        objectWillChange.send()
    }

    func addNewGrammar(name: String = "New Pattern", template: String = "{date}_{study}_{device-id}") {
        let newID = UUID().uuidString.prefix(8).lowercased()
        let newGrammar = FilenameGrammar(
            id: String(newID),
            name: name,
            template: template,
            fields: [
                GrammarField(name: "date", role: "Date & Time"),
                GrammarField(name: "study", role: "Study"),
                GrammarField(name: "device-id", role: "Device ID")
            ],
            isDefault: false
        )
        grammarCatalog.grammars.append(newGrammar)
        selectGrammar(id: newGrammar.id)
    }

    func updateActiveTemplate(_ newTemplate: String) {
        activeTemplate = newTemplate
        syncCurrentTemplateToCatalog()
        recalculateGrammarExtraction()
        objectWillChange.send()
    }

    func updateGrammarField(name: String, role: String, formatHint: String = "", stripBrackets: Bool = false) {
        guard let gIdx = grammarCatalog.grammars.firstIndex(where: { $0.id == activeGrammarID }) else { return }
        if let fIdx = grammarCatalog.grammars[gIdx].fields.firstIndex(where: { $0.name == name }) {
            grammarCatalog.grammars[gIdx].fields[fIdx].role = role
            grammarCatalog.grammars[gIdx].fields[fIdx].formatHint = formatHint
            grammarCatalog.grammars[gIdx].fields[fIdx].stripBrackets = stripBrackets
        } else {
            grammarCatalog.grammars[gIdx].fields.append(GrammarField(name: name, role: role, formatHint: formatHint, stripBrackets: stripBrackets))
        }
        recalculateGrammarExtraction()
        objectWillChange.send()
    }

    func recalculateGrammarExtraction() {
        guard let source = selectedSource else {
            sampleExtractedFacts = ExtractedGrammarFacts(isMatched: false)
            grammarMatchError = nil
            return
        }

        let filename = source.url.lastPathComponent
        guard let activeGrammar = grammarCatalog.grammars.first(where: { $0.id == activeGrammarID }) else {
            sampleExtractedFacts = ExtractedGrammarFacts(isMatched: false)
            grammarMatchError = "No active grammar selected"
            return
        }

        var effective = activeGrammar
        effective.template = activeTemplate

        do {
            let (_, names) = try FilenameGrammarEngine.compile(template: activeTemplate)
            for name in names {
                if !effective.fields.contains(where: { $0.name == name }) {
                    let role = name.lowercased().contains("date") ? "Date & Time" :
                               name.lowercased().contains("device") ? "Device ID" :
                               name.lowercased().contains("instrument") ? "Instrument" :
                               name.lowercased().contains("mode") ? "Mode" :
                               name.lowercased().contains("study") ? "Study" : "Remarks"
                    effective.fields.append(GrammarField(name: name, role: role))
                }
            }
            if let idx = grammarCatalog.grammars.firstIndex(where: { $0.id == activeGrammarID }) {
                grammarCatalog.grammars[idx].fields = effective.fields
            }
            grammarMatchError = nil
        } catch {
            grammarMatchError = error.localizedDescription
            sampleExtractedFacts = ExtractedGrammarFacts(isMatched: false, unmatchedReason: error.localizedDescription)
            return
        }

        sampleExtractedFacts = FilenameGrammarEngine.extract(from: filename, grammar: effective)
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

            // Save grammar catalog to .rawviewer/view/grammar.yaml
            saveGrammarCatalog()

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