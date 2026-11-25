import Foundation
import Testing

/// One-at-a-time gate for tests that point XDG_CONFIG_HOME at a temp dir.
/// Swift Testing runs suites in parallel in one process, so a setenv in one suite
/// can change the global config another suite reads. Holders run one at a time.
actor GlobalConfigGate {
    static let shared = GlobalConfigGate()

    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Runs `body` with the global config pointed at a fresh temp dir, never the real one.
/// Holds the shared gate for the whole body, so no other isolated test overlaps it.
func withIsolatedGlobalConfig<T>(_ body: () async throws -> T) async throws -> T {
    await GlobalConfigGate.shared.enter()
    let previous = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    let xdgDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rawview-swift-xdg-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(
            at: xdgDir.appendingPathComponent("raw-viewer"),
            withIntermediateDirectories: true
        )
        setenv("XDG_CONFIG_HOME", xdgDir.path, 1)
        let result = try await body()
        restoreGlobalConfig(previous: previous, xdgDir: xdgDir)
        await GlobalConfigGate.shared.leave()
        return result
    } catch {
        restoreGlobalConfig(previous: previous, xdgDir: xdgDir)
        await GlobalConfigGate.shared.leave()
        throw error
    }
}

private func restoreGlobalConfig(previous: String?, xdgDir: URL) {
    if let previous {
        setenv("XDG_CONFIG_HOME", previous, 1)
    } else {
        unsetenv("XDG_CONFIG_HOME")
    }
    try? FileManager.default.removeItem(at: xdgDir)
}

/// Test trait: runs the test under `withIsolatedGlobalConfig`.
/// Use as `@Test(.globalConfigIsolated) func ...`.
struct GlobalConfigIsolated: TestTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await withIsolatedGlobalConfig {
            try await function()
        }
    }
}

extension Trait where Self == GlobalConfigIsolated {
    static var globalConfigIsolated: Self { GlobalConfigIsolated() }
}
