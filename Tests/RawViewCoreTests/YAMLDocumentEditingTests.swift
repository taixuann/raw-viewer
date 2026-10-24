import Foundation
import Testing
@testable import RawViewCore

/// Task 6: developer source-draft lifecycle over the Task 2/3 document
/// contract. A source draft is the exact edited text (bytes and comments);
/// Apply parses and validates it into the visual document (apply is not
/// save); Save validates every variant and never replaces a valid file on
/// failure or external change. These tests pin the headless-simulable core;
/// window/quit interception and the AppKit editors are manual cases.
struct YAMLDocumentEditingTests {
    private func twoVariantDocument() throws -> ProfileDocumentV3 {
        try ProfileDocumentV3.parse(
            text: ProfileDocumentV3Tests.baseYAML
                + ProfileDocumentV3Tests.positionalVariant(id: "cv-2col", mode: "ca"))
    }

    private func tempProjectRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task6-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tempProject() throws -> ProjectContext {
        try ProjectContext.open(try tempProjectRoot(), dataRootRelativePath: ".")
    }

    private func profileFileURL(project: ProjectContext, profileID: String) -> URL {
        project.root.appendingPathComponent(".rawviewer/instrument/\(profileID).yaml")
    }

    // MARK: - Exact bytes and comments

    @Test func sourceDraftPreservesExactBytesAndComments() throws {
        let headed = "# Project autolab-usth — hand edits below. Do not reformat.\n"
            + ProfileDocumentV3Tests.baseYAML
            + "\n# trailing note: cv uses ; delimiter\n"
        // The draft is held verbatim; parsing never rewrites it.
        let document = try ProfileDocumentV3.parse(text: headed)
        #expect(headed.hasPrefix("# Project autolab-usth"))
        #expect(headed.hasSuffix("# trailing note: cv uses ; delimiter\n"))
        // Byte-exact save path: validated text lands on disk unchanged.
        _ = try document.validate()
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".rawviewer/instrument/autolab-usth.yaml")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try headed.write(to: file, atomically: true, encoding: .utf8)
        let roundTripped = try String(contentsOf: file, encoding: .utf8)
        #expect(roundTripped == headed)
        #expect(try ProfileDocumentV3.parse(text: roundTripped) == document)
    }

    // MARK: - Invalid drafts never touch disk

    @Test func invalidDraftNeverTouchesDisk() throws {
        let project = try tempProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let file = profileFileURL(project: project, profileID: "autolab-usth")

        // Unparseable text: no file appears.
        let broken = ProfileDocumentV3Tests.baseYAML.replacingOccurrences(
            of: "schema_version: 3", with: "schema_version: [3")
        #expect(throws: ProfileDocumentError.self) { try ProfileDocumentV3.parse(text: broken) }
        #expect(FileManager.default.fileExists(atPath: file.path) == false)

        // Structurally invalid text: validation fails before any write.
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: ProfileDocumentV3Tests.baseYAML + "\nbogus_root: 1\n")
        }
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test func failedSavePreservesExistingValidFile() throws {
        let project = try tempProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        let saved = try model.saveDocument(project: project, catalog: ProfileDocumentV3Tests.catalog())
        let goodBytes = try Data(contentsOf: saved)

        // Stage an edit that fails whole-document validation (empty routing
        // value on a sibling variant blocks Save, not navigation).
        try model.setVariantKeyEnabled("mode", enabled: true)
        try model.updateSelectedVariantKeyValue(key: "mode", value: "")
        #expect(throws: ProfileDocumentError.self) {
            try model.saveDocument(project: project, catalog: ProfileDocumentV3Tests.catalog())
        }
        // Failure leaves the valid file byte-identical and the draft intact.
        #expect(try Data(contentsOf: saved) == goodBytes)
        #expect(model.profileDirty == true)
    }

    // MARK: - Save validates all variants

    @Test func saveValidatesAllVariantsNotOnlySelected() throws {
        let project = try tempProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        // Corrupt only the non-selected variant: every key value must be
        // nonempty, so blanking cv-2col's value must block the whole save.
        #expect(model.selectVariant(id: "cv-2col") == true)
        try model.updateSelectedVariantKeyValue(key: "mode", value: "")
        #expect(model.selectVariant(id: "cv") == true)
        #expect(throws: ProfileDocumentError.self) {
            try model.saveDocument(project: project, catalog: ProfileDocumentV3Tests.catalog())
        }
        let file = profileFileURL(project: project, profileID: "autolab-usth")
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    // MARK: - Two dirty documents

    @Test func twoDirtyDocumentsStayIndependent() throws {
        let project = try tempProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let first = EditorWorkspaceModel()
        first.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        let second = EditorWorkspaceModel()
        second.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv-2col")

        first.modeName = "CV edited in A"
        // Refresh-first: stage binding writes before trusting the flag.
        #expect(first.refreshDirtyFromStagedEdits() == true)
        #expect(second.profileDirty == false)
        #expect(second.modeName == "CV two-column")

        // Saving A writes the whole A document (both variants); B is untouched.
        let savedA = try first.saveDocument(project: project, catalog: ProfileDocumentV3Tests.catalog())
        #expect(first.profileDirty == false)
        #expect(second.profileDirty == false)
        let reloaded = try ProfileDocumentV3.parse(text: try String(contentsOf: savedA, encoding: .utf8))
        #expect(reloaded.variants.count == 2)
        #expect(reloaded.variants.first(where: { $0.id == "cv" })?.name == "CV edited in A")
        #expect(reloaded.variants.first(where: { $0.id == "cv-2col" })?.name == "CV two-column")
    }

    // MARK: - External change and canceled transitions

    @Test func externalChangeAbortsSaveAndKeepsBothCopies() throws {
        let project = try tempProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        let saved = try model.saveDocument(project: project, catalog: ProfileDocumentV3Tests.catalog())

        // External change lands after our last save.
        let external = try String(contentsOf: saved, encoding: .utf8)
            .replacingOccurrences(of: "Autolab USTH", with: "Autolab External")
        try external.write(to: saved, atomically: true, encoding: .utf8)

        model.modeName = "CV local edit"
        // Refresh-first: stage the binding write so the guard sees it.
        #expect(model.refreshDirtyFromStagedEdits() == true)
        #expect(throws: ProfileDocumentError.self) {
            try model.saveDocument(project: project, catalog: ProfileDocumentV3Tests.catalog())
        }
        // Neither copy clobbered the other: disk keeps the external text,
        // memory keeps the local draft.
        #expect(try String(contentsOf: saved, encoding: .utf8) == external)
        #expect(model.modeName == "CV local edit")
        #expect(model.profileDirty == true)
    }

    @Test func canceledTransitionKeepsEverything() throws {
        let project = try tempProject()
        defer { try? FileManager.default.removeItem(at: project.root) }
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        // Dirty draft, then Cancel: no save, no revert, no variant loss.
        model.modeName = "CV unsaved"
        #expect(model.selectVariant(id: "cv-2col") == true)
        #expect(model.selectVariant(id: "cv") == true)
        #expect(model.modeName == "CV unsaved")
        #expect(model.profileDirty == true)
        let document = try model.makeProfileDocument()
        #expect(document.variants.count == 2)
        #expect(document.variants.first(where: { $0.id == "cv" })?.name == "CV unsaved")
        let file = profileFileURL(project: project, profileID: "autolab-usth")
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    // MARK: - Grammar catalog drafts

    @Test func grammarDraftAppliesOnlyWhenValid() throws {
        let catalog = ProfileDocumentV3Tests.catalog()
        let text = try FilenameGrammarEngine.serializedYAML(catalog: catalog)
        // Valid draft round-trips through the strict loader; the live
        // catalog is replaced only after that load succeeds. The loader may
        // normalize defaults, so stability is pinned on the second load.
        let dir = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let draft = dir.appendingPathComponent("grammar-draft.yaml")
        try text.write(to: draft, atomically: true, encoding: .utf8)
        let first = try FilenameGrammarEngine.load(fileURL: draft)
        #expect(first.grammars.count == 1)
        #expect(first.grammars.first?.id == "standard-scientific")
        let restaged = try FilenameGrammarEngine.serializedYAML(catalog: first)
        try restaged.write(to: draft, atomically: true, encoding: .utf8)
        #expect(try FilenameGrammarEngine.load(fileURL: draft) == first)

        // Invalid draft: the load fails and the live catalog is untouched.
        try "schema_version: 1\ngrammars: [oops\n".write(to: draft, atomically: true, encoding: .utf8)
        #expect(throws: GrammarCatalogError.self) { try FilenameGrammarEngine.load(fileURL: draft) }
        #expect(catalog.grammars.count == 1)
    }
}
