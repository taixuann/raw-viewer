import Foundation
import Testing
@testable import RawViewCore

struct UsthLabFixtureTests {
    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static var workspaceRoot: URL {
        repoRoot.appendingPathComponent("fixtures/workspaces/usth-lab")
    }

    private struct ExpectedEntry: Sendable {
        let relativePath: String
        let profileID: String
        let variant: String
        let plottable: Bool
        let dataRowCount: Int?
        let xQuantity: String?
        let xUnit: String?
        let yQuantity: String?
        let yUnit: String?
        let metadataKeys: [String]
    }

    private enum ExpectedParseError: Error {
        case invalid(String)
    }

    private static func parseExpectedEntries(text: String) throws -> [ExpectedEntry] {
        let root = try YAMLParser.parse(text, allowIndentlessSequences: false)
        guard let items = root.value(for: "entries")?.listItems else { return [] }
        return try items.map { item in
            guard let map = item.mapEntries else {
                throw ExpectedParseError.invalid("entry must be a mapping")
            }
            func optionalScalar(_ key: String) -> String? {
                map.first(where: { $0.key == key })?.value.scalarValue
            }
            guard let relativePath = optionalScalar("relative_path") else {
                throw ExpectedParseError.invalid("missing relative_path")
            }
            guard let profileID = optionalScalar("profile_id") else {
                throw ExpectedParseError.invalid("missing profile_id")
            }
            guard let variant = optionalScalar("variant") else {
                throw ExpectedParseError.invalid("missing variant")
            }
            func optionalAxisScalar(_ key: String) -> String? {
                guard let value = optionalScalar(key) else { return nil }
                if value == "null" || value.isEmpty { return nil }
                return value
            }
            guard let plottableText = optionalScalar("plottable") else {
                throw ExpectedParseError.invalid("missing plottable")
            }
            let xQuantity = optionalAxisScalar("x_quantity")
            let xUnit = optionalAxisScalar("x_unit")
            let yQuantity = optionalAxisScalar("y_quantity")
            let yUnit = optionalAxisScalar("y_unit")
            let plottable: Bool
            switch plottableText {
            case "true": plottable = true
            case "false": plottable = false
            default:
                throw ExpectedParseError.invalid("plottable not bool")
            }
            if plottable {
                guard xQuantity != nil, xUnit != nil, yQuantity != nil, yUnit != nil else {
                    throw ExpectedParseError.invalid("plottable entry missing axis fields")
                }
            }
            let dataRowCount = optionalScalar("data_row_count").flatMap(Int.init)
            let metadataNode = map.first(where: { $0.key == "metadata_keys" })?.value
            let metadataKeys: [String]
            if let list = metadataNode?.listItems {
                metadataKeys = list.compactMap(\.scalarValue)
            } else if metadataNode?.scalarValue == "[]" {
                metadataKeys = []
            } else {
                metadataKeys = []
            }
            return ExpectedEntry(
                relativePath: relativePath,
                profileID: profileID,
                variant: variant,
                plottable: plottable,
                dataRowCount: dataRowCount,
                xQuantity: xQuantity,
                xUnit: xUnit,
                yQuantity: yQuantity,
                yUnit: yUnit,
                metadataKeys: metadataKeys)
        }
    }

    private static func acquisitionMetadataKeys(_ measurement: NormalizedMeasurement) -> [String] {
        measurement.metadataSections
            .filter { $0.title == "Acquisition" }
            .flatMap { $0.fields.map(\.key) }
            .sorted()
    }

    private static func acquisitionString(_ measurement: NormalizedMeasurement, key: String) -> String? {
        measurement.metadataSections
            .filter { $0.title == "Acquisition" }
            .flatMap(\.fields)
            .first { $0.key == key }
            .flatMap { field -> String? in
                if case .string(let text) = field.value { return text }
                return nil
            }
    }

    @Test func expectedYAMLEntryCounts() async throws {
        let expectedText = try String(
            contentsOf: Self.workspaceRoot.appendingPathComponent("expected.yaml"), encoding: .utf8)
        let rows = try Self.parseExpectedEntries(text: expectedText)
        #expect(rows.count == 9)
        #expect(rows.filter(\.plottable).count == 6)
    }

