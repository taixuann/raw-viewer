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

    @Test func discreteKeyTreatsEmptyCellsAsCycleOne() {
        #expect(ProgressionPlotReader.discreteKey(from: "") == "1")
        #expect(ProgressionPlotReader.discreteKey(from: nil as Double?) == "1")
        #expect(ProgressionPlotReader.discreteKey(from: Double.nan) == "1")
    }

    @Test func emptyProgressionCellSegmentsAsCycleOne() {
        let col = ProfileColumnV3(
            id: "step",
            source: ColumnSourceV3(header: "Step"),
            label: "Step",
            quantity: "index",
            role: .progression,
            progression: ColumnProgressionV3(type: .index, behavior: .discrete))
        let x: [Double?] = [0, 1]
        let y: [Double?] = [5, 6]
        let prog: [Double?] = [nil, 1]
        let segments = ProgressionPlotReader.segments(x: x, y: y, progression: prog, column: col)
        #expect(segments.map(\.name).sorted() == ["1"])
        #expect(segments[0].points.count == 2)
    }

    @Test func inferredContinuousFromTimeColumnName() {
        let col = ProfileColumnV3(
            id: "scan_time",
            source: ColumnSourceV3(header: "t"),
            label: "Scan duration",
            quantity: "time",
            role: .progression,
            progression: ColumnProgressionV3(type: .index, behavior: nil))
        #expect(ProgressionPlotReader.isContinuousBehavior(column: col, distinctDiscreteKeys: 3) == true)
    }

    @Test func inferredContinuousFromProgressionTypeTime() {
        let col = ProfileColumnV3(
            id: "elapsed",
            source: ColumnSourceV3(header: "Elapsed"),
            label: "Elapsed",
            quantity: "generic",
            role: .progression,
            progression: ColumnProgressionV3(type: .time, behavior: nil))
        #expect(ProgressionPlotReader.isContinuousBehavior(column: col, distinctDiscreteKeys: 2) == true)
    }

    @Test func inferredContinuousFromHighCardinality() {
        let col = ProfileColumnV3(
            id: "step",
            source: ColumnSourceV3(header: "Step"),
            label: "Step",
            quantity: "index",
            role: .progression,
            progression: ColumnProgressionV3(type: .index, behavior: nil))
        #expect(ProgressionPlotReader.isContinuousBehavior(column: col, distinctDiscreteKeys: 51) == true)
        #expect(ProgressionPlotReader.isContinuousBehavior(column: col, distinctDiscreteKeys: 50) == false)
    }

    @Test func inferredContinuousSegmentsUseTimeWindow() {
        let col = ProfileColumnV3(
            id: "step",
            source: ColumnSourceV3(header: "Step"),
            label: "Step",
            quantity: "index",
            role: .progression,
            progression: ColumnProgressionV3(type: .index, behavior: nil))
        var x: [Double?] = []
        var y: [Double?] = []
        var prog: [Double?] = []
        for index in 0..<60 {
            x.append(Double(index))
            y.append(Double(index))
            prog.append(Double(index))
        }
        let segments = ProgressionPlotReader.segments(x: x, y: y, progression: prog, column: col)
        #expect(segments.count == 1)
        #expect(segments[0].name == "Time Window")
        #expect(segments[0].points.count == 60)
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
