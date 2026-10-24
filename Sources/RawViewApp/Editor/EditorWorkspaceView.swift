import CryptoKit
import SwiftUI
import RawViewCore

/// Clean high-level container shell assembling Profile Studio:
/// - Shared Header: `EditorCenterCanvasView` (document bar + 4 Dedicated Tabs:
///   Raw Stream Studio | Live Sandbox Studio | Filename Grammar | Profile YAML).
///   The left sidebar file stays intact as reference only and is never mounted.
public struct EditorWorkspaceView: View {
    public let project: ProjectContext
    public let sources: [RawSource]
    public var initialSelectedSource: RawSource? = nil
    public var developerMode: Bool = false

    public enum StudioTab: String, CaseIterable, Identifiable {
        case rawStream = "Raw Stream Studio"
        case liveSandbox = "Live Sandbox Studio"
        case tokens = "Filename Grammar"
        case profileYAML = "Profile YAML"
        public var id: String { rawValue }
    }

    @StateObject private var model = EditorWorkspaceViewModel()

    public init(
        project: ProjectContext,
        sources: [RawSource],
        initialSelectedSource: RawSource? = nil,
        developerMode: Bool = false
    ) {
        self.project = project
        self.sources = sources
        self.initialSelectedSource = initialSelectedSource
        self.developerMode = developerMode
    }

    /// Tabs that fit the current mode; Profile YAML is Developer Mode only.
    private var availableTabs: [StudioTab] {
        developerMode ? StudioTab.allCases : [.rawStream, .liveSandbox, .tokens]
    }

    public var body: some View {
        // Draft state (StateObject model) lives above all conditional mounting,
        // so tab switches never drop in-memory variant drafts.
        // Task 3: full-width canvas; the sidebar stays unmounted (reference only).
        EditorCenterCanvasView(model: model, selectedStudioTab: $model.selectedStudioTab, availableTabs: availableTabs, sources: sources)
            .frame(minWidth: 500)
            .frame(maxHeight: .infinity)
        // One focused-window Save target: header focus never retargets it.
        .focusedSceneValue(\.editorSaveAction, { model.saveFocusedDocument(tab: model.selectedStudioTab) })
        .background(EditorCloseGuard { model.requestWindowClose() })
        .alert("Unsaved profile changes", isPresented: $model.showDirtyConfirm) {
            Button("Save") { model.confirmSaveAndContinue() }
            Button("Discard", role: .destructive) { model.confirmDiscardAndContinue() }
            Button("Cancel", role: .cancel) { model.cancelTransition() }
        } message: {
            Text("Save the whole profile document, discard the draft, or cancel and keep editing.")
        }
        .onAppear {
            model.developerMode = developerMode
            model.setup(project: project, sources: sources, initialSource: initialSelectedSource)
        }
        .onChange(of: developerMode) { _, newValue in
            // Disabling with a dirty draft keeps the draft guarded (close,
            // quit and document switches still confirm); it only hides tabs.
            model.developerMode = newValue
            if !newValue && model.selectedStudioTab == .profileYAML {
                model.selectedStudioTab = .rawStream
            }
        }
        .onChange(of: initialSelectedSource) { _, newSource in
            if let newSource = newSource {
                // Guarded (M2): workspace-driven sample swaps confirm first,
                // preserving the established reset semantics on continue.
                model.requestSampleSwitch(to: newSource, preserveProfile: false)
            }
        }
    }
}

// MARK: - Task 6: window-close interception for dirty workspaces.

/// Installs a close-guard delegate proxy on the hosting window. All other
/// delegate behavior forwards to SwiftUI's original delegate untouched.
private struct EditorCloseGuard: NSViewRepresentable {
    var onShouldClose: () -> Bool

    func makeCoordinator() -> EditorCloseGuardCoordinator {
        EditorCloseGuardCoordinator()
    }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        let proxy = context.coordinator.proxy
        if (window.delegate as? EditorCloseProxy) !== proxy {
            proxy.original = window.delegate
            proxy.onShouldClose = onShouldClose
            window.delegate = proxy
        } else {
            proxy.onShouldClose = onShouldClose
        }
    }
}

private final class EditorCloseGuardCoordinator {
    let proxy = EditorCloseProxy()
}