    @Test func plottableRowsMatchExpectedProfileAndAxes() async throws {
        let project = try ProjectContext.open(Self.workspaceRoot)
        let expectedText = try String(
            contentsOf: Self.workspaceRoot.appendingPathComponent("expected.yaml"), encoding: .utf8)
        let rows = try Self.parseExpectedEntries(text: expectedText).filter(\.plottable)
        #expect(rows.count == 6)
        let sources = try project.discoverSources()
        for entry in rows {
            let source = try #require(sources.first { $0.relativePath == entry.relativePath })
            let measurement = try await InstrumentReader.load(source.url, project: project)
            let tag = entry.relativePath
            #expect(measurement.provenance["profile_id"] == entry.profileID, "\(tag) profile_id")
            #expect(measurement.provenance["mode"] == entry.variant, "\(tag) mode")
            let xKey = try #require(measurement.view.x, "\(tag) missing view.x")
            let yKey = try #require(measurement.view.y?.first, "\(tag) missing view.y")
            let xChannel = try #require(measurement.channel(named: xKey), "\(tag) missing x channel")
            let yChannel = try #require(measurement.channel(named: yKey), "\(tag) missing y channel")
            let expectedXQ = try #require(entry.xQuantity, "\(tag) missing expected x_quantity")
            let expectedXU = try #require(entry.xUnit, "\(tag) missing expected x_unit")
            let expectedYQ = try #require(entry.yQuantity, "\(tag) missing expected y_quantity")
            let expectedYU = try #require(entry.yUnit, "\(tag) missing expected y_unit")
            #expect(xChannel.quantity == expectedXQ, "\(tag) x quantity")
            #expect(xChannel.unit == expectedXU, "\(tag) x unit")
            #expect(yChannel.quantity == expectedYQ, "\(tag) y quantity")
            #expect(yChannel.unit == expectedYU, "\(tag) y unit")
        }
    }

    @Test func tableRowCountsMatchExpectedYAMLIncludingNonPlottable() async throws {
        let project = try ProjectContext.open(Self.workspaceRoot)
        let expectedText = try String(
            contentsOf: Self.workspaceRoot.appendingPathComponent("expected.yaml"), encoding: .utf8)
        let rows = try Self.parseExpectedEntries(text: expectedText)
        let sources = try project.discoverSources()
        for entry in rows {
            guard let expectedRows = entry.dataRowCount else { continue }
            if !entry.plottable {
                #expect(expectedRows == 0, "\(entry.relativePath): non-plottable data_row_count")
                continue
            }
            let source = try #require(sources.first { $0.relativePath == entry.relativePath })
            let measurement = try await InstrumentReader.load(source.url, project: project)
            let pointCount = measurement.channels.first?.values.count ?? 0
            #expect(pointCount == expectedRows, "\(entry.relativePath): data_row_count")
        }
    }

    @Test func keithleyResolvesThreeProfileColumns() async throws {
        let project = try ProjectContext.open(Self.workspaceRoot)
        let relative = "data/raw/2026-10-07/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt"
        let source = try #require(try project.discoverSources().first { $0.relativePath == relative })
        let measurement = try await InstrumentReader.load(source.url, project: project)
        #expect(measurement.channels.count == 3)
        let voltage = try #require(measurement.channel(named: "voltage"))
        #expect(voltage.quantity == "voltage")
        #expect(voltage.unit == "V")
        let current = try #require(measurement.channel(named: "current"))
        #expect(current.quantity == "current")
        #expect(current.unit == "A")
        let timestamp = try #require(measurement.channel(named: "timestamp"))
        #expect(timestamp.quantity == "time")
        #expect(timestamp.unit == "s")
        #expect(voltage.values.count == 121)
        #expect(current.values.count == 121)
        #expect(timestamp.values.count == 121)
    }

    @Test func plottableMetadataKeysMatchExpectedYAML() async throws {
        let project = try ProjectContext.open(Self.workspaceRoot)
        let expectedText = try String(
            contentsOf: Self.workspaceRoot.appendingPathComponent("expected.yaml"), encoding: .utf8)
        let rows = try Self.parseExpectedEntries(text: expectedText)
            .filter { $0.plottable && !$0.metadataKeys.isEmpty }
        #expect(rows.count == 1)
        let sources = try project.discoverSources()
        for entry in rows {
            let source = try #require(sources.first { $0.relativePath == entry.relativePath })
            let measurement = try await InstrumentReader.load(source.url, project: project)
            let actual = Self.acquisitionMetadataKeys(measurement)
            #expect(actual == entry.metadataKeys.sorted(), "\(entry.relativePath): \(actual)")
            #expect(actual.count == 2)
            #expect(Self.acquisitionString(measurement, key: "Date") == "2026/10/07")
            #expect(Self.acquisitionString(measurement, key: "Time") == "14:37:03.3081121444702148437")
        }
    }

