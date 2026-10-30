import XCTest
@testable import RawViewCore

final class FilePreviewPerformanceTests: XCTestCase {
    func testSampleHeadReadsOnlyHeadFromLargeFile() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let dummyLine = "1.000, 2.000, 3.000, 4.000\n"
        let data = Data(String(repeating: dummyLine, count: 50_000).utf8) // ~1.4 MB
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let preview = FilePreviewReader.loadSampleHead(url: tempURL, lines: 10)
        let rows = preview.components(separatedBy: .newlines)
        XCTAssertEqual(rows.count, 10)
        XCTAssertTrue(rows.first?.contains("1.000, 2.000") == true)
    }
}
