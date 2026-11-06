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
        let keysightYAML = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("core/tests/fixtures/profiles/keysight-b1500a.yaml"))
        let profilesDir = tmp.appendingPathComponent(".raw-viewer/profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try keysightYAML.write(to: profilesDir.appendingPathComponent("priority.yaml"), atomically: true, encoding: .utf8)
        let legacyDir = tmp.appendingPathComponent("data/instruments", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try keysightYAML.write(to: legacyDir.appendingPathComponent("legacy.yaml"), atomically: true, encoding: .utf8)
        let project = try ProjectContext.open(tmp)
        let catalog = ProfileCatalog.load(project: project)
        let keysight = catalog.profiles.first { $0.profileID == "usth/keysight-b1500a" }
        #expect(keysight != nil)
        #expect(keysight?.relativePath.hasPrefix(".raw-viewer/profiles/") == true)
    }

    @Test func legacyDirectoriesStillLoadWithoutRawViewerProfiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawview-legacy-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
        let keysightYAML = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("core/tests/fixtures/profiles/keysight-b1500a.yaml"))
        let legacyDir = tmp.appendingPathComponent("data/.rawview/instrument", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try keysightYAML.write(to: legacyDir.appendingPathComponent("legacy.yaml"), atomically: true, encoding: .utf8)
        let project = try ProjectContext.open(tmp)
        let catalog = ProfileCatalog.load(project: project)
        let keysight = catalog.profiles.first { $0.profileID == "usth/keysight-b1500a" }
        #expect(keysight != nil)
        #expect(keysight?.relativePath.hasPrefix("data/.rawview/instrument/") == true)
    }

    @Test func dataInstrumentsWithNonYAMLFilesDoesNotSuppressBuiltins() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawview-non-yaml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("data/instruments"), withIntermediateDirectories: true)
        try "# python script".write(to: tmp.appendingPathComponent("data/instruments/reader.py"), atomically: true, encoding: .utf8)
        let project = try ProjectContext.open(tmp)
        let catalog = ProfileCatalog.load(project: project)
        #expect(!catalog.profiles.isEmpty)
        #expect(catalog.profiles.contains { $0.profileID == "usth/keithley-2400" })
    }
}
