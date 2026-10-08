import Testing
@testable import RawViewCore

struct AxisFormatterTests {
    @Test func scalesMicroAmperesProperly() {
        let values: [Double] = [0.0, 5e-6, 10e-6, 15e-6]
        let info = AxisFormatter.scaleInfo(for: values, baseUnit: "A")
        #expect(info.factor == 1e-6)
        #expect(info.prefix == "µ")
        #expect(info.displayUnit == "µA")

        #expect(AxisFormatter.formatTick(0.0, factor: info.factor) == "0.0")
        #expect(AxisFormatter.formatTick(5e-6, factor: info.factor) == "5.0")
        #expect(AxisFormatter.formatTick(15e-6, factor: info.factor) == "15.0")
    }

    @Test func scalesKiloCountsProperly() {
        let values: [Double] = [0.0, 40000.0, 80000.0, 120000.0]
        let info = AxisFormatter.scaleInfo(for: values, baseUnit: "counts")
        #expect(info.factor == 1000.0)
        #expect(info.prefix == "k")
        #expect(info.displayUnit == "kcounts")

        #expect(AxisFormatter.formatTick(0.0, factor: info.factor) == "0.0")
        #expect(AxisFormatter.formatTick(40000.0, factor: info.factor) == "40.0")
        #expect(AxisFormatter.formatTick(120000.0, factor: info.factor) == "120.0")
    }

    @Test func preservesUnscaledVoltsInRange() {
        let values: [Double] = [-5.0, 0.0, 2.5, 5.0]
        let info = AxisFormatter.scaleInfo(for: values, baseUnit: "V")
        #expect(info.factor == 1.0)
        #expect(info.prefix == "")
        #expect(info.displayUnit == "V")

        #expect(AxisFormatter.formatTick(-5.0, factor: info.factor) == "-5.0")
        #expect(AxisFormatter.formatTick(0.0, factor: info.factor) == "0.0")
        #expect(AxisFormatter.formatTick(2.5, factor: info.factor) == "2.5")
    }

    @Test func normalizesCmMinusOne() {
        let values: [Double] = [760.0, 1400.0, 2000.0]
        let info = AxisFormatter.scaleInfo(for: values, baseUnit: "cm-1")
        #expect(info.factor == 1000.0)
        #expect(info.displayUnit == "kcm⁻¹")

        #expect(AxisFormatter.formatTick(760.0, factor: info.factor) == "0.8")
        #expect(AxisFormatter.formatTick(1400.0, factor: info.factor) == "1.4")
        #expect(AxisFormatter.formatTick(2000.0, factor: info.factor) == "2.0")
    }

    @Test func avoidsNegativeZero() {
        #expect(AxisFormatter.formatTick(-0.000000001, factor: 1.0) == "0.0")
    }
}
