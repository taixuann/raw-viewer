import Foundation
import Testing
@testable import RawViewCore

struct BuiltinAssetsTests {
    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static var standardKeithleySource: String {
        let path = repoRoot.appendingPathComponent(
            "fixtures/workspaces/usth-lab/data/raw/2026-10-07/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt"
        )
        return try! String(contentsOf: path, encoding: .utf8)
    }

    private func tempProject() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawview-swift-builtin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
        return dir
    }

    @Test func freshProjectLoadsBuiltinsAndResolvesFiles() async throws {
        let tmp = try tempProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = try ProjectContext.open(tmp)
        let v3ctx = V3Reader.context(project: project)
        let catalog = try #require(v3ctx.catalog)
        #expect(catalog.grammars.count == 1)
        #expect(catalog.grammars[0].id == "standard-scientific")

        let profileCat = ProfileCatalog.load(project: project)
        #expect(profileCat.issues.isEmpty)
        #expect(profileCat.profiles.contains { $0.profileID == "usth/keithley-2400" })
        #expect(profileCat.profiles.contains { $0.profileID == "usth/autolab-usth" })
        #expect(profileCat.profiles.contains { $0.profileID == "usth/horiba-labram" })
        #expect(profileCat.profiles.contains { $0.profileID == "usth/iop-hanoi" })

        // 1. Standard-named Keithley file
        let standardURL = tmp.appendingPathComponent(
            "data/raw/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt"
        )
        try FileManager.default.createDirectory(at: standardURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.standardKeithleySource.write(to: standardURL, atomically: true, encoding: .utf8)

        let measurement = try await InstrumentReader.load(standardURL, project: project)
        #expect(measurement.instrument.id == "keithley-2400")
        #expect(measurement.applicationMode == "dual-sweep")
        #expect(measurement.channel(named: "voltage")?.values.count == 121)

        // 2. Non-standard named Keithley file selects by content
        let nonStandardURL = tmp.appendingPathComponent("data/raw/custom_sweep.txt")
        try Self.standardKeithleySource.write(to: nonStandardURL, atomically: true, encoding: .utf8)
        let nonStandardMeasurement = try await InstrumentReader.load(nonStandardURL, project: project)
        #expect(nonStandardMeasurement.instrument.id == "keithley-2400")
        #expect(nonStandardMeasurement.channel(named: "voltage")?.values.count == 121)
    }

    @Test func disablingProfileInConfigStopsItMatching() async throws {
        let tmp = try tempProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configURL = tmp.appendingPathComponent(".raw-viewer/config.yaml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "schema_version: 1\nprofiles:\n  disabled:\n    - usth/keithley-2400\n"
            .write(to: configURL, atomically: true, encoding: .utf8)

        let project = try ProjectContext.open(tmp)
        let profileCat = ProfileCatalog.load(project: project)
        #expect(!profileCat.profiles.contains { $0.profileID == "usth/keithley-2400" })
        #expect(profileCat.profiles.contains { $0.profileID == "usth/autolab-usth" })

        let nonStandardURL = tmp.appendingPathComponent("data/raw/custom_sweep.txt")
        try FileManager.default.createDirectory(at: nonStandardURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.standardKeithleySource.write(to: nonStandardURL, atomically: true, encoding: .utf8)

        let fallback = try await InstrumentReader.load(nonStandardURL, project: project)
        #expect(fallback.instrument.id == "generic-table")
    }

    @Test func overridingOneBuiltinKeepsTheRest() throws {
        let tmp = try tempProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let customProfile = """
schema_version: 4
id: usth/keithley-2400
revision: 2
instrument:
  id: keithley-2400-custom
  name: Custom Keithley 2400
variants:
  dual-sweep:
    when:
      content_contains_any:
        - LabVIEW Measurement
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\\t"
    rows:
      names_prefix: X_Value
      data_prefix: ""
    metadata: []
    columns:
      voltage:
        role: channel
        header: Untitled
        quantity: voltage
        unit: V
      current:
        role: channel
        header: Untitled 1
        quantity: current
        unit: A
    plot:
      x: voltage
      y: [current]
"""
        let customURL = tmp.appendingPathComponent(".raw-viewer/profiles/my-keithley.yaml")
        try FileManager.default.createDirectory(at: customURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try customProfile.write(to: customURL, atomically: true, encoding: .utf8)

        let project = try ProjectContext.open(tmp)
        let profileCat = ProfileCatalog.load(project: project)
        #expect(profileCat.issues.isEmpty)
        let keithley = try #require(profileCat.profiles.first { $0.profileID == "usth/keithley-2400" })
        #expect(keithley.instrumentID == "keithley-2400-custom")
        #expect(profileCat.profiles.contains { $0.profileID == "usth/autolab-usth" })
        #expect(profileCat.profiles.contains { $0.profileID == "usth/horiba-labram" })
        #expect(profileCat.profiles.contains { $0.profileID == "usth/iop-hanoi" })
    }

    @Test func olderRevisionEmitsWarning() throws {
        let tmp = try tempProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let oldProfile = """
schema_version: 4
id: usth/keithley-2400
revision: 0
instrument:
  id: keithley-2400-old
  name: Old Keithley 2400
variants:
  dual-sweep:
    when:
      content_contains_any:
        - LabVIEW Measurement
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\\t"
    rows:
      names_prefix: X_Value
      data_prefix: ""
    metadata: []
    columns:
      voltage:
        role: channel
        header: Untitled
        quantity: voltage
        unit: V
      current:
        role: channel
        header: Untitled 1
        quantity: current
        unit: A
    plot:
      x: voltage
      y: [current]
"""
        let oldURL = tmp.appendingPathComponent(".raw-viewer/profiles/old-keithley.yaml")
        try FileManager.default.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try oldProfile.write(to: oldURL, atomically: true, encoding: .utf8)

        let project = try ProjectContext.open(tmp)
        let profileCat = ProfileCatalog.load(project: project)
        #expect(profileCat.issues.contains {
            $0.contains("usth/keithley-2400") && $0.contains("older than built-in revision")
        })
    }

    @Test func duplicateEnabledAndDisabledThrows() throws {
        let yaml = "schema_version: 1\nprofiles:\n  enabled:\n    - usth/keithley-2400\n  disabled:\n    - usth/keithley-2400\n"
        #expect(throws: ProjectSettingsError.self) {
            try ProjectSettingsStore.parseConfig(text: yaml)
        }
    }

    @Test func unknownKeysInProfilesThrows() throws {
        let yaml = "schema_version: 1\nprofiles:\n  unknown_field: true\n"
        #expect(throws: ProjectSettingsError.self) {
            try ProjectSettingsStore.parseConfig(text: yaml)
        }
    }
}
