import Foundation
import Testing
@testable import RawViewCore

/// Lock-guarded visit counter shared across task boundaries in tests.
final class VisitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    @discardableResult func increment() -> Int { lock.withLock { _count += 1; return _count } }
}

/// Holds the outer task handle so a synchronous walk hook can cancel the very
/// task driving it. The handle is set synchronously right after task creation,
/// while the worker still needs scheduling plus filesystem I/O before any hook
/// can fire, so cancellation from the hook always lands mid-flight.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<[RawSource], Error>?
    func set(_ task: Task<[RawSource], Error>) { lock.withLock { _task = task } }
    func cancel() { lock.withLock { _task?.cancel() } }
}

private func makeWideProject(directoryCount: Int) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for index in 0..<directoryCount {
        let dir = root.appendingPathComponent("data/raw/batch-\(index)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.csv"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("b.csv"))
    }
    return root
}

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
}

@Test func doesNotDiscoverDescendantProjectRoots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    try Data("selected".utf8).write(to: raw.appendingPathComponent("selected.csv"))
    let descendantRaw = root.appendingPathComponent("studies/nested/data/raw")
    try FileManager.default.createDirectory(at: descendantRaw, withIntermediateDirectories: true)
    try Data("other project".utf8).write(to: descendantRaw.appendingPathComponent("other.csv"))
    try Data("id: nested".utf8).write(to: root.appendingPathComponent("studies/nested/project.yaml"))
    try FileManager.default.createSymbolicLink(at: raw.appendingPathComponent("nested-project"), withDestinationURL: root.appendingPathComponent("studies/nested"))

    let project = try ProjectContext.open(root)
    let sources = try project.discoverSources()

    // Symlink entries are listed lexically with zero claimed target size and
    // never followed: the linked subtree is not traversed, so the descendant
    // project file stays out while the link itself stays listed.
    #expect(sources.map(\.relativePath) == ["data/raw/nested-project", "data/raw/selected.csv"])
    #expect(sources.first(where: { $0.relativePath == "data/raw/nested-project" })?.byteSize == 0)
    let nestedLink = try #require(sources.first { $0.relativePath == "data/raw/nested-project" })
    let report = await InstrumentReader.inspectMany([nestedLink], project: project)
    #expect(report.results.first?.inspection == nil)
    #expect(report.results.first?.error?.contains("outside") == true)
}

@Test func doesNotRecurseIntoNestedProjectData() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    try Data("top".utf8).write(to: raw.appendingPathComponent("top.csv"))
    let nestedRaw = raw.appendingPathComponent("inner/data/raw")
    try FileManager.default.createDirectory(at: nestedRaw, withIntermediateDirectories: true)
    try Data("deep".utf8).write(to: nestedRaw.appendingPathComponent("deep.csv"))

    let sources = try ProjectContext.open(root).discoverSources()

    #expect(sources.map(\.relativePath) == ["data/raw/top.csv"])
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

@Test func discoverySkipsSPEAndAFFMFilesCaseInsensitively() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    try Data("shown".utf8).write(to: raw.appendingPathComponent("shown.csv"))
    try Data("not viewed".utf8).write(to: raw.appendingPathComponent("skip.SPE"))
    try Data("not viewed".utf8).write(to: raw.appendingPathComponent("skip.AfFm"))

    let sources = try ProjectContext.open(root).discoverSources()

    #expect(sources.map(\.relativePath) == ["data/raw/shown.csv"])
}

@Test func discoveryIncludesOnlySupportedMeasurementExtensions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    try Data("meas1".utf8).write(to: raw.appendingPathComponent("device.csv"))
    try Data("meas2".utf8).write(to: raw.appendingPathComponent("spec.txt"))
    try Data("meas3".utf8).write(to: raw.appendingPathComponent("labview.lvm"))
    try Data("meas4".utf8).write(to: raw.appendingPathComponent("UPPER.CSV"))
    try Data("log".utf8).write(to: raw.appendingPathComponent("run.log"))
    try Data("log".utf8).write(to: raw.appendingPathComponent(".intake.log"))
    try Data("script".utf8).write(to: raw.appendingPathComponent("run.py"))
    try Data("json".utf8).write(to: raw.appendingPathComponent("info.json"))

    let sources = try ProjectContext.open(root).discoverSources()

    #expect(sources.map(\.relativePath).sorted() == [
        "data/raw/UPPER.CSV",
        "data/raw/device.csv",
        "data/raw/labview.lvm",
        "data/raw/spec.txt"
    ])
}

