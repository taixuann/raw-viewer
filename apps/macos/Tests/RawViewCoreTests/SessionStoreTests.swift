import XCTest
@testable import RawViewCore

final class SessionStoreTests: XCTestCase {
    func testAppendAndLoadTurnsInDailyFolder() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(projectRoot: tempDir)
        let sessionId = UUID()
        let testDate = Date(timeIntervalSince1970: 1776345600) // 2026-04-16

        let turn1 = ChatTurn(
            id: UUID(),
            timestamp: testDate,
            role: "user",
            content: "/setup-grammar",
            metadata: ["source": "sample_01.csv"]
        )

        let turn2 = ChatTurn(
            id: UUID(),
            timestamp: testDate.addingTimeInterval(5),
            role: "assistant",
            content: "Grammar created.",
            metadata: [:],
            toolUses: [
                ToolUseRecord(id: "call-1", name: "rawview-setup-grammar", status: "success", input: nil, output: "Saved .rawviewer/grammar.yaml")
            ]
        )

        try await store.appendTurn(turn1, sessionId: sessionId, date: testDate)
        try await store.appendTurn(turn2, sessionId: sessionId, date: testDate)

        let turns = try await store.loadTurns(sessionId: sessionId, date: testDate)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].content, "/setup-grammar")
        XCTAssertEqual(turns[0].role, "user")
        XCTAssertEqual(turns[0].metadata["source"], "sample_01.csv")
        XCTAssertEqual(turns[1].content, "Grammar created.")
        XCTAssertEqual(turns[1].toolUses?.first?.name, "rawview-setup-grammar")

        // Verify physical file path: .rawviewer/session/YYYY-MM-DD/<sessionId>.jsonl
        let expectedFile = store.fileURL(sessionId: sessionId, date: testDate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFile.path))
        XCTAssertTrue(expectedFile.path.contains(".rawviewer/session/"))
    }

    func testCorruptedLineIsSkippedGracefully() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(projectRoot: tempDir)
        let sessionId = UUID()
        let testDate = Date(timeIntervalSince1970: 1776345600)

        // Write one valid turn
        let validTurn = ChatTurn(role: "user", content: "Hello AI")
        try await store.appendTurn(validTurn, sessionId: sessionId, date: testDate)

        // Directly append corrupted lines and empty lines to the file
        let file = store.fileURL(sessionId: sessionId, date: testDate)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let corruptedData = "NOT_A_VALID_JSON_LINE\n{\"broken\":true\n\n".data(using: .utf8)!
        try handle.write(contentsOf: corruptedData)
        try handle.close()

        // Append a second valid turn
        let validTurn2 = ChatTurn(role: "assistant", content: "Hello human")
        try await store.appendTurn(validTurn2, sessionId: sessionId, date: testDate)

        // Load turns: only the 2 valid turns should be returned
        let turns = try await store.loadTurns(sessionId: sessionId, date: testDate)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].content, "Hello AI")
        XCTAssertEqual(turns[1].content, "Hello human")
    }
}
