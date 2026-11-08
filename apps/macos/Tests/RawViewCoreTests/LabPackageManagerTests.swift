import XCTest
@testable import RawViewCore

final class LabPackageManagerTests: XCTestCase {
    var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LabPackageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try super.tearDownWithError()
    }

    func testGlobalPathResolverDefaults() {
        let home = tempDirectory.appendingPathComponent("fakeHome")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let resolved = GlobalPathResolver.resolveGlobalConfigDirectory(home: home, env: [:])
        XCTAssertTrue(resolved.path.hasSuffix("Library/Application Support/raw-viewer"))

        let grammar = GlobalPathResolver.globalGrammarFile(globalConfigDir: resolved)
        XCTAssertEqual(grammar.lastPathComponent, "grammar.yaml")

        let config = GlobalPathResolver.globalConfigFile(globalConfigDir: resolved)
        XCTAssertEqual(config.lastPathComponent, "config.yaml")

        let packages = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: resolved)
        XCTAssertEqual(packages.lastPathComponent, "packages")

        let projectRoot = tempDirectory.appendingPathComponent("myProject")
        let projConfig = GlobalPathResolver.projectConfigFile(projectRoot: projectRoot)
        XCTAssertEqual(projConfig.path, projectRoot.appendingPathComponent(".raw-viewer/config.yaml").path)
    }

    func testGlobalPathResolverHonorsXDGWhenDirectoryExists() {
        let xdgDir = tempDirectory.appendingPathComponent("xdg")
        let appDir = xdgDir.appendingPathComponent("raw-viewer")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        let resolved = GlobalPathResolver.resolveGlobalConfigDirectory(home: tempDirectory, env: ["XDG_CONFIG_HOME": xdgDir.path])
        XCTAssertEqual(resolved.path, appDir.path)
    }

    func testInstallAndRemoveUSTHLabPackage() throws {
        let fakeGlobal = tempDirectory.appendingPathComponent("global")
        try FileManager.default.createDirectory(at: fakeGlobal, withIntermediateDirectories: true)

        XCTAssertFalse(LabPackageManager.isUSTHPackageInstalled(globalConfigDir: fakeGlobal))
        XCTAssertEqual(LabPackageManager.listInstalledPackages(globalConfigDir: fakeGlobal).count, 0)

        // Install USTH package
        try LabPackageManager.installUSTHLabPackage(globalConfigDir: fakeGlobal)

        XCTAssertTrue(LabPackageManager.isUSTHPackageInstalled(globalConfigDir: fakeGlobal))
        let installed = LabPackageManager.listInstalledPackages(globalConfigDir: fakeGlobal)
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed.first?.id, "usth-lab")
        XCTAssertEqual(installed.first?.version, "0.1.0")
        XCTAssertEqual(installed.first?.profiles.count, 4)

        // Verify profiles written
        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: fakeGlobal).appendingPathComponent("usth")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profilesDir.appendingPathComponent("keithley-2400.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profilesDir.appendingPathComponent("autolab-usth.yaml").path))

        // Check project conflict detection
        let fakeProject = tempDirectory.appendingPathComponent("proj")
        let localProfiles = fakeProject.appendingPathComponent(".raw-viewer/profiles/usth")
        try FileManager.default.createDirectory(at: localProfiles, withIntermediateDirectories: true)
        try "test".write(to: localProfiles.appendingPathComponent("keithley-2400.yaml"), atomically: true, encoding: .utf8)

        let conflicts = LabPackageManager.detectProjectConflicts(package: installed[0], projectRoot: fakeProject)
        XCTAssertEqual(conflicts, ["usth/keithley-2400"])

        // Remove package
        try LabPackageManager.removePackage(id: "usth-lab", globalConfigDir: fakeGlobal)
        XCTAssertFalse(LabPackageManager.isUSTHPackageInstalled(globalConfigDir: fakeGlobal))
        XCTAssertEqual(LabPackageManager.listInstalledPackages(globalConfigDir: fakeGlobal).count, 0)
    }
}
