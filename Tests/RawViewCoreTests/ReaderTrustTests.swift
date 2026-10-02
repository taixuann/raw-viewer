import Foundation
import Testing
@testable import RawViewCore

@Test func approvalIsBoundToCanonicalProjectAndReaderHashAndCanBeRevoked() throws {
    let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: projectRoot) }
    let raw = projectRoot.appendingPathComponent("data/raw")
    let instruments = projectRoot.appendingPathComponent("data/instruments")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: instruments, withIntermediateDirectories: true)
    let reader = instruments.appendingPathComponent("reader.py")
    try Data("# fixture one".utf8).write(to: reader)
    let project = try ProjectContext.open(projectRoot)
    let approval = try #require(ReaderApproval.issue(afterUserReviewOf: project))
    #expect(approval.isCurrent(for: project))
    let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: otherRoot) }
    let otherRaw = otherRoot.appendingPathComponent("data/raw")
    let otherInstruments = otherRoot.appendingPathComponent("data/instruments")
    try FileManager.default.createDirectory(at: otherRaw, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherInstruments, withIntermediateDirectories: true)
    try Data("# fixture one".utf8).write(to: otherInstruments.appendingPathComponent("reader.py"))
    #expect(!approval.isCurrent(for: try ProjectContext.open(otherRoot)))
    let encoded = try JSONEncoder().encode(approval)
    let restored = try JSONDecoder().decode(ReaderApproval.self, from: encoded)
    #expect(restored == approval)
    #expect(restored.isCurrent(for: project))
    try Data("# fixture changed".utf8).write(to: reader)
    #expect(!restored.isCurrent(for: project))
    var storedApproval: ReaderApproval? = restored
    storedApproval = nil
    #expect(storedApproval == nil)
}

@Test func selectedSourceCannotEscapeRawRootThroughSymlink() throws {
    let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let rawRoot = projectRoot.appendingPathComponent("data/raw")
    let instruments = projectRoot.appendingPathComponent("data/instruments")
    try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: instruments, withIntermediateDirectories: true)
    try Data("print('reader')".utf8).write(to: instruments.appendingPathComponent("reader.py"))
    let outside = projectRoot.appendingPathComponent("outside.csv")
    try Data("fixture".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: rawRoot.appendingPathComponent("escape.csv"), withDestinationURL: outside)
    let project = try ProjectContext.open(projectRoot)
    #expect(!project.containsSource(rawRoot.appendingPathComponent("escape.csv")))
}

@Test func externalInstrumentsRootSymlinkAllowsInventoryButCannotReceiveApproval() throws {
    let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let externalInstruments = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: projectRoot)
        try? FileManager.default.removeItem(at: externalInstruments)
    }
    let rawRoot = projectRoot.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalInstruments, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: rawRoot.appendingPathComponent("source.csv"))
    let marker = projectRoot.appendingPathComponent("READER_EXECUTED")
    try Data("from pathlib import Path\nPath(\"\(marker.path)\").write_text(\"ran\")\n".utf8)
        .write(to: externalInstruments.appendingPathComponent("reader.py"))
    try FileManager.default.createSymbolicLink(
        at: projectRoot.appendingPathComponent("data/instruments"),
        withDestinationURL: externalInstruments
    )
    let project = try ProjectContext.open(projectRoot)
    #expect(try project.discoverSources().map(\.relativePath) == ["data/raw/source.csv"])
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(ReaderApproval.issue(afterUserReviewOf: project) == nil)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func inProjectInstrumentsSymlinkMayReceiveApproval() throws {
    let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: projectRoot) }
    let rawRoot = projectRoot.appendingPathComponent("data/raw")
    let sharedInstruments = projectRoot.appendingPathComponent("shared-instruments")
    try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sharedInstruments, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: rawRoot.appendingPathComponent("source.csv"))
    let marker = projectRoot.appendingPathComponent("READER_EXECUTED")
    try Data("from pathlib import Path\nPath(\"\(marker.path)\").write_text(\"ran\")\n".utf8)
        .write(to: sharedInstruments.appendingPathComponent("reader.py"))
    try FileManager.default.createSymbolicLink(
        at: projectRoot.appendingPathComponent("data/instruments"),
        withDestinationURL: sharedInstruments
    )

    let project = try ProjectContext.open(projectRoot)

    #expect(try project.discoverSources().map(\.relativePath) == ["data/raw/source.csv"])
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(ReaderApproval.issue(afterUserReviewOf: project) != nil)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func escapingReaderSymlinkDoesNotBlockInventoryOrReceiveApproval() throws {
    let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: projectRoot) }
    let rawRoot = projectRoot.appendingPathComponent("data/raw")
    let instruments = projectRoot.appendingPathComponent("data/instruments")
    try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: instruments, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: rawRoot.appendingPathComponent("source.csv"))
    let marker = projectRoot.appendingPathComponent("READER_EXECUTED")
    let externalReader = projectRoot.appendingPathComponent("external-reader.py")
    try Data("from pathlib import Path\nPath(\"\(marker.path)\").write_text(\"ran\")\n".utf8).write(to: externalReader)
    try FileManager.default.createSymbolicLink(at: instruments.appendingPathComponent("reader.py"), withDestinationURL: externalReader)

    let project = try ProjectContext.open(projectRoot)

    #expect(try project.discoverSources().map(\.relativePath) == ["data/raw/source.csv"])
    #expect(ReaderApproval.issue(afterUserReviewOf: project) == nil)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}
