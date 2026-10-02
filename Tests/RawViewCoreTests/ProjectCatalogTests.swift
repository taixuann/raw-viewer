import Foundation
import Testing
@testable import RawViewCore

@Test func discoversNestedSourcesInStableRelativePathOrderWithoutReader() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: raw.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try Data("b".utf8).write(to: raw.appendingPathComponent("z.csv"))
    try Data("a".utf8).write(to: raw.appendingPathComponent("nested/a.csv"))

    let project = try ProjectContext.open(root)
    let sources = try project.discoverSources()

    #expect(sources.map(\.relativePath) == ["data/raw/nested/a.csv", "data/raw/z.csv"])
    #expect(sources.map(\.id) == sources.map(\.relativePath))
    #expect(sources.map(\.byteSize) == [1, 1])
    #expect(sources.allSatisfy { $0.url == $0.url.resolvingSymlinksInPath().standardizedFileURL })
    #expect(ReaderApproval.issue(afterUserReviewOf: project) == nil)
}

@Test func doesNotListDirectoriesAsRawSources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: raw.appendingPathComponent("ignored-directory"), withIntermediateDirectories: true)
    try Data("ok".utf8).write(to: raw.appendingPathComponent("source.csv"))

    let sources = try ProjectContext.open(root).discoverSources()

    #expect(sources.map(\.relativePath) == ["data/raw/source.csv"])
}

@Test func rejectsDiscoveredSymlinksThatEscapeRawRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    let inside = raw.appendingPathComponent("inside.csv")
    try Data("inside".utf8).write(to: inside)
    let outside = root.appendingPathComponent("outside.csv")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: raw.appendingPathComponent("escape.csv"), withDestinationURL: outside)

    let project = try ProjectContext.open(root)
    let sources = try project.discoverSources()

    #expect(sources.map(\.relativePath) == ["data/raw/inside.csv"])
}
