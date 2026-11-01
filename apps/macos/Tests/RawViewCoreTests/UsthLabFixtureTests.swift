import Foundation
import Testing
@testable import RawViewCore

struct UsthLabFixtureTests {
    private static var workspaceRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("fixtures/workspaces/usth-lab")
    }

    @Test func plottableRowsMatchExpectedProfileAndAxes() async throws {
        let project = try ProjectContext.open(Self.workspaceRoot)
        let expected = try String(
            contentsOf: Self.workspaceRoot.appendingPathComponent("expected.yaml"), encoding: .utf8)
        let rows = expected
            .split(separator: "\n")
            .filter { $0.contains("relative_path:") && $0.contains("data/raw") }
        #expect(!rows.isEmpty)
        let keithleyLine = rows.first { $0.contains("keithley-2400.dual-sweep") && $0.contains("reproducible") }!
        let relative = keithleyLine.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        let source = try project.discoverSources().first { $0.relativePath == relative }!
        let measurement = try await InstrumentReader.load(source.url, project: project)
        #expect(measurement.provenance["profile_id"] == "usth/keithley-2400")
        #expect(measurement.provenance["mode"] == "dual-sweep")
        let xKey = try #require(measurement.view.x)
        let yKey = try #require(measurement.view.y?.first)
        #expect(measurement.channel(named: xKey)?.quantity == "voltage")
        #expect(measurement.channel(named: yKey)?.quantity == "current")
    }
}
