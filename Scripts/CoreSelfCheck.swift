import CryptoKit
import Foundation

@main
enum CoreSelfCheck {
    static func main() async throws {
        let json = #"{"contract_version":1,"source":{"path":"data/raw/selected.csv","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"instrument":{"id":"keysight-b1500a","name":"Keysight B1500A"},"application_mode":"list-sweep","view":{"kind":"xy","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","quantity":"voltage","values":[0.2,0.0,0.1]},{"name":"current","label":"Current","unit":"A","values":[3.0,1.0,2.0]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#
        let value = try NormalizedMeasurement.decode(Data(json.utf8))
        precondition(value.view.preserveOrder)
        precondition(value.channel(named: "voltage")?.values == [0.2, 0.0, 0.1])
        precondition(value.channel(named: "voltage")?.quantity == "voltage")
        precondition(value.channel(named: "current")?.values == [3, 1, 2])
        precondition(AxisTransform.values([-1, 2], absolute: false, scale: .logarithmic) == .failure(.invalidLogDomain))
        precondition(AxisTransform.values([-1, 2], absolute: true, scale: .logarithmic) == .success([0, log10(2)]))
        do {
            _ = try NormalizedMeasurement.decode(Data(#"{"contract_version":2}"#.utf8))
            fatalError("unsupported version was accepted")
        } catch ContractError.unsupportedVersion(2) {
        }

        let inspections = [
            SourceInspection(source: "data/raw/a.csv", size: nil, instrumentID: "b1500", instrumentName: "B1500A",
                             applicationMode: "sweep", timestamp: "2026-09-30T10:00:00Z", deviceID: "D1",
                             category: "study-a", supportStatus: "supported", validationState: "valid",
                             readerVersion: "1", profileID: "iv", profileHash: "abc", error: nil),
            SourceInspection(source: "data/raw/b.csv", size: nil, instrumentID: "b1500", instrumentName: nil,
                             applicationMode: "pulse", timestamp: nil, deviceID: nil, category: nil,
                             supportStatus: nil, validationState: nil, readerVersion: nil, profileID: nil,
                             profileHash: nil, error: "unsupported")
        ]
        let grouping = SourceGrouping(inspections: inspections)
        precondition(grouping.sampleDevice.map(\.label) == ["D1"])
        precondition(grouping.category.map(\.label) == ["study-a"])
        precondition(grouping.measurementMode.map(\.label) == ["pulse", "sweep"])
        precondition(grouping.dateBatch.map(\.label) == ["2026-09-30"])
        precondition(SourceGrouping(inspections: [inspections[0]]).status.map(\.label) == ["Support: supported", "Validation: valid"])
        precondition(SourceGrouping.date(from: "2026-09-30T10:00:00Z") == "2026-09-30")
        precondition(SourceGrouping.date(from: "2026-+9-30T10:00:00Z") == nil)
        let filter = SourceFilter()
        precondition(filter.isEmpty)
        var g = SourceFilter(); g.toggle(facet: "instrument", value: "Fixture"); g.toggle(facet: "category", value: "Missing")
        precondition(!g.matches(["instrument": ["Fixture"], "category": ["S1"]]))
        g.clear()
        precondition(g.isEmpty && g.matches([:]))
        try await readerBoundarySelfCheck()
        print("RawView core self-check passed")
    }

    static func readerBoundarySelfCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-self-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("PROJECT_CODE_EXECUTED")
        let script = "from pathlib import Path\nPath(\"\(marker.path)\").write_text(\"ran\")\n"
        let outside = root.appendingPathComponent("outside.csv")

        func write(_ relativePath: String, _ contents: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        try write("data/raw/dual.csv", dualSweepCSV)
        try write("data/raw/no-header.csv", "SetupTitle, 2-terminal dual Vsweep\nMetaData, x, y\n")
        try write("data/raw/b.dat", "FIXTURE.DAT\nDATNAME, X, Y\nDATROW, 1, 2\n")
        try write("data/instruments/keysight-b1500a.yaml", keysightProfile)
        try write("data/instruments/unversioned-dat.yaml", unversionedDATProfile)
        try write("data/instruments/reader.py", script)
        try Data("outside marker".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/raw/escape.csv"), withDestinationURL: outside)

        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        precondition(sources.map(\.relativePath) == ["data/raw/b.dat", "data/raw/dual.csv", "data/raw/no-header.csv"])
        let report = await InstrumentReader.inspectMany(sources, project: project)
        precondition(report.results.count == 3)
        precondition(report.results.first { $0.id == "data/raw/dual.csv" }?.inspection?.instrumentID == "keysight-b1500a")
        precondition(report.results.first { $0.id == "data/raw/b.dat" }?.error?.contains("unversioned") == true)
        precondition(report.results.first { $0.id == "data/raw/no-header.csv" }?.inspection?.supportStatus == "supported")

        let dualURL = sources.first { $0.relativePath == "data/raw/dual.csv" }?.url
        guard let dualURL else { fatalError("dual fixture missing") }
        let measurement = try await InstrumentReader.load(dualURL, project: project)
        precondition(measurement.channel(named: "voltage")?.values == [0, 0.1, 0.2, 0.1, 0])
        precondition(measurement.channel(named: "current")?.values == [1e-12, 2e-12, 3e-12, 4e-12, 5e-12])
        precondition(measurement.channel(named: "voltage")?.quantity == "voltage")
        precondition(measurement.channel(named: "current")?.unit == "A")
        let dualData = try Data(contentsOf: dualURL)
        precondition(measurement.source.sha256 == sha256Hex(dualData))
        precondition(measurement.provenance["profile_id"] == "keysight-b1500a")

        do {
            let noHeaderURL = root.appendingPathComponent("data/raw/no-header.csv")
            _ = try await InstrumentReader.load(noHeaderURL, project: project)
            fatalError("a source without a DataName row was loaded")
        } catch {
            precondition(error.localizedDescription.contains("DataName"))
        }
        precondition(!FileManager.default.fileExists(atPath: marker.path))

        let outsideRoot = root.appendingPathComponent("instruments-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try Data(keysightProfile.utf8).write(to: outsideRoot.appendingPathComponent("keysight-b1500a.yaml"))
        let escapedProject = root.appendingPathComponent("escaped-project")
        try FileManager.default.createDirectory(at: escapedProject.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escapedProject.appendingPathComponent("data/instruments"), withDestinationURL: outsideRoot)
        try Data("outside".utf8).write(to: escapedProject.appendingPathComponent("data/raw/source.csv"))
        let escapedContext = try ProjectContext.open(escapedProject)
        let escapedReport = await InstrumentReader.inspectMany(try escapedContext.discoverSources(), project: escapedContext)
        precondition(escapedReport.profileIssues.contains { $0.contains("resolves outside this project") })
        precondition(escapedReport.results.first?.inspection == nil)
        try FileManager.default.removeItem(at: outsideRoot)
    }

    static let dualSweepCSV = "\u{FEFF}SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, 1E-12\nDataValue, 0.1, 2E-12\nDataValue, 0.2, 3E-12\nDataValue, 0.1, 4E-12\nDataValue, 0, 5E-12\n"

    static let keysightProfile = """
    schema_version: 1
    instrument:
      id: keysight-b1500a
      name: Keysight B1500A
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
            header: "I2"
            aliases: ["I1"]
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

    static let unversionedDATProfile = """
    instrument:
      id: fixture-dat
      name: Fixture DAT
    formats:
      - id: dat
        extensions: [".dat"]
        delimiter: ","
        rows:
          names_prefix: "DATNAME"
          data_prefix: "DATROW"
        columns:
          x:
            header: "X"
            unit: "s"
          y:
            header: "Y"
            unit: "V"
    modes:
      - id: default
        format: dat
        detect: ["FIXTURE.DAT"]
        extract:
          x: x
          y: [y]
    """
}
