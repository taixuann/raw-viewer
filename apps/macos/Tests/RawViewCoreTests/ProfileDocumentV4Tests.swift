import Foundation
import Testing
@testable import RawViewCore

struct ProfileDocumentV4Tests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func fixtureText(_ relative: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func loadProfile(yaml: String, path: String) -> ProfileLoadOutcome {
        ProfileSchema.load(text: yaml, relativePath: path, sha256: sha256Hex(Data(yaml.utf8)))
    }

    @Test func v1V2V3FixturesStillLoad() throws {
        for (path, relative) in [
            ("compat/keysight-b1500a-v1.yaml", "core/tests/fixtures/profiles/compat/keysight-b1500a-v1.yaml"),
            ("compat/keysight-b1500a-v2.yaml", "core/tests/fixtures/profiles/compat/keysight-b1500a-v2.yaml"),
            ("acme-v3.yaml", "core/tests/fixtures/profiles/acme-v3.yaml"),
        ] {
            let yaml = try Self.fixtureText(relative)
            let outcome = loadProfile(yaml: yaml, path: path)
            #expect(outcome.issues.isEmpty, "\(path): \(outcome.issues.joined(separator: "\n"))")
            if path.contains("v3") {
                #expect(outcome.v3Document != nil, "\(path)")
            } else {
                #expect(outcome.profile != nil, "\(path)")
            }
        }
    }

    @Test func unsupportedSchemaVersionListsV4() throws {
        let yaml = try Self.fixtureText("core/tests/fixtures/profiles/compat/keysight-b1500a-v1.yaml")
            .replacingOccurrences(of: "schema_version: 1", with: "schema_version: 9")
        let outcome = loadProfile(yaml: yaml, path: "broken.yaml")
        let text = outcome.issues.joined(separator: "\n")
        #expect(text.contains("unsupported schema_version 9"), "\(text)")
        #expect(text.contains("schema_version 1, 2, 3, and 4"), "\(text)")
    }

    @Test func keysightV4ProfileLoadsAndCompiles() throws {
        let yaml = try Self.fixtureText("core/tests/fixtures/profiles/keysight-b1500a.yaml")
        let outcome = loadProfile(yaml: yaml, path: "keysight-b1500a.yaml")
        #expect(outcome.issues.isEmpty, outcome.issues.joined(separator: "\n"))
        let profile = try #require(outcome.profile)
        #expect(profile.profileID == "usth/keysight-b1500a")
        #expect(profile.schemaVersion == 4)
        #expect(profile.modes.count == 7)
    }

    @Test func progressionRoundTrip() throws {
        let yaml = """
            schema_version: 4
            id: usth/demo
            instrument:
              id: demo
              name: Demo
            variants:
              run:
                format:
                  kind: tabular
                  extensions: [".txt"]
                  delimiter: ","
                rows:
                  header: 1
                  data_start: 2
                columns:
                  t:
                    role: progression
                    type: time
                    behavior: continuous
                    header: T
                    quantity: time
                    unit: s
                    label: Time
                  i:
                    role: progression
                    type: index
                    behavior: discrete
                    header: I
                    quantity: index
                    unit: "1"
                    label: Index
                  c:
                    role: channel
                    header: C
                    quantity: current
                    unit: A
                    label: Current
                plot:
                  x: t
                  y: [c]
                when:
                  content_contains_any: ["demo"]
            """
        let doc = try ProfileV4Codec.parse(text: yaml)
        let t = try #require(doc.variants["run"]?.columns["t"])
        #expect(t.progression?.progressionType == "time")
        #expect(t.progression?.behavior == "continuous")
    }

    @Test func variantsMapIsKeyedByApplicationMode() throws {
        let yaml = """
            schema_version: 4
            id: usth/demo
            instrument:
              id: demo
              name: Demo
            variants:
              cv:
                format:
                  kind: tabular
                  extensions: [".txt"]
                  delimiter: ","
                rows:
                  names_prefix: H
                  data_prefix: D
                columns:
                  x:
                    role: channel
                    header: X
                    quantity: voltage
                    unit: V
                    label: X
                  y:
                    role: channel
                    header: Y
                    quantity: current
                    unit: A
                    label: Y
                plot:
                  x: x
                  y: [y]
                when:
                  content_contains_any: ["cv"]
            """
        let doc = try ProfileV4Codec.parse(text: yaml)
        #expect(doc.variants.keys.sorted() == ["cv"])
    }

    @Test func overlappingRowsFailValidation() throws {
        let yaml = """
            schema_version: 4
            id: usth/demo
            instrument:
              id: demo
              name: Demo
            variants:
              m:
                format:
                  kind: tabular
                  extensions: [".txt"]
                  delimiter: ","
                rows:
                  metadata: [1, "2-4"]
                  header: 3
                columns:
                  x:
                    role: channel
                    header: X
                    quantity: voltage
                    unit: V
                    label: X
                plot:
                  x: x
                  y: [x]
                when:
                  content_contains_any: ["x"]
            """
        do {
            _ = try ProfileV4Codec.parse(text: yaml)
            Issue.record("expected overlapping rows to fail")
        } catch let error as ProfileV4Error {
            #expect(error.localizedDescription.contains("overlap"))
        }
    }
}
