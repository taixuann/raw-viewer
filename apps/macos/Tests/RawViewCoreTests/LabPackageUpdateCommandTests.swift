import XCTest
@testable import RawViewCore

/// What each Lab Packages button writes to disk, run against a temporary install (issue #121).
final class LabPackageUpdateCommandTests: XCTestCase {
    private let keithley = LabPackageTestFixtures.keithleyID
    private let autolab = LabPackageTestFixtures.autolabID
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateCommandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    private var keithleyBundled: String { LabPackageManager.bundledText(BuiltinAssets.keithley2400YAML) }
    private var autolabBundled: String { LabPackageManager.bundledText(BuiltinAssets.autolabUsthYAML) }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testUpdateProfileWritesOnlyThatProfile() throws {
        let global = tempDirectory.appendingPathComponent("global")
        let olderAutolab = LabPackageTestFixtures.olderRevision(of: BuiltinAssets.autolabUsthYAML)
        try LabPackageTestFixtures.makeInstall(
            global: global,
            version: "0.1.1",
            files: [
                keithley: LabPackageTestFixtures.olderRevision(of: BuiltinAssets.keithley2400YAML),
                autolab: olderAutolab
            ]
        )
        let profiles = LabPackageTestFixtures.profilesDirectory(global: global)

        let outcome = try LabPackagePresentation.run(.updateProfile(keithley), globalConfigDir: global)

        XCTAssertEqual(outcome.written, [keithley])
        XCTAssertEqual(outcome.kept, [])
        XCTAssertEqual(try read(profiles.appendingPathComponent("keithley-2400.yaml")), keithleyBundled)
        XCTAssertEqual(try read(profiles.appendingPathComponent("autolab-usth.yaml")), olderAutolab)
    }

    func testUpdatePackageWritesEveryAvailableProfileAndBumpsPackageVersion() throws {
        let global = tempDirectory.appendingPathComponent("global")
        try LabPackageTestFixtures.makeInstall(
            global: global,
            version: "0.1.0",
            files: [
                keithley: LabPackageTestFixtures.olderRevision(of: BuiltinAssets.keithley2400YAML),
                autolab: LabPackageTestFixtures.olderRevision(of: BuiltinAssets.autolabUsthYAML)
            ]
        )
        let profiles = LabPackageTestFixtures.profilesDirectory(global: global)

        let outcome = try LabPackagePresentation.run(.updatePackage, globalConfigDir: global)

        XCTAssertEqual(outcome.written, [keithley, autolab])
        XCTAssertEqual(outcome.kept, [])
        XCTAssertEqual(try read(profiles.appendingPathComponent("keithley-2400.yaml")), keithleyBundled)
        XCTAssertEqual(try read(profiles.appendingPathComponent("autolab-usth.yaml")), autolabBundled)
        XCTAssertEqual(try LabPackageManager.readInstalledUSTHManifest(globalConfigDir: global).version, "0.1.1")
    }

    func testReplaceEditedProfileWritesBundledCopy() throws {
        let global = tempDirectory.appendingPathComponent("global")
        try LabPackageTestFixtures.makeInstall(
            global: global,
            files: [keithley: keithleyBundled + "# my own edit\n"],
            recorded: [keithley: keithleyBundled]
        )

        let outcome = try LabPackagePresentation.run(.replaceEditedProfile(keithley), globalConfigDir: global)

        XCTAssertEqual(outcome.written, [keithley])
        XCTAssertEqual(outcome.kept, [])
        XCTAssertEqual(try read(LabPackageTestFixtures.profilesDirectory(global: global).appendingPathComponent("keithley-2400.yaml")), keithleyBundled)
    }

    func testKeepBothEditedProfileKeepsEditedFileAndStagesBundledCopy() throws {
        let global = tempDirectory.appendingPathComponent("global")
        let edited = keithleyBundled + "# my own edit\n"
        try LabPackageTestFixtures.makeInstall(
            global: global,
            files: [keithley: edited],
            recorded: [keithley: keithleyBundled]
        )

        let outcome = try LabPackagePresentation.run(.keepBothEditedProfile(keithley), globalConfigDir: global)

        XCTAssertEqual(outcome.written, [])
        XCTAssertEqual(outcome.kept, [keithley])
        XCTAssertEqual(try read(LabPackageTestFixtures.profilesDirectory(global: global).appendingPathComponent("keithley-2400.yaml")), edited)
        XCTAssertEqual(
            try read(LabPackageTestFixtures.packageDirectory(global: global).appendingPathComponent("staged/keithley-2400.yaml")),
            keithleyBundled
        )
    }

