import Foundation
import Testing
@testable import RawViewCore

struct ProfileCatalogDiscoveryTests {
    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    @Test func rawViewerProfilesLoadAndTakePrecedence() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawview-profiles-priority-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
        let keysight = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("core/tests/fixtures/profiles/keysight-b1500a.yaml"))
        let profilesDir = tmp.appendingPathComponent(".raw-viewer/profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try keysight.write(to: profilesDir.appendingPathComponent("priority.yaml"), atomically: true, encoding: .utf8)
        let legacyDir = tmp.appendingPathComponent("data/instruments", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try keysight.write(to: legacyDir.appendingPathComponent("legacy.yaml"), atomically: true, encoding: .utf8)
        let project = try ProjectContext.open(tmp)
        let catalog = ProfileCatalog.load(project: project)
        #expect(catalog.profiles.count == 1)
        #expect(catalog.profiles[0].relativePath.hasPrefix(".raw-viewer/profiles/"))
    }

    @Test func legacyDirectoriesStillLoadWithoutRawViewerProfiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawview-legacy-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
        let keysight = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("core/tests/fixtures/profiles/keysight-b1500a.yaml"))
        let legacyDir = tmp.appendingPathComponent("data/.rawview/instrument", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try keysight.write(to: legacyDir.appendingPathComponent("legacy.yaml"), atomically: true, encoding: .utf8)
        let project = try ProjectContext.open(tmp)
        let catalog = ProfileCatalog.load(project: project)
        #expect(catalog.profiles.count == 1)
        #expect(catalog.profiles[0].relativePath.hasPrefix("data/.rawview/instrument/"))
    }
}
