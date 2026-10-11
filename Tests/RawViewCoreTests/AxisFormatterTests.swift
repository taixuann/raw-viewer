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
}