private final class EditorCloseProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    var onShouldClose: (() -> Bool)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onShouldClose?() ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(windowShouldClose(_:)) { return true }
        return original?.responds(to: aSelector) ?? super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if aSelector == #selector(windowShouldClose(_:)) { return nil }
        return original
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
    /// Editor discovery rejects: never selectable, never lenient-loaded.
    /// The files stay untouched; `reason` is the actual parse/validation
    /// failure behind the excluded-count diagnostic and import errors.
    @Published var excludedProfiles: [EditorExcludedProfile] = []
    @Published var sandboxXCol: String?
    @Published var sandboxYCol: String?

    @Published var cohortTestResult: String?
    @Published var cohortTestSuccess: Bool = false
    @Published var saveStatusMessage: String?
    // MARK: - Task 3: guarded transitions (dirty Save/Discard/Cancel)
    @Published var showDirtyConfirm = false
    var pendingProfileURL: URL? = nil
    var pendingSource: RawSource? = nil
    var pendingPreserveProfile: Bool = true

    // MARK: - Grammar Engine State
    @Published var grammarCatalog: FilenameGrammarCatalog = FilenameGrammarCatalog(grammars: FilenameGrammarCatalog.standardDefaults, activeGrammarID: "standard-scientific")
    @Published var activeGrammarID: String = "standard-scientific" {
        didSet {
            guard activeGrammarID != oldValue else { return }
            selectGrammar(id: activeGrammarID)
        }
    }
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
        // Task 6: per-window quit/close guard through the shared tracker.
        EditorDirtyTracker.shared.register(
            self,
            label: "profile \(project.root.lastPathComponent)",
            hasWork: { [weak self] in self?.hasUnsavedWork ?? false },
            save: { [weak self] in self?.saveForTermination() ?? true })
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

        self.savedProfiles = []
        self.excludedProfiles = []
        let sorted = collectedURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        // Strict v3-only discovery: a saved profile must parse as schema v3
        // AND validate against the current catalog. Anything else is an
        // excluded diagnostic, never a selectable entry. Originals untouched.
        for file in sorted {
            let name = file.lastPathComponent
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                excludedProfiles.append(EditorExcludedProfile(
                    fileName: name, reason: "unreadable file; skipped."))
                continue
            }
            if let miss = EditorProfileDiscovery.classify(
                fileName: name, text: text, catalog: grammarCatalog) {
                excludedProfiles.append(miss)
            } else {
                savedProfiles.append(file)
            }
        }
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

                // Strict import: incompatible files are rejected with the
                // actual reason. The just-written copy is removed; the
                // source original is never touched.
                if let miss = EditorProfileDiscovery.classify(
                    fileName: selectedURL.lastPathComponent, text: content,
                    catalog: grammarCatalog) {
                    try? FileManager.default.removeItem(at: destURL)
                    refreshSavedProfiles()
                    saveStatusMessage = "Import rejected: '\(selectedURL.lastPathComponent)' \(miss.reason) Original unchanged."
                    return
                }

                refreshSavedProfiles()
                // Refresh-first (M1/M2): stage binding writes before trusting the flag.
                if hasUnsavedWork {
                    // Never trap or silently drop the draft: confirm first.
                    pendingProfileURL = destURL
                    pendingSource = nil
                    showDirtyConfirm = true
                    return
                }
                loadSavedProfile(url: destURL)
                saveStatusMessage = "Imported & loaded: \(selectedURL.lastPathComponent)"
            } catch {
                saveStatusMessage = "Import error: \(error.localizedDescription)"
            }
        }
    }

    func loadSavedProfile(url: URL) {
        // Stage-then-confirm (M2): never silently replace a dirty document.
        // Confirmed continuations call forceLoadSavedProfile directly.
        editor.stageCurrentVariantEdits()
        if editor.profileDirty || profileYAMLDirty || grammarYAMLDirty {
            pendingProfileURL = url
            pendingSource = nil
            pendingVariantID = nil
            showDirtyConfirm = true
            return
        }
        forceLoadSavedProfile(url: url)
    }

    private func forceLoadSavedProfile(url: URL) {
        // A new document resets the source drafts; the tabs reload lazily.
        profileYAMLLoadedID = nil
        profileYAMLBaseline = nil
        profileYAMLFileBaseline = nil
        profileYAMLText = ""
        profileYAMLDiagnostic = nil
        appliedProfileDoc = nil
        loadedProfileURL = url
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Strict v3-only load: the file must parse as schema v3 and
            // validate against the current catalog. Anything else is
            // rejected with the actual reason; no lenient legacy fallback.
            let document: ProfileDocumentV3
            do {
                document = try ProfileDocumentV3.parse(text: text)
                try document.validate(catalog: grammarCatalog)
            } catch {
                self.saveStatusMessage = "Profile error: '\(url.lastPathComponent)' \(error.localizedDescription) Not loaded."
                return
            }
            do {
                editor.applyProfileDocument(document, selectedVariantID: nil)
                // Baseline is the exact bytes on disk (comments preserved),
                // not the re-serialization, so the first visual save succeeds.
                editor.rebaseSaveBaseline(to: text)
                self.tokens = editor.tokens
                syncSemanticElementsFromTokens()
                syncDefaultPlotChannels()
                self.saveStatusMessage = "Loaded profile '\(document.profileName)' (\(document.variants.count) variants)"
                updateSiblingPreviews()
                loadRepresentativeSampleForProfile(profileURL: url)
                refreshPreviewMatch()
                objectWillChange.send()
                return
            }
        } catch {
            self.saveStatusMessage = "Failed to load profile: \(error.localizedDescription)"
        }
    }

    /// +New with no loaded document: one blank v3 variant from the live
    /// sample parse. Loaded + dirty, never a disk write; the first save
    /// creates the file through the normal validated save path.
    func createBlankProfileFromSample(newID: String, newName: String) {
        let cleanID = newID.trimmingCharacters(in: .whitespaces)
        let cleanName = newName.trimmingCharacters(in: .whitespaces)
        let display = cleanName.isEmpty ? cleanID.capitalized : cleanName
        // ponytail: filename evidence is the sample stem when selected; content markers are user edits.
        var match: VariantMatchV3? = nil
        if let stem = selectedSource?.url.deletingPathExtension().lastPathComponent, !stem.isEmpty {
            match = VariantMatchV3(filenameContainsAll: [stem], contentContainsAny: nil)
        }
        do {
            try editor.newDocumentFromSample(
                profileID: cleanID, profileName: display,
                grammarID: activeGrammarID, match: match, catalog: grammarCatalog)
            syncDefaultPlotChannels()
            refreshPreviewMatch()
            saveStatusMessage = "Created blank profile '\(display)' from the current sample (unsaved)."
        } catch {
            saveStatusMessage = "New profile error: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    // MARK: - Task 3: variant-aware document lifecycle

    var profileDirty: Bool { editor.profileDirty }
    var hasProfileDocument: Bool { editor.profileDocument != nil }
    var variantIDs: [String] { editor.profileDocument?.variants.map(\.id) ?? [] }
    var selectedVariantID: String? { editor.selectedVariantID }
    var profileDisplayName: String {
        guard let doc = editor.profileDocument else { return "" }
        return doc.profileName.isEmpty ? doc.profileID : doc.profileName
    }
    var variantKeys: [String] { editor.profileDocument?.variantKeys ?? [] }
    /// Live settings references for rename guards: Explorer views and
    /// source-label rows load from the project settings file. A missing
    /// file means no settings references; corrupt settings surface at
    /// their own save/load gates, never here.
    var settingsExplorerViews: [ExplorerViewDefinition] {
        guard let root = project?.root,
              let settings = try? ProjectSettingsStore.load(projectRoot: root) else { return [] }
        return settings.explorerViews
    }
    var settingsSourceLabels: [SourceLabelLayout] {
        guard let root = project?.root,
              let settings = try? ProjectSettingsStore.load(projectRoot: root) else { return [] }
        return settings.sourceLabels
    }
    var profileGrammarID: String? { editor.profileDocument?.grammarID }
    var isProfileGrammarActive: Bool {
        guard let gid = editor.profileDocument?.grammarID else { return false }
        return gid == activeGrammarID
    }

    // MARK: - Task 7: variant switches happen through the sample-matched
    // flow; the explicit Variant picker, Add/Duplicate variant, Duplicate
    // Profile, and Keys value-entry UI are removed. The editor model keeps
    // selectVariant/duplicateCurrentVariant/duplicateProfile tested (see
    // ProfileDocumentV3Tests) but unreferenced from UI.

    /// Required-only key eligibility, scoped to the active profile's grammar.
    func isVariantKeyFieldEnabled(name: String) -> Bool {
        guard editor.profileDocument != nil, isProfileGrammarActive else { return false }
        guard let field = grammarCatalog.grammars
            .first(where: { $0.id == activeGrammarID })?.fields.first(where: { $0.name == name })
        else { return false }
        return !field.isOptional
    }

    /// Variant Key toggles persist in the profile YAML only, never the grammar.
    /// Task 7: enabling a key immediately autofills its value read-only from
    /// the current sample's extracted fields (the save-after-grammar fix).
    func setVariantKey(name: String, enabled: Bool) {
        do {
            try editor.setVariantKeyEnabled(name, enabled: enabled)
            if enabled {
                editor.autofillSelectedVariantKeyValues(
                    from: sampleExtractedFacts.extractedFields,
                    isMatched: sampleExtractedFacts.isMatched)
            }
            saveStatusMessage = enabled
                ? "Routing key '\(name)' added; fill values for every variant before saving."
                : "Routing key '\(name)' removed."
        } catch {
            saveStatusMessage = "Routing key error: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func useActiveGrammarForProfile() {
        guard editor.profileDocument != nil else { return }
        editor.rebindProfile(grammarID: activeGrammarID)
        saveStatusMessage = "Profile rebound to grammar '\(activeGrammarID)'; review routing keys for every variant."
        objectWillChange.send()
    }

    // Selected-variant Matching & Layout accessors for the Raw Stream Studio.
    var selectedVariantRows: RowLocatorsV3? { editor.selectedVariant?.rawStream.rows }
    var selectedVariantMatch: VariantMatchV3? { editor.selectedVariant?.match }
    var selectedVariantExtensions: [String] { editor.selectedVariant?.rawStream.extensions ?? [] }
    var selectedVariantEncodings: [String] { editor.selectedVariant?.rawStream.encodings ?? [] }
    var selectedVariantColumns: [ProfileColumnV3] { editor.selectedVariant?.rawStream.columns ?? [] }

    func setVariantHeader(_ header: HeaderLocatorV3) {
        do { try editor.updateSelectedVariant { $0.rawStream.rows.header = header } }
        catch { saveStatusMessage = "Layout error: \(error.localizedDescription)" }
        objectWillChange.send()
    }

    func setVariantDataStart(_ dataStart: DataStartV3) {
        do { try editor.updateSelectedVariant { $0.rawStream.rows.dataStart = dataStart } }
        catch { saveStatusMessage = "Layout error: \(error.localizedDescription)" }
        objectWillChange.send()
    }

    func setVariantPrefixes(dataPrefix: String?, commentPrefix: String?) {
        do {
            try editor.updateSelectedVariant {
                $0.rawStream.rows.dataPrefix = dataPrefix
                $0.rawStream.rows.commentPrefix = commentPrefix
            }
        } catch { saveStatusMessage = "Layout error: \(error.localizedDescription)" }
        objectWillChange.send()
    }

    func setVariantStream(extensions: [String], encodings: [String]) {
        do {
            try editor.updateSelectedVariant {
                $0.rawStream.extensions = extensions
                $0.rawStream.encodings = encodings
            }
        } catch { saveStatusMessage = "Layout error: \(error.localizedDescription)" }
        objectWillChange.send()
    }

    func setVariantMatch(filenameContainsAll: [String]?, contentContainsAny: [String]?) {
        do {
            try editor.updateSelectedVariant {
                if filenameContainsAll == nil && contentContainsAny == nil {
                    $0.match = nil
                } else {
                    $0.match = VariantMatchV3(
                        filenameContainsAll: filenameContainsAll,
                        contentContainsAny: contentContainsAny)
                }
            }
        } catch { saveStatusMessage = "Layout error: \(error.localizedDescription)" }
        objectWillChange.send()
    }

    func setVariantExcludedMetadata(_ rows: [Int]) {
        do { try editor.updateSelectedVariant { $0.rawStream.rows.excludedMetadata = rows } }
        catch { saveStatusMessage = "Layout error: \(error.localizedDescription)" }
        objectWillChange.send()
    }

    /// Sandbox axis choices stay preview-only until this explicit action,
    /// which replaces the complete default list on the selected variant only.
    func useSandboxAsProfileDefaults() {
        guard let x = sandboxXCol, let y = sandboxYCol else {
            saveStatusMessage = "Pick preview X and Y first; nothing applied."
            return
        }
        do {
            try editor.usePreviewAsDefaults(x: x, y: [y])
            syncDefaultPlotChannels()
            saveStatusMessage = "Profile defaults for '\(selectedVariantID ?? "variant")' set to X=\(x) Y=[\(y)]."
        } catch {
            saveStatusMessage = "Defaults error: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    /// Profile Save writes the whole document; failures leave files untouched.
    /// When the visual state still matches an applied YAML source, the exact
    /// draft bytes land on disk (comments preserved).
    func saveProfileDocument() {
        guard let project = project else { return }
        editor.stageCurrentVariantEdits()
        // Applied source still current on both sides: the exact draft bytes
        // (with comments) land on disk instead of a re-serialization.
        if profileYAMLTextForByteSave() != nil {
            saveProfileYAML()
            return
        }
        do {
            let url = try editor.saveDocument(project: project, catalog: grammarCatalog)
            refreshSavedProfiles()
            let count = editor.profileDocument?.variants.count ?? 0
            saveStatusMessage = "Saved profile \(url.lastPathComponent) (\(count) variants) to .rawviewer/instrument/."
            // Keep an open profile draft honest: clean rebases, dirty warns.
            if profileYAMLBaseline != nil, let bytes = try? String(contentsOf: url, encoding: .utf8) {
                profileYAMLFileBaseline = bytes
                if !profileYAMLDirty {
                    profileYAMLText = bytes
                    profileYAMLBaseline = bytes
                    profileYAMLPath = url.path
                    loadedProfileURL = url
                    profileYAMLLoadedID = "\(editor.profileDocument?.profileID ?? "")@\(url.path)"
                } else {
                    profileYAMLDiagnostic = "Profile saved from visual edits; this source is stale — Reload to continue from disk."
                }
            }
        } catch {
            // External-change blocks name their recovery; other failures
            // (validation) must not point at Reload.
            let recovery = error.localizedDescription.contains("changed on disk")
                ? " Reload from Disk to reconcile." : ""
            saveStatusMessage = "Save error: \(error.localizedDescription)\(recovery)"
        }
        objectWillChange.send()
    }

    /// The exact applied bytes, only when the visual document and the draft
    /// text both still equal the applied document (no divergence either way).
    private func profileYAMLTextForByteSave() -> String? {
        guard let snap = appliedProfileDoc,
              let current = try? editor.makeProfileDocument(), snap == current,
              let textDoc = try? ProfileDocumentV3.parse(text: profileYAMLText),
              (try? textDoc.validate(catalog: grammarCatalog)) != nil,
              textDoc == snap else { return nil }
        return profileYAMLText
    }

    // MARK: - Task 3: guarded transitions

    /// Unsaved work includes staged profile edits and source drafts:
    /// profile/sample transitions must confirm first, never silently strand
    /// the draft. Continuations keep upgrade state; only an explicit Cancel
    /// drops it.
    var hasUnsavedWork: Bool {
        editor.refreshDirtyFromStagedEdits()
            || profileYAMLDirty || grammarYAMLDirty
    }

    func requestProfileSwitch(to url: URL) {
        // Refresh-first (M1): stage binding writes before trusting the flag.
        if hasUnsavedWork {
            pendingProfileURL = url
            pendingSource = nil
            showDirtyConfirm = true
        } else {
            loadSavedProfile(url: url)
        }
    }

    func requestSampleSwitch(to source: RawSource, preserveProfile: Bool = true) {
        // Refresh-first (M1): stage binding writes before trusting the flag.
        if hasUnsavedWork {
            pendingSource = source
            pendingPreserveProfile = preserveProfile
            pendingProfileURL = nil
            showDirtyConfirm = true
        } else {
            selectSource(source, preserveProfile: preserveProfile)
        }
    }

    func confirmDiscardAndContinue() {
        showDirtyConfirm = false
        discardProfileYAML()
        discardGrammarYAML()
        if let url = pendingProfileURL {
            pendingProfileURL = nil
            pendingVariantID = nil
            forceLoadSavedProfile(url: url)
        } else if let source = pendingSource {
            pendingSource = nil
            pendingVariantID = nil
            let preserve = pendingPreserveProfile
            pendingPreserveProfile = true
            selectSource(source, preserveProfile: preserve)
        } else if let variant = pendingVariantID {
            pendingVariantID = nil
            editor.selectVariant(id: variant)
            syncDefaultPlotChannels()
            refreshPreviewMatch()
            objectWillChange.send()
        } else if pendingDelete != nil {
            // Drafts discarded; the destructive step still needs its
            // explicit target-naming confirmation before anything mutates.
            stageDeleteConfirmation()
        }
    }

    func confirmSaveAndContinue() {
        showDirtyConfirm = false
        // YAML drafts save through their validated byte-exact paths; a
        // failed save aborts the transition and keeps everything.
        if profileYAMLDirty {
            saveProfileYAML()
            guard !profileYAMLDirty else { return }
        } else if grammarYAMLDirty {
            saveGrammarYAML()
            guard !grammarYAMLDirty else { return }
        } else {
            saveProfileDocument()
        }
        guard !editor.profileDirty else { return } // Failed Save aborts the transition.
        if let url = pendingProfileURL {
            pendingProfileURL = nil
            pendingVariantID = nil
            forceLoadSavedProfile(url: url)
        } else if let source = pendingSource {
            pendingSource = nil
            pendingVariantID = nil
            let preserve = pendingPreserveProfile
            pendingPreserveProfile = true
            selectSource(source, preserveProfile: preserve)
        } else if let variant = pendingVariantID {
            pendingVariantID = nil
            editor.selectVariant(id: variant)
            syncDefaultPlotChannels()
            refreshPreviewMatch()
            objectWillChange.send()
        } else if pendingDelete != nil {
            // Saved cleanly; the destructive step still needs its explicit
            // target-naming confirmation before anything mutates.
            stageDeleteConfirmation()
        }
    }

    func cancelTransition() {
        showDirtyConfirm = false
        pendingProfileURL = nil
        pendingSource = nil
        pendingPreserveProfile = true
        pendingVariantID = nil
        pendingDelete = nil
    }

    // MARK: - Task 4: safe Delete Profile + Delete Grammar

    /// Destructive intent staged behind the dirty Save/Discard/Cancel gate.
    /// The dirty dialog never deletes: continuations only arm the explicit
    /// target-naming confirmation below.
    enum PendingDelete {
        case profile(URL)
        case grammar(String)
    }

    @Published var showDeleteConfirm = false
    @Published var deleteConfirmTitle = ""
    @Published var deleteConfirmMessage = ""
    var pendingDelete: PendingDelete? = nil

    /// The loaded profile is deletable only when it is a canonical
    /// project-owned file. Anything else disables Delete Profile.
    var canDeleteProfile: Bool {
        guard let url = loadedProfileURL else { return false }
        return isCanonicalProfileURL(url)
    }

    /// A grammar entry is deletable only when the active grammar exists in
    /// the catalog. An empty catalog disables Delete Grammar.
    var canDeleteGrammar: Bool {
        grammarCatalog.grammars.contains(where: { $0.id == activeGrammarID })
    }

    func requestDeleteProfile() {
        guard let url = loadedProfileURL, isCanonicalProfileURL(url) else {
            saveStatusMessage = "Delete error: no deletable project profile is selected."
            objectWillChange.send()
            return
        }
        editor.stageCurrentVariantEdits()
        pendingDelete = .profile(url)
        pendingProfileURL = nil
        pendingSource = nil
        pendingVariantID = nil
        if hasUnsavedWork {
            showDirtyConfirm = true
            return
        }
        stageDeleteConfirmation()
    }

    func requestDeleteGrammar() {
        guard grammarCatalog.grammars.contains(where: { $0.id == activeGrammarID }) else {
            saveStatusMessage = "Delete error: no deletable grammar is selected."
            objectWillChange.send()
            return
        }
        pendingDelete = .grammar(activeGrammarID)
        pendingProfileURL = nil
        pendingSource = nil
        pendingVariantID = nil
        if hasUnsavedWork {
            showDirtyConfirm = true
            return
        }
        stageDeleteConfirmation()
    }

    /// Arms the explicit confirmation naming the exact target. The pending
    /// intent survives; only Confirm or Cancel resolves it.
    func stageDeleteConfirmation() {
        guard let target = pendingDelete else { return }
        switch target {
        case .profile(let url):
            deleteConfirmTitle = "Delete Profile '\(url.lastPathComponent)'?"
            deleteConfirmMessage = "This permanently removes .rawviewer/instrument/\(url.lastPathComponent) from this project. This cannot be undone."
        case .grammar(let id):
            let name = grammarCatalog.grammars.first(where: { $0.id == id })?.name ?? id
            deleteConfirmTitle = "Delete Grammar '\(name)'?"
            deleteConfirmMessage = "This removes one entry from .rawviewer/grammar.yaml. Deletion is blocked while any profile, Explorer view, or source label still references it."
        }
        showDeleteConfirm = true
    }

    func confirmDelete() {
        showDeleteConfirm = false
        guard let target = pendingDelete else { return }
        pendingDelete = nil
        switch target {
        case .profile(let url): deleteProfileFile(at: url)
        case .grammar(let id): deleteGrammarEntry(id: id)
        }
    }

    func cancelDelete() {
        showDeleteConfirm = false
        pendingDelete = nil
    }

    /// Deletes one verified project-owned profile file. Any failure
    /// preserves the selection, drafts, and disk bytes. On success another
    /// valid v3 profile loads, or a cleared empty state remains that Cmd+S
    /// cannot resurrect (no document, no baselines, no file).
    private func deleteProfileFile(at url: URL) {
        guard let project else { return }
        let expected = (url == loadedProfileURL) ? profileYAMLFileBaseline?.data(using: .utf8) : nil
        do {
            try FilenameGrammarEngine.deleteVerifiedProfile(
                at: url, projectRoot: project.root, expectedBytes: expected)
        } catch {
            saveStatusMessage = "Delete error: \(error.localizedDescription) Nothing was deleted."
            objectWillChange.send()
            return
        }
        let name = url.lastPathComponent
        loadedProfileURL = nil
        editor.profileDocument = nil
        editor.selectedVariantID = nil
        // No document, no file: clear the Core baseline so a later save
        // cannot compare against a deleted file's bytes.
        editor.rebaseSaveBaseline(to: nil)
        profileYAMLText = ""
        profileYAMLBaseline = nil
        profileYAMLFileBaseline = nil
        profileYAMLLoadedID = nil
        profileYAMLPath = ""
        profileYAMLDiagnostic = nil
        appliedProfileDoc = nil
        previewMatch = .idle
        refreshSavedProfiles()
        if let next = savedProfiles.first {
            forceLoadSavedProfile(url: next)
            if editor.profileDocument != nil {
                saveStatusMessage = "Deleted profile '\(name)'."
            }
        } else {
            saveStatusMessage = "Deleted profile '\(name)'. No profiles remain."
        }
        syncDefaultPlotChannels()
        objectWillChange.send()
    }

    /// Removes one grammar entry (never grammar.yaml itself), blocked with
    /// dependents listed while referenced. Any failure preserves the
    /// in-memory catalog, drafts, and disk bytes. The final deletion
    /// persists an empty catalog with New available, never a recreation.
    private func deleteGrammarEntry(id: String) {
        guard let project else { return }
        let name = grammarCatalog.grammars.first(where: { $0.id == id })?.name ?? id
        let blockers: [String]
        do {
            blockers = try FilenameGrammarEngine.grammarDeleteBlockers(grammarID: id, projectRoot: project.root)
        } catch {
            saveStatusMessage = "Delete error: \(error.localizedDescription) Nothing was deleted."
            objectWillChange.send()
            return
        }
        var pending = blockers
        if editor.profileDocument?.grammarID == id {
            pending.append("open profile '\(editor.profileDocument?.profileName ?? id)' uses grammar '\(id)'")
        }
        guard pending.isEmpty else {
            saveStatusMessage = "Cannot delete grammar '\(name)'; still referenced by \(pending.joined(separator: ", "))."
            objectWillChange.send()
            return
        }
        var reduced = grammarCatalog
        reduced.grammars.removeAll(where: { $0.id == id })
        if reduced.activeGrammarID == id { reduced.activeGrammarID = nil }
        do {
            try FilenameGrammarEngine.save(catalog: reduced, project: project)
        } catch {
            saveStatusMessage = "Delete error: \(error.localizedDescription) Nothing was deleted."
            objectWillChange.send()
            return
        }
        let yamlWasOpen = grammarYAMLLoaded
        grammarCatalog = reduced
        if reduced.grammars.contains(where: { $0.id == activeGrammarID }) {
            // Selection survives; nothing to retarget.
        } else if let first = reduced.grammars.first {
            activeGrammarID = first.id
            activeTemplate = first.template
        } else {
            activeGrammarID = ""
            activeTemplate = ""
        }
        // Rebase or clear the grammar source draft so Cmd+S cannot
        // resurrect the deleted entry.
        if yamlWasOpen {
            grammarYAMLText = (try? FilenameGrammarEngine.serializedYAML(catalog: reduced)) ?? ""
            grammarYAMLBaseline = grammarYAMLText
            grammarFileBaseline = grammarYAMLText
            grammarCatalogSnapshot = reduced
            grammarYAMLLoadedID = "\(reduced.grammars.count)@\(activeGrammarID)"
        } else {
            grammarYAMLBaseline = nil
            grammarFileBaseline = nil
            grammarYAMLLoadedID = nil
            grammarCatalogSnapshot = nil
        }
        grammarYAMLDiagnostic = nil
        refreshSavedProfiles()
        recalculateGrammarExtraction()
        refreshPreviewMatch()
        saveStatusMessage = reduced.grammars.isEmpty
            ? "Deleted grammar '\(name)'. The catalog is now empty."
            : "Deleted grammar '\(name)'."
        objectWillChange.send()
    }

    // MARK: - Task 6: developer source drafts (exact bytes, apply is not save)

    @Published var developerMode = false
    @Published var grammarYAMLMode = false
    @Published var selectedStudioTab: EditorWorkspaceView.StudioTab = .rawStream
    var pendingVariantID: String? = nil

    // Profile YAML draft: the whole variants document as exact text.
    @Published var profileYAMLText = ""
    @Published var profileYAMLDiagnostic: String? = nil
    @Published var profileYAMLPath = ""
    @Published var profileYAMLReadOnly = false
    @Published var profileYAMLReadOnlyNote = ""
    @Published var loadedProfileURL: URL? = nil
    private var profileYAMLBaseline: String? = nil
    private var profileYAMLFileBaseline: String? = nil
    private var profileYAMLLoadedID: String? = nil
    /// Set by Apply: the document projected into the visual state.
    private var appliedProfileDoc: ProfileDocumentV3? = nil

    // Grammar YAML draft: the whole project catalog as exact text.
    @Published var grammarYAMLText = ""
    @Published var grammarYAMLDiagnostic: String? = nil
    @Published var grammarYAMLPath = ""
    private var grammarYAMLBaseline: String? = nil
    private var grammarFileBaseline: String? = nil
    private var grammarYAMLLoadedID: String? = nil
    /// Catalog revision the grammar draft was opened or applied from.
    private var grammarCatalogSnapshot: FilenameGrammarCatalog? = nil

    var profileYAMLLoaded: Bool { profileYAMLBaseline != nil }
    var grammarYAMLLoaded: Bool { grammarYAMLBaseline != nil }
    var profileYAMLDirty: Bool { profileYAMLBaseline != nil && profileYAMLText != profileYAMLBaseline }
    var grammarYAMLDirty: Bool { grammarYAMLBaseline != nil && grammarYAMLText != grammarYAMLBaseline }

    var profileYAMLStatus: String {
        if profileYAMLReadOnly { return "Read-only" }
        if profileYAMLDiagnostic != nil { return "Needs attention" }
        return profileYAMLDirty ? "Unsaved changes" : "Matches \(profileYAMLBaseline == nil ? "new document" : "disk")"
    }

    var grammarYAMLStatus: String {
        if grammarYAMLDiagnostic != nil { return "Needs attention" }
        return grammarYAMLDirty ? "Unsaved changes" : "Matches \(grammarYAMLBaseline == nil ? "current catalog" : "disk")"
    }

    private func canonicalProfileDir() -> URL? {
        project?.root.appendingPathComponent(".rawviewer/instrument", isDirectory: true)
    }

    private func isCanonicalProfileURL(_ url: URL) -> Bool {
        guard let dir = canonicalProfileDir() else { return false }
        return url.path.hasPrefix(dir.path + "/")
    }

    private func grammarFileURL() -> URL? {
        project?.root.appendingPathComponent(".rawviewer/grammar.yaml")
    }

    /// Loads the exact file bytes (or the staged serialization for unsaved
    /// documents) once per document; tab switches never clobber a draft.
    func openProfileYAML() {
        guard developerMode else { return }
        let id = editor.profileDocument.map { "\($0.profileID)@\(loadedProfileURL?.path ?? "unsaved")" } ?? "none"
        guard profileYAMLLoadedID != id else { return }
        profileYAMLLoadedID = id
        profileYAMLDiagnostic = nil
        appliedProfileDoc = nil
        if let url = loadedProfileURL, isCanonicalProfileURL(url),
           let bytes = try? String(contentsOf: url, encoding: .utf8) {
            profileYAMLText = bytes
            profileYAMLBaseline = bytes
            profileYAMLFileBaseline = bytes
            profileYAMLPath = url.path
            profileYAMLReadOnly = false
            profileYAMLReadOnlyNote = ""
            if editor.profileDirty {
                profileYAMLDiagnostic = "Unsaved visual edits exist; applying this source replaces them. Save the profile first to keep them."
            }
        } else if loadedProfileURL != nil && !isCanonicalProfileURL(loadedProfileURL!) {
            // Study imports stay read-only here; Import copies into
            // the canonical viewer-owned directory for editing.
            profileYAMLReadOnly = true
            profileYAMLReadOnlyNote = "Study sources are read-only here. Use Import YAML Profile… to copy this profile into .rawviewer/instrument/ for editing."
            profileYAMLPath = loadedProfileURL?.path ?? ""
            if let document = editor.profileDocument, let staged = try? document.serializedYAML() {
                profileYAMLText = staged
                profileYAMLBaseline = staged
            } else {
                profileYAMLText = ""
                profileYAMLBaseline = nil
            }
            profileYAMLFileBaseline = nil
        } else if let document = editor.profileDocument {
            editor.stageCurrentVariantEdits()
            if let snapshot = makeProfileDocumentSnapshot(),
               let staged = try? snapshot.serializedYAML() {
                profileYAMLText = staged
                profileYAMLBaseline = staged
                profileYAMLReadOnlyNote = ""
            } else {
                profileYAMLText = ""
                profileYAMLBaseline = nil
                profileYAMLReadOnlyNote = "The visual draft is incomplete and cannot seed the source view; resolve it or load a saved profile."
            }
            profileYAMLFileBaseline = nil
            profileYAMLPath = ".rawviewer/instrument/\(document.profileID).yaml (new file on save)"
            profileYAMLReadOnly = false
        } else {
            profileYAMLText = ""
            profileYAMLBaseline = nil
            profileYAMLFileBaseline = nil
            profileYAMLPath = ""
            profileYAMLReadOnly = false
            profileYAMLReadOnlyNote = "Load a profile before editing its source."
        }
    }

    /// Staged-document snapshot for YAML baselines: folds visual edits
    /// without trapping; nil when no document is loaded.
    private func makeProfileDocumentSnapshot() -> ProfileDocumentV3? {
        try? editor.makeProfileDocument()
    }

    /// Strict catalog-only parse of a draft string (via a temporary file),
    /// so Apply and Save share one validation path. Nil when invalid.
    private func catalogFromText(_ text: String) -> FilenameGrammarCatalog? {
        let draft = FileManager.default.temporaryDirectory
            .appendingPathComponent("grammar-draft-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: draft) }
        guard (try? text.write(to: draft, atomically: true, encoding: .utf8)) != nil else { return nil }
        return try? FilenameGrammarEngine.load(fileURL: draft)
    }

    /// Explicit Apply: a valid draft projects into the visual document.
    /// Apply is not save. An invalid draft stays intact with a diagnostic.
    func applyProfileYAML() {
        guard !profileYAMLReadOnly else { return }
        // A clean source never silently reverts unsaved visual edits; an
        // edited source is explicit intent and proceeds.
        editor.stageCurrentVariantEdits()
        if !profileYAMLDirty && editor.profileDirty {
            profileYAMLDiagnostic = "Unsaved visual edits exist; Save the profile first, or edit this source to replace them explicitly."
            objectWillChange.send()
            return
        }
        do {
            let document = try ProfileDocumentV3.parse(text: profileYAMLText)
            try document.validate(catalog: grammarCatalog)
            let keep = editor.selectedVariantID.flatMap { id in document.variants.contains(where: { $0.id == id }) ? id : nil }
            editor.applyProfileDocument(document, selectedVariantID: keep)
            appliedProfileDoc = document
            profileYAMLDiagnostic = nil
            syncDefaultPlotChannels()
            refreshPreviewMatch()
            saveStatusMessage = "Applied source to visual state (unsaved). Save to write it to disk."
        } catch {
            profileYAMLDiagnostic = "Invalid profile source — nothing applied: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    /// Source save: validates every variant first, refuses external
    /// rename/delete/change, then writes the exact draft bytes (comments
    /// preserved — never a re-serialization).
    func saveProfileYAML() {
        guard let project, !profileYAMLReadOnly else { return }
        let text = profileYAMLText
        let document: ProfileDocumentV3
        do {
            document = try ProfileDocumentV3.parse(text: text)
            try document.validate(catalog: grammarCatalog)
        } catch {
            profileYAMLDiagnostic = "Invalid profile source — nothing written: \(error.localizedDescription)"
            saveStatusMessage = "Save error: \(error.localizedDescription)"
            objectWillChange.send()
            return
        }
        // Independent visual edits must never be silently replaced: only a
        // visual state that still matches the applied source may byte-save.
        editor.stageCurrentVariantEdits()
        if editor.profileDirty {
            let matchesApplied: Bool = {
                guard let snap = appliedProfileDoc,
                      let current = try? editor.makeProfileDocument() else { return false }
                return snap == current
            }()
            if !matchesApplied {
                profileYAMLDiagnostic = "Unsaved visual edits diverge from this source; Apply the source to replace them explicitly, or save from the visual tab."
                saveStatusMessage = "Save error: visual edits diverge from the source draft."
                objectWillChange.send()
                return
            }
        }
        let dir = project.root.appendingPathComponent(".rawviewer/instrument", isDirectory: true)
        let file = dir.appendingPathComponent("\(document.profileID).yaml")
        let disk = try? String(contentsOf: file, encoding: .utf8)
        if let baseline = profileYAMLFileBaseline {
            if disk == nil {
                profileYAMLDiagnostic = "The profile file was deleted or renamed on disk; Reload from Disk to reconcile before saving."
                saveStatusMessage = "Save error: the profile file changed on disk."
                objectWillChange.send()
                return
            } else if disk != baseline {
                profileYAMLDiagnostic = "The profile file changed on disk; Reload from Disk to reconcile before saving."
                saveStatusMessage = "Save error: the profile file changed on disk."
                objectWillChange.send()
                return
            }
        } else if disk != nil {
            profileYAMLDiagnostic = "A profile file appeared on disk since this draft started; Reload from Disk to reconcile before saving."
            saveStatusMessage = "Save error: the profile file changed on disk."
            objectWillChange.send()
            return
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            profileYAMLDiagnostic = "Write failed — the previous file is untouched: \(error.localizedDescription)"
            saveStatusMessage = "Save error: \(error.localizedDescription)"
            objectWillChange.send()
            return
        }
        let keep = editor.selectedVariantID.flatMap { id in document.variants.contains(where: { $0.id == id }) ? id : nil }
        editor.applyProfileDocument(document, selectedVariantID: keep)
        // Exact bytes (comments preserved) differ from the re-serialization:
        // rebase Core to what actually landed, or the next visual save blocks.
        editor.rebaseSaveBaseline(to: text)
        appliedProfileDoc = nil
        profileYAMLBaseline = text
        profileYAMLFileBaseline = text
        profileYAMLLoadedID = "\(document.profileID)@\(file.path)"
        profileYAMLPath = file.path
        loadedProfileURL = file
        profileYAMLDiagnostic = nil
        refreshSavedProfiles()
        syncDefaultPlotChannels()
        refreshPreviewMatch()
        saveStatusMessage = "Saved profile \(file.lastPathComponent) (\(document.variants.count) variants) byte-exact."
        objectWillChange.send()
    }

    func reloadProfileYAMLFromDisk() {
        profileYAMLLoadedID = nil
        openProfileYAML()
        saveStatusMessage = "Reloaded profile source from disk; local edits discarded."
        objectWillChange.send()
    }

    func discardProfileYAML() {
        profileYAMLText = profileYAMLBaseline ?? ""
        appliedProfileDoc = nil
        profileYAMLDiagnostic = nil
        objectWillChange.send()
    }

    /// Loads the exact catalog bytes once per catalog revision; the global
    /// template is never the YAML target.
    func openGrammarYAML() {
        guard developerMode else { return }
        let id = "\(grammarCatalog.grammars.count)@\(activeGrammarID)"
        guard grammarYAMLLoadedID != id else { return }
        grammarYAMLLoadedID = id
        grammarYAMLDiagnostic = nil
        grammarCatalogSnapshot = grammarCatalog
        if let file = grammarFileURL() {
            grammarYAMLPath = file.path
            grammarFileBaseline = try? String(contentsOf: file, encoding: .utf8)
        } else {
            grammarYAMLPath = ""
            grammarFileBaseline = nil
        }
        grammarYAMLText = (try? FilenameGrammarEngine.serializedYAML(catalog: grammarCatalog)) ?? ""
        grammarYAMLBaseline = grammarYAMLText
    }

    /// Explicit Apply for the catalog: the draft loads through the strict
    /// file loader, so only a valid catalog lands.
    func applyGrammarYAML() {
        // A clean source never silently reverts visual grammar edits; an
        // edited source is explicit intent and proceeds.
        if !grammarYAMLDirty, let snap = grammarCatalogSnapshot, grammarCatalog != snap {
            grammarYAMLDiagnostic = "The visual grammar changed since this source opened; edit the source or Reload to continue from the current catalog."
            objectWillChange.send()
            return
        }
        guard let catalog = catalogFromText(grammarYAMLText) else {
            grammarYAMLDiagnostic = "Invalid grammar source — nothing applied; fix the text or Reload from Disk."
            objectWillChange.send()
            return
        }
        grammarCatalog = catalog
        if let match = catalog.grammars.first(where: { $0.id == activeGrammarID }) {
            activeTemplate = match.template
        } else if let first = catalog.grammars.first {
            activeGrammarID = first.id
            activeTemplate = first.template
        }
        grammarCatalogSnapshot = catalog
        grammarYAMLDiagnostic = nil
        recalculateGrammarExtraction()
        saveStatusMessage = "Applied grammar source to visual state (unsaved). Save to write it to disk."
        objectWillChange.send()
    }

    /// Grammar source save: validates, refuses external change and visual
    /// divergence, writes the exact draft bytes to the project catalog only.
    func saveGrammarYAML() {
        guard project != nil else { return }
        guard let file = grammarFileURL() else { return }
        let text = grammarYAMLText
        guard catalogFromText(text) != nil else {
            grammarYAMLDiagnostic = "Invalid grammar source — nothing written; fix the text or Reload from Disk."
            saveStatusMessage = "Grammar save error: invalid grammar source."
            objectWillChange.send()
            return
        }
        // A visual grammar edit after Apply must never be silently replaced.
        if let snap = grammarCatalogSnapshot, grammarCatalog != snap {
            grammarYAMLDiagnostic = "The visual grammar changed since this source was applied; Apply the source to replace it explicitly, or save from the visual tab."
            saveStatusMessage = "Grammar save error: visual edits diverge from the source draft."
            objectWillChange.send()
            return
        }
        let disk = try? String(contentsOf: file, encoding: .utf8)
        if let baseline = grammarFileBaseline {
            if disk != baseline {
                grammarYAMLDiagnostic = disk == nil
                    ? "The grammar file was deleted on disk; Reload to reconcile before saving."
                    : "The grammar file changed on disk; Reload to reconcile before saving."
                saveStatusMessage = "Grammar save error: the grammar file changed on disk."
                objectWillChange.send()
                return
            }
        } else if disk != nil {
            grammarYAMLDiagnostic = "A grammar file appeared on disk since this draft started; Reload to reconcile before saving."
            saveStatusMessage = "Grammar save error: the grammar file changed on disk."
            objectWillChange.send()
            return
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            grammarYAMLDiagnostic = "Write failed — the previous file is untouched: \(error.localizedDescription)"
            saveStatusMessage = "Grammar save error: \(error.localizedDescription)"
            objectWillChange.send()
            return
        }
        grammarCatalogSnapshot = grammarCatalog
        grammarYAMLBaseline = text
        grammarFileBaseline = text
        grammarYAMLLoadedID = "\(grammarCatalog.grammars.count)@\(activeGrammarID)"
        grammarYAMLDiagnostic = nil
        saveStatusMessage = "Saved grammar catalog (.rawviewer/grammar.yaml) byte-exact."
        objectWillChange.send()
    }

    func reloadGrammarYAMLFromDisk() {
        grammarYAMLLoadedID = nil
        openGrammarYAML()
        saveStatusMessage = "Reloaded grammar source from disk; local edits discarded."
        objectWillChange.send()
    }

    func discardGrammarYAML() {
        grammarYAMLText = grammarYAMLBaseline ?? ""
        grammarCatalogSnapshot = grammarCatalog
        grammarYAMLDiagnostic = nil
        objectWillChange.send()
    }

    /// One Save entry for the focused window: the active tab's document
    /// only. A profile save never touches the grammar catalog and a grammar
    /// save never touches the profile; no combined save is reachable.
    func saveFocusedDocument(tab: EditorWorkspaceView.StudioTab) {
        switch tab {
        case .profileYAML:
            saveProfileYAML()
        case .tokens where grammarYAMLMode:
            saveGrammarYAML()
        case .tokens:
            saveGrammarToProject()
        default:
            saveProfileDocument()
        }
    }

    /// Termination/close Save: YAML drafts save through their validated
    /// byte-exact paths; false means the close must abort.
    func saveForTermination() -> Bool {
        if profileYAMLDirty {
            saveProfileYAML()
            guard !profileYAMLDirty else { return false }
        }
        if grammarYAMLDirty {
            saveGrammarYAML()
            guard !grammarYAMLDirty else { return false }
        }
        if editor.refreshDirtyFromStagedEdits() {
            saveProfileDocument()
            guard !editor.profileDirty else { return false }
        }
        return true
    }

    /// Synchronous window-close verdict for the NSWindow delegate proxy:
    /// Save attempts first, a failed Save aborts, Cancel keeps everything.
    func requestWindowClose() -> Bool {
        guard hasUnsavedWork else { return true }
        let alert = NSAlert()
        alert.messageText = "Unsaved profile changes"
        alert.informativeText = "Save the whole profile document, discard the draft, or cancel and keep editing."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveForTermination()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
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
        guard project != nil else { return }
        let profileBaseName = profileURL.deletingPathExtension().lastPathComponent
        let id = editor.instrumentID.isEmpty ? profileBaseName : editor.instrumentID

        let matched = sources.first(where: {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(id) ||
            (!editor.instrumentName.isEmpty && $0.url.lastPathComponent.localizedCaseInsensitiveContains(editor.instrumentName))
        }) ?? sources.first

        if let matched = matched {
            selectSource(matched, preserveProfile: true)
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
        // A reloaded catalog resets the grammar source draft.
        grammarYAMLLoadedID = nil
        grammarYAMLBaseline = nil
        grammarYAMLText = ""
        grammarYAMLDiagnostic = nil
        grammarCatalogSnapshot = nil
        grammarFileBaseline = nil
        do {
            let loaded = try FilenameGrammarEngine.load(project: project)
            self.grammarCatalog = loaded
            if let activeID = loaded.activeGrammarID, let match = loaded.grammars.first(where: { $0.id == activeID }) {
                self.activeGrammarID = match.id
                self.activeTemplate = match.template
            } else if let first = loaded.grammars.first {
                self.activeGrammarID = first.id
                self.activeTemplate = first.template
            }
        } catch GrammarCatalogError.fileNotFound {
            // Canonical file absent: read the legacy path once, with diagnostics.
            do {
                let legacy = try FilenameGrammarEngine.importLegacy(project: project)
                self.grammarCatalog = legacy.catalog
                if let activeID = legacy.catalog.activeGrammarID,
                   let match = legacy.catalog.grammars.first(where: { $0.id == activeID }) {
                    self.activeGrammarID = match.id
                    self.activeTemplate = match.template
                } else if let first = legacy.catalog.grammars.first {
                    self.activeGrammarID = first.id
                    self.activeTemplate = first.template
                }
                if legacy.catalog.grammars.isEmpty {
                    self.grammarCatalog = FilenameGrammarCatalog(grammars: FilenameGrammarCatalog.standardDefaults, activeGrammarID: "standard-scientific")
                    if let first = grammarCatalog.grammars.first {
                        self.activeGrammarID = first.id
                        self.activeTemplate = first.template
                    }
                } else {
                    saveStatusMessage = "Using legacy grammar definitions (\(legacy.diagnostics.count) migration notes); review recommended."
                }
            } catch {
                self.grammarCatalog = FilenameGrammarCatalog(grammars: FilenameGrammarCatalog.standardDefaults, activeGrammarID: "standard-scientific")
                if let first = grammarCatalog.grammars.first {
                    self.activeGrammarID = first.id
                    self.activeTemplate = first.template
                }
            }
        } catch {
            // Malformed canonical data is an error: surface it, never silently
            // fall back to legacy definitions or defaults.
            self.grammarCatalog = FilenameGrammarCatalog(grammars: FilenameGrammarCatalog.standardDefaults, activeGrammarID: "standard-scientific")
            if let first = grammarCatalog.grammars.first {
                self.activeGrammarID = first.id
                self.activeTemplate = first.template
            }
            saveStatusMessage = "Grammar load error: \(error.localizedDescription)"
        }
        recalculateGrammarExtraction()
    }

    func saveGrammarToProject() {
        guard let project = project else { return }
        syncCurrentTemplateToCatalog()
        grammarCatalog.activeGrammarID = activeGrammarID
        do {
            try FilenameGrammarEngine.save(catalog: grammarCatalog, project: project)
            saveStatusMessage = "Saved grammar catalog (.rawviewer/grammar.yaml)"
            // Keep an open grammar draft honest: a clean draft rebases to the
            // new bytes, a dirty one is warned stale (never silently merged).
            if let file = grammarFileURL(), let bytes = try? String(contentsOf: file, encoding: .utf8) {
                grammarFileBaseline = bytes
                if grammarYAMLBaseline != nil {
                    if !grammarYAMLDirty {
                        grammarYAMLText = bytes
                        grammarYAMLBaseline = bytes
                        grammarCatalogSnapshot = grammarCatalog
                    } else {
                        grammarYAMLDiagnostic = "Grammar saved from visual edits; this source is stale — Reload to continue from disk."
                    }
                }
            }
        } catch {
            saveStatusMessage = "Grammar save error: \(error.localizedDescription)"
        }
    }

    func saveGrammarCatalog() {
        saveGrammarToProject()
    }

    func syncCurrentTemplateToCatalog() {
        guard let idx = grammarCatalog.grammars.firstIndex(where: { $0.id == activeGrammarID }) else { return }
        grammarCatalog.grammars[idx].template = activeTemplate
    }

    func selectGrammar(id: String) {
        if activeGrammarID != id {
            activeGrammarID = id
        }
        grammarCatalog.activeGrammarID = id
        if let match = grammarCatalog.grammars.first(where: { $0.id == id }) {
            activeTemplate = match.template
        }
        recalculateGrammarExtraction()
        refreshPreviewMatch()
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

    func renameActiveGrammar(to newName: String) {
        guard let idx = grammarCatalog.grammars.firstIndex(where: { $0.id == activeGrammarID }) else { return }
        grammarCatalog.grammars[idx].name = newName
        objectWillChange.send()
    }

    func updateGrammarField(
        name: String,
        role: String? = nil,
        type: GrammarFieldType = .string,
        formatHint: String = "",
        stripBrackets: Bool = false,
        isOptional: Bool = false,
        isFacet: Bool = true
    ) {
        guard let gIdx = grammarCatalog.grammars.firstIndex(where: { $0.id == activeGrammarID }) else { return }
        if let fIdx = grammarCatalog.grammars[gIdx].fields.firstIndex(where: { $0.name == name }) {
            grammarCatalog.grammars[gIdx].fields[fIdx].role = role
            grammarCatalog.grammars[gIdx].fields[fIdx].type = type
            grammarCatalog.grammars[gIdx].fields[fIdx].formatHint = formatHint
            grammarCatalog.grammars[gIdx].fields[fIdx].stripBrackets = stripBrackets
            grammarCatalog.grammars[gIdx].fields[fIdx].isOptional = isOptional
            grammarCatalog.grammars[gIdx].fields[fIdx].isFacet = isFacet
        } else {
            grammarCatalog.grammars[gIdx].fields.append(GrammarField(
                name: name,
                role: role,
                type: type,
                formatHint: formatHint,
                stripBrackets: stripBrackets,
                isOptional: isOptional,
                isFacet: isFacet
            ))
        }
        recalculateGrammarExtraction()
        objectWillChange.send()
    }

    /// Ordered list of all variable names declared in activeTemplate
    var templateVariableNames: [String] {
        var seen: [String] = []
        for name in FilenameGrammarEngine.templateVariables(in: activeTemplate) {
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
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

        // Ensure fields exist for all variables currently typed in activeTemplate.
        // New variables get a neutral custom role equal to their own name;
        // role and type are never inferred from name substrings.
        for name in templateVariableNames {
            if !effective.fields.contains(where: { $0.name == name }) {
                effective.fields.append(GrammarField(name: name, role: name, type: .string, formatHint: ""))
            }
        }
        if let idx = grammarCatalog.grammars.firstIndex(where: { $0.id == activeGrammarID }) {
            grammarCatalog.grammars[idx].fields = effective.fields
        }

        do {
            _ = try FilenameGrammarEngine.compile(template: activeTemplate, fields: effective.fields)
            grammarMatchError = nil
        } catch {
            grammarMatchError = error.localizedDescription
        }

        let facts = FilenameGrammarEngine.extract(from: filename, grammar: effective)
        sampleExtractedFacts = facts
        if !facts.isMatched && grammarMatchError == nil {
            grammarMatchError = facts.unmatchedReason
        }
        // Task 7: tick-only keys autofill read-only from the current sample
        // on every select/match (stage + dirty); unmatched samples never fill.
        if facts.isMatched {
            editor.autofillSelectedVariantKeyValues(
                from: facts.extractedFields, isMatched: true)
        }
    }

    func updateSampleGrammarFacts() {
        recalculateGrammarExtraction()
    }

    func runAutoDetect() {
        editor.smartAutoDetect()
        editor.markProfileDirty()
        syncDefaultPlotChannels()
        objectWillChange.send()
    }

    func updateColumn(index: Int, column: ColumnDefinition) {
        guard index < editor.columns.count else { return }
        editor.columns[index] = column
        editor.markProfileDirty()
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
        editor.markProfileDirty()
        objectWillChange.send()
    }

    func removeMetadataTag(lineIndex: Int, tokenIndex: Int) {
        editor.removeMetadataCellTag(lineIndex: lineIndex, tokenIndex: tokenIndex)
        editor.markProfileDirty()
        objectWillChange.send()
    }

    func tagRange(range: ClosedRange<Int>, tag: LineRegionType) {
        editor.tagRange(from: range.lowerBound, to: range.upperBound, as: tag)
        editor.markProfileDirty()
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
        editor.stageCurrentVariantEdits()
        var parts: [String] = []
        var profileFailed = false
        // Whole-document save first; a failure aborts the combined action and
        // never replaces the valid file on disk.
        if editor.profileDocument != nil {
            do {
                let savedFile = try editor.saveDocument(project: project, catalog: grammarCatalog)
                parts.append("profile \(savedFile.lastPathComponent)")
            } catch {
                parts.append("profile FAILED (\(error.localizedDescription))")
                profileFailed = true
            }
        } else {
            do {
                let savedFile = try editor.saveProfile(project: project)
                parts.append("profile \(savedFile.lastPathComponent)")
            } catch {
                parts.append("profile FAILED (\(error.localizedDescription))")
                profileFailed = true
            }
        }
        if !profileFailed {
            // Category rules stay until Explorer consumers migrate (legacy preserved).
            do {
                let catIndex = semanticElements.first(where: { $0.role == "category" || $0.role == "Study" || $0.role == "Mode" })?.index
                let devIndex = semanticElements.first(where: { $0.role == "legend" || $0.role == "Device ID" || $0.role == "Library" })?.index
                let rule = CategoryRule(
                    delimiters: editor.tokenDelimiters,
                    categoryIndex: catIndex,
                    deviceIndex: devIndex,
                    elements: semanticElements
                )
                try CategoryRuleEngine.save(rules: rule, project: project)
                parts.append("rules")
            } catch {
                parts.append("rules FAILED (\(error.localizedDescription))")
            }

            // Grammar catalog to the canonical project path.
            syncCurrentTemplateToCatalog()
            grammarCatalog.activeGrammarID = activeGrammarID
            do {
                try FilenameGrammarEngine.save(catalog: grammarCatalog, project: project)
                parts.append("grammar .rawviewer/grammar.yaml")
            } catch {
                parts.append("grammar FAILED (\(error.localizedDescription))")
            }
        }

        refreshSavedProfiles()
        saveStatusMessage = "Saved " + parts.joined(separator: "; ") + "."
    }

    func applyCustomStructure(delimiter: String, decimalSeparator: String, headerLine: Int?, dataStartLine: Int, skippedMetadataLines: Set<Int> = []) {
        editor.delimiter = delimiter
        editor.decimalDelimiter = decimalSeparator
        editor.markProfileDirty()
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

    // MARK: - Task 1: schema badge (strict v3-only; no upgrade flow)

    /// Read-only schema badge: v3 for typed documents, empty state otherwise.
    var schemaBadgeText: String {
        editor.profileDocument != nil ? "Profile schema v3" : "No profile"
    }

    /// Preview confirmation for the active profile AND variant. Anything but
    /// `.confirmed` leaves the preview unconfirmed; `.noMatch` clears the
    /// stale confirmation without touching loaded definitions.
    enum PreviewMatchState: Equatable {
        case idle
        case searching
        case confirmed(String)
        case unconfirmed(String)
        case noMatch
        case ambiguous(String)
        case ioError(String)
    }

    @Published var previewMatch: PreviewMatchState = .idle
    private var previewMatchGeneration = 0

    /// Re-checks the preview match for the active profile/variant: the
    /// current sample first, then deterministic source order. Bounded,
    /// off-main, generation-checked so late results never win.
    func refreshPreviewMatch() {
        previewMatchGeneration += 1
        let generation = previewMatchGeneration
        guard editor.profileDocument != nil else {
            previewMatch = .idle
            return
        }
        previewMatch = .searching
        var ordered: [RawSource] = []
        if let current = selectedSource, sources.contains(current) {
            ordered.append(current)
        }
        ordered += sources.filter { $0 != selectedSource }.sorted { $0.relativePath < $1.relativePath }
        runPreviewMatch(sourcesToCheck: ordered, generation: generation, manual: nil)
    }

    func retryPreviewMatch() {
        refreshPreviewMatch()
    }

    /// Manual sample choice: switches immediately (preserving
    /// drafts/definitions) but stays unconfirmed until the check lands.
    func chooseSamplePreview(_ source: RawSource) {
        previewMatchGeneration += 1
        let generation = previewMatchGeneration
        editor.stageCurrentVariantEdits()
        selectSource(source, preserveProfile: true)
        previewMatch = .unconfirmed(source.relativePath)
        runPreviewMatch(sourcesToCheck: [source], generation: generation, manual: source)
        objectWillChange.send()
    }

    private func runPreviewMatch(sourcesToCheck: [RawSource], generation: Int, manual: RawSource?) {
        guard let project,
              let document = editor.profileDocument,
              let variantID = editor.selectedVariantID ?? document.variants.first?.id else { return }
        let grammar = grammarCatalog
        let grammarFile = project.root.appendingPathComponent(".rawviewer/grammar.yaml")
        Task.detached(priority: .userInitiated) { [weak self] in
            // Fresh grammar fingerprint per run; nil when the catalog file is absent.
            let grammarSHA: String? = {
                guard let bytes = try? Data(contentsOf: grammarFile) else { return nil }
                return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }()
            var candidates: [PreviewSampleCandidate] = []
            var firstReadError: String? = nil
            for source in sourcesToCheck {
                do {
                    let handle = try FileHandle(forReadingFrom: source.url)
                    let prefix = try handle.read(upToCount: 64 * 1024) ?? Data()
                    try handle.close()
                    let size = (try? FileManager.default.attributesOfItem(atPath: source.url.path)[.size] as? NSNumber)?.intValue ?? prefix.count
                    let ext = source.url.pathExtension
                    candidates.append(PreviewSampleCandidate(
                        sourceID: source.relativePath,
                        basename: source.url.lastPathComponent,
                        fileExtension: ext.isEmpty ? "" : "." + ext.lowercased(),
                        prefixBytes: prefix, byteSize: size))
                } catch {
                    if firstReadError == nil {
                        firstReadError = source.relativePath + ": " + error.localizedDescription
                    }
                }
            }
            let outcome = PreviewSampleMatcher.match(
                candidates: candidates, document: document, variantID: variantID,
                grammar: grammar, grammarSHA256: grammarSHA)
            await self?.applyPreviewMatch(
                outcome: outcome, readError: firstReadError, generation: generation, manual: manual)
        }
    }

    /// Applies a match outcome only when its generation is still current, so
    /// a late A-to-B result can never overwrite a newer check.
    private func applyPreviewMatch(
        outcome: PreviewSampleMatch, readError: String?, generation: Int, manual: RawSource?
    ) {
        guard generation == previewMatchGeneration else { return }
        switch outcome {
        case .confirmed(let id):
            previewMatch = .confirmed(id)
            if selectedSource?.relativePath != id,
               let hit = sources.first(where: { $0.relativePath == id }) {
                editor.stageCurrentVariantEdits()
                selectSource(hit, preserveProfile: true)
            }
        case .ambiguous(let note):
            previewMatch = .ambiguous(note)
        case .noMatch:
            if let error = readError {
                previewMatch = .ioError(error)
            } else if let manual {
                previewMatch = .unconfirmed(manual.relativePath)
                saveStatusMessage = "Sample '\(manual.url.lastPathComponent)' does not match variant '\(editor.selectedVariantID ?? "?")'; preview is unconfirmed."
            } else {
                previewMatch = .noMatch
            }
        }
        objectWillChange.send()
    }
}

// MARK: - Task 6: native YAML source editing (monospaced, undo, no substitutions).

/// NSTextView source editor: native undo/redo, monospaced, all automatic
/// substitutions off. The binding round-trips without echo loops.
struct YAMLSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var label: String = "YAML source editor"

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  textView.string != text.wrappedValue else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Shared source-tab chrome: exact path/scope header, editor, text status,
/// actionable diagnostics, and the explicit Apply/Save/Reload/Discard row.
/// Apply projects into visual state; only Save touches disk.
struct YAMLSourcePanel: View {
    var scope: String
    var path: String
    var status: String
    var isDirty: Bool
    var isLoaded: Bool
    var isReadOnly: Bool
    var readOnlyNote: String
    var emptyNote: String
    @Binding var text: String
    var diagnostic: String?
    var editorLabel: String
    var applyLabel: String
    var saveLabel: String
    var onApply: () -> Void
    var onSave: () -> Void
    var onReload: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(path.isEmpty ? "No source open" : path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                        .accessibilityLabel("Source path: \(path.isEmpty ? "none" : path)")
                    if !scope.isEmpty {
                        Text(scope)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.1))
                    .clipShape(Capsule())
                    .accessibilityLabel("Source status: \(status)")
            }
            if isReadOnly && !readOnlyNote.isEmpty {
                Label(readOnlyNote, systemImage: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !isLoaded {
                Text(emptyNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                YAMLSourceEditor(text: $text, isEditable: !isReadOnly, label: editorLabel)
                    .accessibilityLabel(editorLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .border(Color.primary.opacity(0.12), width: 1)
            }
            if let diagnostic {
                Text(diagnostic)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel("Source problem: \(diagnostic)")
            }
            HStack(spacing: 8) {
                Button("Apply to Visual") { onApply() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isReadOnly || !isLoaded)
                    .help(applyLabel)
                Button(saveLabel) { onSave() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isReadOnly || !isDirty)
                    .help("Validates every variant, then writes these exact bytes. Invalid drafts never touch disk.")
                Button("Reload from Disk") { onReload() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isLoaded)
                    .help("Drops local edits and reloads the exact file bytes.")
                Button("Discard Edits", role: .destructive) { onDiscard() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isDirty)
                    .help("Drops local edits back to the opened bytes.")
                Spacer()
            }
        }
        .padding(14)
    }

    private var statusColor: Color {
        if diagnostic != nil { return .red }
        return isDirty ? .orange : .green
    }
}

/// Task 6: whole-variants-document source tab (Developer Mode only).
struct ProfileYAMLSourceView: View {
    @ObservedObject var model: EditorWorkspaceViewModel

    var body: some View {
        YAMLSourcePanel(
            scope: model.profileYAMLPath.isEmpty ? "" : "Whole profile document (\(model.variantIDs.count) variants)",
            path: model.profileYAMLPath,
            status: model.profileYAMLStatus,
            isDirty: model.profileYAMLDirty,
            isLoaded: model.profileYAMLLoaded,
            isReadOnly: model.profileYAMLReadOnly,
            readOnlyNote: model.profileYAMLReadOnlyNote,
            emptyNote: model.profileYAMLReadOnlyNote.isEmpty ? "Load a profile before editing its source." : model.profileYAMLReadOnlyNote,
            text: $model.profileYAMLText,
            diagnostic: model.profileYAMLDiagnostic,
            editorLabel: "Profile YAML source editor",
            applyLabel: "Parses and validates the whole document, then projects it into the visual state. Apply is not save.",
            saveLabel: "Save Profile YAML",
            onApply: { model.applyProfileYAML() },
            onSave: { model.saveProfileYAML() },
            onReload: { model.reloadProfileYAMLFromDisk() },
            onDiscard: { model.discardProfileYAML() }
        )
        .onAppear { model.openProfileYAML() }
        .onChange(of: model.loadedProfileURL) { _, _ in model.openProfileYAML() }
    }
}

/// Task 6: whole-catalog source mode inside Filename Grammar (Developer Mode).
struct GrammarYAMLSourceView: View {
    @ObservedObject var model: EditorWorkspaceViewModel

    var body: some View {
        YAMLSourcePanel(
            scope: "Whole project catalog (\(model.grammarCatalog.grammars.count) grammars)",
            path: model.grammarYAMLPath,
            status: model.grammarYAMLStatus,
            isDirty: model.grammarYAMLDirty,
            isLoaded: model.grammarYAMLLoaded,
            isReadOnly: false,
            readOnlyNote: "",
            emptyNote: "The grammar catalog is unavailable.",
            text: $model.grammarYAMLText,
            diagnostic: model.grammarYAMLDiagnostic,
            editorLabel: "Grammar YAML source editor",
            applyLabel: "Loads the whole catalog through the strict validator, then projects it into the visual state. Apply is not save.",
            saveLabel: "Save Grammar YAML",
            onApply: { model.applyGrammarYAML() },
            onSave: { model.saveGrammarYAML() },
            onReload: { model.reloadGrammarYAMLFromDisk() },
            onDiscard: { model.discardGrammarYAML() }
        )
        .onAppear { model.openGrammarYAML() }
    }
}