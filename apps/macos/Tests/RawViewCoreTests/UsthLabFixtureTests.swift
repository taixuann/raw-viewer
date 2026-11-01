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

    private static func parseExpectedEntries(text: String) -> [ExpectedEntry] {
        var entries: [ExpectedEntry] = []
        var relativePath: String?
        var profileID: String?
        var variant: String?
        var plottable = false
        var xQuantity: String?
        var xUnit: String?
        var yQuantity: String?
        var yUnit: String?
        var metadataKeys: [String] = []
        var inMetadataList = false

        func flush() {
            guard let rp = relativePath, let pid = profileID, let varnt = variant,
                  let xq = xQuantity, let xu = xUnit, let yq = yQuantity, let yu = yUnit else { return }
            entries.append(
                ExpectedEntry(
                    relativePath: rp,
                    profileID: pid,
                    variant: varnt,
                    plottable: plottable,
                    xQuantity: xq,
                    xUnit: xu,
                    yQuantity: yq,
                    yUnit: yu,
                    metadataKeys: metadataKeys))
            relativePath = nil
            profileID = nil
            variant = nil
            plottable = false
            xQuantity = nil
            xUnit = nil
            yQuantity = nil
            yUnit = nil
            metadataKeys = []
            inMetadataList = false
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- id:") {
                flush()
                continue
            }
            if inMetadataList {
                if trimmed.hasPrefix("- ") {
                    metadataKeys.append(String(trimmed.dropFirst(2)))
                    continue
                }
                inMetadataList = false
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "relative_path": relativePath = value
            case "profile_id": profileID = value
            case "variant": variant = value
            case "plottable": plottable = value == "true"
            case "x_quantity": xQuantity = value
            case "x_unit": xUnit = value
            case "y_quantity": yQuantity = value
            case "y_unit": yUnit = value
            case "metadata_keys":
                if value == "[]" {
                    metadataKeys = []
                } else {
                    inMetadataList = true
                }
            default:
                break
            }
        }
        flush()
        return entries
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
        let rows = Self.parseExpectedEntries(text: expectedText).filter(\.plottable)
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
        let rows = Self.parseExpectedEntries(text: expectedText)
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
