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
        XCTAssertEqual(installed.first?.version, LabPackageManager.usthPackageVersion)
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

    // MARK: - Update planning (issue #121)

    private let keithleyID = "usth/keithley-2400"
    private let autolabID = "usth/autolab-usth"

    private func profileText(_ revision: Int, _ body: String) -> String {
        "schema_version: 4\nrevision: \(revision)\nname: \(body)\n"
    }

    private func bundledRecord(_ id: String, _ text: String) -> BundledProfileRecord {
        let filename = String(id.split(separator: "/").last ?? "") + ".yaml"
        return BundledProfileRecord(
            id: id,
            filename: filename,
            text: text,
            sha256: sha256Hex(Data(text.utf8)),
            revision: LabPackageManager.profileRevision(in: text) ?? 0
        )
    }

    private func manifestEntry(_ id: String, recordedText: String) -> ManifestProfileEntry {
        ManifestProfileEntry(
            id: id,
            filename: String(id.split(separator: "/").last ?? "") + ".yaml",
            sha256: sha256Hex(Data(recordedText.utf8))
        )
    }

    private func installedFile(_ id: String, onDiskText: String) -> InstalledProfileFile {
        InstalledProfileFile(
            id: id,
            revision: LabPackageManager.profileRevision(in: onDiskText),
            sha256: sha256Hex(Data(onDiskText.utf8))
        )
    }

    func testCase1SameVersionAndRevisionsListNoUpdate() throws {
        let keithley = profileText(1, "keithley")
        let autolab = profileText(1, "autolab")

        let plan = LabPackageManager.planUpdate(
            installedVersion: "0.1.0",
            installedEntries: [manifestEntry(keithleyID, recordedText: keithley), manifestEntry(autolabID, recordedText: autolab)],
            installedFiles: [installedFile(keithleyID, onDiskText: keithley), installedFile(autolabID, onDiskText: autolab)],
            bundledVersion: "0.1.0",
            bundled: [bundledRecord(keithleyID, keithley), bundledRecord(autolabID, autolab)],
            projectOverrides: []
        )

        XCTAssertNil(plan.packageUpdate)
        XCTAssertEqual(plan.profiles, [])
        XCTAssertEqual(try LabPackageManager.selectWrites(plan: plan, only: [], replace: []), [])
    }

    func testCase2NewerBundledVersionListsPackageWithChangedProfile() throws {
        let keithleyOld = profileText(1, "keithley")
        let autolab = profileText(1, "autolab")
        let keithleyNew = profileText(2, "keithley new")

        let plan = LabPackageManager.planUpdate(
            installedVersion: "0.0.9",
            installedEntries: [manifestEntry(keithleyID, recordedText: keithleyOld), manifestEntry(autolabID, recordedText: autolab)],
            installedFiles: [installedFile(keithleyID, onDiskText: keithleyOld), installedFile(autolabID, onDiskText: autolab)],
            bundledVersion: "0.1.0",
            bundled: [bundledRecord(keithleyID, keithleyNew), bundledRecord(autolabID, autolab)],
            projectOverrides: []
        )

        XCTAssertEqual(plan.packageID, "usth-lab")
        XCTAssertEqual(plan.packageUpdate, VersionChange(installed: "0.0.9", bundled: "0.1.0"))
        XCTAssertEqual(
            plan.profiles,
            [ProfileUpdate(id: keithleyID, installedRevision: 1, bundledRevision: 2, state: .updateAvailable)]
        )
    }

    func testCase3OneNewerProfileIsWrittenAloneAndOthersStayUntouched() throws {
        let keithleyOld = profileText(1, "keithley")
        let autolab = profileText(1, "autolab")
        let keithleyNew = profileText(2, "keithley new")
        let bundled = [bundledRecord(keithleyID, keithleyNew), bundledRecord(autolabID, autolab)]

        let plan = LabPackageManager.planUpdate(
            installedVersion: "0.1.0",
            installedEntries: [manifestEntry(keithleyID, recordedText: keithleyOld), manifestEntry(autolabID, recordedText: autolab)],
            installedFiles: [installedFile(keithleyID, onDiskText: keithleyOld), installedFile(autolabID, onDiskText: autolab)],
            bundledVersion: "0.1.0",
            bundled: bundled,
            projectOverrides: []
        )

        XCTAssertNil(plan.packageUpdate)
        XCTAssertEqual(plan.profiles.map(\.id), [keithleyID])
        XCTAssertEqual(plan.profiles.first?.state, .updateAvailable)
        let writes = try LabPackageManager.selectWrites(plan: plan, only: [], replace: [])
        XCTAssertEqual(writes, [keithleyID])
        let entries = LabPackageManager.upgradedEntries(
            installedEntries: [manifestEntry(keithleyID, recordedText: keithleyOld), manifestEntry(autolabID, recordedText: autolab)],
            bundled: bundled,
            written: writes
        )
        XCTAssertEqual(entries.map(\.id), [keithleyID, autolabID])
        XCTAssertEqual(entries[0].sha256, sha256Hex(Data(keithleyNew.utf8)))
        XCTAssertEqual(entries[1].sha256, sha256Hex(Data(autolab.utf8)))
    }

    func testCase4EditedProfileIsNotReplacedWithoutConsent() throws {
        let keithleyInstalled = profileText(1, "keithley")
        let keithleyEdited = profileText(1, "keithley with my edit")
        let keithleyNew = profileText(2, "keithley new")

        let plan = LabPackageManager.planUpdate(
            installedVersion: "0.1.0",
            installedEntries: [manifestEntry(keithleyID, recordedText: keithleyInstalled)],
            installedFiles: [installedFile(keithleyID, onDiskText: keithleyEdited)],
            bundledVersion: "0.2.0",
            bundled: [bundledRecord(keithleyID, keithleyNew)],
            projectOverrides: []
        )

        XCTAssertEqual(
            plan.profiles,
            [ProfileUpdate(id: keithleyID, installedRevision: 1, bundledRevision: 2, state: .locallyEdited)]
        )
        XCTAssertEqual(try LabPackageManager.selectWrites(plan: plan, only: [], replace: []), [])
        XCTAssertThrowsError(try LabPackageManager.selectWrites(plan: plan, only: [keithleyID], replace: [])) { error in
            XCTAssertEqual(
                error as? LabPackageError,
                .upgradeRefused("usth/keithley-2400 was edited locally; pass --replace usth/keithley-2400 to replace it")
            )
        }
        XCTAssertEqual(
            try LabPackageManager.selectWrites(plan: plan, only: [keithleyID], replace: [keithleyID]),
            [keithleyID]
        )
    }

    func testCase5ProjectLocalOverrideIsReportedAndNeverChanged() throws {
        let keithleyOld = profileText(1, "keithley")
        let keithleyNew = profileText(2, "keithley new")

        let plan = LabPackageManager.planUpdate(
            installedVersion: "0.1.0",
            installedEntries: [manifestEntry(keithleyID, recordedText: keithleyOld)],
            installedFiles: [installedFile(keithleyID, onDiskText: keithleyOld)],
            bundledVersion: "0.2.0",
            bundled: [bundledRecord(keithleyID, keithleyNew)],
            projectOverrides: [keithleyID]
        )

        XCTAssertEqual(
            plan.profiles,
            [ProfileUpdate(id: keithleyID, installedRevision: 1, bundledRevision: 2, state: .projectOverride)]
        )
        XCTAssertEqual(try LabPackageManager.selectWrites(plan: plan, only: [], replace: [keithleyID]), [])
        XCTAssertThrowsError(try LabPackageManager.selectWrites(plan: plan, only: [keithleyID], replace: [])) { error in
            guard case LabPackageError.upgradeRefused(let message) = error else {
                return XCTFail("expected upgradeRefused, got \(error)")
            }
            XCTAssertTrue(message.contains("project-local"), message)
        }
    }

    func testCase6ManifestAfterUpdateHasNewVersionAndSha256OnDisk() throws {
        let keithleyOld = bundledKeithleyRevision0()
        try writeInstalledFixture(
            globalConfigDir: tempDirectory.appendingPathComponent("global"),
            version: "0.0.9",
            entries: allBundledEntries(overriding: [keithleyID: (recorded: keithleyOld, onDisk: keithleyOld)])
        )
        let global = tempDirectory.appendingPathComponent("global")

        let outcome = try LabPackageManager.upgradeUSTHLabPackage(globalConfigDir: global)

        XCTAssertEqual(outcome.written, [keithleyID])
        let installed = try LabPackageManager.readInstalledUSTHManifest(globalConfigDir: global)
        XCTAssertEqual(installed.version, LabPackageManager.usthPackageVersion)
        let keithleyBundled = LabPackageManager.bundledText(BuiltinAssets.keithley2400YAML)
        XCTAssertEqual(
            installed.entries.first { $0.id == keithleyID }?.sha256,
            sha256Hex(Data(keithleyBundled.utf8))
        )
    }

    func testCase3UpgradeOnDiskWritesOnlyTheNewerProfile() throws {
        let global = tempDirectory.appendingPathComponent("global")
        let autolab = LabPackageManager.bundledText(BuiltinAssets.autolabUsthYAML)
        try writeInstalledFixture(
            globalConfigDir: global,
            version: "0.1.0",
            entries: allBundledEntries(overriding: [keithleyID: (recorded: bundledKeithleyRevision0(), onDisk: bundledKeithleyRevision0())])
        )
        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: global).appendingPathComponent("usth")

        let outcome = try LabPackageManager.upgradeUSTHLabPackage(globalConfigDir: global)

        XCTAssertEqual(outcome.plan.profiles.map(\.id), [keithleyID])
        XCTAssertEqual(outcome.written, [keithleyID])
        XCTAssertEqual(outcome.kept, [])
        XCTAssertEqual(
            try String(contentsOf: profilesDir.appendingPathComponent("keithley-2400.yaml"), encoding: .utf8),
            LabPackageManager.bundledText(BuiltinAssets.keithley2400YAML)
        )
        XCTAssertEqual(
            try String(contentsOf: profilesDir.appendingPathComponent("autolab-usth.yaml"), encoding: .utf8),
            autolab
        )
    }

    func testCase4KeepBothKeepsEditedFileAndStagesBundledCopy() throws {
        let global = tempDirectory.appendingPathComponent("global")
        let edited = bundledKeithleyRevision0() + "# my own edit\n"
        try writeInstalledFixture(
            globalConfigDir: global,
            version: "0.1.0",
            entries: allBundledEntries(overriding: [keithleyID: (recorded: bundledKeithleyRevision0(), onDisk: edited)])
        )
        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: global).appendingPathComponent("usth")

        let outcome = try LabPackageManager.upgradeUSTHLabPackage(globalConfigDir: global)

        XCTAssertEqual(outcome.written, [])
        XCTAssertEqual(outcome.kept, [keithleyID])
        XCTAssertEqual(
            try String(contentsOf: profilesDir.appendingPathComponent("keithley-2400.yaml"), encoding: .utf8),
            edited
        )
        let staged = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: global)
            .appendingPathComponent("usth-lab/staged/keithley-2400.yaml")
        XCTAssertEqual(
            try String(contentsOf: staged, encoding: .utf8),
            LabPackageManager.bundledText(BuiltinAssets.keithley2400YAML)
        )
    }

    func testCase4ReplaceWithConsentWritesBundledFile() throws {
        let global = tempDirectory.appendingPathComponent("global")
        let edited = bundledKeithleyRevision0() + "# my own edit\n"
        try writeInstalledFixture(
            globalConfigDir: global,
            version: "0.1.0",
            entries: allBundledEntries(overriding: [keithleyID: (recorded: bundledKeithleyRevision0(), onDisk: edited)])
        )
        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: global).appendingPathComponent("usth")

        let outcome = try LabPackageManager.upgradeUSTHLabPackage(globalConfigDir: global, replace: [keithleyID])

        XCTAssertEqual(outcome.written, [keithleyID])
        XCTAssertEqual(
            try String(contentsOf: profilesDir.appendingPathComponent("keithley-2400.yaml"), encoding: .utf8),
            LabPackageManager.bundledText(BuiltinAssets.keithley2400YAML)
        )
    }

    private func bundledKeithleyRevision0() -> String {
        LabPackageManager.bundledText(BuiltinAssets.keithley2400YAML)
            .replacingOccurrences(of: "revision: 1", with: "revision: 0")
    }

    private func allBundledEntries(
        overriding: [String: (recorded: String, onDisk: String)]
    ) -> [(id: String, recorded: String, onDisk: String)] {
        BuiltinAssets.builtinProfiles.map { item in
            let bundled = LabPackageManager.bundledText(item.yaml)
            let override = overriding[item.id]
            return (id: item.id, recorded: override?.recorded ?? bundled, onDisk: override?.onDisk ?? bundled)
        }
    }

    private func writeInstalledFixture(
        globalConfigDir: URL,
        version: String,
        entries: [(id: String, recorded: String, onDisk: String)]
    ) throws {
        let fm = FileManager.default
        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: globalConfigDir).appendingPathComponent("usth", isDirectory: true)
        let pkgDir = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: globalConfigDir).appendingPathComponent("usth-lab", isDirectory: true)
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        var manifestEntries: [ManifestProfileEntry] = []
        for entry in entries {
            let filename = String(entry.id.split(separator: "/").last ?? "") + ".yaml"
            try entry.onDisk.write(to: profilesDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
            manifestEntries.append(ManifestProfileEntry(id: entry.id, filename: filename, sha256: sha256Hex(Data(entry.recorded.utf8))))
        }
        let manifest = LabPackageManager.renderUSTHManifest(version: version, entries: manifestEntries)
        try manifest.write(to: pkgDir.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)
    }
}