    func testUpdatePackageNeverWritesAProjectOverriddenProfile() throws {
        let global = tempDirectory.appendingPathComponent("global")
        let project = tempDirectory.appendingPathComponent("project")
        let olderKeithley = LabPackageTestFixtures.olderRevision(of: BuiltinAssets.keithley2400YAML)
        try LabPackageTestFixtures.makeInstall(
            global: global,
            version: "0.1.0",
            files: [keithley: olderKeithley, autolab: LabPackageTestFixtures.olderRevision(of: BuiltinAssets.autolabUsthYAML)]
        )
        let overrideDir = project.appendingPathComponent(".raw-viewer/profiles/usth", isDirectory: true)
        try FileManager.default.createDirectory(at: overrideDir, withIntermediateDirectories: true)
        try "id: usth/keithley-2400\n".write(to: overrideDir.appendingPathComponent("keithley-2400.yaml"), atomically: true, encoding: .utf8)

        let outcome = try LabPackagePresentation.run(.updatePackage, globalConfigDir: global, projectRoot: project)

        XCTAssertEqual(outcome.written, [autolab])
        XCTAssertEqual(try read(LabPackageTestFixtures.profilesDirectory(global: global).appendingPathComponent("keithley-2400.yaml")), olderKeithley)
    }

    func testPackageStaysUpdateAvailableAfterOneProfileUpdateUntilPackageUpdateBumpsVersion() throws {
        let global = tempDirectory.appendingPathComponent("global")
        try LabPackageTestFixtures.makeInstall(
            global: global,
            version: "0.1.0",
            files: [
                keithley: LabPackageTestFixtures.olderRevision(of: BuiltinAssets.keithley2400YAML),
                autolab: LabPackageTestFixtures.olderRevision(of: BuiltinAssets.autolabUsthYAML)
            ]
        )
        _ = try LabPackagePresentation.run(.updateProfile(keithley), globalConfigDir: global)
        let installed = try XCTUnwrap(LabPackageManager.listInstalledPackages(globalConfigDir: global).first)

        let afterProfile = LabPackagePresentation.section(for: installed, plan: try LabPackagePresentation.plan(globalConfigDir: global))

        XCTAssertEqual(afterProfile.packageStatusText, "Update available: 0.1.0 → 0.1.1")
        XCTAssertTrue(afterProfile.canUpdatePackage)
        XCTAssertEqual(try LabPackageManager.readInstalledUSTHManifest(globalConfigDir: global).version, "0.1.0")

        let outcome = try LabPackagePresentation.run(.updatePackage, globalConfigDir: global)

        XCTAssertEqual(outcome.written, [autolab])
        XCTAssertEqual(LabPackagePresentation.successLine(for: outcome, command: .updatePackage), "Updated usth/autolab-usth. Package is now version 0.1.1.")
        XCTAssertEqual(try LabPackageManager.readInstalledUSTHManifest(globalConfigDir: global).version, "0.1.1")
    }

    func testUpdatePackageStagesEditedProfileWithoutReplacingIt() throws {
        let global = tempDirectory.appendingPathComponent("global")
        let bundledKeithley = keithleyBundled
        let edited = bundledKeithley + "# my own edit\n"
        try LabPackageTestFixtures.makeInstall(
            global: global,
            version: "0.1.0",
            files: [keithley: edited, autolab: LabPackageTestFixtures.olderRevision(of: BuiltinAssets.autolabUsthYAML)],
            recorded: [keithley: bundledKeithley]
        )

        let outcome = try LabPackagePresentation.run(.updatePackage, globalConfigDir: global)

        XCTAssertEqual(outcome.written, [autolab])
        XCTAssertEqual(outcome.kept, [keithley])
        XCTAssertEqual(try read(LabPackageTestFixtures.profilesDirectory(global: global).appendingPathComponent("keithley-2400.yaml")), edited)
        XCTAssertEqual(
            try read(LabPackageTestFixtures.packageDirectory(global: global).appendingPathComponent("staged/keithley-2400.yaml")),
            bundledKeithley
        )
    }

    func testSectionBuiltFromDiskShowsPackageAndProfileUpdates() throws {
        let global = tempDirectory.appendingPathComponent("global")
        try LabPackageTestFixtures.makeInstall(
            global: global,
            version: "0.1.0",
            files: [keithley: LabPackageTestFixtures.olderRevision(of: BuiltinAssets.keithley2400YAML)]
        )
        let installed = try XCTUnwrap(LabPackageManager.listInstalledPackages(globalConfigDir: global).first)

        let plan = try LabPackagePresentation.plan(globalConfigDir: global)
        let section = LabPackagePresentation.section(for: installed, plan: plan)

        XCTAssertEqual(section.packageStatusText, "Update available: 0.1.0 → 0.1.1")
        XCTAssertTrue(section.canUpdatePackage)
        XCTAssertEqual(section.rows.map(\.profileID), [keithley, autolab, "usth/horiba-labram", "usth/iop-hanoi"])
        XCTAssertEqual(section.rows.map(\.kind), [.updateAvailable, .current, .current, .current])
        XCTAssertEqual(section.rows.map(\.revisionText), ["rev 0 → 1", nil, nil, nil])
    }
}
