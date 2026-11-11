import Foundation

public struct AxisFormatter: Sendable {
    public struct ScaleInfo: Sendable, Equatable {
        public let factor: Double
        public let prefix: String
        public let displayUnit: String

        public init(factor: Double, prefix: String, displayUnit: String) {
            self.factor = factor
            self.prefix = prefix
            self.displayUnit = displayUnit
        }
    }

    /// Determines the optimal 10^(3k) SI scale factor and display unit string
    /// so tick values remain within a comfortable [0.1 ... 999.9] range.
    public static func scaleInfo(for values: [Double], baseUnit: String) -> ScaleInfo {
        let finite = values.filter { $0.isFinite && $0 != 0 }
        guard let maxVal = finite.map({ abs($0) }).max(), maxVal > 0 else {
            return ScaleInfo(factor: 1.0, prefix: "", displayUnit: normalizedUnit(baseUnit))
        }

        let cleanBase = normalizedUnit(baseUnit)

        let factor: Double
        let prefix: String

        if maxVal >= 1e12 {
            factor = 1e12; prefix = "T"
        } else if maxVal >= 1e9 {
            factor = 1e9; prefix = "G"
        } else if maxVal >= 1e6 {
            factor = 1e6; prefix = "M"
        } else if maxVal >= 1e3 {
            factor = 1e3; prefix = "k"
        } else if maxVal >= 1.0 {
            factor = 1.0; prefix = ""
        } else if maxVal >= 1e-3 {
            factor = 1e-3; prefix = "m"
        } else if maxVal >= 1e-6 {
            factor = 1e-6; prefix = "µ"
        } else if maxVal >= 1e-9 {
            factor = 1e-9; prefix = "n"
        } else if maxVal >= 1e-12 {
            factor = 1e-12; prefix = "p"
        } else {
            factor = 1.0; prefix = ""
        }

        let combinedUnit: String
        if prefix.isEmpty {
            combinedUnit = cleanBase
        } else if cleanBase.isEmpty {
            combinedUnit = "10³"
        } else if cleanBase.hasPrefix("k") || cleanBase.hasPrefix("M") || cleanBase.hasPrefix("m") || cleanBase.hasPrefix("µ") {
            combinedUnit = "\(prefix)\(cleanBase)"
        } else {
            combinedUnit = "\(prefix)\(cleanBase)"
        }

        return ScaleInfo(factor: factor, prefix: prefix, displayUnit: combinedUnit)
    }

    /// Normalizes common scientific unit representations (e.g. "cm-1" -> "cm⁻¹").
    public static func normalizedUnit(_ unit: String) -> String {
        unit.replacingOccurrences(of: "cm-1", with: "cm⁻¹")
            .replacingOccurrences(of: "cm^-1", with: "cm⁻¹")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Formats a tick value scaled by `factor` into regular decimal "XXX.X" format.
    /// Guaranteed to never produce scientific "E" notation.
    public static func formatTick(_ value: Double, factor: Double = 1.0, precision: Int = 1) -> String {
        guard value.isFinite else { return "—" }
        let scaled = factor != 0 ? (value / factor) : value
        let formatStr = "%.\(max(0, precision))f"
        var formatted = String(format: formatStr, scaled)
        if formatted.hasPrefix("-") {
            let withoutMinus = String(formatted.dropFirst())
            if withoutMinus.allSatisfy({ $0 == "0" || $0 == "." }) {
                formatted = withoutMinus
            }
        }
        return formatted
    }

    public struct NiceTicksResult: Sendable, Equatable {
        /// Tick values in original raw data coordinates
        public let tickValues: [Double]
        /// Step in raw data coordinates
        public let step: Double
        /// Display precision (digits after decimal point) when formatted with factor
        public let precision: Int

        public init(tickValues: [Double], step: Double, precision: Int) {
            self.tickValues = tickValues
            self.step = step
            self.precision = precision
        }
    }

    /// Computes scientific "nice ticks" (multiples of 1, 2, 2.5, 5 * 10^k in scaled space)
    /// across [lower, upper]. Ticks are guaranteed to pass cleanly through 0 (if in range)
    /// and avoid floating point rounding noise like "-0.2" at the origin.
    public static func niceTicks(
        lower: Double,
        upper: Double,
        factor: Double = 1.0,
        maxTicks: Int = 5
    ) -> NiceTicksResult {
        guard lower.isFinite, upper.isFinite, lower < upper else {
            let single = lower.isFinite ? lower : 0.0
            return NiceTicksResult(tickValues: [single], step: 1.0, precision: 0)
        }
        let effectiveFactor = (factor != 0 && factor.isFinite) ? factor : 1.0
        let sLo = lower / effectiveFactor
        let sHi = upper / effectiveFactor
        let span = sHi - sLo
        guard span > 0 else {
            return NiceTicksResult(tickValues: [lower], step: 1.0, precision: 0)
        }

        let rawStep = span / Double(max(2, maxTicks))
        let exponent = floor(log10(rawStep))
        let mag = pow(10.0, exponent)
        let fraction = rawStep / mag

        let niceFraction: Double
        if fraction <= 1.5 {
            niceFraction = 1.0
        } else if fraction <= 3.0 {
            niceFraction = fraction <= 2.2 ? 2.0 : 2.5
        } else if fraction <= 7.0 {
            niceFraction = 5.0
        } else {
            niceFraction = 10.0
        }
        let scaledStep = niceFraction * mag
        let rawStepActual = scaledStep * effectiveFactor

        let firstScaled = ceil(sLo / scaledStep) * scaledStep
        let lastScaled = floor(sHi / scaledStep) * scaledStep

        var rawTicks: [Double] = []
        var currScaled = firstScaled
        let displayPrecision: Int = {
            if exponent >= 0 {
                return (scaledStep.truncatingRemainder(dividingBy: 1.0) == 0) ? 0 : 1
            } else {
                return max(0, Int(-exponent) + (niceFraction == 2.5 ? 1 : 0))
            }
        }()

        while currScaled <= lastScaled + scaledStep * 0.5 {
            var rawVal = currScaled * effectiveFactor
            if abs(currScaled) < 1e-12 {
                rawVal = 0.0
            }
            rawTicks.append(rawVal)
            currScaled += scaledStep
        }

        if rawTicks.isEmpty {
            rawTicks = [(lower + upper) / 2.0]
        }

        return NiceTicksResult(tickValues: rawTicks, step: rawStepActual, precision: displayPrecision)
    }

    /// Generates minor tick values in original raw data coordinates between major ticks.
    public static func minorTicks(
        majorTicks: [Double],
        step: Double,
        subdivisions: Int
    ) -> [Double] {
        guard subdivisions > 1, majorTicks.count >= 2, step > 0 else { return [] }
        let subStep = step / Double(subdivisions)
        var result: [Double] = []
        for i in 0..<(majorTicks.count - 1) {
            let start = majorTicks[i]
            for k in 1..<subdivisions {
                let val = start + Double(k) * subStep
                result.append(val)
            }
        }
        return result
    }
}
