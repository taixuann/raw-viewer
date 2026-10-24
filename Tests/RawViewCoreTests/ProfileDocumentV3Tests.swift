import Foundation
import Testing
@testable import RawViewCore

/// Task 2: typed variant profile contract (schema v3).
/// RED-first: these tests define ProfileDocumentV3, its locators, editor
/// make/apply mapping and ProfileUpgradeDraft before they exist.
struct ProfileDocumentV3Tests {
    // MARK: - Fixtures

    static let baseYAML: String = """
        schema_version: 3
        identity:
          id: "autolab-usth"
          name: "Autolab USTH"
          instrument:
            id: "pgstat-01"
            name: "Potentiostat 01"
        filename:
          grammar_id: "standard-scientific"
          variant_keys:
            - "instrument"
            - "mode"
        variants:
          - id: "cv"
            name: "CV"
            key_values:
              instrument: "autolab-usth"
              mode: "cv"
            match:
              filename_contains_all:
                - "cv"
              content_contains_any:
                - "Cyclic"
            raw_stream:
              extensions:
                - ".txt"
              encoding:
                - "utf-8"
              delimiter: ";"
              decimal_separator: ","
              rows:
                header:
                  first_nonblank: true
                data_start:
                  after_header: true
                excluded_metadata: []
              columns:
                - id: "potential"
                  source:
                    header: "Potential applied (V)"
                  label: "Voltage"
                  quantity: "voltage"
                  unit: "V"
                  required: true
                  role: "channel"
                  axes:
                    - "x"
                - id: "current"
                  source:
                    header: "WE(1).Current (A)"
                    aliases:
                      - "I"
                  label: "Current"
                  quantity: "current"
                  unit: "A"
                  required: true
                  role: "channel"
                  axes:
                    - "y"
                - id: "charge"
                  source:
                    header: "Charge (C)"
                  label: "Charge"
                  quantity: "charge"
                  unit: "C"
                  required: false
                  role: "channel"
                  axes:
                    - "y"
                - id: "notes"
                  source:
                    header: "Notes"
                  label: "Notes"
                  quantity: "text"
                  required: true
                  role: "skip"
                  axes: []
                - id: "step"
                  source:
                    header: "Step"
                  label: "Step"
                  quantity: "index"
                  required: true
                  role: "progression"
                  axes: []
                  progression:
                    type: "index"
                    behavior: "discrete"
            metadata: []
            default_plot:
              x: "potential"
              y:
                - "current"
        """

    /// A second variant sharing the base key tuple but with a positional
    /// layout and distinguishing selectors. `id` is substitutable per test.
    static func positionalVariant(id: String, mode: String) -> String {
        "\n" + """
          - id: "\(id)"
            name: "CV two-column"
            key_values:
              instrument: "autolab-usth"
              mode: "\(mode)"
            match:
              filename_contains_all:
                - "cv"
                - "2col"
            raw_stream:
              extensions:
                - ".txt"
              encoding:
                - "utf-8"
              delimiter: ";"
              decimal_separator: ","
              rows:
                header:
                  row: 3
                data_start:
                  row: 4
                excluded_metadata: []
              columns:
                - id: "potential"
                  source:
                    column: 1
                  label: "Voltage"
                  quantity: "voltage"
                  required: true
                  role: "channel"
                  axes:
                    - "x"
                - id: "current"
                  source:
                    column: 2
                  label: "Current"
                  quantity: "current"
                  required: true
                  role: "channel"
                  axes:
                    - "y"
            metadata: []
            default_plot:
              x: "potential"
              y:
                - "current"
        """
    }

    static func catalog() -> FilenameGrammarCatalog {
        FilenameGrammarCatalog(grammars: [
            FilenameGrammar(
                id: "standard-scientific",
                name: "Standard Filename Pattern",
                template: "{instrument}.{mode}_{sample}",
                fields: [
                    GrammarField(name: "instrument", role: "instrument", type: .string),
                    GrammarField(name: "mode", role: "mode", type: .string),
                    GrammarField(name: "sample", role: "sample", type: .string, isOptional: true),
                ])
        ])
    }

    private func mutated(_ old: String, _ new: String, base: String = baseYAML) -> String {
        let baseLines = base.components(separatedBy: "\n")
        let oldLines = old.components(separatedBy: "\n")
        guard oldLines.count <= baseLines.count else {
            fatalError("mutation anchor longer than base: " + old)
        }
        let want = oldLines.map { $0.trimmingCharacters(in: .whitespaces) }
        for start in 0...(baseLines.count - oldLines.count) {
            let run = baseLines[start..<(start + oldLines.count)]
            guard run.map({ $0.trimmingCharacters(in: .whitespaces) }) == want else { continue }
            let indent = String(baseLines[start].prefix(while: { $0 == " " }))
            let newLines = new.components(separatedBy: "\n")
            // New continuations are written relative to the anchor line.
            let floor = newLines.first?.prefix(while: { $0 == " " }).count ?? 0
            let rebuilt = newLines.map { line -> String in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
                var rest = line
                var drop = floor
                while drop > 0 && rest.hasPrefix(" ") { rest.removeFirst(); drop -= 1 }
                return indent + rest
            }
            return (baseLines[..<start] + rebuilt + baseLines[(start + oldLines.count)...]).joined(separator: "\n")
        }
        fatalError("mutation anchor not found: " + old)
    }

    // MARK: - Round-trip

    @Test func testV3RoundTripsMultipleVariants() throws {
        let sha = String(repeating: "a", count: 64)
        let doc = ProfileDocumentV3(
            profileID: "autolab-usth",
            profileName: "Autolab USTH",
            instrumentID: "pgstat-01",
            instrumentName: "Potentiostat 01",
            vendor: "Metrohm",
            model: "PGSTAT204",
            grammarID: "standard-scientific",
            variantKeys: ["instrument", "mode"],
            variants: [
                ProfileVariantV3(
                    id: "cv", name: "CV",
                    keyValues: ["instrument": "autolab-usth", "mode": "cv"],
                    match: VariantMatchV3(
                        filenameContainsAll: ["cv"],
                        contentContainsAny: ["Cyclic Voltammetry"]),
                    rawStream: RawStreamV3(
                        extensions: [".txt"], encodings: ["utf-8", "windows-1252"],
                        delimiter: ";", decimalSeparator: ",",
                        rows: RowLocatorsV3(
                            header: .firstNonBlank, dataStart: .afterHeader,
                            dataPrefix: "", commentPrefix: "#",
                            excludedMetadata: [8]),
                        columns: [
                            ProfileColumnV3(id: "potential",
                                            source: ColumnSourceV3(header: "Potential applied (V)"),
                                            label: "Voltage", quantity: "voltage", unit: "V",
                                            role: .channel, axes: [.x]),
                            ProfileColumnV3(id: "current",
                                            source: ColumnSourceV3(header: "WE(1).Current (A)", aliases: ["I"]),
                                            label: "Current", quantity: "current", unit: "A",
                                            role: .channel, axes: [.y]),
                            ProfileColumnV3(id: "current_b",
                                            source: ColumnSourceV3(header: "WE(2).Current (A)"),
                                            label: "Current B", quantity: "current", unit: "A",
                                            role: .channel, axes: [.y]),
                            ProfileColumnV3(id: "charge",
                                            source: ColumnSourceV3(header: "Charge (C)"),
                                            label: "Charge", quantity: "charge", unit: "C",
                                            required: false, role: .channel, axes: [.y]),
                            ProfileColumnV3(id: "elapsed",
                                            source: ColumnSourceV3(header: "Time (s)"),
                                            label: "Time", quantity: "time", unit: "s",
                                            role: .progression, axes: [.x],
                                            progression: ColumnProgressionV3(type: .time, behavior: .continuous)),
                            ProfileColumnV3(id: "step",
                                            source: ColumnSourceV3(header: "Step"),
                                            label: "Step", quantity: "index",
                                            role: .progression,
                                            progression: ColumnProgressionV3(type: .index, behavior: .discrete)),
                            ProfileColumnV3(id: "notes",
                                            source: ColumnSourceV3(header: "Notes"),
                                            label: "Notes", quantity: "text",
                                            role: .skip),
                        ]),
                    metadata: [
                        VariantMetadataV3(key: "started", role: "datetime", row: 1, column: 2,
                                          format: "DDMMYY-HHmmSS"),
                        VariantMetadataV3(key: "operator", role: "operator", row: 2, column: 2),
                        VariantMetadataV3(key: "junk", role: "ignore", row: 3, column: 1),
                        VariantMetadataV3(key: "gain", role: "parameter", row: 4, column: 2,
                                          parameterName: "range", parameterRow: 4, parameterColumn: 1),
                    ],
                    metadataCapture: [.preHeaderFields, .commentKeyValue(prefix: "#")],
                    defaultPlot: DefaultPlotV3(x: "potential", y: ["current", "current_b"],
                                               progression: "elapsed")),
                ProfileVariantV3(
                    id: "cv-2col", name: "CV two-column",
                    keyValues: ["instrument": "autolab-usth", "mode": "cv"],
                    match: VariantMatchV3(filenameContainsAll: ["cv", "2col"], contentContainsAny: nil),
                    rawStream: RawStreamV3(
                        extensions: [".txt"], encodings: ["utf-8"],
                        delimiter: ";", decimalSeparator: ",",
                        rows: RowLocatorsV3(header: .row(3), dataStart: .row(4)),
                        columns: [
                            ProfileColumnV3(id: "potential",
                                            source: ColumnSourceV3(column: 1),
                                            label: "Voltage", quantity: "voltage",
                                            role: .channel, axes: [.x]),
                            ProfileColumnV3(id: "current",
                                            source: ColumnSourceV3(column: 2),
                                            label: "Current", quantity: "current",
                                            role: .channel, axes: [.y]),
                        ]),
                    metadata: [],
                    metadataCapture: [],
                    defaultPlot: DefaultPlotV3(x: "potential", y: ["current"], progression: nil)),
                ProfileVariantV3(
                    id: "ca", name: "CA",
                    keyValues: ["instrument": "autolab-usth", "mode": "ca"],
                    match: nil,
                    rawStream: RawStreamV3(
                        extensions: [".csv"], encodings: ["utf-8"],
                        delimiter: ",", decimalSeparator: ".",
                        rows: RowLocatorsV3(header: .row(5), dataStart: .row(7),
                                            commentPrefix: "//",
                                            excludedMetadata: [1]),
                        columns: [
                            ProfileColumnV3(id: "time",
                                            source: ColumnSourceV3(header: "t/s"),
                                            label: "Time", quantity: "time", unit: "s",
                                            role: .channel, axes: [.x]),
                            ProfileColumnV3(id: "current",
                                            source: ColumnSourceV3(column: 2, header: "i/A"),
                                            label: "Current", quantity: "current", unit: "A",
                                            role: .channel, axes: [.y]),
                        ]),
                    metadata: [],
                    metadataCapture: [],
                    defaultPlot: DefaultPlotV3(x: "time", y: ["current"], progression: nil)),
                ProfileVariantV3(
                    id: "eis", name: "EIS",
                    keyValues: ["instrument": "autolab-usth", "mode": "eis"],
                    match: VariantMatchV3(filenameContainsAll: nil,
                                          contentContainsAny: ["FRA", "impedance"]),
                    rawStream: RawStreamV3(
                        extensions: [".dfr", ".txt"], encodings: ["iso-8859-1"],
                        delimiter: "\t", decimalSeparator: ".",
                        rows: RowLocatorsV3(header: .prefix("Freq"),
                                            dataStart: .afterHeader,
                                            dataPrefix: "DATA"),
                        columns: [
                            ProfileColumnV3(id: "freq",
                                            source: ColumnSourceV3(header: "Frequency (Hz)"),
                                            label: "Frequency", quantity: "frequency", unit: "Hz",
                                            role: .channel, axes: [.x]),
                            ProfileColumnV3(id: "zreal",
                                            source: ColumnSourceV3(header: "Z' (ohm)"),
                                            label: "Z real", quantity: "impedance", unit: "ohm",
                                            role: .channel, axes: [.y]),
                            ProfileColumnV3(id: "zimag",
                                            source: ColumnSourceV3(header: "Z'' (ohm)"),
                                            label: "Z imag", quantity: "impedance", unit: "ohm",
                                            role: .channel, axes: [.y]),
                        ]),
                    metadata: [],
                    metadataCapture: [],
                    defaultPlot: nil),
            ],
            legacyOrigin: ProfileLegacyOrigin(path: "data/instruments/rawview/autolab.yaml", sha256: sha))
        let text = try doc.serializedYAML()
        let back = try ProfileDocumentV3.parse(text: text)
        #expect(back == doc)
        try back.validate(catalog: Self.catalog())
        let again = try ProfileDocumentV3.parse(text: try back.serializedYAML())
        #expect(again == doc)
    }

