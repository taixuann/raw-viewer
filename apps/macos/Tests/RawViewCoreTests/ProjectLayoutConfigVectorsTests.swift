import Foundation
import Testing
@testable import RawViewCore

struct ProjectLayoutConfigVectorsTests {
    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static func crossLanguageContractURL() -> URL {
        repoRoot().appendingPathComponent("fixtures/grammar/cross_language_contract.yaml")
    }

    private static func loadCrossLanguageContract() throws -> YAMLNode {
        let contractURL = crossLanguageContractURL()
        let text = try String(contentsOf: contractURL, encoding: .utf8)
        return try YAMLParser.parse(text)
    }

    @Test func sharedConfigVectorsMatchSwiftLoader() throws {
        let contract = try Self.loadCrossLanguageContract()
        guard let rel = contract.value(for: "config_vectors")?.value(for: "file")?.scalarValue else {
            Issue.record("missing config_vectors.file in contract")
            return
        }
        let vectorsURL = Self.repoRoot().appendingPathComponent("fixtures/grammar").appendingPathComponent(rel)
        let text = try String(contentsOf: vectorsURL, encoding: .utf8)
        let doc = try YAMLParser.parse(text)
        guard let vectors = doc.value(for: "vectors")?.listItems else {
            Issue.record("missing vectors list in \(vectorsURL.path)")
            return
        }

        for vector in vectors {
            guard let id = vector.value(for: "id")?.scalarValue else { continue }
            let tempProject = FileManager.default.temporaryDirectory
                .appendingPathComponent("rawview-config-vector-\(id)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempProject) }
            try FileManager.default.createDirectory(at: tempProject, withIntermediateDirectories: true)

            if let relConfig = vector.value(for: "config_file")?.scalarValue {
                let sourceConfig = Self.repoRoot().appendingPathComponent("fixtures/config").appendingPathComponent(relConfig)
                let body = try String(contentsOf: sourceConfig, encoding: .utf8)
                let targetDir = tempProject.appendingPathComponent(".raw-viewer", isDirectory: true)
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                try body.write(to: targetDir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
            }

            if let expect = vector.value(for: "expect") {
                let loaded = try ProjectSettingsStore.loadConfigOrDefault(projectRoot: tempProject)
                if let dataRoot = expect.value(for: "data_root")?.scalarValue {
                    #expect(loaded.dataRoot == dataRoot, "\(id): data_root mismatch")
                }
                if let defaultView = expect.value(for: "default_view")?.scalarValue {
                    #expect(loaded.defaultView == defaultView, "\(id): default_view mismatch")
                }
                if let defaultPreset = expect.value(for: "default_preset")?.scalarValue {
                    #expect(loaded.defaultPreset == defaultPreset, "\(id): default_preset mismatch")
                }
            } else if let expectErr = vector.value(for: "expect_error") {
                let needle = expectErr.value(for: "detail_contains")?.scalarValue ?? ""
                var thrownReason: String?
                do {
                    _ = try ProjectSettingsStore.load(projectRoot: tempProject)
                    Issue.record("\(id): expected error containing \(needle), but succeeded")
                } catch let err as ProjectSettingsError {
                    thrownReason = err.reason
                } catch {
                    thrownReason = error.localizedDescription
                }
                if let reason = thrownReason {
                    #expect(reason.contains(needle), "\(id): error message '\(reason)' did not contain '\(needle)'")
                }
            }
        }
    }
}