@Test func listsDiscoveredSymlinksLexicallyWithoutTargetAccess() throws {
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

    // Symlink entries stay listed lexically (claimed path, no target size) so
    // inspection can report them; the target is never resolved or read.
    #expect(sources.map(\.relativePath) == ["data/raw/escape.csv", "data/raw/inside.csv"])
    #expect(sources.first(where: { $0.relativePath == "data/raw/escape.csv" })?.byteSize == 0)
}

@Test func discoveryAsyncUsesProductionSeamOffMain() async throws {
    let root = try makeWideProject(directoryCount: 4)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try ProjectContext.open(root)
    let direct = try project.discoverSources()
    let viaSeam = try await project.discoverSourcesAsync()
    #expect(viaSeam.map(\.relativePath) == direct.map(\.relativePath))
    #expect(viaSeam.count == 8)
}

@Test func discoveryAsyncCanceledBeforeProgressThrowsWithoutWalkingAll() async throws {
    let total = 40
    let root = try makeWideProject(directoryCount: total)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try ProjectContext.open(root)
    // The hook cancels the driving task from inside the walk itself, so the
    // cancel provably lands mid-flight with no thread-blocking handshake.
    let counter = VisitCounter()
    let box = TaskBox()
    let task = Task {
        try await project.discoverSourcesAsync(onVisitDirectory: { _ in
            counter.increment()
            box.cancel()
        })
    }
    box.set(task)
    await #expect(throws: CancellationError.self) { try await task.value }
    // Canceled discovery never walks the remaining directories.
    #expect(counter.count < total + 1)
}

@Test func discoveryAsyncCanceledDuringInventoryStopsEarly() async throws {
    let total = 40
    let stopAt = 8
    let root = try makeWideProject(directoryCount: total)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try ProjectContext.open(root)
    let counter = VisitCounter()
    let box = TaskBox()
    let task = Task {
        try await project.discoverSourcesAsync(onVisitDirectory: { _ in
            if counter.increment() == stopAt { box.cancel() }
        })
    }
    box.set(task)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(counter.count >= stopAt)
    #expect(counter.count <= stopAt + 2)
    #expect(counter.count < total + 1)
}

@Test func wideDirectoryInventoryIsCancellable() async throws {
    let total = 3000
    let stopAt = 50
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    for index in 0..<total {
        try Data("x".utf8).write(to: raw.appendingPathComponent("f\(index).csv"))
    }
    let project = try ProjectContext.open(root)
    let counter = VisitCounter()
    let box = TaskBox()
    let task = Task {
        try await project.discoverSourcesAsync(onVisitFile: { _ in
            if counter.increment() == stopAt { box.cancel() }
        })
    }
    box.set(task)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(counter.count >= stopAt)
    #expect(counter.count < total)
}

@Test func discoveryGateSupersedesStaleGenerations() async {
    let gate = DiscoveryGate()
    let stale = await gate.begin()
    #expect(await gate.isCurrent(stale))
    let current = await gate.begin()
    #expect(await gate.isCurrent(current))
    // The superseded generation must not install: this is the exact guard the
    // production consumer checks before applying discovered sources.
    #expect(!(await gate.isCurrent(stale)))
}

@Test func reselectSupersedesInFlightDiscovery() async throws {
    let total = 40
    let root = try makeWideProject(directoryCount: total)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try ProjectContext.open(root)
    let gate = DiscoveryGate()
    let tokenA = await gate.begin()
    let counter = VisitCounter()
    let box = TaskBox()
    let taskA = Task {
        try await project.discoverSourcesAsync(onVisitDirectory: { _ in
            counter.increment()
            box.cancel()
        })
    }
    box.set(taskA)
    await #expect(throws: CancellationError.self) { try await taskA.value }
    // Reselection starts generation B; the cancelled run must not install.
    let tokenB = await gate.begin()
    #expect(!(await gate.isCurrent(tokenA)))
    #expect(await gate.isCurrent(tokenB))
    // Generation B completes normally with the full inventory.
    let sourcesB = try await project.discoverSourcesAsync()
    #expect(sourcesB.count == total * 2)
    #expect(await gate.isCurrent(tokenB))
}

@Test func discoveryFiltersSymlinksToUnsupportedExtensions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    
    let target = raw.appendingPathComponent("data.csv")
    try Data("meas".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: raw.appendingPathComponent("symlink.csv"), withDestinationURL: target)
    try FileManager.default.createSymbolicLink(at: raw.appendingPathComponent("symlink.log"), withDestinationURL: target)
    
    let sources = try ProjectContext.open(root).discoverSources()
    
    let paths = sources.map(\.relativePath).sorted()
    #expect(paths == ["data/raw/data.csv", "data/raw/symlink.csv"])
}