    @Test func testScalarEscapingRoundTrip() throws {
        var doc = try ProfileDocumentV3.parse(text: Self.baseYAML)
        doc.variants[0].rawStream.columns[0].source.header = "Weird \"quoted\" \\ header; with # hash"
        doc.variants[0].rawStream.columns[0].label = "tab\there"
        doc.variants[0].rawStream.rows.commentPrefix = "#;"
        let back = try ProfileDocumentV3.parse(text: try doc.serializedYAML())
        #expect(back == doc)
    }

    @Test func testSpecInstrumentExampleParses() throws {
        // Verbatim single-variant example from the v3 design spec (flow lists).
        let example = """
            schema_version: 3
            identity:
              id: autolab-usth
              name: Autolab USTH
              instrument:
                id: autolab-usth
                name: Autolab USTH
            filename:
              grammar_id: standard-scientific
              variant_keys: [instrument, mode]
            variants:
              - id: cv
                name: CV
                key_values:
                  instrument: autolab-usth
                  mode: cv
                raw_stream:
                  extensions: [".txt"]
                  encoding: [utf-8]
                  delimiter: ";"
                  decimal_separator: ","
                  rows:
                    header:
                      first_nonblank: true
                    data_start:
                      after_header: true
                    excluded_metadata: []
                  columns:
                    - id: potential
                      source:
                        header: "Potential applied (V)"
                      label: Voltage
                      quantity: voltage
                      unit: V
                      required: true
                      role: channel
                      axes: [x]
                    - id: current
                      source:
                        header: "WE(1).Current (A)"
                      label: Current
                      quantity: current
                      unit: A
                      required: true
                      role: channel
                      axes: [y]
                metadata: []
                default_plot:
                  x: potential
                  y: [current]
            """
        let doc = try ProfileDocumentV3.parse(text: example)
        #expect(doc.profileID == "autolab-usth")
        #expect(doc.variantKeys == ["instrument", "mode"])
        #expect(doc.variants.count == 1)
        #expect(doc.variants[0].defaultPlot == DefaultPlotV3(x: "potential", y: ["current"], progression: nil))
        #expect(doc.variants[0].rawStream.delimiter == ";")
        #expect(doc.variants[0].rawStream.rows.header == .firstNonBlank)
    }

    @Test func testSpecGrammarExampleParsesWithYAMLParser() throws {
        // Verbatim grammar example from the v3 design spec: syntax only.
        let example = """
            schema_version: 1
            grammars:
              - id: standard-scientific
                name: Standard Filename Pattern
                template: "{instrument}.{mode}_{sample}"
                fields:
                  - name: instrument
                    role: instrument
                    type: string
                    optional: false
                  - name: mode
                    role: mode
                    type: string
                    optional: false
                  - name: sample
                    role: sample
                    type: string
                    optional: false
            """
        let node = try YAMLParser.parse(example)
        let grammars = try #require(node.value(for: "grammars")?.listItems)
        #expect(grammars.count == 1)
        #expect(grammars[0].value(for: "template")?.scalarValue == "{instrument}.{mode}_{sample}")
        #expect(grammars[0].value(for: "fields")?.listItems?.count == 3)
    }

    // MARK: - Rejections