    @Test func autolabCvProgressionAndSkipColumns() async throws {
        let project = try ProjectContext.open(Self.workspaceRoot)
        let relative =
            "data/raw/2025-11-27/271125-000000_autolab-usth.cv_[au-pda]_cv.deposition_r.[20mv-ph-8.4].txt"
        let source = try #require(try project.discoverSources().first { $0.relativePath == relative })
        let measurement = try await InstrumentReader.load(source.url, project: project)
        let channelNames = measurement.channels.map(\.name).sorted()
        #expect(channelNames == ["current", "electrode_potential", "scan"])
        let scan = try #require(measurement.channel(named: "scan"))
        #expect(scan.quantity == "index")
        #expect(measurement.view.x == "electrode_potential")
        #expect(measurement.view.y == ["current"])
        let profileURL = Self.workspaceRoot
            .appendingPathComponent(".raw-viewer/profiles/autolab-usth.yaml")
        let yaml = try String(contentsOf: profileURL, encoding: .utf8)
        let doc = try ProfileV4Codec.parse(text: yaml)
        let cv = try #require(doc.variants["cv"])
        let scanCol = try #require(cv.columns["scan"])
        #expect(scanCol.role == .progression)
        #expect(scanCol.progression?.behavior == "discrete")
    }

    @Test func autolabCaAxesAndSkipColumns() async throws {
        let project = try ProjectContext.open(Self.workspaceRoot)
        let relative =
            "data/raw/2026-09-21/210926-131400_autolab-usth.ca_[cu-ec-pda.c5-ito.2]_ca.protonation.txt"
        let source = try #require(try project.discoverSources().first { $0.relativePath == relative })
        let measurement = try await InstrumentReader.load(source.url, project: project)
        #expect(measurement.channels.map(\.name).sorted() == ["current", "time"])
        #expect(measurement.view.x == "time")
        #expect(measurement.view.y == ["current"])
    }

    @Test func autolabEisNyquistViewAndBodeChannels() async throws {
        let project = try ProjectContext.open(Self.workspaceRoot)
        let relative =
            "data/raw/2026-04-21/210426-000000_autolab-usth.eis_[gce-pda]_eis.characterization_r.[ph-6.65].txt"
        let source = try #require(try project.discoverSources().first { $0.relativePath == relative })
        let measurement = try await InstrumentReader.load(source.url, project: project)
        #expect(measurement.channels.map(\.name).sorted() == [
            "frequency", "phase", "z_double_prime", "z_magnitude", "z_prime",
        ])
        #expect(measurement.view.x == "z_prime")
        #expect(measurement.view.y == ["z_double_prime"])
        let zPrime = try #require(measurement.channel(named: "z_prime"))
        #expect(zPrime.quantity == "impedance_real")
        #expect(zPrime.unit == "ohm")
        let zDouble = try #require(measurement.channel(named: "z_double_prime"))
        #expect(zDouble.quantity == "impedance")
        #expect(zDouble.unit == "ohm")
        let frequency = try #require(measurement.channel(named: "frequency"))
        #expect(frequency.quantity == "frequency")
        #expect(frequency.unit == "Hz")
        let magnitude = try #require(measurement.channel(named: "z_magnitude"))
        #expect(magnitude.quantity == "impedance")
        #expect(magnitude.unit == "ohm")
        let phase = try #require(measurement.channel(named: "phase"))
        #expect(phase.quantity == "phase")
        #expect(phase.unit == "deg")
        let profileURL = Self.workspaceRoot
            .appendingPathComponent(".raw-viewer/profiles/autolab-usth.yaml")
        let yaml = try String(contentsOf: profileURL, encoding: .utf8)
        let doc = try ProfileV4Codec.parse(text: yaml)
        let eis = try #require(doc.variants["eis"])
        #expect(eis.plot.x == "z_prime")
        #expect(eis.plot.y == ["z_double_prime"])
        #expect(eis.columns["index"]?.role == .skip)
    }

    @Test func autolabCvAxesProgressionProvenance() async throws {
        let project = try ProjectContext.open(Self.workspaceRoot)
        let relative =
            "data/raw/2025-11-27/271125-000000_autolab-usth.cv_[au-pda]_cv.deposition_r.[20mv-ph-8.4].txt"
        let source = try #require(try project.discoverSources().first { $0.relativePath == relative })
        let measurement = try await InstrumentReader.load(source.url, project: project)
        #expect(measurement.eligibleXIDs == ["electrode_potential"])
        #expect(measurement.eligibleYIDs == ["current"])
        #expect(measurement.progressionChannel?.name == "scan")
    }
}
