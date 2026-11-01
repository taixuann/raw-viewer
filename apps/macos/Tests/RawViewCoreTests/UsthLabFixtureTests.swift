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
        return try items.map { item in
            guard let map = item.mapEntries else {
                throw ExpectedParseError.invalid("expected entry map")
            }
            func scalar(_ key: String) throws -> String {
                guard let value = map.first(where: { $0.key == key })?.value.scalarValue else {
                    throw ExpectedParseError.invalid("missing \(key)")
                }
                return value
            }
            func bool(_ key: String) throws -> Bool {
                switch try scalar(key) {
                case "true": return true
                case "false": return false
                default:
                    throw ExpectedParseError.invalid("\(key) not bool")
                }
            }
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
                relativePath: try scalar("relative_path"),
                profileID: try scalar("profile_id"),
                variant: try scalar("variant"),
                plottable: try bool("plottable"),
                xQuantity: try scalar("x_quantity"),
                xUnit: try scalar("x_unit"),
                yQuantity: try scalar("y_quantity"),
                yUnit: try scalar("y_unit"),
                metadataKeys: metadataKeys)
        }
    }

    private static func acquisitionMetadataKeys(_ measurement: NormalizedMeasurement) -> [String] {
        measurement.metadataSections
            .filter { $0.title == "Acquisition" }
            .flatMap { $0.fields.map(\.key) }
            .sorted()
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
            #expect(actual == entry.metadataKeys, "\(entry.relativePath): \(actual)")
            #expect(actual.count == 11)
        }
    }
}
