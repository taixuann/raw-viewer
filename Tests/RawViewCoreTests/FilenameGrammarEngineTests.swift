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

    @Test func optionalFieldAllowsMissingSegment() throws {
        let template = "{date}_{study}_r.[{remarks}]"
        let grammar = FilenameGrammar(
            id: "opt-test",
            name: "Optional Test",
            template: template,
            fields: [
                GrammarField(name: "date", role: "Date & Time"),
                GrammarField(name: "study", role: "Study"),
                GrammarField(name: "remarks", role: "Remarks", stripBrackets: true, isOptional: true)
            ]
        )

        // Filename WITH optional remarks
        let withRemarks = "271125_deposition_r.[100mv].txt"
        let res1 = FilenameGrammarEngine.extract(from: withRemarks, grammar: grammar)
        #expect(res1.isMatched == true)
        #expect(res1.extractedFields["remarks"] == "100mv")

        // Filename WITHOUT optional remarks
        let withoutRemarks = "271125_deposition.txt"
        let res2 = FilenameGrammarEngine.extract(from: withoutRemarks, grammar: grammar)
        #expect(res2.isMatched == true)
        #expect(res2.extractedFields["study"] == "deposition")
        #expect(res2.extractedFields["remarks"] == nil)
    }

    @Test func numberAndDatetimeFormatMatching() throws {
        let template = "{date}_batch_{batch}_scan_{scan}_{conc}mM"
        let grammar = FilenameGrammar(
            id: "num-test",
            name: "Number & Date Formatting Test",
            template: template,
            fields: [
                GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "yyyyMMdd"),
                GrammarField(name: "batch", role: "Remarks", type: .number, formatHint: "01"),
                GrammarField(name: "scan", role: "Remarks", type: .number, formatHint: "001"),
                GrammarField(name: "conc", role: "Remarks", type: .number, formatHint: "0.0")
            ]
        )

        let matchingFilename = "20261012_batch_05_scan_003_12.5mM.csv"
        let res1 = FilenameGrammarEngine.extract(from: matchingFilename, grammar: grammar)
        #expect(res1.isMatched == true)
        #expect(res1.extractedFields["date"] == "20261012")
        #expect(res1.extractedFields["batch"] == "05")
        #expect(res1.extractedFields["scan"] == "003")
        #expect(res1.extractedFields["conc"] == "12.5")

        // Batch with single digit should NOT match 2-digit "01" pattern:
        let nonMatchingBatch = "20261012_batch_5_scan_003_12.5mM.csv"
        let res2 = FilenameGrammarEngine.extract(from: nonMatchingBatch, grammar: grammar)
        #expect(res2.isMatched == false)
    }

    @Test func testStandardDefaultsCanonicalNaming() throws {
        let first = try #require(FilenameGrammarCatalog.standardDefaults.first)
        #expect(first.id == "standard-scientific")
        #expect(first.name == "Standard Filename Pattern")
        #expect(!first.name.contains("Autolab"))
        #expect(first.isDefault == true)
    }

    @Test func standardScientificTemplateWithBatchAndDateTime() throws {
        let standard = FilenameGrammarCatalog.standardDefaults.first!
        #expect(standard.template == "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]_{batch}")
        let (_, fieldNames) = try FilenameGrammarEngine.compile(template: standard.template, fields: standard.fields)
        #expect(fieldNames.contains("batch"))

        let sample = "261012-143000_Autolab.CV_[D01]_Stability_r.[scan1]_001.csv"
        let facts = FilenameGrammarEngine.extract(from: sample, grammar: standard)
        #expect(facts.isMatched == true)
        #expect(facts.extractedFields["date"] == "261012-143000")
        #expect(facts.extractedFields["batch"] == "001")
        #expect(facts.extractedFields["device-id"] == "D01")
    }

    @Test func globalAndProjectStorageIsolation() throws {
        let globalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: globalDir) }
        let globalFile = globalDir.appendingPathComponent("grammar.yaml")

        let testCatalog = FilenameGrammarCatalog(grammars: [
            FilenameGrammar(id: "global-1", name: "Global Grammar", template: "{date}_{study}")
        ])
        try FilenameGrammarEngine.save(catalog: testCatalog, fileURL: globalFile)

        let loaded = FilenameGrammarEngine.load(fileURL: globalFile)
        #expect(loaded?.grammars.first?.id == "global-1")
    }

    @Test func loadCombinedMergesProjectAndGlobalGrammars() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let tempGlobalDir = FileManager.default.temporaryDirectory.appendingPathComponent("global-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempGlobalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempGlobalDir) }
        let tempGlobalFile = tempGlobalDir.appendingPathComponent("grammar.yaml")

        let projectGrammar = FilenameGrammar(id: "proj-1", name: "Project G", template: "{date}_{study}")
        let projectCatalog = FilenameGrammarCatalog(grammars: [projectGrammar], activeGrammarID: "proj-1")
        try FilenameGrammarEngine.save(catalog: projectCatalog, project: project)

        let globalGrammar = FilenameGrammar(id: "glob-1", name: "Global G", template: "{date}_{instrument}")
        let globalCatalog = FilenameGrammarCatalog(grammars: [globalGrammar], activeGrammarID: "glob-1")
        try FilenameGrammarEngine.save(catalog: globalCatalog, fileURL: tempGlobalFile)

        let combined = FilenameGrammarEngine.loadCombined(project: project, globalURL: tempGlobalFile)
        #expect(combined.projectGrammars.count == 1)
        #expect(combined.projectGrammars.first?.id == "proj-1")
        #expect(combined.projectGrammars.first?.scope == .project)
        #expect(combined.globalGrammars.count == 1)
        #expect(combined.globalGrammars.first?.id == "glob-1")
        #expect(combined.globalGrammars.first?.scope == .global)
        #expect(combined.activeID == "proj-1")
    }

    @Test func standardScientificTemplatePermutations() throws {
        let standard = FilenameGrammarCatalog.standardDefaults.first!

        // 1. With remarks and batch
        let s1 = "261012-143000_Autolab.CV_[D01]_Stability_r.[scan1]_001.csv"
        let f1 = FilenameGrammarEngine.extract(from: s1, grammar: standard)
        #expect(f1.isMatched == true)
        #expect(f1.extractedFields["remarks"] == "scan1")
        #expect(f1.extractedFields["batch"] == "001")

        // 2. With remarks, without batch
        let s2 = "261012-143000_Autolab.CV_[D01]_Stability_r.[scan1].csv"
        let f2 = FilenameGrammarEngine.extract(from: s2, grammar: standard)
        #expect(f2.isMatched == true)
        #expect(f2.extractedFields["remarks"] == "scan1")
        #expect(f2.extractedFields["batch"] == nil)

        // 3. Without remarks, with batch
        let s3 = "261012-143000_Autolab.CV_[D01]_Stability_001.csv"
        let f3 = FilenameGrammarEngine.extract(from: s3, grammar: standard)
        #expect(f3.isMatched == true)
        #expect(f3.extractedFields["remarks"] == nil)
        #expect(f3.extractedFields["batch"] == "001")

        // 4. Without remarks, without batch
        let s4 = "261012-143000_Autolab.CV_[D01]_Stability.csv"
        let f4 = FilenameGrammarEngine.extract(from: s4, grammar: standard)
        #expect(f4.isMatched == true)
        #expect(f4.extractedFields["remarks"] == nil)
        #expect(f4.extractedFields["batch"] == nil)
    }

    @Test func testProgressiveTokenExtractionOnPartialMismatch() throws {
        let grammar = FilenameGrammar(
            id: "standard-scientific",
            name: "Standard Filename Pattern",
            template: "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]_{batch}",
            fields: [
                GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "DDMMYY-HHmmSS"),
                GrammarField(name: "instrument", role: "Instrument", type: .string),
                GrammarField(name: "mode", role: "Mode", type: .string),
                GrammarField(name: "device-id", role: "Device ID", type: .string, stripBrackets: true),
                GrammarField(name: "study", role: "Study", type: .string),
                GrammarField(name: "remarks", role: "Remarks", type: .string, stripBrackets: true, isOptional: true),
                GrammarField(name: "batch", role: "Batch", type: .number, formatHint: "001", isOptional: true)
            ]
        )
        let filename = "271125-000000_autolab.cv_[d01]_kinetics_r.[100mv]-extra.txt"
        let facts = FilenameGrammarEngine.extract(from: filename, grammar: grammar)

        #expect(facts.isMatched == false)
        #expect(facts.extractedFields["date"] == "271125-000000")
        #expect(facts.extractedFields["instrument"] == "autolab")
        #expect(facts.extractedFields["mode"] == "cv")
        #expect(facts.extractedFields["device-id"] == "d01")
        #expect(facts.extractedFields["study"] == "kinetics")
    }
}

