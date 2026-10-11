import Foundation
import Testing
@testable import RawViewCore

struct FilenameGrammarEngineTests {

    private func makeProject() throws -> (project: ProjectContext, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grammar-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataDir = root.appendingPathComponent("data/raw", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let project = try ProjectContext.open(root, dataRootRelativePath: "data/raw")
        return (project, root)
    }

    @Test func patternCompilationAndExtraction() throws {
        let template = "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]"
        let grammar = FilenameGrammar(
            id: "autolab-convention",
            name: "Autolab USTH Scientific",
            template: template,
            fields: [
                GrammarField(name: "date", role: "Date & Time", formatHint: "DDMMYY-HHmmSS"),
                GrammarField(name: "instrument", role: "Instrument"),
                GrammarField(name: "mode", role: "Mode"),
                GrammarField(name: "device-id", role: "Device ID", stripBrackets: true),
                GrammarField(name: "study", role: "Study"),
                GrammarField(name: "remarks", role: "Remarks", stripBrackets: true)
            ]
        )

        let filename = "271125-000000_autolab-usth.cv_[au-pda]_cv.deposition_r.[100mv-ph-7.4].txt"
        let result = FilenameGrammarEngine.extract(from: filename, grammar: grammar)

        #expect(result.isMatched == true)
        #expect(result.extractedFields["date"] == "271125-000000")
        #expect(result.extractedFields["instrument"] == "autolab-usth")
        #expect(result.extractedFields["mode"] == "cv")
        #expect(result.extractedFields["device-id"] == "au-pda")
        #expect(result.extractedFields["study"] == "cv.deposition")
        #expect(result.extractedFields["remarks"] == "100mv-ph-7.4")
        #expect(result.deviceID == "au-pda")
        #expect(result.timestamp == "271125-000000")
        #expect(result.category == "cv.deposition")
    }

    @Test func unmatchedFilenameReportsMismatch() throws {
        let template = "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]"
        let grammar = FilenameGrammar(
            id: "autolab-convention",
            name: "Autolab USTH Scientific",
            template: template,
            fields: []
        )

        let mismatched = "random_sample_without_structure.csv"
        let result = FilenameGrammarEngine.extract(from: mismatched, grammar: grammar)

        #expect(result.isMatched == false)
        #expect(result.extractedFields.isEmpty)
    }

    @Test func yamlPersistenceAndCatalogLoading() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let grammar1 = FilenameGrammar(
            id: "autolab-convention",
            name: "Autolab USTH Scientific",
            template: "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]",
            fields: [
                GrammarField(name: "date", role: "Date & Time", formatHint: "DDMMYY-HHmmSS"),
                GrammarField(name: "device-id", role: "Device ID", stripBrackets: true)
            ],
            isDefault: true
        )

        let grammar2 = FilenameGrammar(
            id: "b1500a-convention",
            name: "Keysight B1500A Convention",
            template: "{wafer}_{die}_{device}_{test-type}",
            fields: [
                GrammarField(name: "device", role: "Device ID")
            ],
            isDefault: false
        )

        let catalog = FilenameGrammarCatalog(
            grammars: [grammar1, grammar2],
            activeGrammarID: "autolab-convention"
        )

        try FilenameGrammarEngine.save(catalog: catalog, project: project)

        let loaded = FilenameGrammarEngine.load(project: project)
        #expect(loaded != nil)
        #expect(loaded?.grammars.count == 2)
        #expect(loaded?.activeGrammarID == "autolab-convention")
        #expect(loaded?.activeGrammar?.name == "Autolab USTH Scientific")
        #expect(loaded?.activeGrammar?.template == "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]")
        #expect(loaded?.activeGrammar?.fields.count == 2)
        #expect(loaded?.activeGrammar?.fields.first?.name == "date")
    }
}
