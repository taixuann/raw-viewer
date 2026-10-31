import Foundation
import Testing
@testable import RawViewCore

struct ProgressionPlotReaderTests {
    private func timeColumn(behavior: ProgressionBehaviorV3) -> ProfileColumnV3 {
        ProfileColumnV3(
            id: "elapsed",
            source: ColumnSourceV3(header: "Time (s)"),
            label: "Time",
            quantity: "time",
            unit: "s",
            role: .progression,
            progression: ColumnProgressionV3(type: .time, behavior: behavior))
    }

    @Test func continuousBehaviorHonorsExplicitMetadata() {
        let col = timeColumn(behavior: .continuous)
        #expect(ProgressionPlotReader.isContinuousBehavior(column: col, distinctDiscreteKeys: 3) == true)
        let discrete = timeColumn(behavior: .discrete)
        #expect(ProgressionPlotReader.isContinuousBehavior(column: discrete, distinctDiscreteKeys: 200) == false)
    }

    @Test func discreteSegmentsFilterSelectedCycles() {
        let col = ProfileColumnV3(
            id: "step",
            source: ColumnSourceV3(header: "Step"),
            label: "Step",
            quantity: "index",
            role: .progression,
            progression: ColumnProgressionV3(type: .index, behavior: .discrete))
        let x: [Double?] = [0, 1, 2, 3]
        let y: [Double?] = [10, 11, 20, 21]
        let prog: [Double?] = [1, 1, 2, 2]
        let all = ProgressionPlotReader.segments(
            x: x, y: y, progression: prog, column: col)
        #expect(all.count == 2)
        #expect(all.map(\.name).sorted() == ["1", "2"])
        let filtered = ProgressionPlotReader.segments(
            x: x, y: y, progression: prog, column: col, selectedDiscreteKeys: ["2"])
        #expect(filtered.count == 1)
        #expect(filtered[0].name == "2")
        #expect(filtered[0].points.count == 2)
    }

    @Test func continuousWindowFiltersByProgressionValues() {
        let col = timeColumn(behavior: .continuous)
        let x: [Double?] = [0, 1, 2, 3]
        let y: [Double?] = [1, 2, 3, 4]
        let prog: [Double?] = [0, 0.5, 1.0, 1.5]
        let window = ProgressionPlotReader.segments(
            x: x, y: y, progression: prog, column: col, timeStart: 0.25, timeStop: 1.0)
        #expect(window.count == 1)
        #expect(window[0].points.count == 2)
        #expect(window[0].points.map(\.0) == [1, 2])
    }
}
