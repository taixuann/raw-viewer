import XCTest
@testable import RawViewCore

/// Single-profile keep-both for the USTH package (issue #121, acceptance case 4).
final class LabPackageKeepBothTests: XCTestCase {
    private let keithleyID = "usth/keithley-2400"
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("KeepBothTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    func testKeepBothForOneEditedProfileStagesBundledCopyAndKeepsEditedFile() throws {
        let global = tempDirectory.appendingPathComponent("global")
        let bundled = LabPackageManager.bundledText(BuiltinAssets.keithley2400YAML)
        let edited = bundled + "# my own edit\n"
        try makeInstall(global: global, files: [keithleyID: edited], recorded: [keithleyID: bundled])
        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: global).appendingPathComponent("usth")
        let packageDir = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: global).appendingPathComponent("usth-lab")

        let outcome = try LabPackageManager.upgradeUSTHLabPackage(globalConfigDir: global, only: [keithleyID], keepBoth: [keithleyID])

        XCTAssertEqual(outcome.written, [])
        XCTAssertEqual(outcome.kept, [keithleyID])
        XCTAssertEqual(try String(contentsOf: profilesDir.appendingPathComponent("keithley-2400.yaml"), encoding: .utf8), edited)
        XCTAssertEqual(try String(contentsOf: packageDir.appendingPathComponent("staged/keithley-2400.yaml"), encoding: .utf8), bundled)
        let manifest = try LabPackageManager.readInstalledUSTHManifest(globalConfigDir: global)
        XCTAssertEqual(manifest.entries.first { $0.id == keithleyID }?.sha256, sha256Hex(Data(bundled.utf8)))
    }

    func testSingleEditedProfileWithoutConsentIsStillRefusedAndNothingIsStaged() throws {
        let global = tempDirectory.appendingPathComponent("global")
        let bundled = LabPackageManager.bundledText(BuiltinAssets.keithley2400YAML)
        let edited = bundled + "# my own edit\n"
        try makeInstall(global: global, files: [keithleyID: edited], recorded: [keithleyID: bundled])
        let packageDir = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: global).appendingPathComponent("usth-lab")

        XCTAssertThrowsError(try LabPackageManager.upgradeUSTHLabPackage(globalConfigDir: global, only: [keithleyID])) { error in
            XCTAssertEqual(
                error as? LabPackageError,
                .upgradeRefused("usth/keithley-2400 was edited locally; pass --replace usth/keithley-2400 to replace it")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageDir.appendingPathComponent("staged").path))
    }

    /// Writes every bundled profile as installed at `version`. `files` overrides the on-disk text,
    /// and `recorded` overrides the text whose sha256 the manifest records.
    private func makeInstall(global: URL, version: String = LabPackageManager.usthPackageVersion, files: [String: String] = [:], recorded: [String: String] = [:]) throws {
        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: global).appendingPathComponent("usth", isDirectory: true)
        let packageDir = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: global).appendingPathComponent("usth-lab", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        var entries: [ManifestProfileEntry] = []
        for item in BuiltinAssets.builtinProfiles {
            let filename = URL(fileURLWithPath: item.relativePath).lastPathComponent
            let onDisk = files[item.id] ?? LabPackageManager.bundledText(item.yaml)
            try onDisk.write(to: profilesDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
            let recordedText = recorded[item.id] ?? onDisk
            entries.append(ManifestProfileEntry(id: item.id, filename: filename, sha256: sha256Hex(Data(recordedText.utf8))))
        }
        try LabPackageManager.renderUSTHManifest(version: version, entries: entries)
            .write(to: packageDir.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)
    }
}
