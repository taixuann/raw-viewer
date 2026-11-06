import Foundation
import Testing
@testable import RawViewCore

struct ProjectLayoutCacheVectorsTests {
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

    @Test func sharedCacheVectorsMatchSwiftLayout() throws {
        let contract = try Self.loadCrossLanguageContract()
        guard let rel = contract.value(for: "cache_vectors")?.value(for: "file")?.scalarValue else {
            Issue.record("missing cache_vectors.file in contract")
            return
        }
        let vectorsURL = Self.repoRoot().appendingPathComponent("fixtures/grammar").appendingPathComponent(rel)
        let text = try String(contentsOf: vectorsURL, encoding: .utf8)
        let doc = try YAMLParser.parse(text)
        guard let cacheVectors = doc.value(for: "cache_vectors")?.listItems else {
            Issue.record("missing cache_vectors list in \(vectorsURL.path)")
            return
        }

        for vector in cacheVectors {
            guard let id = vector.value(for: "id")?.scalarValue,
                  let os = vector.value(for: "os")?.scalarValue,
                  let projectRoot = vector.value(for: "project_root")?.scalarValue,
                  let expectedHash = vector.value(for: "expected_hash")?.scalarValue
            else { continue }

            if os == "macos" {
                let computedHash = sha256Hex(Data(projectRoot.utf8))
                #expect(computedHash == expectedHash, "\(id): hash mismatch")

                let homeURL: URL?
                if let home = vector.value(for: "home")?.scalarValue {
                    homeURL = URL(fileURLWithPath: home)
                } else {
                    homeURL = nil
                }

                let cacheDir = ProjectIndexStore.projectCacheDirectory(
                    projectRoot: URL(fileURLWithPath: projectRoot),
                    home: homeURL
                )
                #expect(cacheDir.path.contains("projects/\(expectedHash)"), "\(id): cache directory path mismatch: \(cacheDir.path)")
                #expect(!cacheDir.path.contains(".raw-viewer"), "\(id): cache directory must not be in .raw-viewer")
                #expect(!cacheDir.path.contains(".rawviewer"), "\(id): cache directory must not be in .rawviewer")
            }
        }
    }
}
