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
        let xQuantity: String
        let xUnit: String
        let yQuantity: String
        let yUnit: String
        let metadataKeys: [String]
    }

    private enum ExpectedParseError: Error {
        case invalid(String)
    }

    private static func parseExpectedEntries(text: String) throws -> [ExpectedEntry] {
        let root = try YAMLParser.parse(text, allowIndentlessSequences: false)
        guard let items = root.value(for: "entries")?.listItems else { return [] }
        return try items.compactMap { item in
            guard let map = item.mapEntries else { return nil }
            func optionalScalar(_ key: String) -> String? {
                map.first(where: { $0.key == key })?.value.scalarValue
            }
            guard let relativePath = optionalScalar("relative_path"),
                  let profileID = optionalScalar("profile_id"),
                  let variant = optionalScalar("variant"),
                  let plottableText = optionalScalar("plottable"),
                  let xQuantity = optionalScalar("x_quantity"),
                  let xUnit = optionalScalar("x_unit"),
                  let yQuantity = optionalScalar("y_quantity"),
                  let yUnit = optionalScalar("y_unit")
            else { return nil }
            let plottable: Bool
            switch plottableText {
            case "true": plottable = true
            case "false": plottable = false
            default:
                throw ExpectedParseError.invalid("plottable not bool")
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
            #expect(xChannel.quantity == entry.xQuantity, "\(tag) x quantity")
            #expect(xChannel.unit == entry.xUnit, "\(tag) x unit")
            #expect(yChannel.quantity == entry.yQuantity, "\(tag) y quantity")
            #expect(yChannel.unit == entry.yUnit, "\(tag) y unit")
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
}
