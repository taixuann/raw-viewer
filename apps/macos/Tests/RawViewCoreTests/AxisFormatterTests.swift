import XCTest
@testable import RawViewCore

final class AxisFormatterTests: XCTestCase {
    func testScalesMicroAmperesProperly() {
        let values: [Double] = [0.0, 5e-6, 10e-6, 15e-6]
        let info = AxisFormatter.scaleInfo(for: values, baseUnit: "A")
        XCTAssertEqual(info.factor, 1e-6)
        XCTAssertEqual(info.prefix, "µ")
        XCTAssertEqual(info.displayUnit, "µA")

        XCTAssertEqual(AxisFormatter.formatTick(0.0, factor: info.factor), "0.0")
        XCTAssertEqual(AxisFormatter.formatTick(5e-6, factor: info.factor), "5.0")
        XCTAssertEqual(AxisFormatter.formatTick(15e-6, factor: info.factor), "15.0")
    }

    func testScalesKiloCountsProperly() {
        let values: [Double] = [0.0, 40000.0, 80000.0, 120000.0]
        let info = AxisFormatter.scaleInfo(for: values, baseUnit: "counts")
        XCTAssertEqual(info.factor, 1000.0)
        XCTAssertEqual(info.prefix, "k")
        XCTAssertEqual(info.displayUnit, "kcounts")

        XCTAssertEqual(AxisFormatter.formatTick(0.0, factor: info.factor), "0.0")
        XCTAssertEqual(AxisFormatter.formatTick(40000.0, factor: info.factor), "40.0")
        XCTAssertEqual(AxisFormatter.formatTick(120000.0, factor: info.factor), "120.0")
    }

    func testPreservesUnscaledVoltsInRange() {
        let values: [Double] = [-5.0, 0.0, 2.5, 5.0]
        let info = AxisFormatter.scaleInfo(for: values, baseUnit: "V")
        XCTAssertEqual(info.factor, 1.0)
        XCTAssertEqual(info.prefix, "")
        XCTAssertEqual(info.displayUnit, "V")

        XCTAssertEqual(AxisFormatter.formatTick(-5.0, factor: info.factor), "-5.0")
        XCTAssertEqual(AxisFormatter.formatTick(0.0, factor: info.factor), "0.0")
        XCTAssertEqual(AxisFormatter.formatTick(2.5, factor: info.factor), "2.5")
    }

    func testNormalizesCmMinusOne() {
        let values: [Double] = [760.0, 1400.0, 2000.0]
        let info = AxisFormatter.scaleInfo(for: values, baseUnit: "cm-1")
        XCTAssertEqual(info.factor, 1000.0)
        XCTAssertEqual(info.displayUnit, "kcm⁻¹")

        XCTAssertEqual(AxisFormatter.formatTick(760.0, factor: info.factor), "0.8")
        XCTAssertEqual(AxisFormatter.formatTick(1400.0, factor: info.factor), "1.4")
        XCTAssertEqual(AxisFormatter.formatTick(2000.0, factor: info.factor), "2.0")
    }

    func testAvoidsNegativeZero() {
        XCTAssertEqual(AxisFormatter.formatTick(-0.000000001, factor: 1.0), "0.0")
    }

    func testNiceTicksPassesThroughExactZeroAndProducesCleanRounds() {
        // Range equivalent to -540 mV to 540 mV in V (factor = 1e-3)
        let res = AxisFormatter.niceTicks(lower: -0.540, upper: 0.540, factor: 1e-3, maxTicks: 5)
        XCTAssertTrue(res.tickValues.contains(0.0), "Ticks must pass through exact zero")
        XCTAssertEqual(res.precision, 0)
        // Check formatted strings
        let formatted = res.tickValues.map { AxisFormatter.formatTick($0, factor: 1e-3, precision: res.precision) }
        XCTAssertTrue(formatted.contains("0"))
        for s in formatted {
            XCTAssertFalse(s.contains(".2"), "Tick '\(s)' must not have odd -0.2 offset")
        }
    }

