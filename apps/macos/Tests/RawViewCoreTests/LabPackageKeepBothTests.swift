import XCTest
@testable import RawViewCore

/// Single-profile keep-both for the USTH package (issue #121, acceptance case 4).
final class LabPackageKeepBothTests: XCTestCase {
    private let keithleyID = LabPackageTestFixtures.keithleyID
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
        try LabPackageTestFixtures.makeInstall(global: global, files: [keithleyID: edited], recorded: [keithleyID: bundled])

        let outcome = try LabPackageManager.upgradeUSTHLabPackage(globalConfigDir: global, only: [keithleyID], keepBoth: [keithleyID])

        XCTAssertEqual(outcome.written, [])
        XCTAssertEqual(outcome.kept, [keithleyID])
        XCTAssertEqual(
            try String(contentsOf: LabPackageTestFixtures.profilesDirectory(global: global).appendingPathComponent("keithley-2400.yaml"), encoding: .utf8),
            edited
        )
        XCTAssertEqual(
            try String(contentsOf: LabPackageTestFixtures.packageDirectory(global: global).appendingPathComponent("staged/keithley-2400.yaml"), encoding: .utf8),
            bundled
        )
        let manifest = try LabPackageManager.readInstalledUSTHManifest(globalConfigDir: global)
        XCTAssertEqual(manifest.entries.first { $0.id == keithleyID }?.sha256, sha256Hex(Data(bundled.utf8)))
    }

    func testSingleEditedProfileWithoutConsentIsStillRefusedAndNothingIsStaged() throws {
        let global = tempDirectory.appendingPathComponent("global")
        let bundled = LabPackageManager.bundledText(BuiltinAssets.keithley2400YAML)
        let edited = bundled + "# my own edit\n"
        try LabPackageTestFixtures.makeInstall(global: global, files: [keithleyID: edited], recorded: [keithleyID: bundled])

        XCTAssertThrowsError(try LabPackageManager.upgradeUSTHLabPackage(globalConfigDir: global, only: [keithleyID])) { error in
            XCTAssertEqual(
                error as? LabPackageError,
                .upgradeRefused("usth/keithley-2400 was edited locally; pass --replace usth/keithley-2400 to replace it")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: LabPackageTestFixtures.packageDirectory(global: global).appendingPathComponent("staged").path))
    }
}
