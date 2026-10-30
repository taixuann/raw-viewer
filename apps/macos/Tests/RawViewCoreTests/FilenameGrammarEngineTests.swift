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
            template: "{date}_{instrument}_{batch}",
            fields: [
                GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "DDMMYY-HHmmSS"),
                GrammarField(name: "instrument", role: "Instrument", type: .string),
                GrammarField(name: "batch", role: "Batch", type: .number, formatHint: "001", isOptional: true),
            ]
        )

        let grammar2 = FilenameGrammar(
            id: "b1500a-convention",
            name: "Keysight B1500A Convention",
            template: "{wafer}_{die}_{device}_{test-type}",
            fields: [
                GrammarField(name: "wafer", role: "Remarks", type: .string),
                GrammarField(name: "die", role: "Remarks", type: .string),
                GrammarField(name: "device", role: "Device ID", type: .string),
                GrammarField(name: "test-type", role: "Remarks", type: .string),
            ]
        )

        let catalog = FilenameGrammarCatalog(grammars: [grammar1, grammar2])

        try FilenameGrammarEngine.save(catalog: catalog, project: project)

        let loaded = try FilenameGrammarEngine.load(project: project)
        #expect(loaded.grammars.count == 2)
        #expect(loaded.grammars[0].id == "autolab-convention")
        #expect(loaded.grammars[0].template == "{date}_{instrument}_{batch}")
        #expect(loaded.grammars[0].fields.count == 3)
        #expect(loaded.grammars[0].fields.first?.name == "date")
        #expect(loaded == catalog)
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
        // Built-in defaults must satisfy the schema-v1 contract so the editor
        // can save them unchanged; compatibility flags simply do not serialize.
        let yaml = try FilenameGrammarEngine.serializedYAML(
            catalog: FilenameGrammarCatalog(grammars: FilenameGrammarCatalog.standardDefaults)
        )
        #expect(yaml.contains("schema_version: 1"))
        #expect(!yaml.contains("is_default"))
        #expect(!yaml.contains("is_facet"))
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
            FilenameGrammar(
                id: "global-1",
                name: "Global Grammar",
                template: "{date}_{study}",
                fields: [
                    GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "yyyyMMdd"),
                    GrammarField(name: "study", role: "Study", type: .string),
                ]
            )
        ])
        try FilenameGrammarEngine.save(catalog: testCatalog, fileURL: globalFile)

        let loaded = try FilenameGrammarEngine.load(fileURL: globalFile)
        #expect(loaded.grammars.first?.id == "global-1")
    }

    @Test func loadCombinedMergesProjectAndGlobalGrammars() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let tempGlobalDir = FileManager.default.temporaryDirectory.appendingPathComponent("global-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempGlobalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempGlobalDir) }
        let tempGlobalFile = tempGlobalDir.appendingPathComponent("grammar.yaml")

        let projectGrammar = FilenameGrammar(
            id: "proj-1",
            name: "Project G",
            template: "{date}_{study}",
            fields: [
                GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "yyyyMMdd"),
                GrammarField(name: "study", role: "Study", type: .string),
            ]
        )
        let projectCatalog = FilenameGrammarCatalog(grammars: [projectGrammar], activeGrammarID: "proj-1")
        try FilenameGrammarEngine.save(catalog: projectCatalog, project: project)

        let globalGrammar = FilenameGrammar(
            id: "glob-1",
            name: "Global G",
            template: "{date}_{instrument}",
            fields: [
                GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "yyyyMMdd"),
                GrammarField(name: "instrument", role: "Instrument", type: .string),
            ]
        )
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

    @Test func noNameSubstringInferenceWithoutDeclaredRoles() throws {
        // Spec: never infer role/type from variable name substrings.
        // Fields without declared roles leave semantic slots empty;
        // raw values remain available as editor feedback only.
        let grammar = FilenameGrammar(
            id: "inference-probe",
            name: "Inference Probe",
            template: "{date}_{study}",
            fields: []
        )
        let facts = FilenameGrammarEngine.extract(from: "20261012_deposition.csv", grammar: grammar)
        #expect(facts.isMatched == true)
        #expect(facts.extractedFields["date"] == "20261012")
        #expect(facts.extractedFields["study"] == "deposition")
        #expect(facts.timestamp == nil)
        #expect(facts.category == nil)
    }

    // MARK: - Schema-v1 persistence contract

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeStrictCatalog() -> FilenameGrammarCatalog {
        FilenameGrammarCatalog(grammars: [
            FilenameGrammar(
                id: "standard-scientific",
                name: "Standard Filename Pattern",
                template: "{instrument}.{mode}_{sample}",
                description: "Schema v1 probe",
                fields: [
                    GrammarField(name: "instrument", role: "Instrument", type: .string),
                    GrammarField(name: "mode", role: "Mode", type: .string),
                    GrammarField(name: "sample", role: "sample", type: .string),
                ]
            ),
            FilenameGrammar(
                id: "batch-tracker",
                name: "Batch Tracker",
                template: "{date}_{batch}",
                fields: [
                    GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "yyyyMMdd"),
                    GrammarField(name: "batch", role: "Batch", type: .number, formatHint: "001", isOptional: true),
                ]
            ),
        ])
    }

    @Test func canonicalRoundTripWritesStrictSchemaV1() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FilenameGrammarEngine.relativePath == ".rawviewer/grammar.yaml")

        let catalog = makeStrictCatalog()
        try FilenameGrammarEngine.save(catalog: catalog, project: project)

        let fileURL = project.root.appendingPathComponent(FilenameGrammarEngine.relativePath)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(text.contains("schema_version: 1"))
        #expect(!text.contains("active_grammar_id"))
        #expect(!text.contains("is_facet"))
        #expect(!text.contains("is_default"))
        #expect(!text.contains("format_hint"))
        #expect(!text.contains("is_optional"))
        #expect(!text.contains("strip_brackets"))
        #expect(!text.contains("scope:"))
        #expect(!text.contains("variant"))
        #expect(!text.contains("explorer"))
        #expect(text.contains("role: \"instrument\""))
        #expect(text.contains("role: \"datetime\""))
        #expect(text.contains("role: \"batch\""))
        #expect(text.contains("role: \"sample\""))
        #expect(text.contains("format: \"001\""))
        #expect(text.contains("optional: true"))
        #expect(text.contains("optional: false"))

        let loaded = try FilenameGrammarEngine.load(project: project)
        #expect(loaded == catalog)

        // Raw text (including leading zeros) survives the round trip.
        let facts = FilenameGrammarEngine.extract(from: "20261012_007.csv", grammar: loaded.grammars[1])
        #expect(facts.isMatched == true)
        #expect(facts.extractedFields["date"] == "20261012")
        #expect(facts.extractedFields["batch"] == "007")
        #expect(facts.batch == "007")
        #expect(facts.timestamp == "20261012")
    }

    @Test func customRolesAndArbitraryVariablesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("grammar.yaml")

        let catalog = FilenameGrammarCatalog(grammars: [
            FilenameGrammar(
                id: "custom-vars",
                name: "Custom Variables",
                template: "{operator}_{chamber}_{run}",
                fields: [
                    GrammarField(name: "operator", role: "operator", type: .string),
                    GrammarField(name: "chamber", role: "chamber", type: .string),
                    GrammarField(name: "run", role: "run", type: .number, formatHint: "01"),
                ]
            ),
        ])
        try FilenameGrammarEngine.save(catalog: catalog, fileURL: fileURL)
        let loaded = try FilenameGrammarEngine.load(fileURL: fileURL)
        #expect(loaded == catalog)

        let facts = FilenameGrammarEngine.extract(from: "alice_A_03.csv", grammar: loaded.grammars[0])
        #expect(facts.isMatched == true)
        #expect(facts.extractedFields["operator"] == "alice")
        #expect(facts.extractedFields["chamber"] == "A")
        #expect(facts.extractedFields["run"] == "03")
        // Custom roles annotate metadata only; they never fill routing slots.
        #expect(facts.timestamp == nil)
        #expect(facts.instrument == nil)
        #expect(facts.mode == nil)
        #expect(facts.category == nil)
        #expect(facts.batch == nil)
    }

    @Test func invalidCatalogsThrowDistinctErrors() throws {
        let valid = FilenameGrammar(
            id: "ok",
            name: "OK",
            template: "{a}_{b}",
            fields: [
                GrammarField(name: "a", role: "remarks", type: .string),
                GrammarField(name: "b", role: "remarks", type: .string),
            ]
        )

        #expect(throws: GrammarCatalogError.duplicateGrammarID("ok")) {
            _ = try FilenameGrammarEngine.serializedYAML(catalog: FilenameGrammarCatalog(grammars: [valid, valid]))
        }
        #expect(throws: GrammarCatalogError.duplicateField(grammar: "ok", field: "a")) {
            let dup = FilenameGrammar(
                id: "ok", name: "OK", template: "{a}",
                fields: [
                    GrammarField(name: "a", role: "remarks"),
                    GrammarField(name: "a", role: "remarks"),
                ]
            )
            _ = try FilenameGrammarEngine.serializedYAML(catalog: FilenameGrammarCatalog(grammars: [dup]))
        }
        #expect(throws: GrammarCatalogError.missingFieldDefinition(grammar: "ok", variable: "b")) {
            let missing = FilenameGrammar(
                id: "ok", name: "OK", template: "{a}_{b}",
                fields: [GrammarField(name: "a", role: "remarks")]
            )
            _ = try FilenameGrammarEngine.serializedYAML(catalog: FilenameGrammarCatalog(grammars: [missing]))
        }
        #expect(throws: GrammarCatalogError.undeclaredField(grammar: "ok", field: "zzz")) {
            let extra = FilenameGrammar(
                id: "ok", name: "OK", template: "{a}",
                fields: [
                    GrammarField(name: "a", role: "remarks"),
                    GrammarField(name: "zzz", role: "remarks"),
                ]
            )
            _ = try FilenameGrammarEngine.serializedYAML(catalog: FilenameGrammarCatalog(grammars: [extra]))
        }
        #expect(throws: GrammarCatalogError.duplicateVariable(grammar: "ok", variable: "a")) {
            let repeated = FilenameGrammar(
                id: "ok", name: "OK", template: "{a}_{a}",
                fields: [GrammarField(name: "a", role: "remarks")]
            )
            _ = try FilenameGrammarEngine.serializedYAML(catalog: FilenameGrammarCatalog(grammars: [repeated]))
        }
        #expect(throws: GrammarCatalogError.incompatibleFormat(field: "a", format: "001")) {
            let badFormat = FilenameGrammar(
                id: "ok", name: "OK", template: "{a}",
                fields: [GrammarField(name: "a", role: "remarks", type: .string, formatHint: "001")]
            )
            _ = try FilenameGrammarEngine.serializedYAML(catalog: FilenameGrammarCatalog(grammars: [badFormat]))
        }
        #expect(throws: GrammarCatalogError.emptyRole(field: "a")) {
            let noRole = FilenameGrammar(
                id: "ok", name: "OK", template: "{a}",
                fields: [GrammarField(name: "a", role: "  ")]
            )
            _ = try FilenameGrammarEngine.serializedYAML(catalog: FilenameGrammarCatalog(grammars: [noRole]))
        }
    }

    @Test func malformedCanonicalDocumentsThrow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("absent.yaml")
        #expect(throws: GrammarCatalogError.fileNotFound(path: missing.path)) {
            _ = try FilenameGrammarEngine.load(fileURL: missing)
        }

        let garbage = dir.appendingPathComponent("garbage.yaml")
        try writeText("::: not yaml :::\n\t- broken\n", to: garbage)
        do {
            _ = try FilenameGrammarEngine.load(fileURL: garbage)
            Issue.record("garbage YAML should throw")
        } catch let error as GrammarCatalogError {
            if case .parseFailed = error { } else {
                Issue.record("expected parseFailed, got \(error)")
            }
        }

        let wrongVersion = dir.appendingPathComponent("v2.yaml")
        try writeText("schema_version: 2\ngrammars: []\n", to: wrongVersion)
        #expect(throws: GrammarCatalogError.invalidSchemaVersion(found: "2")) {
            _ = try FilenameGrammarEngine.load(fileURL: wrongVersion)
        }

        let unversioned = dir.appendingPathComponent("unversioned.yaml")
        try writeText("grammars:\n  - id: \"g\"\n    name: \"G\"\n    template: \"{a}\"\n    fields:\n      - name: \"a\"\n        role: \"remarks\"\n        type: \"string\"\n        optional: false\n", to: unversioned)
        #expect(throws: GrammarCatalogError.invalidSchemaVersion(found: nil)) {
            _ = try FilenameGrammarEngine.load(fileURL: unversioned)
        }

        let unknownType = dir.appendingPathComponent("badtype.yaml")
        try writeText("schema_version: 1\ngrammars:\n  - id: \"g\"\n    name: \"G\"\n    template: \"{a}\"\n    fields:\n      - name: \"a\"\n        role: \"remarks\"\n        type: \"integer\"\n        optional: false\n", to: unknownType)
        #expect(throws: GrammarCatalogError.unknownType(field: "a", found: "integer")) {
            _ = try FilenameGrammarEngine.load(fileURL: unknownType)
        }

        let missingType = dir.appendingPathComponent("notype.yaml")
        try writeText("schema_version: 1\ngrammars:\n  - id: \"g\"\n    name: \"G\"\n    template: \"{a}\"\n    fields:\n      - name: \"a\"\n        role: \"remarks\"\n        optional: false\n", to: missingType)
        #expect(throws: GrammarCatalogError.unknownType(field: "a", found: nil)) {
            _ = try FilenameGrammarEngine.load(fileURL: missingType)
        }

        let legacyKey = dir.appendingPathComponent("legacykey.yaml")
        try writeText("schema_version: 1\nactive_grammar_id: \"g\"\ngrammars:\n  - id: \"g\"\n    name: \"G\"\n    template: \"{a}\"\n    fields:\n      - name: \"a\"\n        role: \"remarks\"\n        type: \"string\"\n        optional: false\n", to: legacyKey)
        #expect(throws: GrammarCatalogError.unexpectedKey(scope: "grammar catalog", key: "active_grammar_id")) {
            _ = try FilenameGrammarEngine.load(fileURL: legacyKey)
        }
    }

    @Test func partialExtractionNeverRoutes() throws {
        let grammar = FilenameGrammar(
            id: "strict",
            name: "Strict",
            template: "{date}_{study}_{batch}",
            fields: [
                GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "yyyyMMdd"),
                GrammarField(name: "study", role: "Study", type: .string),
                GrammarField(name: "batch", role: "Batch", type: .number, formatHint: "001"),
            ]
        )

        let complete = FilenameGrammarEngine.extract(from: "20261012_deposition_007.csv", grammar: grammar)
        #expect(complete.isMatched == true)
        #expect(complete.unmatchedReason == nil)
        #expect(complete.extractedFields["batch"] == "007")

        let truncated = FilenameGrammarEngine.extract(from: "20261012_deposition.csv", grammar: grammar)
        #expect(truncated.isMatched == false)
        #expect(truncated.unmatchedReason != nil)

        let trailingGarbage = FilenameGrammarEngine.extract(from: "20261012_deposition_007-extra.csv", grammar: grammar)
        #expect(trailingGarbage.isMatched == false)
    }

    @Test func legacyImportReportsDiagnosticsAndLeavesOriginals() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyURL = project.root.appendingPathComponent(FilenameGrammarEngine.legacyRelativePath)
        let legacyText = """
            active_grammar_id: "autolab-convention"
            grammars:
              - id: "autolab-convention"
                name: "Autolab USTH Scientific"
                template: "{date}_{study}_{batch}"
                description: "Legacy probe"
                is_default: true
                fields:
                  - name: "date"
                    role: "Date & Time"
                    type: "datetime"
                    format_hint: "DDMMYY-HHmmSS"
                    strip_brackets: false
                    is_optional: false
                    is_facet: true
                  - name: "study"
                    role: "Study"
                    is_optional: true
                    is_facet: false
                  - name: "batch"
                    role: "Batch"
                    type: "number"
                    format_hint: "001"
            """
        try writeText(legacyText + "\n", to: legacyURL)
        let beforeBytes = try Data(contentsOf: legacyURL)

        let imported = try FilenameGrammarEngine.importLegacy(project: project)
        #expect(imported.catalog.grammars.count == 1)
        #expect(imported.catalog.activeGrammarID == "autolab-convention")
        let fields = imported.catalog.grammars[0].fields
        #expect(fields.count == 3)
        // Absent legacy type defaults to string and is flagged for review.
        #expect(fields.first(where: { $0.name == "study" })?.type == .string)
        #expect(fields.first(where: { $0.name == "date" })?.formatHint == "DDMMYY-HHmmSS")
        #expect(fields.first(where: { $0.name == "study" })?.isOptional == true)
        #expect(fields.first(where: { $0.name == "study" })?.isFacet == false)
        let blob = imported.diagnostics.joined(separator: "\n")
        #expect(blob.contains("active_grammar_id"))
        #expect(blob.contains("is_facet"))
        #expect(blob.contains("format_hint"))
        #expect(blob.contains("is_optional"))
        #expect(blob.contains("needs review"))
        // Legacy originals are never rewritten by an import.
        #expect(try Data(contentsOf: legacyURL) == beforeBytes)

        // Canonical load does not silently promote legacy definitions.
        let canonicalURL = project.root.appendingPathComponent(FilenameGrammarEngine.relativePath)
        #expect(throws: GrammarCatalogError.fileNotFound(path: canonicalURL.path)) {
            _ = try FilenameGrammarEngine.load(project: project)
        }
        do {
            _ = try FilenameGrammarEngine.importLegacy(fileURL: canonicalURL)
            Issue.record("absent legacy file should throw")
        } catch let error as GrammarCatalogError {
            #expect(error == .fileNotFound(path: canonicalURL.path))
        }

        // Re-saving the import produces strict schema-v1 output with stable keys.
        try FilenameGrammarEngine.save(catalog: imported.catalog, project: project)
        let savedText = try String(contentsOf: canonicalURL, encoding: .utf8)
        #expect(savedText.contains("schema_version: 1"))
        #expect(savedText.contains("role: \"datetime\""))
        #expect(!savedText.contains("is_facet"))
        #expect(!savedText.contains("active_grammar_id"))
        let reloaded = try FilenameGrammarEngine.load(project: project)
        #expect(reloaded.grammars[0].fields.map(\.name) == ["date", "study", "batch"])
        #expect(reloaded.grammars[0].fields.map(\.role) == ["Date & Time", "Study", "Batch"])
    }

    @Test func malformedCanonicalNeverFallsBackToLegacy() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyURL = project.root.appendingPathComponent(FilenameGrammarEngine.legacyRelativePath)
        try writeText("grammars:\n  - id: \"legacy-only\"\n    name: \"Legacy\"\n    template: \"{a}\"\n    fields:\n      - name: \"a\"\n        role: \"remarks\"\n        type: \"string\"\n", to: legacyURL)
        let canonicalURL = project.root.appendingPathComponent(FilenameGrammarEngine.relativePath)
        try writeText("schema_version: 1\ngrammars: [oops\n", to: canonicalURL)

        do {
            _ = try FilenameGrammarEngine.load(project: project)
            Issue.record("malformed canonical file should throw, not fall back")
        } catch let error as GrammarCatalogError {
            if case .parseFailed = error { } else {
                Issue.record("expected parseFailed, got \(error)")
            }
        }
    }

    @Test func invalidSavePreservesExistingDocument() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let valid = makeStrictCatalog()
        try FilenameGrammarEngine.save(catalog: valid, project: project)
        let fileURL = project.root.appendingPathComponent(FilenameGrammarEngine.relativePath)
        let before = try Data(contentsOf: fileURL)

        let duplicated = FilenameGrammarCatalog(grammars: [valid.grammars[0], valid.grammars[0]])
        #expect(throws: GrammarCatalogError.duplicateGrammarID("standard-scientific")) {
            try FilenameGrammarEngine.save(catalog: duplicated, project: project)
        }
        #expect(try Data(contentsOf: fileURL) == before)
        #expect(try FilenameGrammarEngine.load(project: project) == valid)
    }

    @Test func loadCombinedNeverMasksMalformedCanonical() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        // Legacy side present with a distinctive id that must never leak through.
        let legacyURL = project.root.appendingPathComponent(FilenameGrammarEngine.legacyRelativePath)
        try writeText("grammars:\n  - id: \"legacy-smuggle\"\n    name: \"Legacy\"\n    template: \"{a}\"\n    fields:\n      - name: \"a\"\n        role: \"remarks\"\n        type: \"string\"\n", to: legacyURL)
        // Canonical exists but is malformed: strict load correctly throws.
        let canonicalURL = project.root.appendingPathComponent(FilenameGrammarEngine.relativePath)
        try writeText("schema_version: 1\ngrammars: [oops\n", to: canonicalURL)
        do {
            _ = try FilenameGrammarEngine.load(project: project)
            Issue.record("malformed canonical should throw, not fall back")
        } catch { }

        let tempGlobalDir = FileManager.default.temporaryDirectory.appendingPathComponent("global-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempGlobalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempGlobalDir) }
        let tempGlobalFile = tempGlobalDir.appendingPathComponent("grammar.yaml")
        try writeText("schema_version: 1\ngrammars: [oops\n", to: tempGlobalFile)

        let combined = FilenameGrammarEngine.loadCombined(project: project, globalURL: tempGlobalFile)
        #expect(combined.projectGrammars.isEmpty)
        #expect(!combined.projectGrammars.contains(where: { $0.id == "legacy-smuggle" }))
        #expect(combined.globalGrammars.map(\.id) == FilenameGrammarCatalog.standardDefaults.map(\.id))
        #expect(combined.activeID == "standard-scientific")
    }

    @Test func loadCombinedHasNoEnforcedPathCallers() throws {
        // Caller audit: loadCombined is a best-effort display helper. The
        // enforced save/routing paths use throwing load(project:), so no file
        // under Sources/ may call loadCombined except its definition site.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourcesRoot = repoRoot.appendingPathComponent("Sources")
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("loadCombined") else { continue }
            if url.lastPathComponent == "FilenameGrammarEngine.swift" { continue }
            offenders.append(url.lastPathComponent)
        }
        #expect(offenders.isEmpty, "loadCombined callers outside its definition: \(offenders)")
        // The editor's enforced paths use throwing load/save, not loadCombined.
        let editorURL = repoRoot.appendingPathComponent("Sources/RawViewApp/Editor/EditorWorkspaceView.swift")
        let editor = try String(contentsOf: editorURL, encoding: .utf8)
        #expect(!editor.contains("loadCombined"))
        #expect(editor.contains("FilenameGrammarEngine.load(project:"))
        #expect(editor.contains("FilenameGrammarEngine.save(catalog:"))
    }

    // MARK: - Task 7: grammar-variable Explorer views (RED-first)

    private func viewGrammar() -> FilenameGrammar {
        FilenameGrammar(
            id: "study-grammar",
            name: "Study",
            template: "{study}_{run}.txt",
            fields: [
                GrammarField(name: "study", role: "Study"),
                GrammarField(name: "run", role: "Batch", isOptional: true),
            ]
        )
    }

    private func viewSource(_ name: String, dir: String = "data/raw") -> RawSource {
        RawSource(
            relativePath: "\(dir)/\(name)",
            url: URL(fileURLWithPath: "/proj/\(dir)/\(name)"),
            byteSize: 8
        )
    }

    @Test func groupsSourcesByDeclaredVariableExactlyOnce() {
        let grammar = viewGrammar()
        let sources = [
            viewSource("alpha_02.txt", dir: "my_batch/batch1"),
            viewSource("beta_01.txt"),
            viewSource("alpha_01.txt", dir: "my_batch/batch2"),
        ]
        let groups = SourceGrouping.groups(sources: sources, grammar: grammar, variable: "study")
        #expect(groups.map(\.label) == ["alpha", "beta"])
        #expect(groups[0].sourceIDs.sorted() == ["my_batch/batch1/alpha_02.txt", "my_batch/batch2/alpha_01.txt"].sorted())
        #expect(groups[1].sourceIDs == ["data/raw/beta_01.txt"])
        // Every source occurs exactly once across all groups.
        #expect(groups.flatMap(\.sourceIDs).sorted() == sources.map(\.id).sorted())
    }

    @Test func groupsPartialAndNonmatchesAsUnmatched() {
        let grammar = FilenameGrammar(
            id: "tagged-grammar",
            name: "Tagged",
            template: "{study}_{run}_{tag}.txt",
            fields: [
                GrammarField(name: "study", role: "Study"),
                GrammarField(name: "run", role: "Batch"),
                GrammarField(name: "tag", role: "Remarks"),
            ]
        )
        let sources = [
            viewSource("alpha_01_x.txt"),
            viewSource("alpha_01.txt"),
            viewSource("notes.csv"),
        ]
        let groups = SourceGrouping.groups(sources: sources, grammar: grammar, variable: "study")
        let byLabel = Dictionary(uniqueKeysWithValues: groups.map { ($0.label, $0.sourceIDs) })
        // Partial facts (truncated token list) never group as confirmed matches.
        #expect(byLabel["alpha"] == ["data/raw/alpha_01_x.txt"])
        #expect((byLabel[SourceGrouping.unmatchedBucketLabel] ?? []).sorted()
            == ["data/raw/alpha_01.txt", "data/raw/notes.csv"])
        #expect(groups.last?.label == SourceGrouping.unmatchedBucketLabel)
    }

    @Test func groupsAbsentOptionalVariableAsMissingValue() {
        let grammar = viewGrammar()
        let sources = [viewSource("alpha.txt"), viewSource("alpha_01.txt")]
        // Routing key fields stay unrelated to view eligibility: grouping by a
        // routing-style field still works, and the absent optional lands in
        // Missing value rather than vanishing.
        let byRun = SourceGrouping.groups(sources: sources, grammar: grammar, variable: "run")
        #expect(byRun.map(\.label) == ["01", SourceGrouping.missingValueBucketLabel])
        #expect(byRun[0].sourceIDs == ["data/raw/alpha_01.txt"])
        #expect(byRun[1].sourceIDs == ["data/raw/alpha.txt"])
        let byStudy = SourceGrouping.groups(sources: sources, grammar: grammar, variable: "study")
        #expect(byStudy.map(\.label) == ["alpha"])
        #expect(byStudy[0].sourceIDs.sorted() == ["data/raw/alpha.txt", "data/raw/alpha_01.txt"])
    }

    @Test func groupsQualifiesLiteralBucketCollisions() {
        let grammar = viewGrammar()
        let sources = [viewSource("Unmatched_01.txt"), viewSource("notes.csv")]
        let groups = SourceGrouping.groups(sources: sources, grammar: grammar, variable: "study")
        let labels = groups.map(\.label)
        #expect(labels.contains(SourceGrouping.unmatchedBucketLabel))
        // A matched literal "Unmatched" must not collide with the bucket.
        let literal = labels.first(where: { $0 != SourceGrouping.unmatchedBucketLabel && $0.contains("Unmatched") })
        #expect(literal != nil, "literal collision was not qualified: \(labels)")
        let byLabel = Dictionary(uniqueKeysWithValues: groups.map { ($0.label, $0.sourceIDs) })
        #expect(byLabel[SourceGrouping.unmatchedBucketLabel] == ["data/raw/notes.csv"])
        #expect(byLabel[literal!] == ["data/raw/Unmatched_01.txt"])
    }

    @Test func groupsOrderIsDeterministicUnderReorderedInput() {
        let grammar = viewGrammar()
        let sources = [
            viewSource("beta_02.txt"), viewSource("notes.csv"),
            viewSource("alpha.txt"), viewSource("alpha_01.txt"),
        ]
        let forward = SourceGrouping.groups(sources: sources, grammar: grammar, variable: "run")
        let backward = SourceGrouping.groups(sources: sources.reversed(), grammar: grammar, variable: "run")
        #expect(forward == backward)
        #expect(forward.map(\.label) == ["01", "02", SourceGrouping.missingValueBucketLabel, SourceGrouping.unmatchedBucketLabel])
    }

    @Test func groupsUnknownVariableAsMissingValue() {
        // Absent references (renamed/deleted variable) never drop sources:
        // full matches land in Missing value, nonmatches in Unmatched.
        let grammar = viewGrammar()
        let sources = [viewSource("alpha_01.txt"), viewSource("notes.csv")]
        let groups = SourceGrouping.groups(sources: sources, grammar: grammar, variable: "renamed-var")
        let byLabel = Dictionary(uniqueKeysWithValues: groups.map { ($0.label, $0.sourceIDs) })
        #expect(byLabel[SourceGrouping.missingValueBucketLabel] == ["data/raw/alpha_01.txt"])
        #expect(byLabel[SourceGrouping.unmatchedBucketLabel] == ["data/raw/notes.csv"])
        #expect(groups.flatMap(\.sourceIDs).sorted() == sources.map(\.id).sorted())
    }

    @Test func removedViewSelectionsPurgeCleanlyAndGroupsStayUnfiltered() throws {
        // Task 7 fix round 1: removing an Explorer view purges its filter
        // selections so no chip renders and grouping stays unfiltered.
        let grammar = viewGrammar()
        let sources = [viewSource("alpha_01.txt"), viewSource("beta_01.txt")]
        let removedKey = "view\0study-grammar\0study"
        var filter = SourceFilter()
        filter.toggle(facet: removedKey, value: "alpha")
        #expect(!filter.isEmpty)
        // A stale selection still filters at the model level before purge.
        #expect(filter.matches([removedKey: ["beta"]]) == false)
        // RED: no API purges stale facets (fails to compile before fix).
        filter.removeFacets(notIn: ["tree", ""])
        #expect(filter.isEmpty)
        #expect(filter.selections[removedKey] == nil)
        // With selections gone, grouping covers every source.
        let groups = SourceGrouping.groups(sources: sources, grammar: grammar, variable: "study")
        #expect(groups.flatMap(\.sourceIDs).sorted() == sources.map(\.id).sorted())
    }

    // MARK: - Task 2: variable-defined names (role optional)

    @Test func variableNativeNamesRoundTripWithoutRole() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("grammar.yaml")

        let catalog = FilenameGrammarCatalog(grammars: [
            FilenameGrammar(
                id: "native",
                name: "Native",
                template: "{batch}_{operator}_{run}",
                fields: [
                    GrammarField(name: "batch", type: .number, formatHint: "001", isOptional: true),
                    GrammarField(name: "operator", type: .string),
                    GrammarField(name: "run", type: .number, formatHint: "01"),
                ]
            ),
        ])
        #expect(catalog.grammars[0].fields.allSatisfy { $0.role == nil })

        try FilenameGrammarEngine.save(catalog: catalog, fileURL: fileURL)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!text.contains("role:"))

        let loaded = try FilenameGrammarEngine.load(fileURL: fileURL)
        #expect(loaded == catalog)

        // {batch} becomes batch, not Remarks.
        let facts = FilenameGrammarEngine.extract(from: "007_alice_03.csv", grammar: loaded.grammars[0])
        #expect(facts.isMatched == true)
        #expect(facts.extractedFields["batch"] == "007")
        #expect(facts.batch == "007")
        #expect(facts.extractedFields["operator"] == "alice")
        #expect(facts.extractedFields["run"] == "03")
        #expect(facts.remarks.isEmpty)
    }

    @Test func legacyRoleMappingSurvivesLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("grammar.yaml")
        try writeText("""
            schema_version: 1
            grammars:
              - id: "legacy-roles"
                name: "Legacy"
                template: "{date}_{device-id}_{batch}"
                fields:
                  - name: "date"
                    role: "datetime"
                    type: "datetime"
                    format: "yyyyMMdd"
                    optional: false
                  - name: "device-id"
                    role: "device"
                    type: "string"
                    optional: false
                  - name: "batch"
                    role: "batch"
                    type: "number"
                    format: "001"
                    optional: true
            """ + "\n", to: fileURL)

        let loaded = try FilenameGrammarEngine.load(fileURL: fileURL)
        // Stored stable keys map back to display labels; nothing is reinterpreted.
        #expect(loaded.grammars[0].fields.map(\.role) == ["Date & Time", "Device ID", "Batch"])

        let facts = FilenameGrammarEngine.extract(from: "20261012_D01_007.csv", grammar: loaded.grammars[0])
        #expect(facts.isMatched == true)
        #expect(facts.timestamp == "20261012")
        #expect(facts.deviceID == "D01")
        #expect(facts.batch == "007")

        // Re-saving keeps the explicit role mapping until explicitly edited.
        try FilenameGrammarEngine.save(catalog: loaded, fileURL: fileURL)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(text.contains("role: \"datetime\""))
        #expect(text.contains("role: \"device\""))
        #expect(text.contains("role: \"batch\""))

        // Same names without roles: exact variable identity only — no legacy
        // alias inference ("date" is not "datetime"), but {batch} is batch,
        // and raw extracted values are identical.
        let native = FilenameGrammar(
            id: "native", name: "Native", template: "{date}_{device-id}_{batch}",
            fields: [
                GrammarField(name: "date", type: .datetime, formatHint: "yyyyMMdd"),
                GrammarField(name: "device-id", type: .string),
                GrammarField(name: "batch", type: .number, formatHint: "001", isOptional: true),
            ]
        )
        let nativeFacts = FilenameGrammarEngine.extract(from: "20261012_D01_007.csv", grammar: native)
        #expect(nativeFacts.isMatched == true)
        #expect(nativeFacts.timestamp == nil)
        #expect(nativeFacts.deviceID == nil)
        #expect(nativeFacts.batch == "007")
        #expect(nativeFacts.extractedFields == facts.extractedFields)
    }

    @Test func customVariableMetadataIsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("grammar.yaml")

        let catalog = FilenameGrammarCatalog(grammars: [
            FilenameGrammar(
                id: "custom-native", name: "Custom Native", template: "{operator}_{chamber}_{run}",
                fields: [
                    GrammarField(name: "operator", type: .string),
                    GrammarField(name: "chamber", type: .string),
                    GrammarField(name: "run", type: .number, formatHint: "01"),
                ]
            ),
        ])
        try FilenameGrammarEngine.save(catalog: catalog, fileURL: fileURL)
        let savedText = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!savedText.contains("role:"))
        let loaded = try FilenameGrammarEngine.load(fileURL: fileURL)
        #expect(loaded == catalog)

        let grammar = loaded.grammars[0]
        let facts = FilenameGrammarEngine.extract(from: "alice_A_03.csv", grammar: grammar)
        #expect(facts.isMatched == true)
        #expect(facts.extractedFields == ["operator": "alice", "chamber": "A", "run": "03"])
        #expect(facts.timestamp == nil)
        #expect(facts.instrument == nil)
        #expect(facts.mode == nil)
        #expect(facts.category == nil)
        #expect(facts.batch == nil)

        // Explorer views group by the arbitrary variable; nothing is dropped.
        let sources = [viewSource("alice_A_03.csv"), viewSource("bob_A_04.csv"), viewSource("alice_B_03.csv")]
        let groups = SourceGrouping.groups(sources: sources, grammar: grammar, variable: "chamber")
        #expect(groups.map(\.label) == ["A", "B"])
        let byLabel = Dictionary(uniqueKeysWithValues: groups.map { ($0.label, $0.sourceIDs) })
        #expect(byLabel["A"]?.sorted() == ["data/raw/alice_A_03.csv", "data/raw/bob_A_04.csv"])
        #expect(groups.flatMap(\.sourceIDs).sorted() == sources.map(\.id).sorted())
    }

    @Test func renameRejectsDuplicateInvalidAndReferencedNames() throws {
        func makeGrammar() -> FilenameGrammar {
            FilenameGrammar(
                id: "g", name: "G", template: "{study}_{run}",
                fields: [
                    GrammarField(name: "study", role: "Study"),
                    GrammarField(name: "run", role: "Batch"),
                ]
            )
        }

        // Happy path: template placeholder and field rename atomically; role untouched.
        var grammar = makeGrammar()
        try FilenameGrammarEngine.renameVariable(in: &grammar, from: "run", to: "trial")
        #expect(grammar.template == "{study}_{trial}")
        #expect(grammar.fields.map(\.name) == ["study", "trial"])
        #expect(grammar.fields[1].role == "Batch")
        let facts = FilenameGrammarEngine.extract(from: "alpha_01.csv", grammar: grammar)
        #expect(facts.extractedFields["trial"] == "01")

        // Duplicate target: rejected, template and fields unchanged.
        var dup = makeGrammar()
        #expect(throws: GrammarCatalogError.duplicateVariable(grammar: "g", variable: "study")) {
            try FilenameGrammarEngine.renameVariable(in: &dup, from: "run", to: "study")
        }
        #expect(dup == makeGrammar())

        // Invalid names: rejected unchanged (empty, whitespace, braces, brackets).
        for bad in ["", "   ", "{x}", "a b", "a{b", "a}b", "a[b", "a]b"] {
            var probe = makeGrammar()
            do {
                try FilenameGrammarEngine.renameVariable(in: &probe, from: "run", to: bad)
                Issue.record("rename to '\(bad)' should throw")
            } catch { }
            #expect(probe == makeGrammar())
        }

        // Unknown source variable: rejected unchanged.
        var missing = makeGrammar()
        #expect(throws: GrammarCatalogError.invalidGrammar(grammar: "g", reason: "unknown variable 'nope'")) {
            try FilenameGrammarEngine.renameVariable(in: &missing, from: "nope", to: "trial")
        }
        #expect(missing == makeGrammar())

        // Referenced names are blocked and list every affected reference.
        var ref = makeGrammar()
        do {
            try FilenameGrammarEngine.renameVariable(
                in: &ref, from: "study", to: "cohort",
                variantKeys: ["study"],
                explorerViews: [ExplorerViewDefinition(grammarID: "g", variable: "study")],
                sourceLabels: [SourceLabelLayout(grammarID: "g", rows: [SourceLabelRow(variables: ["study", "run"])])]
            )
            Issue.record("referenced rename should throw")
        } catch let error as GrammarCatalogError {
            guard case .referencedVariable(let g, let v, let refs) = error else {
                Issue.record("expected referencedVariable, got \(error)")
                return
            }
            #expect(g == "g")
            #expect(v == "study")
            #expect(refs.count == 3)
            #expect(refs.contains(where: { $0.contains("study") }))
        }
        #expect(ref == makeGrammar())

        // References owned by other grammars never block.
        var other = makeGrammar()
        try FilenameGrammarEngine.renameVariable(
            in: &other, from: "study", to: "cohort",
            explorerViews: [ExplorerViewDefinition(grammarID: "other", variable: "study")],
            sourceLabels: [SourceLabelLayout(grammarID: "other", rows: [SourceLabelRow(variables: ["study"])])]
        )
        #expect(other.template == "{cohort}_{run}")

        // No-op rename to the same name succeeds without changes.
        var same = makeGrammar()
        try FilenameGrammarEngine.renameVariable(in: &same, from: "run", to: "run")
        #expect(same == makeGrammar())
    }

    @Test func renameBlockedBySettingsFileReferences() throws {
        // TMPDIR fixture: a real setting.yaml with an Explorer view and a
        // source-label row referencing grammar "g" variable "study".
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameSettings-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".rawviewer", isDirectory: true),
            withIntermediateDirectories: true)
        let settingsYAML = """
            schema_version: 3
            data_root: "data/raw"
            default_view: "tree"
            default_preset: "nature-single"
            developer_mode: false
            explorer_views:
              - grammar_id: "g"
                variable: "study"
            source_labels:
              - grammar_id: "g"
                rows:
                  - variables: ["study"]
                    font_size: 12
                    weight: "regular"
                    font: "normal"
                    emphasis: "primary"
            """
        try settingsYAML.write(
            to: root.appendingPathComponent(".rawviewer/setting.yaml"),
            atomically: true, encoding: .utf8)
        let settings = try ProjectSettingsStore.load(projectRoot: root)
        #expect(settings != nil)

        var grammar = FilenameGrammar(
            id: "g", name: "G", template: "{study}_{run}",
            fields: [
                GrammarField(name: "study", role: "Study"),
                GrammarField(name: "run", role: "Batch"),
            ]
        )
        do {
            try FilenameGrammarEngine.renameVariable(
                in: &grammar, from: "study", to: "cohort",
                variantKeys: [],
                explorerViews: settings?.explorerViews ?? [],
                sourceLabels: settings?.sourceLabels ?? []
            )
            Issue.record("settings-referenced rename should throw")
        } catch let error as GrammarCatalogError {
            guard case .referencedVariable(let g, let v, let refs) = error else {
                Issue.record("expected referencedVariable, got \(error)")
                return
            }
            #expect(g == "g")
            #expect(v == "study")
            #expect(refs.contains(where: { $0.contains("Explorer view") }))
            #expect(refs.contains(where: { $0.contains("source label row") }))
        }
        #expect(grammar.template == "{study}_{run}")
        #expect(grammar.fields.map(\.name) == ["study", "run"])
    }

    @Test func nilRoleSurvivesTypeAndFormatEdits() throws {
        // A variable-native field (nil role) keeps nil through type/format
        // edits and serializes with no role line.
        var catalog = FilenameGrammarCatalog(grammars: [
            FilenameGrammar(
                id: "g", name: "G", template: "{batch}",
                fields: [GrammarField(name: "batch")]
            )
        ])
        catalog.grammars[0].fields[0].type = .number
        catalog.grammars[0].fields[0].formatHint = "001"
        #expect(catalog.grammars[0].fields[0].role == nil)
        let text = try FilenameGrammarEngine.serializedYAML(catalog: catalog)
        #expect(!text.contains("role:"))
        #expect(text.contains("name: \"batch\""))
        #expect(text.contains("format: \"001\""))
    }

    // MARK: - Task 4: safe grammar deletion

    private func makeTwoGrammarCatalog() -> FilenameGrammarCatalog {
        FilenameGrammarCatalog(grammars: [
            FilenameGrammar(
                id: "g1", name: "G1", template: "{study}_{run}",
                fields: [
                    GrammarField(name: "study", role: "Study"),
                    GrammarField(name: "run", role: "Batch"),
                ]
            ),
            FilenameGrammar(
                id: "g2", name: "G2", template: "{study}_{run}",
                fields: [
                    GrammarField(name: "study", role: "Study"),
                    GrammarField(name: "run", role: "Batch"),
                ]
            ),
        ])
    }

    private let task4SettingsYAML = """
        schema_version: 3
        data_root: "data/raw"
        default_view: "tree"
        default_preset: "nature-single"
        developer_mode: false
        explorer_views:
          - grammar_id: "g1"
            variable: "study"
        source_labels:
          - grammar_id: "g1"
            rows:
              - variables: ["study"]
                font_size: 12
                weight: "regular"
                font: "normal"
                emphasis: "primary"
        """

    @Test func grammarDeleteBlocksProfileAndViewReferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrammarDelete-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownedDir = root.appendingPathComponent(".rawviewer/instrument", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedDir, withIntermediateDirectories: true)
        // A valid-shaped profile, an excluded legacy file, and an excluded
        // malformed file all reference g1; g2 is referenced nowhere.
        try "schema_version: 3\nfilename:\n  grammar_id: \"g1\"\n".write(
            to: ownedDir.appendingPathComponent("p1.yaml"), atomically: true, encoding: .utf8)
        try "schema_version: 2\nfilename:\n  grammar_id: \"g1\"\n".write(
            to: ownedDir.appendingPathComponent("legacy.yaml"), atomically: true, encoding: .utf8)
        try "schema_version: 3\nfilename: [unclosed\n  grammar_id: \"g1\"\n".write(
            to: ownedDir.appendingPathComponent("broken.yaml"), atomically: true, encoding: .utf8)
        try task4SettingsYAML.write(
            to: root.appendingPathComponent(".rawviewer/setting.yaml"),
            atomically: true, encoding: .utf8)

        let blockers = try FilenameGrammarEngine.grammarDeleteBlockers(grammarID: "g1", projectRoot: root)
        #expect(blockers.contains(where: { $0.contains("p1.yaml") && $0.contains("g1") }))
        #expect(blockers.contains(where: { $0.contains("legacy.yaml") && $0.contains("g1") }))
        #expect(blockers.contains(where: { $0.contains("broken.yaml") && $0.contains("g1") }))
        #expect(blockers.contains(where: { $0.contains("study") && $0.contains("g1") }))
        #expect(blockers.contains(where: { $0.contains("source label") && $0.contains("g1") }))
        #expect(try FilenameGrammarEngine.grammarDeleteBlockers(grammarID: "g2", projectRoot: root) == [])

        // Fail closed: an unreadable dependent never silently passes.
        try FileManager.default.createDirectory(
            at: ownedDir.appendingPathComponent("unreadable.yaml"), withIntermediateDirectories: true)
        #expect(throws: SafeDeleteError.self) {
            try FilenameGrammarEngine.grammarDeleteBlockers(grammarID: "g2", projectRoot: root)
        }

        // Fail closed: corrupt settings block every grammar deletion.
        let corruptRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrammarDeleteCorrupt-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        try FileManager.default.createDirectory(
            at: corruptRoot.appendingPathComponent(".rawviewer", isDirectory: true),
            withIntermediateDirectories: true)
        try "schema_version: 99\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\n".write(
            to: corruptRoot.appendingPathComponent(".rawviewer/setting.yaml"),
            atomically: true, encoding: .utf8)
        #expect(throws: SafeDeleteError.self) {
            try FilenameGrammarEngine.grammarDeleteBlockers(grammarID: "g2", projectRoot: corruptRoot)
        }
    }

    @Test func lastGrammarDeletionPersistsEmptyCatalog() throws {
        let (project, root) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let single = FilenameGrammarCatalog(grammars: [makeTwoGrammarCatalog().grammars[0]])
        try FilenameGrammarEngine.save(catalog: single, project: project)

        // Deleting the final entry persists an empty catalog, never a
        // recreation and never the grammar.yaml file removal.
        var reduced = single
        reduced.grammars.removeAll(where: { $0.id == "g1" })
        reduced.activeGrammarID = nil
        try FilenameGrammarEngine.save(catalog: reduced, project: project)

        let file = root.appendingPathComponent(".rawviewer/grammar.yaml")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == "schema_version: 1\ngrammars: []\n")
        let reloaded = try FilenameGrammarEngine.load(project: project)
        #expect(reloaded.grammars.isEmpty)
        #expect(reloaded.activeGrammarID == nil)
    }
}