    func testNiceTicksMicroAmperes() {
        // Range -14 uA to 16 uA in A (factor = 1e-6)
        let res = AxisFormatter.niceTicks(lower: -14e-6, upper: 16e-6, factor: 1e-6, maxTicks: 5)
        XCTAssertTrue(res.tickValues.contains(0.0))
        let formatted = res.tickValues.map { AxisFormatter.formatTick($0, factor: 1e-6, precision: res.precision) }
        XCTAssertTrue(formatted.contains("0"))
    }

    func testCustomTickCounts() {
        let res3 = AxisFormatter.niceTicks(lower: 0, upper: 100, factor: 1.0, maxTicks: 3)
        XCTAssertLessThanOrEqual(res3.tickValues.count, 5)

        let res8 = AxisFormatter.niceTicks(lower: 0, upper: 100, factor: 1.0, maxTicks: 8)
        XCTAssertGreaterThanOrEqual(res8.tickValues.count, 4)
    }

    func testMinorTicksSubdivision() {
        let majors = [0.0, 10.0, 20.0]
        let minors = AxisFormatter.minorTicks(majorTicks: majors, step: 10.0, subdivisions: 2)
        XCTAssertEqual(minors, [5.0, 15.0])

        let minors4 = AxisFormatter.minorTicks(majorTicks: majors, step: 10.0, subdivisions: 4)
        XCTAssertEqual(minors4, [2.5, 5.0, 7.5, 12.5, 15.0, 17.5])

        // Outer margins included when lower/upper provided
        let minorsOuter = AxisFormatter.minorTicks(
            majorTicks: [2.0, 4.0],
            step: 2.0,
            subdivisions: 2,
            lower: 0.5,
            upper: 5.5
        )
        XCTAssertEqual(minorsOuter, [1.0, 3.0, 5.0])
    }

    func testExactUniformTicksAlwaysMatchesRequestedCount() {
        let res5 = AxisFormatter.exactUniformTicks(lower: 0.0, upper: 10.0, factor: 1.0, count: 5)
        XCTAssertEqual(res5.tickValues.count, 5)
        XCTAssertEqual(res5.tickValues, [0.0, 2.5, 5.0, 7.5, 10.0])

        let res7 = AxisFormatter.ticks(lower: -0.2, upper: 1.0, factor: 1.0, requestedCount: 7)
        XCTAssertEqual(res7.tickValues.count, 7)
        XCTAssertEqual(res7.tickValues.first!, -0.2, accuracy: 1e-9)
        XCTAssertEqual(res7.tickValues.last!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(res7.tickValues[1] - res7.tickValues[0], res7.tickValues[2] - res7.tickValues[1], accuracy: 1e-9)
    }

    func testNormalizeDateGranularities() {
        // USTH lab format DDMMYY-HHmmss (Day: 10, Month: 08, Year: 26 -> 2026)
        let usth = "100826-102100"
        XCTAssertEqual(FilenameGrammarEngine.normalizeDate(usth, formatHint: "DDMMYY-HHmmSS", granularity: .year), "2026")
        XCTAssertEqual(FilenameGrammarEngine.normalizeDate(usth, formatHint: "DDMMYY-HHmmSS", granularity: .month), "2026-08")
        XCTAssertEqual(FilenameGrammarEngine.normalizeDate(usth, formatHint: "DDMMYY-HHmmSS", granularity: .day), "2026-08-10")
        XCTAssertEqual(FilenameGrammarEngine.normalizeDate(usth, formatHint: "DDMMYY-HHmmSS", granularity: .raw), usth)

        // ISO format YYYY-MM-DD
        let iso = "2026-08-10"
        XCTAssertEqual(FilenameGrammarEngine.normalizeDate(iso, granularity: .year), "2026")
        XCTAssertEqual(FilenameGrammarEngine.normalizeDate(iso, granularity: .month), "2026-08")
        XCTAssertEqual(FilenameGrammarEngine.normalizeDate(iso, granularity: .day), "2026-08-10")
    }
}
