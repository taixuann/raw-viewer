import Foundation

/// Represents a single tool execution record within a chat turn.
public struct ToolUseRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let input: String?
    public let output: String?

    public init(
        id: String,
        name: String,
        status: String,
        input: String? = nil,
        output: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.input = input
        self.output = output
    }
}

/// A single turn in an AI chat conversation (user prompt or assistant response).
public struct ChatTurn: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let role: String
    public var content: String
    public var metadata: [String: String]
    public var toolUses: [ToolUseRecord]?
    public var error: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        role: String,
        content: String,
        metadata: [String: String] = [:],
        toolUses: [ToolUseRecord]? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.role = role
        self.content = content
        self.metadata = metadata
        self.toolUses = toolUses
        self.error = error
    }
}

/// Actor managing append-only JSONL session files under `<project>/.rawviewer/session/<YYYY-MM-DD>/<session-id>.jsonl`.
/// Inspired by OakReader's SessionStore architecture.
public actor SessionStore {
    public let projectRoot: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static func formatDayString(date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents(in: TimeZone.current, from: date)
        let year = comps.year ?? 1970
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Resolves the daily session directory: `.rawviewer/session/YYYY-MM-DD/`
    nonisolated public func dailyDirectory(for date: Date = Date()) -> URL {
        let dateString = Self.formatDayString(date: date)
        return projectRoot
            .appendingPathComponent(".rawviewer", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent(dateString, isDirectory: true)
    }

    /// Resolves the path to a session's `.jsonl` file.
    nonisolated public func fileURL(sessionId: UUID, date: Date = Date()) -> URL {
        dailyDirectory(for: date).appendingPathComponent("\(sessionId.uuidString).jsonl")
    }

    /// Appends a new turn as a line of JSON followed by a newline.
    public func appendTurn(_ turn: ChatTurn, sessionId: UUID, date: Date = Date()) throws {
        let dir = dailyDirectory(for: date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = fileURL(sessionId: sessionId, date: date)

        var data = try encoder.encode(turn)
        data.append(0x0A)

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    /// Reads and decodes all turns from the session file line by line.
    public func loadTurns(sessionId: UUID, date: Date = Date()) throws -> [ChatTurn] {
        let url = fileURL(sessionId: sessionId, date: date)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ChatTurn.self, from: data)
        }
    }
}
