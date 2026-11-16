import XCTest
@testable import RawViewCore

final class PlotMemoTests: XCTestCase {
    /// Models repeated mouse moves over an unchanged plot: each move reads the
    /// prepared transform with the same key. The transform must run once.
    func testHoverDoesNotRerunTransform() {
        let source: [Double?] = [1, nil, 4, 9]
        var transformRuns = 0
        let memo = PlotMemo<[String], [Double?]>()
        let linearKey = ["x", "linear", "absolute:false"]
        let transform = { () -> [Double?] in
            transformRuns += 1
            return source.map { $0.map { log10($0) } }
        }

        var lastResult: [Double?] = []
        for _ in 0..<500 {
            lastResult = memo.value(for: linearKey, compute: transform)
        }

        XCTAssertEqual(memo.computeCount, 1)
        XCTAssertEqual(transformRuns, 1)
        XCTAssertEqual(lastResult, [0, nil, log10(4), log10(9)])

        let logKey = ["x", "log", "absolute:false"]
        _ = memo.value(for: logKey, compute: transform)
        _ = memo.value(for: logKey, compute: transform)
        XCTAssertEqual(memo.computeCount, 2)
        XCTAssertEqual(transformRuns, 2)
    }
}
