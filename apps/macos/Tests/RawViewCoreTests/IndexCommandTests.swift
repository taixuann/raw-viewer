import Foundation
import XCTest
@testable import RawViewCore

final class IndexCommandTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for url in tempDirs {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func createTempDir(prefix: String = "index-cli-test") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    func testParseValidArguments() throws {
        let args = ["--project", "/tmp/proj", "--data-root", "data/raw", "--save-settings", "--rebuild", "--json"]
        let opts = try IndexCommand.parse(args)
        XCTAssertEqual(opts.projectURL.path, URL(fileURLWithPath: "/tmp/proj").standardizedFileURL.path)
        XCTAssertEqual(opts.dataRoot, "data/raw")
        XCTAssertTrue(opts.saveSettings)
        XCTAssertTrue(opts.rebuild)
        XCTAssertTrue(opts.jsonOutput)
    }

    func testParseShortFlags() throws {
        let args = ["-p", "/tmp/proj", "-d", "custom/root"]
        let opts = try IndexCommand.parse(args)
        XCTAssertEqual(opts.dataRoot, "custom/root")
        XCTAssertFalse(opts.saveSettings)
        XCTAssertFalse(opts.rebuild)
        XCTAssertFalse(opts.jsonOutput)
    }

    func testMissingProjectThrows() {
        XCTAssertThrowsError(try IndexCommand.parse([])) { error in
            XCTAssertEqual(error as? IndexCommandError, .missingProjectArgument)
        }
    }

    func testUnknownFlagThrows() {
        XCTAssertThrowsError(try IndexCommand.parse(["--project", "/tmp/proj", "--bogus"])) { error in
            XCTAssertEqual(error as? IndexCommandError, .unknownFlag("--bogus"))
        }
    }

    func testMissingFlagValueThrows() {
        XCTAssertThrowsError(try IndexCommand.parse(["--project"])) { error in
            XCTAssertEqual(error as? IndexCommandError, .missingFlagValue("--project"))
        }
    }

    func testSaveSettingsWithoutDataRootThrows() {
        XCTAssertThrowsError(try IndexCommand.parse(["--project", "/tmp/proj", "--save-settings"])) { error in
            XCTAssertEqual(error as? IndexCommandError, .saveSettingsRequiresDataRoot)
        }
    }

    func testAbsoluteDataRootThrows() {
        XCTAssertThrowsError(try IndexCommand.parse(["--project", "/tmp/proj", "--data-root", "/data/raw"])) { error in
            XCTAssertEqual(error as? IndexCommandError, .dataRootMustBeRelative("/data/raw"))
        }
    }

    func testParentDataRootThrows() {
        XCTAssertThrowsError(try IndexCommand.parse(["--project", "/tmp/proj", "--data-root", "../data"])) { error in
            XCTAssertEqual(error as? IndexCommandError, .outsideProjectBoundary("../data"))
        }
    }

    func testNoSavedConfigAndNoExplicitRootFailsWithConfigurationError() async throws {
        let proj = createTempDir(prefix: "cli-no-config")
        let raw = proj.appendingPathComponent("data/raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)

        let opts = IndexCommandOptions(projectURL: proj)
        let (_, exitCode) = await IndexCommand.run(options: opts)
        XCTAssertEqual(exitCode, .configurationOrArguments)
    }

    func testExplicitDataRootOverridesSavedSettingsWithoutOverwritingUnlessRequested() async throws {
        let proj = createTempDir(prefix: "cli-override")
        let defaultRaw = proj.appendingPathComponent("data/raw")
        let customRaw = proj.appendingPathComponent("data/custom")
        try FileManager.default.createDirectory(at: defaultRaw, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customRaw, withIntermediateDirectories: true)

        // Save original settings pointing to data/raw
        let initialSettings = ProjectSettings(dataRoot: "data/raw", defaultView: "tree")
        try ProjectSettingsStore.save(initialSettings, projectRoot: proj)

        // Run with explicit --data-root data/custom without --save-settings
        let opts = IndexCommandOptions(projectURL: proj, dataRoot: "data/custom", saveSettings: false)
        let resolved = try IndexCommand.resolveProject(options: opts)
        XCTAssertEqual(resolved.dataRootRelativePath, "data/custom")

        // Saved settings on disk still say data/raw
        let loaded = try ProjectSettingsStore.load(projectRoot: proj)
        XCTAssertEqual(loaded?.dataRoot, "data/raw")

        // Now run with --save-settings
        let saveOpts = IndexCommandOptions(projectURL: proj, dataRoot: "data/custom", saveSettings: true)
        _ = try IndexCommand.resolveProject(options: saveOpts)

        // Disk now updated
        let reloaded = try ProjectSettingsStore.load(projectRoot: proj)
        XCTAssertEqual(reloaded?.dataRoot, "data/custom")
    }

    func testExplicitDataRootCorrectsInvalidSavedConfiguration() async throws {
        let proj = createTempDir(prefix: "cli-corrupt")
        let customRaw = proj.appendingPathComponent("data/custom")
        try FileManager.default.createDirectory(at: customRaw, withIntermediateDirectories: true)

        // Create corrupt settings file
        let settingDir = proj.appendingPathComponent(".rawviewer/setting")
        try FileManager.default.createDirectory(at: settingDir, withIntermediateDirectories: true)
        let settingFile = settingDir.appendingPathComponent("setting.yaml")
        try "corrupt: true: invalid: yaml".write(to: settingFile, atomically: true, encoding: .utf8)

        // Without explicit root, fails
        let optsNoRoot = IndexCommandOptions(projectURL: proj)
        let (_, code) = await IndexCommand.run(options: optsNoRoot)
        XCTAssertEqual(code, .configurationOrArguments)

        // With explicit root, succeeds in resolving
        let optsWithRoot = IndexCommandOptions(projectURL: proj, dataRoot: "data/custom")
        let resolved = try IndexCommand.resolveProject(options: optsWithRoot)
        XCTAssertEqual(resolved.dataRootRelativePath, "data/custom")
    }
}
