import Foundation

/// Fast bounded file preview utility to read the head of large data files without loading entire content into memory.
public enum FilePreviewReader {
    public static func loadSampleHead(url: URL, lines: Int = 30, maxBytes: Int = 16384) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let headData = try? handle.read(upToCount: maxBytes), !headData.isEmpty else { return "" }
        guard let text = String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .ascii) else {
            return ""
        }
        let rows = text.components(separatedBy: .newlines)
        return rows.prefix(lines).joined(separator: "\n")
    }
}
