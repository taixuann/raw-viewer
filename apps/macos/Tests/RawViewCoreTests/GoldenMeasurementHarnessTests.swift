import Foundation
import Testing
@testable import RawViewCore

struct GoldenMeasurementHarnessTests {
    private struct Manifest: Decodable {
        struct Case: Decodable {
            let id: String
            let grammarFile: String?
            let profileFiles: [String: String]
            let sourceFiles: [String: String]
            let sourceToLoad: String

            enum CodingKeys: String, CodingKey {
                case id
                case grammarFile = "grammar_file"
                case profileFiles = "profile_files"
                case sourceFiles = "source_files"
                case sourceToLoad = "source_to_load"
            }
        }

        let cases: [Case]
    }

    @Test func normalizedMeasurementGoldenHarness() async throws {
        let environment = ProcessInfo.processInfo.environment
        let shouldWrite = environment["RAWVIEW_WRITE_GOLDENS"] == "1"
        let shouldVerify = environment["RAWVIEW_VERIFY_GOLDENS"] == "1"
        guard shouldWrite || shouldVerify else { return }

        let repoRoot = try Self.repoRoot()
        let fixturesRoot = repoRoot.appendingPathComponent("core/tests/fixtures")
        let goldenRoot = repoRoot.appendingPathComponent("core/tests/golden")
        let manifestURL = fixturesRoot.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)

        for entry in manifest.cases {
            let root = try makeProject(
                fixturesRoot: fixturesRoot,
                grammarFile: entry.grammarFile,
                profileFiles: entry.profileFiles,
                sourceFiles: entry.sourceFiles
            )
            defer { try? FileManager.default.removeItem(at: root) }

            let project = try ProjectContext.open(root)
            let sources = try project.discoverSources()
            guard let source = sources.first(where: { $0.relativePath == entry.sourceToLoad }) else {
                Issue.record("Case \(entry.id): source_to_load \(entry.sourceToLoad) was not discovered")
                continue
            }

            let measurement = try await InstrumentReader.load(source.url, project: project)
            let encoded = try NormalizedMeasurementGoldenEncoder.encode(measurement)
            let goldenURL = goldenRoot.appendingPathComponent("\(entry.id).json")

            if shouldWrite {
                try FileManager.default.createDirectory(at: goldenRoot, withIntermediateDirectories: true)
                try encoded.write(to: goldenURL, options: .atomic)
                continue
            }

            guard FileManager.default.fileExists(atPath: goldenURL.path) else {
                Issue.record("Case \(entry.id): missing golden file at \(goldenURL.path)")
                continue
            }
            let expected = try Data(contentsOf: goldenURL)
            guard encoded == expected else {
                let diffURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("rawview-golden-\(entry.id)-actual.json")
                try encoded.write(to: diffURL)
                Issue.record(
                    """
                    Golden mismatch for \(entry.id).
                    expected: \(goldenURL.path)
                    actual:   \(diffURL.path)
                    Re-run with RAWVIEW_WRITE_GOLDENS=1 to refresh the checked-in golden.
                    """
                )
            }
        }
    }

    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func makeProject(
        fixturesRoot: URL,
        grammarFile: String?,
        profileFiles: [String: String],
        sourceFiles: [String: String]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawview-golden-\(UUID().uuidString)")
        for (relativePath, fixtureRelative) in sourceFiles {
            let payload = try Data(contentsOf: fixturesRoot.appendingPathComponent(fixtureRelative))
            let destination = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: destination)
        }
        if let grammarFile {
            let payload = try Data(contentsOf: fixturesRoot.appendingPathComponent(grammarFile))
            let destination = root.appendingPathComponent(".rawviewer/grammar.yaml")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: destination)
        }
        for (name, fixtureRelative) in profileFiles {
            let payload = try Data(contentsOf: fixturesRoot.appendingPathComponent(fixtureRelative))
            let destination = root.appendingPathComponent("data/instruments/\(name)")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: destination)
        }
        return root
    }
}
