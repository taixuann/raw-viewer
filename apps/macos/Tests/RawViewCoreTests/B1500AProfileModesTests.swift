import Foundation
import Testing
@testable import RawViewCore

/// RawView-owned B1500A regression at the confirmed seam:
/// selected folder -> YAML validation -> complete normalized arrays.
/// Synthetic fixtures only; no real data.
struct B1500AProfileModesTests {
    @Test func listSweepPreservesRawValuesAndOrderWithoutTransform() async throws {
        let profile = try shippedProfile()
        let csv = """
        SetupTitle, I/V List Sweep 1V
        DataName, V1, I2
        DataValue, 0.2, 3E-9
        DataValue, 0.0, 1E-9
        DataValue, 0.1, 2E-9
        """
        let root = try makeModeProject(
            profile: profile,
            sources: ["data/raw/keysight-b1500a.list-sweep_one.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        let inspection = try #require(report.results.first?.inspection)
        #expect(inspection.applicationMode == "list-sweep")
        #expect(inspection.instrumentID == "keysight-b1500a")

        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.applicationMode == "list-sweep")
        // Non-monotonic acquisition order preserved exactly; raw currents kept
        // (a legacy current * -1 transform would flip these signs).
        #expect(measurement.channel(named: "voltage")?.values == [0.2, 0.0, 0.1])
        #expect(measurement.channel(named: "current")?.values == [3e-9, 1e-9, 2e-9])
        #expect(measurement.channel(named: "voltage")?.quantity == "voltage")
        #expect(measurement.channel(named: "voltage")?.unit == "V")
        #expect(measurement.channel(named: "current")?.quantity == "current")
        #expect(measurement.channel(named: "current")?.unit == "A")
        #expect(measurement.view.x == "voltage")
        #expect(measurement.view.y == ["current"])
        #expect(measurement.view.preserveOrder)
        #expect(measurement.channel(named: "current")?.gapCount == 0)
    }

    @Test func listSweepWithoutManifestIsSingleDisplayableButOverlayBlocked() async throws {
        let profile = try shippedProfile()
        let csvA = """
        SetupTitle, I/V List Sweep 0V
        DataName, V1, I2
        DataValue, 0.2, 3E-9
        DataValue, 0.0, 1E-9
        """
        let csvB = """
        SetupTitle, I/V List Sweep 2V
        DataName, V1, I2
        DataValue, 0.2, 4E-9
        DataValue, 0.0, 5E-9
        """
        let root = try makeModeProject(
            profile: profile,
            sources: [
                "data/raw/keysight-b1500a.list-sweep_a.csv": Data(csvA.utf8),
                "data/raw/keysight-b1500a.list-sweep_b.csv": Data(csvB.utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources().sorted(by: { $0.relativePath < $1.relativePath })
        var measurements: [NormalizedMeasurement] = []
        for source in sources {
            measurements.append(try await InstrumentReader.load(source.url, project: project))
        }
        #expect(measurements.count == 2)
        // Singly displayable: each load keeps full arrays in order.
        #expect(measurements[0].channel(named: "current")?.values == [3e-9, 1e-9])
        // No manifest membership: overlay stays blocked, never inferred.
        let result = OverlayEvaluator.evaluate(measurements: measurements, manifests: [])
        guard case .blocked(let reason) = result else {
            Issue.record("list-sweep pair without manifest was accepted for overlay")
            return
        }
        #expect(reason.contains("manifest"))
    }

    @Test func dualSweepSelectsByHeaderSignature() async throws {
        let profile = try shippedProfile()
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        DataName, V1, I2
        DataValue, 0.0, 1E-12
        DataValue, 0.1, 2E-12
        DataValue, 0.2, 3E-12
        DataValue, 0.1, 4E-12
        DataValue, 0.0, 5E-12
        """
        let root = try makeModeProject(
            profile: profile,
            sources: ["data/raw/keysight-b1500a.dual-sweep_one.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        #expect(report.results.first?.inspection?.applicationMode == "dual-sweep")
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.applicationMode == "dual-sweep")
        #expect(measurement.channel(named: "voltage")?.values == [0.0, 0.1, 0.2, 0.1, 0.0])
        #expect(measurement.view.preserveOrder)
    }

    @Test func wgfmuRetainsEveryRequiredPlotPointAndDeclaredUnits() async throws {
        let profile = try shippedProfile()
        let csv = """
        SetupTitle, STP decay
        DataName, Time, MeasResult1_value, MeasResult2_value
        DataValue, 0, 0, 1E-12
        DataValue, 1E-9, 0.5, 2E-12
        DataValue, 2E-9, 1.0, 3E-12
        """
        let root = try makeModeProject(
            profile: profile,
            sources: ["data/raw/keysight-b1500a.wgfmu_std.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        #expect(report.results.first?.inspection?.applicationMode == "wgfmu")

        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.applicationMode == "wgfmu")
        #expect(measurement.channel(named: "time")?.values == [0, 1e-9, 2e-9])
        #expect(measurement.channel(named: "signal_1")?.values == [0, 0.5, 1.0])
        #expect(measurement.channel(named: "signal_2")?.values == [1e-12, 2e-12, 3e-12])
        #expect(measurement.channel(named: "time")?.quantity == "time")
        #expect(measurement.channel(named: "time")?.unit == "s")
        #expect(measurement.channel(named: "signal_1")?.quantity == "unknown")
        #expect(measurement.channel(named: "signal_1")?.unit == "unspecified")
        #expect(measurement.channel(named: "signal_1")?.label == "Channel 1")
        #expect(measurement.channel(named: "signal_2")?.quantity == "unknown")
        #expect(measurement.channel(named: "signal_2")?.unit == "unspecified")
        #expect(measurement.channel(named: "signal_2")?.label == "Channel 2")
        #expect(measurement.view.x == "time")
        #expect(measurement.view.y == ["signal_1"])
        #expect(measurement.view.preserveOrder)
        // Optional per-point times absent: skipped without invented values.
        #expect(measurement.channels.count == 3)
    }

    @Test func wgfmuPpfTimeFirstRowLoadsCompleteOrderedArrays() async throws {
        let profile = try shippedProfile()
        let csv = """
        time_s,current_a
        0,1e-12
        2e-9,3e-12
        1e-9,2e-12
        """
        let root = try makeModeProject(
            profile: profile,
            sources: ["data/raw/keysight-b1500a.wgfmu_ppf-time.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        #expect(report.results.first?.inspection?.applicationMode == "wgfmu-ppf-time")
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.channel(named: "time")?.values == [0, 2e-9, 1e-9])
        #expect(measurement.channel(named: "current")?.values == [1e-12, 3e-12, 2e-12])
        #expect(measurement.channel(named: "time")?.quantity == "time")
        #expect(measurement.channel(named: "time")?.unit == "s")
        #expect(measurement.channel(named: "current")?.quantity == "current")
        #expect(measurement.channel(named: "current")?.unit == "A")
        #expect(measurement.view.x == "time")
        #expect(measurement.view.y == ["current"])
        #expect(measurement.view.preserveOrder)
    }

    @Test func wgfmuPpfIndexFirstRowPlotsPulseIndex() async throws {
        let profile = try shippedProfile()
        let csv = """
        index-pulse,current_a
        0,1e-12
        1,2e-12
        """
        let root = try makeModeProject(
            profile: profile,
            sources: ["data/raw/keysight-b1500a.wgfmu_ppf-index.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.results.first?.inspection?.applicationMode == "wgfmu-ppf-index")
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.channel(named: "pulse_index")?.values == [0, 1])
        #expect(measurement.channel(named: "pulse_index")?.quantity == "pulse")
        #expect(measurement.channel(named: "pulse_index")?.unit == "pulse")
        #expect(measurement.view.x == "pulse_index")
        #expect(measurement.view.y == ["current"])
        #expect(measurement.view.preserveOrder)
    }

    @Test func wgfmuStpKeepsOptionalFitOnlyWhenPresent() async throws {
        let profile = try shippedProfile()
        let fit = "time_s,voltage_v,current_v,fit\n0,0.1,1e-9,0.5\n1e-9,0.2,2e-9,0.6\n"
        let fitCurrent = "time_s,voltage_v,current_v,fit_current\n0,0.1,1e-9,0.7\n"
        let root = try makeModeProject(
            profile: profile,
            sources: [
                "data/raw/keysight-b1500a.wgfmu_stp-fit.csv": Data(fit.utf8),
                "data/raw/keysight-b1500a.wgfmu_stp-fitc.csv": Data(fitCurrent.utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources().sorted(by: { $0.relativePath < $1.relativePath })
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        #expect(report.results.allSatisfy { $0.inspection?.applicationMode == "wgfmu-stp" })
        let withFit = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(withFit.channels.count == 4)
        #expect(withFit.channel(named: "fit")?.values == [0.5, 0.6])
        #expect(withFit.channel(named: "fit_current") == nil)
        #expect(withFit.channel(named: "voltage")?.quantity == "voltage")
        #expect(withFit.channel(named: "voltage")?.unit == "V")
        #expect(withFit.channel(named: "current")?.quantity == "unknown")
        #expect(withFit.channel(named: "current")?.unit == "unspecified")
        #expect(withFit.channel(named: "current")?.label == "current_v")
        #expect(withFit.view.x == "time")
        #expect(withFit.view.y == ["voltage"])
        let withFitCurrent = try await InstrumentReader.load(sources[1].url, project: project)
        #expect(withFitCurrent.channel(named: "fit_current")?.values == [0.7])
        #expect(withFitCurrent.channel(named: "fit") == nil)
    }

    @Test func wgfmuEnduranceKeepsOptionalChannelOnlyWhenPresent() async throws {
        let profile = try shippedProfile()
        let full = "SetupTitle, endurance\nDataName, raw_cycles, raw_ch2, raw_ch1\nDataValue, 0, 1e-12, 2e-12\nDataValue, 1, 3e-12, 4e-12\n"
        let minimal = "SetupTitle, endurance\nDataName, raw_cycles, raw_ch2\nDataValue, 0, 1e-12\n"
        let root = try makeModeProject(
            profile: profile,
            sources: [
                "data/raw/keysight-b1500a.wgfmu_end-full.csv": Data(full.utf8),
                "data/raw/keysight-b1500a.wgfmu_end-min.csv": Data(minimal.utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources().sorted(by: { $0.relativePath < $1.relativePath })
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.results.allSatisfy { $0.inspection?.applicationMode == "wgfmu-endurance" })
        let withOptional = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(withOptional.channels.count == 3)
        #expect(withOptional.channel(named: "cycles")?.values == [0, 1])
        #expect(withOptional.channel(named: "cycles")?.quantity == "cycles")
        #expect(withOptional.channel(named: "cycles")?.unit == "cycles")
        #expect(withOptional.channel(named: "channel_1")?.values == [2e-12, 4e-12])
        #expect(withOptional.view.x == "cycles")
        #expect(withOptional.view.y == ["channel_2"])
        let withoutOptional = try await InstrumentReader.load(sources[1].url, project: project)
        #expect(withoutOptional.channels.count == 2)
        #expect(withoutOptional.channel(named: "channel_1") == nil)
    }

    @Test func firstRowHeaderKindIsV2OnlyAndRejectsRows() async throws {
        let v1Profile = """
        schema_version: 1
        instrument:
          id: probe
          name: Probe
        formats:
          - id: f
            kind: first-row-header
            extensions: [".csv"]
            delimiter: ","
            columns:
              a:
                header: "a"
                quantity: unknown
                unit: "unspecified"
              b:
                header: "b"
                quantity: unknown
                unit: "unspecified"
        modes:
          - id: m
            format: f
            detect: ["a"]
            extract:
              x: a
              y: [b]
        """
        let v1Root = try makeModeProject(profile: v1Profile, sources: ["data/raw/a.csv": Data("a,b\n0,1\n".utf8)])
        defer { try? FileManager.default.removeItem(at: v1Root) }
        let v1Project = try ProjectContext.open(v1Root)
        let v1Report = await InstrumentReader.inspectMany(try v1Project.discoverSources(), project: v1Project)
        #expect(v1Report.results.first?.inspection == nil)
        #expect(v1Report.results.first?.error?.contains("first-row-header") == true)
        let rowsProfile = v1Profile
            .replacingOccurrences(of: "schema_version: 1", with: "schema_version: 2")
            .replacingOccurrences(of: "delimiter: \",\"", with: "delimiter: \",\"\n    rows:\n      names_prefix: \"H\"")
        let rowsRoot = try makeModeProject(profile: rowsProfile, sources: ["data/raw/a.csv": Data("a,b\n0,1\n".utf8)])
        defer { try? FileManager.default.removeItem(at: rowsRoot) }
        let rowsProject = try ProjectContext.open(rowsRoot)
        let rowsReport = await InstrumentReader.inspectMany(try rowsProject.discoverSources(), project: rowsProject)
        #expect(rowsReport.results.first?.inspection == nil)
        #expect(rowsReport.results.first?.error?.contains("rows is not part of kind") == true)
    }

    @Test func firstRowCorruptCellBlocksWithLineDiagnostic() async throws {        let profile = try shippedProfile()
        let csv = "time_s,current_a\n0,1e-12\n1e-9,--\n"
        let root = try makeModeProject(
            profile: profile,
            sources: ["data/raw/keysight-b1500a.wgfmu_corrupt.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        // Header recognition still matches the ppf-time mode; the corrupt data
        // cell blocks the load naming file, line, column, and value.
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.results.first?.inspection?.applicationMode == "wgfmu-ppf-time")
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(sources[0].url, project: project)
        }
        do {
            _ = try await InstrumentReader.load(sources[0].url, project: project)
            Issue.record("corrupt first-row cell was loaded instead of blocked")
        } catch {
            #expect(error.localizedDescription.contains("line 3"))
            #expect(error.localizedDescription.contains("current"))
            #expect(error.localizedDescription.contains("--"))
        }
    }

    @Test func foreignBasenameWithMatchingHeaderStaysBlocked() async throws {
        let profile = try shippedProfile()
        let csv = "time_s,current_a\n0,1e-12\n1e-9,2e-12\n"
        let root = try makeModeProject(
            profile: profile,
            sources: ["data/raw/foreign.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        // The header matches ppf-time, but the basename lacks the Keysight
        // token, so the source stays blocked naming the missing token.
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("keysight-b1500a.wgfmu") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(sources[0].url, project: project)
        }
    }

    @Test func listSweepHeaderWithLegacyDualSweepSuffixResolvesToListSweep() async throws {
        let profile = try shippedProfile()
        let csv = """
        SetupTitle, I/V List Sweep 1V
        DataName, V1, I2
        DataValue, 0.2, 3E-9
        DataValue, 0.0, 1E-9
        """
        let root = try makeModeProject(
            profile: profile,
            sources: [
                "data/raw/keysight-b1500a.dual-sweep_legacy.csv": Data(csv.utf8),
                "data/raw/foreign-list.csv": Data(csv.utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources().sorted(by: { $0.relativePath < $1.relativePath })
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        // Legacy dual-sweep-suffixed basename with a list-sweep header: the
        // list-sweep signature wins on the B1500A instrument token.
        let legacy = report.results.first { $0.source.relativePath == "data/raw/keysight-b1500a.dual-sweep_legacy.csv" }
        #expect(legacy?.inspection?.applicationMode == "list-sweep")
        let measurement = try await InstrumentReader.load(sources[1].url, project: project)
        #expect(measurement.channel(named: "voltage")?.values == [0.2, 0.0])
        #expect(measurement.channel(named: "current")?.values == [3e-9, 1e-9])
        #expect(measurement.view.preserveOrder)
        // A foreign basename with the same header stays blocked.
        let foreign = report.results.first { $0.source.relativePath == "data/raw/foreign-list.csv" }
        #expect(foreign?.inspection == nil)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(sources[0].url, project: project)
        }
    }

    @Test func stpRequiresCommaDelimitedRequiredColumnSignature() async throws {
        let profile = try shippedProfile()
        let comma = "time_s,voltage_v,current_v,fit\n0,0.1,1e-9,0.5\n"
        let semicolon = "SetupTitle, synthetic semicolon table\ntime_s;voltage_v;current_v;fit\n0;0.1;1e-9;0.5\n"
        let root = try makeModeProject(
            profile: profile,
            sources: [
                "data/raw/keysight-b1500a.wgfmu_stp-comma.csv": Data(comma.utf8),
                "data/raw/keysight-b1500a.wgfmu_stp-semi.csv": Data(semicolon.utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources().sorted(by: { $0.relativePath < $1.relativePath })
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        // Comma layout keeps matching; the semicolon lookalike is unmatched
        // at inspection and blocked before load. No semicolon parsing is added.
        #expect(report.results.first { $0.source.relativePath == "data/raw/keysight-b1500a.wgfmu_stp-comma.csv" }?.inspection?.applicationMode == "wgfmu-stp")
        #expect(report.results.first { $0.source.relativePath == "data/raw/keysight-b1500a.wgfmu_stp-semi.csv" }?.inspection == nil)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(sources[1].url, project: project)
        }
    }

    @Test func dualSweepWithGenericSweepTextInMetadataResolvesUniquelyToDualSweep() async throws {
        let profile = try shippedProfile()
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        ApplicationTest, I/V Sweep, Public
        DataName, V1, I1
        DataValue, 0, 1E-12
        DataValue, 0.1, 2E-12
        """
        let root = try makeModeProject(
            profile: profile,
            sources: ["data/raw/keysight-b1500a.dual-sweep_meta.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        // Generic I/V Sweep text in unrelated metadata must not pull the
        // source into list-sweep: the dual signature wins uniquely.
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        #expect(report.results.first?.inspection?.applicationMode == "dual-sweep")
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.channel(named: "voltage")?.values == [0, 0.1])
        #expect(measurement.channel(named: "current")?.values == [1e-12, 2e-12])
        #expect(measurement.view.preserveOrder)
    }
}

private func shippedProfile() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot.appendingPathComponent("Examples/rawview/keysight-b1500a.yaml")
    return try String(contentsOf: url, encoding: .utf8)
}

private func makeModeProject(profile: String, sources: [String: Data]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-b1500a-\(UUID().uuidString)")
    for (relativePath, data) in sources {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    let profileURL = root.appendingPathComponent("data/instruments/keysight-b1500a.yaml")
    try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(profile.utf8).write(to: profileURL)
    return root
}
