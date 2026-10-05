import Foundation
import Testing
@testable import RawViewCore

struct ReaderTrustTests {
    @Test func projectReaderAndRuntimeCodeAreNeverExecuted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("PROJECT_CODE_EXECUTED")
        let script = "from pathlib import Path\nPath(\"\(marker.path)\").write_text(\"ran\")\n"

        try write("data/raw/dual.csv", Data(Fixtures.dualSweepCSV.utf8), under: root)
        try write("data/instruments/keysight-b1500a.yaml", Data(Fixtures.keysightProfile.utf8), under: root)
        try write("data/instruments/reader.py", Data(script.utf8), under: root)
        try write("data/runtime/instrument_runtime.py", Data(script.utf8), under: root)

        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.results.count == 1)
        #expect(report.results[0].inspection != nil)
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.channel(named: "voltage")?.values == [0, 0.1, 0.2, 0.1, 0])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func escapedSourceSymlinkCannotBeInspectedOrLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("data/raw/inside.csv", Data(Fixtures.dualSweepCSV.utf8), under: root)
        let outside = root.appendingPathComponent("outside.csv")
        try Data(Fixtures.dualSweepCSV.utf8).write(to: outside)
        let escapedLink = root.appendingPathComponent("data/raw/escape.csv")
        try FileManager.default.createSymbolicLink(at: escapedLink, withDestinationURL: outside)

        let project = try ProjectContext.open(root)
        #expect(try project.discoverSources().map(\.relativePath) == ["data/raw/inside.csv"])
        let forged = RawSource(relativePath: "data/raw/escape.csv", url: escapedLink, byteSize: 1)
        let report = await InstrumentReader.inspectMany([forged], project: project)
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("data/raw/escape.csv") == true)
        #expect(report.results.first?.error?.contains("outside") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(escapedLink, project: project)
        }
        do {
            _ = try await InstrumentReader.load(escapedLink, project: project)
            Issue.record("escaped source loaded instead of rejected")
        } catch {
            #expect(error.localizedDescription.contains("data/raw/escape.csv"))
            #expect(error.localizedDescription.contains("outside"))
        }
    }

    @Test func inRootSymlinkToExcludedTargetIsRejectedWithoutFollowing() async throws {
        // A .csv symlink naming a .spe target is rejected from the link text
        // alone: the prohibited target is never resolved, stat-ed, opened, or
        // read. Direct and forged callers both fail closed.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("data/raw/more/hidden.spe", Data("prohibited target".utf8), under: root)
        let sneaky = root.appendingPathComponent("data/raw/sneaky.csv")
        try FileManager.default.createSymbolicLink(atPath: sneaky.path, withDestinationPath: "more/hidden.spe")

        let project = try ProjectContext.open(root)
        let forged = RawSource(relativePath: "data/raw/sneaky.csv", url: sneaky, byteSize: 1)
        let report = await InstrumentReader.inspectMany([forged], project: project)
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("data/raw/sneaky.csv") == true)
        #expect(report.results.first?.error?.contains("symlink") == true)
        do {
            _ = try await InstrumentReader.load(sneaky, project: project)
            Issue.record("symlink source loaded instead of rejected")
        } catch {
            #expect(error.localizedDescription.contains("data/raw/sneaky.csv"))
            #expect(error.localizedDescription.contains("symlink"))
        }
    }

    @Test func externalInstrumentsRootFailsClosedWithoutUsingOutsideProfiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-trust-\(UUID().uuidString)")
        let outsideInstruments = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideInstruments)
        }
        let marker = outsideInstruments.appendingPathComponent("PROFILE_CODE_EXECUTED")
        try write("data/raw/dual.csv", Data(Fixtures.dualSweepCSV.utf8), under: root)
        try FileManager.default.createDirectory(at: outsideInstruments, withIntermediateDirectories: true)
        try Data(Fixtures.keysightProfile.utf8).write(to: outsideInstruments.appendingPathComponent("keysight-b1500a.yaml"))
        try Data("from pathlib import Path\nPath(\"\(marker.path)\").write_text(\"ran\")\n".utf8)
            .write(to: outsideInstruments.appendingPathComponent("reader.py"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("data/instruments"),
            withDestinationURL: outsideInstruments
        )

        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.profileIssues.contains { $0.contains("data/instruments resolves outside this project") })
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("No instrument profile supports") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func escapedProfileSymlinkIsSkipped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-trust-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-profile-\(UUID().uuidString).yaml")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write("data/raw/dual.csv", Data(Fixtures.dualSweepCSV.utf8), under: root)
        try write("data/instruments/.keep", Data(), under: root)
        try Data(Fixtures.keysightProfile.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("data/instruments/escaped.yaml"),
            withDestinationURL: outside
        )

        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.profileIssues.contains { $0.contains("data/instruments/escaped.yaml") && $0.contains("resolves outside data/instruments") })
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("No instrument profile supports") == true)
    }

    @Test func missingRawDirectoryOffersActionableMessage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("data/instruments/.keep", Data(), under: root)
        do {
            _ = try ProjectContext.open(root)
            Issue.record("a project without data/raw was accepted")
        } catch {
            #expect(error.localizedDescription.contains("data/raw"))
        }
    }

    private func write(_ relativePath: String, _ data: Data, under root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