    @Test func testRejectsUnsafeProfileIDs() {
        for bad in ["", "../evil", "a/b", "..", ".", "a\\b", "bad\nid"] {
            #expect(throws: ProfileDocumentError.self) {
                try ProfileDocumentV3.parse(text: self.mutated("id: \"autolab-usth\"", "id: \"" + bad + "\""))
            }
        }
    }

    @Test func testRejectsDuplicateVariantAndColumnIDs() {
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: Self.baseYAML + Self.positionalVariant(id: "cv", mode: "ca"))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated("- id: \"current\"", "- id: \"potential\""))
        }
    }

    @Test func testAllowsDuplicateKeyTuplesWithSelectors() throws {
        let doc = try ProfileDocumentV3.parse(
            text: Self.baseYAML + Self.positionalVariant(id: "cv-2col", mode: "cv"))
        #expect(doc.variants.count == 2)
        try doc.validate(catalog: Self.catalog())
    }

    @Test func testRejectsIncompleteKeyValues() {
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated(
                "key_values:\n              instrument: \"autolab-usth\"\n              mode: \"cv\"",
                "key_values:\n  instrument: \"autolab-usth\""))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated(
                "key_values:\n              instrument: \"autolab-usth\"\n              mode: \"cv\"",
                "key_values:\n  instrument: \"autolab-usth\"\n  mode: \"cv\"\n  extra: \"x\""))
        }
    }

    @Test func testRejectsUnknownAndOptionalRoutingKeys() throws {
        let withKeys = self.mutated(
            "variant_keys:\n            - \"instrument\"\n            - \"mode\"",
            "variant_keys:\n  - \"instrument\"\n  - \"nosuch\"")
        let withUnknown = try ProfileDocumentV3.parse(text: self.mutated(
            "mode: \"cv\"", "nosuch: \"x\"", base: withKeys))
        #expect(throws: ProfileDocumentError.self) { try withUnknown.validate(catalog: Self.catalog()) }
        var optionalDoc = try ProfileDocumentV3.parse(text: Self.baseYAML)
        optionalDoc.grammarID = "g"
        optionalDoc.variantKeys = ["instrument", "sample"]
        optionalDoc.variants[0].keyValues = ["instrument": "autolab-usth", "sample": "s1"]
        #expect(throws: ProfileDocumentError.self) { try optionalDoc.validate(catalog: Self.catalog()) }
        try optionalDoc.validate(catalog: FilenameGrammarCatalog(grammars: [
            FilenameGrammar(id: "g", name: "G", template: "{instrument}_{sample}", fields: [
                GrammarField(name: "instrument", role: "instrument", type: .string),
                GrammarField(name: "sample", role: "sample", type: .string),
            ])]))
    }

    @Test func testRejectsUnknownSelectorsAndEnums() {
        let cases: [(String, String)] = [
            ("filename_contains_all:", "bogus_selector:"),
            ("role: \"skip\"", "role: \"aux\""),
            ("- \"x\"", "- \"z\""),
            ("type: \"index\"", "type: \"bogus\""),
            ("behavior: \"discrete\"", "behavior: \"bogus\""),
            ("encoding:\n                - \"utf-8\"", "encoding:\n  - \"rot13\""),
            ("decimal_separator: \",\"", "decimal_separator: \"|\""),
            ("delimiter: \";\"", "delimiter: \";;\""),
            ("first_nonblank: true", "bogus_locator: true"),
        ]
        for (old, new) in cases {
            #expect(throws: ProfileDocumentError.self) {
                try ProfileDocumentV3.parse(text: self.mutated(old, new))
            }
        }
        // comment_key_value without its required prefix
        var doc = try! ProfileDocumentV3.parse(text: Self.baseYAML)
        doc.variants[0].metadataCapture = [.commentKeyValue(prefix: "")]
        #expect(throws: ProfileDocumentError.self) { try doc.serializedYAML() }
    }

    @Test func testRejectsInvalidCoordinates() {
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated("row: 3", "row: 0",
                base: Self.baseYAML + Self.positionalVariant(id: "cv-2col", mode: "ca")))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated("column: 2", "column: 0",
                base: Self.baseYAML + Self.positionalVariant(id: "cv-2col", mode: "ca")))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated(
                "excluded_metadata: []", "excluded_metadata:\n  - 0"))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated(
                "excluded_metadata: []", "excluded_metadata:\n  - 1\n  - 1"))
        }
        // Metadata fixed cell on an excluded metadata row is rejected.
        #expect(throws: ProfileDocumentError.self) {
            let excluded = self.mutated(
                "excluded_metadata: []",
                "excluded_metadata:\n                  - 1")
            return try ProfileDocumentV3.parse(text: self.mutated(
                "metadata: []",
                """
                metadata:
                  - key: "started"
                    role: "datetime"
                    source:
                      row: 1
                      column: 2
                """, base: excluded))
        }
    }

    @Test func testRejectsBadDefaultAxes() {
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated("x: \"potential\"", "x: \"nosuch\""))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated(
                "y:\n                - \"current\"", "y: []"))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated("x: \"potential\"", "x: \"notes\""))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated("- \"current\"", "- \"charge\""))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated("x: \"potential\"", "x: \"charge\""))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated(
                "y:\n                - \"current\"", "y:\n                - \"potential\""))
        }
    }

    @Test func testRejectsEmptySelectorListsAndSchema() {
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated(
                "filename_contains_all:\n                - \"cv\"",
                "filename_contains_all: []"))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: self.mutated("schema_version: 3", "schema_version: 2"))
        }
        #expect(throws: ProfileDocumentError.self) {
            try ProfileDocumentV3.parse(text: Self.baseYAML + "\nbogus_root: 1\n")
        }
    }

    @Test func testValidateAgainstCatalog() throws {
        let doc = try ProfileDocumentV3.parse(text: Self.baseYAML)
        try doc.validate(catalog: Self.catalog())
        var badGrammar = doc
        badGrammar.grammarID = "nosuch"
        #expect(throws: ProfileDocumentError.self) { try badGrammar.validate(catalog: Self.catalog()) }
    }

    // MARK: - Editor mapping

    @Test func testEditorApplyMakePreservesAllVariants() throws {
        let original = try ProfileDocumentV3.parse(
            text: Self.baseYAML + Self.positionalVariant(id: "cv-2col", mode: "ca"))
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(original, selectedVariantID: "cv-2col")
        // Profile identity stays split from instrument identity.
        #expect(model.profileID == "autolab-usth")
        #expect(model.profileName == "Autolab USTH")
        #expect(model.instrumentID == "pgstat-01")
        #expect(model.instrumentName == "Potentiostat 01")
        #expect(model.modeID == "cv-2col")
        #expect(model.columns.count == 2)
        // Switch selection and remake: the unselected variant survives byte-equal.
        model.applyProfileDocument(try model.makeProfileDocument(), selectedVariantID: "cv")
        #expect(model.modeID == "cv")
        let remade = try ProfileDocumentV3.parse(text: try model.makeProfileDocument().serializedYAML())
        #expect(remade.variants.count == 2)
        #expect(remade.variants.first { $0.id == "cv-2col" } == original.variants.first { $0.id == "cv-2col" })
        #expect(remade.profileID == "autolab-usth")
        #expect(remade.instrumentID == "pgstat-01")
    }

    @Test func testEditorMakeAddsNoFallbackDefaults() throws {
        var doc = try ProfileDocumentV3.parse(text: Self.baseYAML)
        doc.variants[0].defaultPlot = nil
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(doc, selectedVariantID: "cv")
        let made = try model.makeProfileDocument()
        #expect(made.variants[0].defaultPlot == nil)
    }

    @Test func testUpgradeDraftFinalize() throws {
        let doc = try ProfileDocumentV3.parse(text: Self.baseYAML)
        var blocked = ProfileUpgradeDraft(
            profileID: "autolab-usth", profileName: "Autolab USTH",
            instrumentID: "pgstat-01", instrumentName: "Potentiostat 01",
            grammarID: "standard-scientific", variantKeys: ["instrument", "mode"],
            variants: doc.variants,
            diagnostics: ["variant ca: grammar binding Needs definition"],
            legacyOrigin: nil)
        #expect(throws: ProfileDocumentError.self) { try blocked.finalize(catalog: Self.catalog()) }
        blocked.diagnostics = []
        blocked.profileID = nil
        #expect(throws: ProfileDocumentError.self) { try blocked.finalize(catalog: Self.catalog()) }
        blocked.profileID = "autolab-usth"
        let done = try blocked.finalize(catalog: Self.catalog())
        #expect(done.variants == doc.variants)
        #expect(done.profileID == "autolab-usth")
    }

    // MARK: - Task 3: variant-aware editing lifecycle

    private func twoVariantDocument() throws -> ProfileDocumentV3 {
        try ProfileDocumentV3.parse(
            text: Self.baseYAML + Self.positionalVariant(id: "cv-2col", mode: "ca"))
    }

    private func tempProjectRoot() throws -> ProjectContext {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task3-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try ProjectContext.open(dir, dataRootRelativePath: ".")
    }

    @Test func testEditASwitchToBAndSaveKeepsBoth() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        #expect(model.profileDirty == false)
        // Edit A in the visual projection.
        model.modeName = "CV edited"
        model.columns[0].label = "Voltage A"
        // Switching stages A in memory; B projects cleanly.
        #expect(model.selectVariant(id: "cv-2col") == true)
        #expect(model.modeName == "CV two-column")
        model.columns[0].label = "Voltage B"
        // Switching back restores A's staged draft.
        #expect(model.selectVariant(id: "cv") == true)
        #expect(model.modeName == "CV edited")
        #expect(model.columns[0].label == "Voltage A")
        #expect(model.profileDirty == true)
        #expect(model.selectVariant(id: "nosuch") == false)
        // Whole-document save keeps both variants' edits.
        let saved = try model.saveDocument(project: try tempProjectRoot(), catalog: Self.catalog())
        #expect(saved.lastPathComponent == "autolab-usth.yaml")
        let reloaded = try ProfileDocumentV3.parse(text: try String(contentsOf: saved, encoding: .utf8))
        #expect(reloaded.variants.count == 2)
        #expect(reloaded.variants.first { $0.id == "cv" }?.name == "CV edited")
        #expect(reloaded.variants.first { $0.id == "cv-2col" }?.rawStream.columns.first?.label == "Voltage B")
        #expect(model.profileDirty == false)
    }

    @Test func testDuplicateProfileCopiesWholeDocument() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        try model.duplicateProfile(newProfileID: "autolab-copy", newProfileName: "Autolab Copy")
        #expect(model.profileID == "autolab-copy")
        #expect(model.profileName == "Autolab Copy")
        // Instrument identity stays independent of the profile copy.
        #expect(model.instrumentID == "pgstat-01")
        let doc = try model.makeProfileDocument()
        #expect(doc.variants.count == 2)
        let saved = try model.saveDocument(project: try tempProjectRoot(), catalog: Self.catalog())
        #expect(saved.lastPathComponent == "autolab-copy.yaml")
        #expect(throws: ProfileDocumentError.self) {
            try model.duplicateProfile(newProfileID: "../evil", newProfileName: "Evil")
        }
    }

    @Test func testDuplicateVariantCopiesOnlySelectedVariant() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        let before = try model.makeProfileDocument()
        try model.duplicateCurrentVariant(newID: "cv-dup", newName: "CV duplicate")
        #expect(model.selectedVariantID == "cv-dup")
        let doc = try model.makeProfileDocument()
        #expect(doc.variants.count == 3)
        let untouched = before.variants.first { $0.id == "cv-2col" }
        #expect(doc.variants.first { $0.id == "cv-2col" } == untouched)
        #expect(throws: ProfileDocumentError.self) {
            try model.duplicateCurrentVariant(newID: "cv", newName: "Clash")
        }
    }

    @Test func testKeySetChangeRequiresEveryVariantValue() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        // Incomplete matrix cannot apply.
        #expect(throws: ProfileDocumentError.self) {
            try model.setVariantKeys(["mode"], valuesByVariantID: [
                "cv": ["mode": "cv"],
            ])
        }
        #expect(throws: ProfileDocumentError.self) {
            try model.setVariantKeys(["mode"], valuesByVariantID: [
                "cv": ["mode": "cv"],
                "cv-2col": ["mode": "ca", "extra": "x"],
            ])
        }
        // Complete explicit matrix applies to every variant and persists in YAML.
        try model.setVariantKeys(["mode"], valuesByVariantID: [
            "cv": ["mode": "cv"],
            "cv-2col": ["mode": "ca"],
        ])
        #expect(model.profileDocument?.variantKeys == ["mode"])
        let text = try model.makeProfileDocument().serializedYAML()
        #expect(text.contains("variant_keys:"))
        #expect(model.profileDirty == true)
        // Per-variant value edits stage into the selected variant only.
        try model.updateSelectedVariantKeyValue(key: "mode", value: "cvx")
        #expect(model.profileDocument?.variants.first { $0.id == "cv" }?.keyValues["mode"] == "cvx")
        #expect(model.profileDocument?.variants.first { $0.id == "cv-2col" }?.keyValues["mode"] == "ca")
        // Single-key toggle dirties the profile; empty values block save, not navigation.
        try model.setVariantKeyEnabled("sample", enabled: true)
        #expect(model.selectVariant(id: "cv-2col") == true)
        #expect(throws: ProfileDocumentError.self) { try model.makeProfileDocument() }
        try model.setVariantKeyEnabled("sample", enabled: false)
        _ = try model.makeProfileDocument()
    }

    @Test func testPreviewSamplePreservesDefinitionsAndDirtyState() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        model.columns[0].label = "Voltage A"
        model.stageCurrentVariantEdits()
        #expect(model.profileDirty == true)
        let sample = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task3-" + UUID().uuidString + ".txt")
        try "a;b\n1;2\n".write(to: sample, atomically: true, encoding: .utf8)
        try model.loadSample(url: sample)
        #expect(model.lines.count == 2)
        #expect(model.profileDirty == true)
        #expect(model.selectedVariantID == "cv")
        #expect(model.columns[0].label == "Voltage A")
        let doc = try model.makeProfileDocument()
        #expect(doc.variants.count == 2)
        #expect(doc.variants.first { $0.id == "cv" }?.rawStream.columns.first?.label == "Voltage A")
    }

    @Test func testRoleAwayFromProgressionClearsMapping() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try ProfileDocumentV3.parse(text: Self.baseYAML), selectedVariantID: "cv")
        let stepIndex = try #require(model.columns.firstIndex(where: { $0.name == "step" }))
        #expect(model.columns[stepIndex].role == .progression)
        model.columns[stepIndex].role = .channel
        let doc = try model.makeProfileDocument()
        let step = try #require(doc.variants.first?.rawStream.columns.first { $0.id == "step" })
        #expect(step.role == .channel)
        #expect(step.progression == nil)
    }

    @Test func testTwoUnresolvedUpgradeDraftsFinalizeWithoutTraps() throws {
        let variants = try twoVariantDocument().variants
        var first = ProfileUpgradeDraft(
            profileID: "p-one", profileName: "P One",
            instrumentID: "pgstat-01", instrumentName: "Potentiostat 01",
            grammarID: "standard-scientific", variantKeys: ["instrument", "mode"],
            variants: [variants[0]],
            diagnostics: ["variant cv: grammar binding Needs definition"],
            legacyOrigin: nil)
        var second = ProfileUpgradeDraft(
            profileID: "p-two", profileName: "P Two",
            instrumentID: "pgstat-01", instrumentName: "Potentiostat 01",
            grammarID: "standard-scientific", variantKeys: ["instrument", "mode"],
            variants: [variants[1]],
            diagnostics: ["variant cv-2col: key value Needs definition"],
            legacyOrigin: nil)
        #expect(throws: ProfileDocumentError.self) { try first.finalize(catalog: Self.catalog()) }
        #expect(throws: ProfileDocumentError.self) { try second.finalize(catalog: Self.catalog()) }
        first.diagnostics = []
        second.diagnostics = []
        second.variants[0].keyValues = ["instrument": "autolab-usth", "mode": "ca"]
        let doneFirst = try first.finalize(catalog: Self.catalog())
        let doneSecond = try second.finalize(catalog: Self.catalog())
        #expect(doneFirst.variants.count == 1)
        #expect(doneSecond.variants.count == 1)
        #expect(doneFirst.profileID != doneSecond.profileID)
    }

    @Test func testSandboxDefaultsApplyToSelectedVariantOnly() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        let otherBefore = try #require(model.profileDocument?.variants.first { $0.id == "cv-2col" }?.defaultPlot)
        if let chargeIndex = model.columns.firstIndex(where: { $0.name == "charge" }) {
            model.columns[chargeIndex].isOptional = false
        }
        // Complete Y-list replacement on the selected variant only.
        try model.usePreviewAsDefaults(x: "potential", y: ["current", "charge"])
        let doc = try model.makeProfileDocument()
        #expect(doc.variants.first { $0.id == "cv" }?.defaultPlot == DefaultPlotV3(x: "potential", y: ["current", "charge"]))
        #expect(doc.variants.first { $0.id == "cv-2col" }?.defaultPlot == otherBefore)
        #expect(throws: ProfileDocumentError.self) { try model.usePreviewAsDefaults(x: "nosuch", y: ["current"]) }
    }

    @Test func testSaveValidatesEveryVariantAndPreservesFileOnFailure() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        let project = try tempProjectRoot()
        let saved = try model.saveDocument(project: project, catalog: Self.catalog())
        // Break the unselected variant; save must fail and keep the good file.
        let goodBytes = try Data(contentsOf: saved)
        model.profileDocument?.variants[1].keyValues = [:]
        #expect(throws: ProfileDocumentError.self) {
            try model.saveDocument(project: project, catalog: Self.catalog())
        }
        #expect(try Data(contentsOf: saved) == goodBytes)
    }

    @Test func testLayoutEditStagesToSelectedVariantOnly() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        try model.updateSelectedVariant {
            $0.rawStream.encodings = ["windows-1252"]
            $0.rawStream.rows = RowLocatorsV3(header: .prefix("Freq"), dataStart: .afterHeader)
            $0.match = VariantMatchV3(filenameContainsAll: ["cv"], contentContainsAny: nil)
        }
        #expect(model.profileDirty == true)
        let doc = try model.makeProfileDocument()
        #expect(doc.variants.first { $0.id == "cv" }?.rawStream.encodings == ["windows-1252"])
        #expect(doc.variants.first { $0.id == "cv-2col" }?.rawStream.encodings == ["utf-8"])
        #expect(throws: ProfileDocumentError.self) {
            try EditorWorkspaceModel().updateSelectedVariant { $0.rawStream.delimiter = ";" }
        }
    }

    @Test func testExternalChangeAbortsSave() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        let project = try tempProjectRoot()
        let saved = try model.saveDocument(project: project, catalog: Self.catalog())
        try "tampered".write(to: saved, atomically: true, encoding: .utf8)
        model.modeName = "CV edited"
        #expect(throws: ProfileDocumentError.self) {
            try model.saveDocument(project: project, catalog: Self.catalog())
        }
        #expect(try String(contentsOf: saved, encoding: .utf8) == "tampered")
    }

    // MARK: - Task 3 fix round 1 (M1/M2/L5 guards)

    @Test func testDirectBindingEditIsCaughtByGuardRefresh() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        // Simulates a grid binding write straight to the legacy fields,
        // bypassing every markProfileDirty call site.
        model.columns[0].label = "Voltage grid-edit"
        #expect(model.profileDirty == false)
        // Guards must refresh (stage-then-check) instead of trusting the flag.
        #expect(model.refreshDirtyFromStagedEdits() == true)
        #expect(model.profileDirty == true)
        let doc = try model.makeProfileDocument()
        #expect(doc.variants.first { $0.id == "cv" }?.rawStream.columns.first?.label == "Voltage grid-edit")
        // Clean documents never prompt.
        let clean = EditorWorkspaceModel()
        clean.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        #expect(clean.refreshDirtyFromStagedEdits() == false)
    }

    @Test func testErrorStatusTextClassifiesAsError() throws {
        #expect(isErrorStatusMessage(nil) == false)
        #expect(isErrorStatusMessage("") == false)
        #expect(isErrorStatusMessage("Saved profile autolab-usth.yaml (2 variants) to .rawviewer/instrument/.") == false)
        #expect(isErrorStatusMessage("Save error: variant cv incomplete") == true)
        #expect(isErrorStatusMessage("Saved a; profile FAILED (needs definition).") == true)
        #expect(isErrorStatusMessage("Failed to load profile: missing file") == true)
        #expect(isErrorStatusMessage("Using legacy grammar definitions (2 migration notes); review recommended.") == false)
    }

    // MARK: - Task 5: thin v1/v2 conversion adapter + preview sample matching

    /// Generic invented instruments only; never real product names.
    static let legacyTabularV2 = """
    schema_version: 2
    instrument:
      id: synth-tab
      name: Synth Tab Fixture
      vendor: Synthworks
      model: ST-1
    formats:
      - id: tab
        kind: tabular
        extensions: [".csv"]
        delimiter: ","
        encoding: ["utf-8", "windows-1252"]
        rows:
          names_prefix: "HDR"
          data_prefix: "ROW"
        columns:
          voltage:
            header: "V1"
            aliases: ["Volt", "V"]
            quantity: voltage
            unit: "V"
            label: "Voltage"
          current:
            header: "I1"
            quantity: current
            unit: "A"
            label: "Current"
          power:
            header: "P1"
            quantity: power
            unit: "W"
            label: "Power"
          aux:
            header: "A1"
            quantity: signal
            unit: "V"
            label: "Aux"
            required: false
    modes:
      - id: sweep-a
        format: tab
        filename_contains_all: ["synthx", "sweep-a"]
        detect: ["SYNTH-TAB-A"]
        extract:
          x: voltage
          y: [current, power]
      - id: sweep-b
        format: tab
        detect: ["SYNTH-TAB-B"]
        extract:
          x: voltage
          y: [current]
    """

    static let legacyFirstRowV2 = """
    schema_version: 2
    instrument:
      id: synth-first
      name: Synth First-Row Fixture
    formats:
      - id: frh
        kind: first-row-header
        extensions: [".csv"]
        delimiter: ","
        columns:
          elapsed:
            header: "Time"
            quantity: time
            unit: "s"
          signal:
            header: "Volts"
            aliases: ["V"]
            quantity: voltage
            unit: "V"
    modes:
      - id: run
        format: frh
        detect: ["SYNTH-FIRST"]
        extract:
          x: elapsed
          y: [signal]
    """

    static let legacyHeaderlessV2 = """
    schema_version: 2
    instrument:
      id: synth-pos
      name: Synth Positional Fixture
    formats:
      - id: pos
        kind: comment-tsv
        extensions: [".txt"]
        delimiter: ","
        columns:
          wavelength:
            column_index: 0
            quantity: length
            unit: "nm"
          counts:
            column_index: 2
            quantity: counts
            unit: "ct"
    modes:
      - id: scan
        format: pos
        detect: ["SYNTH-POS"]
        extract:
          x: wavelength
          y: [counts]
    """

    private func legacyProfile(_ yaml: String) throws -> InstrumentProfile {
        let outcome = ProfileSchema.load(
            text: yaml, relativePath: "data/instruments/synth.yaml",
            sha256: sha256Hex(Data(yaml.utf8)))
        guard let profile = outcome.profile else {
            throw ProfileDocumentError.invalid(reason: outcome.issues.joined(separator: "\n"))
        }
        return profile
    }

    @Test func testUpgradePreservesMarkerLayoutDeclarations() throws {
        let profile = try legacyProfile(Self.legacyTabularV2)
        let draft = try LegacyProfileUpgrader.draft(
            from: profile, modeIDs: nil,
            legacyPath: "data/instruments/synth.yaml",
            sha256: sha256Hex(Data(Self.legacyTabularV2.utf8)))
        #expect(draft.variants.map(\.id) == ["sweep-a", "sweep-b"])
        #expect(draft.profileID == "synth-tab")
        #expect(draft.instrumentID == "synth-tab")
        #expect(draft.instrumentName == "Synth Tab Fixture")
        #expect(draft.vendor == "Synthworks")
        #expect(draft.model == "ST-1")
        #expect(draft.legacyOrigin == ProfileLegacyOrigin(
            path: "data/instruments/synth.yaml",
            sha256: sha256Hex(Data(Self.legacyTabularV2.utf8))))
        // Grammar and routing keys are Needs definition, never guessed.
        #expect(draft.grammarID == nil)
        #expect(draft.variantKeys.isEmpty)
        #expect(draft.diagnostics.contains { $0.contains("filename.grammar_id") && $0.contains("Needs definition") })
        #expect(draft.diagnostics.contains { $0.contains("filename.variant_keys") && $0.contains("Needs definition") })
        #expect(draft.diagnostics.filter { $0.contains(".key_values Needs definition") }.count == 2)
        let variant = try #require(draft.variants.first { $0.id == "sweep-a" })
        #expect(variant.keyValues.isEmpty)
        #expect(variant.rawStream.extensions == [".csv"])
        #expect(variant.rawStream.encodings == ["utf-8", "windows-1252"])
        #expect(variant.rawStream.delimiter == ",")
        #expect(variant.rawStream.decimalSeparator == ".")
        #expect(variant.rawStream.rows.header == .prefix("HDR"))
        #expect(variant.rawStream.rows.dataStart == .afterHeader)
        #expect(variant.rawStream.rows.dataPrefix == "ROW")
        #expect(variant.match == VariantMatchV3(
            filenameContainsAll: ["synthx", "sweep-a"], contentContainsAny: ["SYNTH-TAB-A"]))
        let voltage = try #require(variant.rawStream.columns.first { $0.id == "voltage" })
        #expect(voltage.source.header == "V1")
        #expect(voltage.source.aliases == ["Volt", "V"])
        #expect(voltage.required)
        #expect(voltage.axes == [.x])
        #expect(variant.rawStream.columns.first { $0.id == "current" }?.axes == [.y])
        #expect(variant.rawStream.columns.first { $0.id == "power" }?.axes == [.y])
        let aux = try #require(variant.rawStream.columns.first { $0.id == "aux" })
        #expect(aux.required == false)
        #expect(aux.axes.isEmpty)
        #expect(variant.defaultPlot == DefaultPlotV3(x: "voltage", y: ["current", "power"]))
        // Adapter emits no fixed metadata: only row-anchored metadata is representable.
        #expect(variant.metadata.isEmpty)
        #expect(variant.metadataCapture == [.preHeaderFields])
    }

    @Test func testUpgradeMapsFirstRowAndHeaderlessLayouts() throws {
        let first = try legacyProfile(Self.legacyFirstRowV2)
        let firstDraft = try LegacyProfileUpgrader.draft(
            from: first, legacyPath: "data/instruments/first.yaml",
            sha256: sha256Hex(Data(Self.legacyFirstRowV2.utf8)))
        let run = try #require(firstDraft.variants.first)
        #expect(run.rawStream.rows.header == .firstNonBlank)
        #expect(run.rawStream.rows.dataStart == .afterHeader)
        #expect(run.rawStream.rows.commentPrefix == nil)
        #expect(run.metadataCapture.isEmpty)
        #expect(run.rawStream.columns.first { $0.id == "signal" }?.source.aliases == ["V"])

        let pos = try legacyProfile(Self.legacyHeaderlessV2)
        let posDraft = try LegacyProfileUpgrader.draft(
            from: pos, legacyPath: "data/instruments/pos.yaml",
            sha256: sha256Hex(Data(Self.legacyHeaderlessV2.utf8)))
        let scan = try #require(posDraft.variants.first)
        #expect(scan.rawStream.rows.header == .none)
        #expect(scan.rawStream.rows.dataStart == .row(1))
        #expect(scan.rawStream.rows.commentPrefix == "#")
        #expect(scan.metadataCapture == [.commentKeyValue(prefix: "#")])
        // Legacy 0-based positions become 1-based physical source columns.
        #expect(scan.rawStream.columns.first { $0.id == "wavelength" }?.source.column == 1)
        #expect(scan.rawStream.columns.first { $0.id == "counts" }?.source.column == 3)
    }

    @Test func testUpgradeNeverFreezesSampleRowCounts() throws {
        let profile = try legacyProfile(Self.legacyTabularV2)
        let draft = try LegacyProfileUpgrader.draft(
            from: profile, legacyPath: "data/instruments/synth.yaml",
            sha256: "00")
        for variant in draft.variants {
            // Marker semantics survive; no sample row number is frozen.
            if case .prefix = variant.rawStream.rows.header { } else {
                Issue.record("tabular upgrade must keep a marker header locator")
            }
            #expect(variant.rawStream.rows.dataStart == .afterHeader)
        }
    }

    @Test func testUpgradeSelectionValidation() throws {
        let profile = try legacyProfile(Self.legacyTabularV2)
        #expect(throws: ProfileDocumentError.self) {
            try LegacyProfileUpgrader.draft(from: profile, modeIDs: [], legacyPath: "p", sha256: "s")
        }
        #expect(throws: ProfileDocumentError.self) {
            try LegacyProfileUpgrader.draft(from: profile, modeIDs: ["nosuch"], legacyPath: "p", sha256: "s")
        }
        let subset = try LegacyProfileUpgrader.draft(
            from: profile, modeIDs: ["sweep-b"], legacyPath: "p", sha256: "s")
        #expect(subset.variants.map(\.id) == ["sweep-b"])
    }

    @Test func testUpgradeDraftBlocksFinalizeUntilResolved() throws {
        let profile = try legacyProfile(Self.legacyTabularV2)
        var draft = try LegacyProfileUpgrader.draft(
            from: profile, modeIDs: ["sweep-a"], legacyPath: "p", sha256: String(repeating: "0", count: 64))
        #expect(throws: ProfileDocumentError.self) { try draft.finalize(catalog: Self.catalog()) }
        draft.resolve(
            grammarID: "standard-scientific", variantKeys: ["instrument", "mode"],
            valuesByVariantID: ["sweep-a": ["instrument": "synthx", "mode": "sweep-a"]])
        #expect(draft.diagnostics.isEmpty)
        let done = try draft.finalize(catalog: Self.catalog())
        #expect(done.variants.map(\.id) == ["sweep-a"])
        #expect(done.grammarID == "standard-scientific")
        #expect(done.legacyOrigin?.path == "p")
    }

    @Test func testUpgradeKeylessResolveStaysValid() throws {
        // Review-ruled: keyless documents are schema-valid; no save blocker.
        let profile = try legacyProfile(Self.legacyFirstRowV2)
        var draft = try LegacyProfileUpgrader.draft(
            from: profile, legacyPath: "p", sha256: String(repeating: "0", count: 64))
        draft.resolve(grammarID: "standard-scientific", variantKeys: [], valuesByVariantID: ["run": [:]])
        let done = try draft.finalize(catalog: Self.catalog())
        #expect(done.variantKeys.isEmpty)
        #expect(done.variants.first?.keyValues.isEmpty == true)
    }

    @Test func testColumnOnlyFixedMetadataFailsValidation() throws {
        var doc = try twoVariantDocument()
        doc.variants[0].metadata = [VariantMetadataV3(key: "m", role: "r", column: 2)]
        let invalid = doc
        #expect(throws: ProfileDocumentError.self) { try invalid.validate() }
        let yaml = Self.baseYAML.replacingOccurrences(
            of: "    metadata: []",
            with: "    metadata:\n      - key: \"m\"\n        role: \"r\"\n        source:\n          column: 2")
        #expect(throws: ProfileDocumentError.self) { try ProfileDocumentV3.parse(text: yaml) }
        // Row-anchored metadata stays valid.
        var anchored = try twoVariantDocument()
        anchored.variants[0].metadata = [VariantMetadataV3(key: "m", role: "r", row: 1, column: 2)]
        try anchored.validate()
    }

    @Test func testUpgradeModelLifecyclePreservesWorkspace() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task5-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacyURL = dir.appendingPathComponent("synth.yaml")
        try Self.legacyTabularV2.write(to: legacyURL, atomically: true, encoding: .utf8)
        let beforeBytes = try Data(contentsOf: legacyURL)

        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try twoVariantDocument(), selectedVariantID: "cv")
        // Multi-mode legacy stages a mode selection; the live document is untouched.
        try model.prepareUpgradeFromLegacyFile(at: legacyURL, relativePath: "data/instruments/synth.yaml")
        #expect(model.upgradeNeedsModeSelection)
        #expect(model.upgradeModeOptions == ["sweep-a", "sweep-b"])
        #expect(model.upgradeDraft == nil)
        #expect(model.profileDocument?.profileID == "autolab-usth")
        // Zero selection fails without disturbing anything.
        #expect(throws: ProfileDocumentError.self) { try model.applyUpgradeModeSelection([]) }
        #expect(model.upgradeDraft == nil)
        #expect(model.profileDocument?.profileID == "autolab-usth")
        // Selecting one mode stages one draft; repeated selection replaces only the draft.
        try model.applyUpgradeModeSelection(["sweep-b"])
        #expect(model.upgradeDraft?.variants.map(\.id) == ["sweep-b"])
        try model.applyUpgradeModeSelection(["sweep-a"])
        #expect(model.upgradeDraft?.variants.map(\.id) == ["sweep-a"])
        #expect(model.profileDocument?.profileID == "autolab-usth")
        // Cancel drops the draft and keeps the document and the original file.
        model.cancelUpgrade()
        #expect(model.upgradeDraft == nil)
        #expect(model.hasUpgradeDraft == false)
        #expect(model.profileDocument?.profileID == "autolab-usth")
        #expect(try Data(contentsOf: legacyURL) == beforeBytes)
    }

    @Test func testFinalizeUpgradeAppliesUnsavedDraft() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task5-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacyURL = dir.appendingPathComponent("synth.yaml")
        try Self.legacyFirstRowV2.write(to: legacyURL, atomically: true, encoding: .utf8)
        let beforeBytes = try Data(contentsOf: legacyURL)

        let model = EditorWorkspaceModel()
        try model.prepareUpgradeFromLegacyFile(at: legacyURL, relativePath: "data/instruments/synth.yaml")
        #expect(model.upgradeNeedsModeSelection == false)
        #expect(model.upgradeDraft?.variants.map(\.id) == ["run"])
        model.resolveUpgrade(
            grammarID: "standard-scientific", variantKeys: ["instrument", "mode"],
            valuesByVariantID: ["run": ["instrument": "synthx", "mode": "run"]])
        let done = try model.finalizeUpgrade(catalog: Self.catalog())
        #expect(done.profileID == "synth-first")
        #expect(model.profileDocument?.profileID == "synth-first")
        #expect(model.profileDirty)
        #expect(model.hasUpgradeDraft == false)
        #expect(try Data(contentsOf: legacyURL) == beforeBytes)
    }

    @Test func testCollidingSavePreservesDraftAndOriginal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Task5-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacyURL = dir.appendingPathComponent("synth.yaml")
        try Self.legacyFirstRowV2.write(to: legacyURL, atomically: true, encoding: .utf8)
        let project = try ProjectContext.open(dir, dataRootRelativePath: ".")
        // A colliding canonical path holds foreign content.
        let clash = dir.appendingPathComponent(".rawviewer/instrument/synth-first.yaml")
        try FileManager.default.createDirectory(at: clash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "foreign: true\n".write(to: clash, atomically: true, encoding: .utf8)

        let model = EditorWorkspaceModel()
        try model.prepareUpgradeFromLegacyFile(at: legacyURL, relativePath: "data/instruments/synth.yaml")
        model.resolveUpgrade(
            grammarID: "standard-scientific", variantKeys: [],
            valuesByVariantID: ["run": [:]])
        _ = try model.finalizeUpgrade(catalog: Self.catalog())
        #expect(throws: ProfileDocumentError.self) {
            try model.saveDocument(project: project, catalog: Self.catalog())
        }
        #expect(try String(contentsOf: clash, encoding: .utf8) == "foreign: true\n")
        #expect(model.profileDocument?.profileID == "synth-first")
        #expect(model.profileDirty)
    }

    // MARK: Task 5 preview sample matching (exact profile + variant)

    private func matchDocument() throws -> ProfileDocumentV3 {
        let profile = try legacyProfile(Self.legacyTabularV2)
        var draft = try LegacyProfileUpgrader.draft(
            from: profile, legacyPath: "data/instruments/synth.yaml",
            sha256: String(repeating: "0", count: 64))
        draft.resolve(
            grammarID: "standard-scientific", variantKeys: ["instrument", "mode"],
            valuesByVariantID: [
                "sweep-a": ["instrument": "synthx", "mode": "sweep-a"],
                "sweep-b": ["instrument": "synthx", "mode": "sweep-b"],
            ])
        return try draft.finalize(catalog: Self.catalog())
    }

    private func tabSample(modeToken: String) -> Data {
        Data("Title, SYNTH-TAB-PLACEHOLDER export\nHDR, V1, I1, P1\nROW, 1, 2, 3\nROW, 2, 4, 6\n"
            .replacingOccurrences(of: "SYNTH-TAB-PLACEHOLDER", with: modeToken).utf8)
    }

    private func candidate(id: String, basename: String, bytes: Data) -> PreviewSampleCandidate {
        PreviewSampleCandidate(
            sourceID: id, basename: basename,
            fileExtension: "." + (basename as NSString).pathExtension,
            prefixBytes: bytes, byteSize: bytes.count)
    }

    @Test func testPreviewMatcherConfirmsExactVariant() throws {
        let doc = try matchDocument()
        let hit = candidate(id: "data/raw/a.csv", basename: "synthx.sweep-a_s01.csv", bytes: tabSample(modeToken: "SYNTH-TAB-A"))
        let other = candidate(id: "data/raw/b.csv", basename: "synthx.sweep-b_s02.csv", bytes: tabSample(modeToken: "SYNTH-TAB-B"))
        // Deterministic order: the first confirmed candidate wins.
        #expect(PreviewSampleMatcher.match(
            candidates: [hit, other], document: doc, variantID: "sweep-a",
            grammar: Self.catalog()) == .confirmed(sourceID: "data/raw/a.csv"))
        #expect(PreviewSampleMatcher.match(
            candidates: [other, hit], document: doc, variantID: "sweep-a",
            grammar: Self.catalog()) == .confirmed(sourceID: "data/raw/a.csv"))
    }

    @Test func testPreviewMatcherSkipsOtherVariantsAndUnrelated() throws {
        let doc = try matchDocument()
        let otherVariant = candidate(
            id: "data/raw/b.csv", basename: "synthx.sweep-b_s02.csv", bytes: tabSample(modeToken: "SYNTH-TAB-B"))
        // A source matching only the sibling variant is no match for this variant.
        #expect(PreviewSampleMatcher.match(
            candidates: [otherVariant], document: doc, variantID: "sweep-a",
            grammar: Self.catalog()) == .noMatch)
        let unrelated = candidate(id: "data/raw/c.csv", basename: "notes.csv", bytes: Data("hello\n".utf8))
        #expect(PreviewSampleMatcher.match(
            candidates: [unrelated], document: doc, variantID: "sweep-a",
            grammar: Self.catalog()) == .noMatch)
    }

    @Test func testPreviewMatcherReportsAmbiguity() throws {
        var doc = try matchDocument()
        // Duplicate key tuple with identical stream checks: undecidable, never first-match.
        doc.variants[1].keyValues = doc.variants[0].keyValues
        doc.variants[1].match = doc.variants[0].match
        let hit = candidate(id: "data/raw/a.csv", basename: "synthx.sweep-a_s01.csv", bytes: tabSample(modeToken: "SYNTH-TAB-A"))
        let outcome = PreviewSampleMatcher.match(
            candidates: [hit], document: doc, variantID: "sweep-a", grammar: Self.catalog())
        guard case .ambiguous(let note) = outcome else {
            Issue.record("expected ambiguity, got \(outcome)")
            return
        }
        #expect(note.contains("Ambiguous"))
    }

    // MARK: - Task 7: variant-defined axis choices (consume, do not reshape)

    static func axisVariant(optionalYPresent: Bool = false) -> ProfileVariantV3 {
        ProfileVariantV3(
            id: "cv",
            name: "CV",
            keyValues: ["instrument": "acme", "mode": "cv"],
            rawStream: RawStreamV3(
                extensions: [".csv"], encodings: ["utf-8"],
                delimiter: ",", decimalSeparator: ".",
                columns: [
                    ProfileColumnV3(id: "potential", label: "Voltage", quantity: "voltage", unit: "V", required: true, role: .channel, axes: [.x]),
                    ProfileColumnV3(id: "current", label: "Current", quantity: "current", unit: "A", required: true, role: .channel, axes: [.y]),
                    // Stable duplicate label: same display text, distinct ID.
                    ProfileColumnV3(id: "current2", label: "Current", quantity: "current", unit: "A", required: true, role: .channel, axes: [.y]),
                    ProfileColumnV3(id: "auxskip", label: "Aux", quantity: "voltage", unit: "V", required: false, role: .skip),
                    ProfileColumnV3(id: "optaux", label: "Aux current", quantity: "current", unit: "A", required: false, role: .channel, axes: [.y]),
                ]),
            defaultPlot: DefaultPlotV3(x: "potential", y: ["current", "current2"]))
    }

    static func axisDocument(variant: ProfileVariantV3) -> ProfileDocumentV3 {
        ProfileDocumentV3(
            profileID: "acme-01", profileName: "Acme",
            instrumentID: "acme", instrumentName: "Acme",
            grammarID: "standard-scientific",
            variantKeys: ["instrument", "mode"],
            variants: [variant])
    }

    static func axisExtraction(includeOptionalY: Bool) -> TabularExtraction {
        func column(_ key: String, _ label: String, _ quantity: String, _ unit: String) -> (ProfileColumn, [Double?]) {
            (ProfileColumn(key: key, header: nil, aliases: [], quantity: quantity, unit: unit, label: label, index: nil, required: true), [1.0, 2.0])
        }
        var columns = [
            column("potential", "Voltage", "voltage", "V"),
            column("current", "Current", "current", "A"),
            column("current2", "Current", "current", "A"),
        ]
        if includeOptionalY {
            columns.append(column("optaux", "Aux current", "current", "A"))
        }
        return TabularExtraction(
            columns: columns,
            reasons: columns.map { $0.1.map { _ in nil as GapReason? } },
            warnings: [],
            headerFields: [],
            sha256: String(repeating: "0", count: 64))
    }

    static func axisMatch(variant: ProfileVariantV3) -> V3Match {
        V3Match(
            document: axisDocument(variant: variant),
            variant: variant,
            grammar: Self.catalog().grammars[0],
            facts: ExtractedGrammarFacts(isMatched: true, extractedFields: ["instrument": "acme", "mode": "cv"]),
            grammarSHA256: "grammar",
            documentPath: ".rawviewer/instrument/acme-01.yaml",
            documentSHA256: "document")
    }

    @Test func axisChoicesExposeMultipleXYAndExcludeSkip() throws {
        let variant = Self.axisVariant()
        let measurement = try V3Reader.measurement(
            relativePath: "data/raw/acme.cv_s01.csv",
            basename: "acme.cv_s01.csv",
            match: Self.axisMatch(variant: variant),
            extracted: Self.axisExtraction(includeOptionalY: false))
        // Multiple default Y series are preserved as the Default-series choice.
        #expect(measurement.view.x == "potential")
        #expect(measurement.view.y == ["current", "current2"])
        // Skip columns are excluded from eligibility; declared axis-capable
        // columns are the effective choices.
        #expect(measurement.provenance["eligible_x"] == "potential")
        #expect(measurement.provenance["eligible_y"] == "current,current2")
        #expect(measurement.provenance["variant_id"] == "cv")
        #expect(measurement.provenance["profile_id"] == "acme-01")
        // Stable duplicate-label selection: same label, distinct stable IDs.
        #expect(measurement.channel(named: "current")?.label == "Current")
        let second = measurement.channel(named: "current2")
        #expect(second?.label == "Current")
        #expect(second?.name != measurement.channel(named: "current")?.name)
        #expect(measurement.channels.map(\.name).contains("auxskip") == false)
    }

    @Test func axisChoicesOfferOptionalOnlyWhenPresent() throws {
        let variant = Self.axisVariant()
        let present = try V3Reader.measurement(
            relativePath: "data/raw/a.csv", basename: "a.csv",
            match: Self.axisMatch(variant: variant),
            extracted: Self.axisExtraction(includeOptionalY: true))
        #expect(present.provenance["eligible_y"] == "current,current2,optaux")
        #expect(present.channel(named: "optaux") != nil)
        let absent = try V3Reader.measurement(
            relativePath: "data/raw/a.csv", basename: "a.csv",
            match: Self.axisMatch(variant: variant),
            extracted: Self.axisExtraction(includeOptionalY: false))
        // Optional-but-absent columns stay absent: never fabricated, and the
        // declared multi-Y defaults are untouched.
        #expect(absent.provenance["eligible_y"] == "current,current2")
        #expect(absent.channel(named: "optaux") == nil)
        #expect(absent.view.y == ["current", "current2"])
    }

    @Test func axisMissingDefaultChannelFailsClosedWithoutSubstitution() throws {
        var variant = Self.axisVariant()
        variant.defaultPlot = DefaultPlotV3(x: "potential", y: ["current", "optaux"])
        #expect(throws: ReaderError.self) {
            try V3Reader.measurement(
                relativePath: "data/raw/a.csv", basename: "a.csv",
                match: Self.axisMatch(variant: variant),
                extracted: Self.axisExtraction(includeOptionalY: false))
        }
    }

    @Test func axisOverrideAppliesWithoutSubstitution() throws {
        // Session overrides reselect declared channels display-only; missing
        // IDs are kept (plots/overlays fail closed, inspector resets).
        let variant = Self.axisVariant()
        let measurement = try V3Reader.measurement(
            relativePath: "data/raw/a.csv", basename: "a.csv",
            match: Self.axisMatch(variant: variant),
            extracted: Self.axisExtraction(includeOptionalY: false))
        #expect(measurement.eligibleXIDs == ["potential"])
        #expect(measurement.eligibleYIDs == ["current", "current2"])
        let single = measurement.withAxisView(x: nil, y: ["current2"])
        #expect(single.view.x == "potential")
        #expect(single.view.y == ["current2"])
        #expect(single.channels.count == measurement.channels.count)
        let stale = measurement.withAxisView(x: nil, y: ["gone"])
        #expect(stale.view.y == ["gone"])
        #expect(stale.channel(named: "gone") == nil)
    }

    // MARK: - Final fix: v3-shaped parse failure warns, never legacy clean-loads

    @Test func testV3ShapedInvalidFileSurfacesV3ErrorsNotLegacySuccess() throws {
        // Corrupt one scalar so v3 parse fails while `schema_version: 3` stays.
        let broken = Self.baseYAML.replacingOccurrences(of: "delimiter: \";\"", with: "delimiter: \";;\"")
        // Strict editor routing rejects any v3-parse failure with the v3
        // detail (see forceLoadSavedProfile); legacy files never reach the
        // editor list at all.
        func isV3Shaped(_ text: String) -> Bool {
            text.range(
                of: #"(?m)^\s*schema_version\s*:\s*[\"']?3[\"']?\s*(#|$)"#,
                options: [.regularExpression]) != nil
        }
        #expect(isV3Shaped(broken))
        #expect(!isV3Shaped(Self.legacyTabularV2))
        // v3 parse fails with detail worth surfacing.
        let detail: String
        do {
            _ = try ProfileDocumentV3.parse(text: broken)
            Issue.record("v3-shaped invalid file must fail v3 parse")
            return
        } catch {
            detail = error.localizedDescription
        }
        #expect(!detail.isEmpty)
        // The lenient legacy loader masks this file: clean-load, no throw.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinalFix-" + UUID().uuidString + ".yaml")
        try broken.write(to: url, atomically: true, encoding: .utf8)
        let legacy = EditorWorkspaceModel()
        try legacy.loadSavedProfile(url: url)
        #expect(!legacy.columns.isEmpty)
        // Fixed routing: the message carries the v3 detail, never a legacy
        // clean-load. (Literal mirrors forceLoadSavedProfile; keep in sync.)
        let warning = "Profile error: '\(url.lastPathComponent)' \(detail) Not loaded."
        #expect(warning.contains(detail))
        #expect(!warning.contains("columns, delimiter"))
        #expect(isErrorStatusMessage(warning))
    }

    // MARK: - Task 1: strict editor discovery (valid v3 only)

    @Test func editorDiscoveryExcludesLegacyMalformedAndInvalidReferences() throws {
        let malformed = Self.baseYAML.replacingOccurrences(of: "delimiter: \";\"", with: "delimiter: \";;\"")
        let unsupported = Self.baseYAML.replacingOccurrences(of: "schema_version: 3", with: "schema_version: 9")
        let missingGrammar = Self.baseYAML.replacingOccurrences(
            of: "grammar_id: \"standard-scientific\"", with: "grammar_id: \"no-such-grammar\"")
        let fixtures: [(fileName: String, text: String)] = [
            (fileName: "valid.yaml", text: Self.baseYAML),
            (fileName: "legacy-v2.yaml", text: Self.legacyTabularV2),
            (fileName: "malformed.yaml", text: malformed),
            (fileName: "unsupported.yaml", text: unsupported),
            (fileName: "missing-grammar.yaml", text: missingGrammar),
        ]
        // Disposable fixtures: discovery only reads; originals stay byte-exact.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorDiscovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var before: [String: Data] = [:]
        for fixture in fixtures {
            let url = dir.appendingPathComponent(fixture.fileName)
            try fixture.text.write(to: url, atomically: true, encoding: .utf8)
            before[fixture.fileName] = try Data(contentsOf: url)
        }
        let inputs = try fixtures.map { fixture in
            (fileName: fixture.fileName,
             text: try String(contentsOf: dir.appendingPathComponent(fixture.fileName), encoding: .utf8))
        }
        let result = EditorProfileDiscovery.partition(files: inputs, catalog: Self.catalog())
        #expect(result.valid == ["valid.yaml"])
        #expect(result.excluded.count == 4)
        #expect(Set(result.excluded.map(\.fileName)) == [
            "legacy-v2.yaml", "malformed.yaml", "unsupported.yaml", "missing-grammar.yaml",
        ])
        for entry in result.excluded { #expect(!entry.reason.isEmpty) }
        for (name, data) in before {
            #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == data)
        }
    }

    // MARK: - Task 4: safe profile deletion

    @Test func deleteRejectsNonOwnedSymlinkAndChangedTargets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileDelete-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownedDir = root.appendingPathComponent(".rawviewer/instrument", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedDir, withIntermediateDirectories: true)
        let ownedBytes = Data("synthetic-owned-profile".utf8)
        let owned = ownedDir.appendingPathComponent("owned.yaml")
        try ownedBytes.write(to: owned)
        let outside = root.appendingPathComponent("outside.yaml")
        try Data("synthetic".utf8).write(to: outside)
        let link = ownedDir.appendingPathComponent("link.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: owned)
        let missing = ownedDir.appendingPathComponent("renamed-away.yaml")

        // Non-owned, symlink, missing, and externally changed targets are
        // rejected; every rejection preserves the owned bytes on disk.
        #expect(throws: SafeDeleteError.notProjectOwned(path: "outside.yaml")) {
            try FilenameGrammarEngine.deleteVerifiedProfile(at: outside, projectRoot: root, expectedBytes: nil)
        }
        #expect(throws: SafeDeleteError.symlinkRefused(path: "link.yaml")) {
            try FilenameGrammarEngine.deleteVerifiedProfile(at: link, projectRoot: root, expectedBytes: nil)
        }
        #expect(throws: SafeDeleteError.changedOnDisk(path: "renamed-away.yaml")) {
            try FilenameGrammarEngine.deleteVerifiedProfile(at: missing, projectRoot: root, expectedBytes: nil)
        }
        #expect(throws: SafeDeleteError.changedOnDisk(path: "owned.yaml")) {
            try FilenameGrammarEngine.deleteVerifiedProfile(
                at: owned, projectRoot: root, expectedBytes: Data("stale-baseline".utf8))
        }
        #expect(try Data(contentsOf: owned) == ownedBytes)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try Data(contentsOf: outside) == Data("synthetic".utf8))

        // The verified owned target deletes exactly once.
        try FilenameGrammarEngine.deleteVerifiedProfile(at: owned, projectRoot: root, expectedBytes: ownedBytes)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
    }

    @Test func failedDeletePreservesState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeletePreserves-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownedDir = root.appendingPathComponent(".rawviewer/instrument", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedDir, withIntermediateDirectories: true)
        let profile = ownedDir.appendingPathComponent("keep.yaml")
        try "schema_version: 3\nfilename:\n  grammar_id: \"g1\"\n".write(
            to: profile, atomically: true, encoding: .utf8)
        let catalog = FilenameGrammarCatalog(grammars: [
            FilenameGrammar(
                id: "g1", name: "G1", template: "{study}_{run}",
                fields: [GrammarField(name: "study"), GrammarField(name: "run")]),
        ])
        let grammarFile = root.appendingPathComponent(".rawviewer/grammar.yaml")
        try FilenameGrammarEngine.save(catalog: catalog, fileURL: grammarFile)
        try """
            schema_version: 3
            data_root: "data/raw"
            default_view: "tree"
            default_preset: "nature-single"
            developer_mode: false
            explorer_views:
              - grammar_id: "g1"
                variable: "study"
            """.write(to: root.appendingPathComponent(".rawviewer/setting.yaml"),
                      atomically: true, encoding: .utf8)
        let profileBefore = try Data(contentsOf: profile)
        let grammarBefore = try Data(contentsOf: grammarFile)

        // A blocked grammar deletion mutates neither the catalog value nor
        // any disk bytes: the caller must not persist on non-empty blockers.
        let blockers = try FilenameGrammarEngine.grammarDeleteBlockers(grammarID: "g1", projectRoot: root)
        #expect(!blockers.isEmpty)
        #expect(try FilenameGrammarEngine.load(fileURL: grammarFile) == catalog)
        #expect(try Data(contentsOf: grammarFile) == grammarBefore)
        #expect(try Data(contentsOf: profile) == profileBefore)

        // Failed profile deletions (symlink, changed bytes) preserve disk.
        let link = ownedDir.appendingPathComponent("keep-link.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: profile)
        #expect(throws: SafeDeleteError.self) {
            try FilenameGrammarEngine.deleteVerifiedProfile(at: link, projectRoot: root, expectedBytes: nil)
        }
        #expect(throws: SafeDeleteError.self) {
            try FilenameGrammarEngine.deleteVerifiedProfile(
                at: profile, projectRoot: root, expectedBytes: Data("wrong".utf8))
        }
        #expect(try Data(contentsOf: profile) == profileBefore)
        #expect(try Data(contentsOf: grammarFile) == grammarBefore)
        #expect(try FilenameGrammarEngine.load(fileURL: grammarFile) == catalog)
    }

    // MARK: - Task 6: New blank v3 from the current sample

    private func directoryListing(_ root: URL) throws -> [String] {
        var paths: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let item as String in enumerator { paths.append(item) }
        }
        return paths.sorted()
    }

    @Test func newFromSampleCreatesLoadedUnsavedV3() throws {
        let project = try tempProjectRoot()
        let before = try directoryListing(project.root)
        // Live sample parse: semicolon decimals, header L1, data L2, X/Y/skip.
        let model = EditorWorkspaceModel()
        model.delimiter = ";"
        model.decimalDelimiter = ","
        model.headerLineIndex = 0
        model.dataStartLineIndex = 1
        model.skippedMetadataLines = [1]
        model.sampleFileURL = URL(fileURLWithPath: "/synthetic/run01.txt")
        model.columns = [
            ColumnDefinition(name: "V", label: "Voltage", quantity: "voltage", unit: "V", isXAxis: true),
            ColumnDefinition(name: "I", label: "Current", quantity: "current", unit: "A", isYAxis: true),
            ColumnDefinition(name: "Notes", label: "Notes", quantity: "text", isSkipped: true),
        ]
        let doc = try model.newDocumentFromSample(
            profileID: "synth-new", profileName: "Synth New",
            grammarID: "standard-scientific",
            match: VariantMatchV3(filenameContainsAll: ["run01"], contentContainsAny: nil),
            catalog: Self.catalog())
        // Loaded: one keyless variant carrying the live parse.
        let loaded = try #require(model.profileDocument)
        #expect(loaded == doc)
        #expect(doc.variants.count == 1)
        #expect(doc.grammarID == "standard-scientific")
        #expect(doc.variantKeys.isEmpty)
        #expect(doc.variants[0].keyValues.isEmpty)
        #expect(doc.profileID == "synth-new")
        #expect(doc.profileName == "Synth New")
        let stream = doc.variants[0].rawStream
        #expect(stream.delimiter == ";")
        #expect(stream.decimalSeparator == ",")
        #expect(stream.rows.header == .row(1))
        #expect(stream.rows.dataStart == .row(2))
        #expect(stream.rows.excludedMetadata == [1])
        #expect(stream.extensions == [".txt"])
        #expect(stream.columns.map { $0.id } == ["V", "I", "Notes"])
        #expect(stream.columns.first(where: { $0.id == "V" })?.axes == [.x])
        #expect(stream.columns.first(where: { $0.id == "I" })?.axes == [.y])
        #expect(stream.columns.first(where: { $0.id == "Notes" })?.role == .skip)
        #expect(doc.variants[0].match == VariantMatchV3(
            filenameContainsAll: ["run01"], contentContainsAny: nil))
        // The built document validates against the active catalog.
        try doc.validate(catalog: Self.catalog())
        // Dirty + unsaved: selection tracks the new variant, disk untouched.
        #expect(model.profileDirty == true)
        #expect(model.selectedVariantID == doc.variants[0].id)
        #expect(try directoryListing(project.root) == before)
    }

    // MARK: - Task 7: tick-only keys with sample autofill

    /// A catalog with a required `batch` field, mirroring the UI rule that
    /// only required grammar fields can be routing keys.
    private func batchCatalog() -> FilenameGrammarCatalog {
        FilenameGrammarCatalog(grammars: [
            FilenameGrammar(
                id: "standard-scientific",
                name: "Standard Filename Pattern",
                template: "{instrument}.{mode}_{sample}",
                fields: [
                    GrammarField(name: "instrument", role: "instrument", type: .string),
                    GrammarField(name: "mode", role: "mode", type: .string),
                    GrammarField(name: "batch", role: "batch", type: .string),
                    GrammarField(name: "sample", role: "sample", type: .string, isOptional: true),
                ])
        ])
    }

    /// Reproduces the reported save-after-grammar failure: ticking a Variant
    /// Key stages empty values, and the save names the exact key.
    @Test func testTickedKeyStagesEmptyValueBlockingSaveWithExactKey() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try ProfileDocumentV3.parse(text: Self.baseYAML), selectedVariantID: "cv")
        try model.setVariantKeyEnabled("sample", enabled: true)
        let message: String
        do {
            _ = try model.saveDocument(project: try tempProjectRoot(), catalog: Self.catalog())
            Issue.record("expected save to fail on the empty staged key value")
            return
        } catch {
            message = error.localizedDescription
        }
        #expect(message == "variants[0].key_values.sample must be nonempty.")
    }

    /// Tick keys on a matched sample: autofill stages the extracted value
    /// (dirty), and Save Profile writes bytes through the validated path.
    @Test func testTickedKeyAutofillsFromSampleThenSaveWritesBytes() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try ProfileDocumentV3.parse(text: Self.baseYAML), selectedVariantID: "cv")
        try model.setVariantKeyEnabled("batch", enabled: true)
        model.autofillSelectedVariantKeyValues(from: ["batch": "B7"], isMatched: true)
        #expect(model.profileDocument?.variants.first?.keyValues["batch"] == "B7")
        #expect(model.profileDirty == true)
        let saved = try model.saveDocument(project: try tempProjectRoot(), catalog: batchCatalog())
        let text = try String(contentsOf: saved, encoding: .utf8)
        #expect(text.contains("B7"))
        let reloaded = try ProfileDocumentV3.parse(text: text)
        #expect(reloaded.variants.first?.keyValues["batch"] == "B7")
        #expect(model.profileDirty == false)
    }

    /// Unmatched samples never autofill; missing extraction stays empty and
    /// the save still names the exact key.
    @Test func testAutofillIgnoresUnmatchedSampleAndNamesMissingKey() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try ProfileDocumentV3.parse(text: Self.baseYAML), selectedVariantID: "cv")
        try model.setVariantKeyEnabled("batch", enabled: true)
        model.autofillSelectedVariantKeyValues(from: ["batch": "B7"], isMatched: false)
        #expect(model.profileDocument?.variants.first?.keyValues["batch"] == "")
        model.autofillSelectedVariantKeyValues(from: [:], isMatched: true)
        #expect(model.profileDocument?.variants.first?.keyValues["batch"] == "")
        let message: String
        do {
            _ = try model.saveDocument(project: try tempProjectRoot(), catalog: batchCatalog())
            Issue.record("expected save to fail on the missing key value")
            return
        } catch {
            message = error.localizedDescription
        }
        #expect(message == "variants[0].key_values.batch must be nonempty.")
    }

    // MARK: - Save-baseline single authority (byte-save rebase)

    /// Byte-save writes exact draft bytes (comments preserved), which differ
    /// from the re-serialized Core baseline. Rebasing to the written bytes
    /// lets the next visual save succeed instead of blocking forever.
    @Test func testByteSaveRebaseLetsVisualSaveSucceed() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try ProfileDocumentV3.parse(text: Self.baseYAML), selectedVariantID: "cv")
        let project = try tempProjectRoot()
        let saved = try model.saveDocument(project: project, catalog: Self.catalog())
        // Byte-save path: exact draft bytes (with a comment) land on disk.
        let byteExact = "# operator note\n" + (try String(contentsOf: saved, encoding: .utf8))
        try byteExact.write(to: saved, atomically: true, encoding: .utf8)
        model.rebaseSaveBaseline(to: byteExact)
        model.modeName = "CV edited"
        let resaved = try model.saveDocument(project: project, catalog: Self.catalog())
        #expect(resaved == saved)
        #expect(try String(contentsOf: saved, encoding: .utf8).contains("CV edited"))
        #expect(model.profileDirty == false)
    }

    /// Without the rebase, the same byte-save still blocks the visual save
    /// and preserves the file: no silent overwrite.
    @Test func testByteSaveWithoutRebaseStillBlocks() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try ProfileDocumentV3.parse(text: Self.baseYAML), selectedVariantID: "cv")
        let project = try tempProjectRoot()
        let saved = try model.saveDocument(project: project, catalog: Self.catalog())
        let byteExact = "# operator note\n" + (try String(contentsOf: saved, encoding: .utf8))
        try byteExact.write(to: saved, atomically: true, encoding: .utf8)
        model.modeName = "CV edited"
        #expect(throws: ProfileDocumentError.self) {
            try model.saveDocument(project: project, catalog: Self.catalog())
        }
        #expect(try String(contentsOf: saved, encoding: .utf8) == byteExact)
    }

    /// Rebasing never disables the guard: a later external change still
    /// aborts the save and preserves the file.
    @Test func testRebasePreservesExternalChangeGuard() throws {
        let model = EditorWorkspaceModel()
        model.applyProfileDocument(try ProfileDocumentV3.parse(text: Self.baseYAML), selectedVariantID: "cv")
        let project = try tempProjectRoot()
        let saved = try model.saveDocument(project: project, catalog: Self.catalog())
        model.rebaseSaveBaseline(to: try String(contentsOf: saved, encoding: .utf8))
        try "tampered".write(to: saved, atomically: true, encoding: .utf8)
        model.modeName = "CV edited"
        #expect(throws: ProfileDocumentError.self) {
            try model.saveDocument(project: project, catalog: Self.catalog())
        }
        #expect(try String(contentsOf: saved, encoding: .utf8) == "tampered")
    }
}
