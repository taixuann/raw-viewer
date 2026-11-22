import XCTest
@testable import RawViewCore

final class PlotDownsamplerTests: XCTestCase {
    /// Columns 0 covers x 0...99 and column 1 covers x 100...199 when columns == 2.
    /// Base y cycles 10...14, so the planted extremes are the only per-column min and max.
    func testDownsamplerKeepsExtremesOfEachPixelColumn() {
        let x = (0..<200).map(Double.init)
        let y = (0..<200).map { index -> Double in
            switch index {
            case 37: return -5
            case 62: return 40
            case 101: return 77
            case 150: return -9
            default: return Double(10 + index % 5)
            }
        }

        let kept = PlotDownsampler.keptIndices(x: x, y: y, columns: 2)

        XCTAssertEqual(kept, [0, 37, 62, 101, 150, 199])
        XCTAssertEqual(kept.map { y[$0] }, [10, -5, 40, 77, -9, 14])
    }

    func testOneSampleSpikeSurvivesDownsampling() {
        let x = (0..<1000).map(Double.init)
        var y = [Double](repeating: 1, count: 1000)
        y[613] = 500

        let kept = PlotDownsampler.keptIndices(x: x, y: y, columns: 50)

        XCTAssertTrue(kept.contains(613))
        XCTAssertEqual(kept.map { y[$0] }.max(), 500)
        XCTAssertEqual(kept.first, 0)
        XCTAssertEqual(kept.last, 999)
        XCTAssertLessThan(kept.count, 1000)
    }

    func testBelowThresholdSeriesIsNotDownsampled() {
        XCTAssertFalse(PlotDownsampler.needsDownsampling(pointCount: 400, plotWidth: 100))
        XCTAssertTrue(PlotDownsampler.needsDownsampling(pointCount: 401, plotWidth: 100))
        XCTAssertFalse(PlotDownsampler.needsDownsampling(pointCount: 4, plotWidth: 0))
        XCTAssertTrue(PlotDownsampler.needsDownsampling(pointCount: 5, plotWidth: 0))
    }

    /// Downsampling only selects original samples, so bounds computed from the
    /// kept subset match bounds from the full series. The cursor readout relies on that.
    func testCursorReadoutUsesOriginalSamples() {
        let count = 10_000
        let x = (0..<count).map(Double.init)
        var y = (0..<count).map { Double(($0 * 37) % 1000) - 500 }
        y[4321] = -700
        y[7777] = 900

        let kept = PlotDownsampler.keptIndices(x: x, y: y, columns: 200)
        let drawn = kept.map { y[$0] }

        XCTAssertLessThan(kept.count, count)
        XCTAssertEqual(y.min(), -700)
        XCTAssertEqual(y.max(), 900)
        XCTAssertEqual(drawn.min(), -700)
        XCTAssertEqual(drawn.max(), 900)
        XCTAssertEqual(kept.map { x[$0] }, kept.map(Double.init))
    }
}
