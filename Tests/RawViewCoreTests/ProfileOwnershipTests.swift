import Foundation
import Testing
@testable import RawViewCore

/// Companion profile ownership: `data/instruments/rawview/` is authoritative
/// when it exists. These tests observe only the reader seam: selected project
/// folder -> YAML validation -> inspection/load results.
struct ProfileOwnershipTests {
    @Test func shippedViewerProfilesMatchDeclaredSyntheticHeaders() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let exampleRoot = packageRoot.appendingPathComponent("Examples/rawview", isDirectory: true)
        let profileNames = ["keysight-b1500a.yaml", "keithley-2400.yaml", "horiba-labram.yaml"]
        let profiles = try Dictionary(uniqueKeysWithValues: profileNames.map { name in
            (name, try String(contentsOf: exampleRoot.appendingPathComponent(name), encoding: .utf8))
        })
        let keithley = Fixtures.lvmSweep.replacingOccurrences(of: "LabVIEW Measurement", with: "Instrument Record")
        let horiba = Fixtures.ramanTsv.replacingOccurrences(of: "#Laser=\t532nm\n", with: "")
        let root = try makeOwnershipProject(
            parentProfiles: [:],
            companion: .files(profiles),
            sources: [
                "data/raw/keysight.csv": Data(Fixtures.dualSweepCSV.utf8),
                "data/raw/keithley.txt": Data(keithley.utf8),
                "data/raw/horiba-comments.txt": Data(horiba.utf8),
                "data/raw/horiba-semicolon.txt": Data(Fixtures.ramanSemicolon.utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)

        #expect(report.profileIssues.isEmpty)
        #expect(report.results.count == 4)
        #expect(report.results.allSatisfy { $0.inspection?.instrumentID != nil })
        #expect(report.results.first { $0.source.relativePath == "data/raw/keysight.csv" }?.inspection?.instrumentID == "keysight-b1500a")
        #expect(report.results.first { $0.source.relativePath == "data/raw/keithley.txt" }?.inspection?.instrumentID == "keithley-2400")
        #expect(report.results.first { $0.source.relativePath == "data/raw/horiba-comments.txt" }?.inspection?.instrumentID == "horiba-labram")
        #expect(report.results.first { $0.source.relativePath == "data/raw/horiba-semicolon.txt" }?.inspection?.instrumentID == "horiba-labram")
    }

    @Test func companionProfilesOverrideStudyOwnedParentProfiles() async throws {
        let root = try makeOwnershipProject(
            parentProfiles: ["parent.yaml": csvProfile(instrumentID: "parent-instrument")],
            companion: .files(["companion.yaml": csvProfile(instrumentID: "companion-instrument")]),
            sources: ["data/raw/dual.csv": Data(sourceCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.profileIssues.isEmpty)
        #expect(report.results.first?.inspection?.instrumentID == "companion-instrument")
        let measurement = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        #expect(measurement.provenance["profile_id"] == "companion-instrument")
        #expect(measurement.channel(named: "voltage")?.values == [0, 0.1])
    }

    @Test func missingCompanionDirectoryKeepsTopLevelProfiles() async throws {
        let root = try makeOwnershipProject(
            parentProfiles: ["parent.yaml": csvProfile(instrumentID: "parent-instrument")],
            companion: .absent,
            sources: ["data/raw/dual.csv": Data(sourceCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.profileIssues.isEmpty)
        #expect(report.results.first?.inspection?.instrumentID == "parent-instrument")
    }

    @Test func emptyCompanionDirectoryFailsClosedWithoutParentFallback() async throws {
        let root = try makeOwnershipProject(
            parentProfiles: ["parent.yaml": csvProfile(instrumentID: "parent-instrument")],
            companion: .empty,
            sources: ["data/raw/dual.csv": Data(sourceCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("No instrument profile supports") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(sources[0].url, project: project)
        }
    }

    @Test func invalidCompanionProfileBlocksWithoutParentFallback() async throws {
        // The companion directory is authoritative even when its only profile
        // is invalid: the parent profile must not rescue the source.
        let root = try makeOwnershipProject(
            parentProfiles: ["parent.yaml": csvProfile(instrumentID: "parent-instrument")],
            companion: .files(["broken.yaml": unversionedCsvProfile]),
            sources: ["data/raw/dual.csv": Data(sourceCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.profileIssues.contains { $0.contains("data/instruments/rawview/broken.yaml") && $0.contains("unversioned") })
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("broken.yaml") == true)
        #expect(report.results.first?.error?.contains("unversioned") == true)
    }

    @Test func unsearchableInstrumentsDirectoryFailsClosedWithoutParentFallback() async throws {
        // An instruments directory that is readable but not searchable gives
        // lstat(rawview) a permission error: absence of the companion entry is
        // not proven, so the catalog fails closed instead of falling back to
        // the parent profile.
        let root = try makeOwnershipProject(
            parentProfiles: ["parent.yaml": csvProfile(instrumentID: "parent-instrument")],
            companion: .absent,
            sources: ["data/raw/dual.csv": Data(sourceCSV.utf8)]
        )
        let instruments = root.appendingPathComponent("data/instruments")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: instruments.path)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: instruments.path)

        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.contains { $0.contains("data/instruments/rawview") && $0.contains("could not be examined") })
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("No instrument profile supports") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(sources[0].url, project: project)
        }
    }

    @Test func nonDirectoryCompanionEntryFailsClosedWithoutParentFallback() async throws {
        let root = try makeOwnershipProject(
            parentProfiles: ["parent.yaml": csvProfile(instrumentID: "parent-instrument")],
            companion: .regularFile,
            sources: ["data/raw/dual.csv": Data(sourceCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.profileIssues.contains { $0.contains("data/instruments/rawview") })
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("No instrument profile supports") == true)
    }

    @Test func companionDirectorySymlinkEscapingDataInstrumentsFailsClosed() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-ownership-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(csvProfile(instrumentID: "outside-instrument").utf8)
            .write(to: outside.appendingPathComponent("outside.yaml"))
        let root = try makeOwnershipProject(
            parentProfiles: ["parent.yaml": csvProfile(instrumentID: "parent-instrument")],
            companion: .absent,
            sources: ["data/raw/dual.csv": Data(sourceCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("data/instruments/rawview"),
            withDestinationURL: outside
        )
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.profileIssues.contains { $0.contains("data/instruments/rawview") && $0.contains("resolves outside") })
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("No instrument profile supports") == true)
    }

    @Test func companionProfileSymlinkEscapingIsSkippedWithoutParentFallback() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-ownership-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(csvProfile(instrumentID: "outside-instrument").utf8).write(to: outside)
        let root = try makeOwnershipProject(
            parentProfiles: ["parent.yaml": csvProfile(instrumentID: "parent-instrument")],
            companion: .empty,
            sources: ["data/raw/dual.csv": Data(sourceCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("data/instruments/rawview/escaped.yaml"),
            withDestinationURL: outside
        )
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.profileIssues.contains { $0.contains("data/instruments/rawview/escaped.yaml") && $0.contains("resolves outside") })
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("No instrument profile supports") == true)
    }
}

private enum CompanionLayout {
    case absent
    case empty
    case files([String: String])
    case regularFile
}

private func makeOwnershipProject(
    parentProfiles: [String: String],
    companion: CompanionLayout,
    sources: [String: Data]
) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-ownership-\(UUID().uuidString)")
    for (relativePath, data) in sources {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    let instruments = root.appendingPathComponent("data/instruments")
    try FileManager.default.createDirectory(at: instruments, withIntermediateDirectories: true)
    for (name, contents) in parentProfiles {
        try Data(contents.utf8).write(to: instruments.appendingPathComponent(name))
    }
    switch companion {
    case .absent:
        break
    case .empty:
        try FileManager.default.createDirectory(at: instruments.appendingPathComponent("rawview"), withIntermediateDirectories: true)
    case .files(let profiles):
        let companionRoot = instruments.appendingPathComponent("rawview")
        try FileManager.default.createDirectory(at: companionRoot, withIntermediateDirectories: true)
        for (name, contents) in profiles {
            try Data(contents.utf8).write(to: companionRoot.appendingPathComponent(name))
        }
    case .regularFile:
        try Data("not a directory".utf8).write(to: instruments.appendingPathComponent("rawview"))
    }
    return root
}

private func csvProfile(instrumentID: String) -> String {
    """
    schema_version: 1
    instrument:
      id: \(instrumentID)
      name: \(instrumentID)
    formats:
      - id: csv
        kind: tabular
        extensions: [".csv"]
        delimiter: ","
        rows:
          names_prefix: "DataName"
          data_prefix: "DataValue"
        columns:
          voltage:
            header: "V1"
            quantity: voltage
            unit: "V"
          current:
            header: "I1"
            quantity: current
            unit: "A"
    modes:
      - id: dual-sweep
        format: csv
        detect: ["2-terminal dual Vsweep"]
        extract:
          x: voltage
          y: [current]
    """
}

private let unversionedCsvProfile = """
instrument:
  id: unversioned-instrument
  name: Unversioned Instrument
formats:
  - id: csv
    extensions: [".csv"]
    delimiter: ","
    rows:
      names_prefix: "DataName"
      data_prefix: "DataValue"
    columns:
      voltage:
        header: "V1"
        unit: "V"
      current:
        header: "I1"
        unit: "A"
modes:
  - id: dual-sweep
    format: csv
    detect: ["2-terminal dual Vsweep"]
    extract:
      x: voltage
      y: [current]
"""

private let sourceCSV = """
SetupTitle, 2-terminal dual Vsweep
DataName, V1, I1
DataValue, 0, 1E-12
DataValue, 0.1, 2E-12
"""
