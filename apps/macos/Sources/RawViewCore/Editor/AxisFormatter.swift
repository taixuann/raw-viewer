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

        let intervals = max(1, maxTicks - 1)
        let rawStep = span / Double(intervals)
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

        let firstScaled = ceil((sLo - 1e-12 * scaledStep) / scaledStep) * scaledStep
        let lastScaled = floor((sHi + 1e-12 * scaledStep) / scaledStep) * scaledStep

        var rawTicks: [Double] = []
        var currScaled = firstScaled
        let displayPrecision: Int = {
            if exponent >= 0 {
                return (scaledStep.truncatingRemainder(dividingBy: 1.0) == 0) ? 0 : 1
            } else {
                return max(0, Int(-exponent) + (niceFraction == 2.5 ? 1 : 0))
            }
        }()

        while currScaled <= lastScaled + scaledStep * 1e-6 {
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

    /// Computes exactly `count` evenly-spaced ticks across `[lower, upper]` (`count - 1` equal intervals).
    public static func exactUniformTicks(
        lower: Double,
        upper: Double,
        factor: Double = 1.0,
        count: Int
    ) -> NiceTicksResult {
        guard lower.isFinite, upper.isFinite, lower < upper else {
            let single = lower.isFinite ? lower : 0.0
            return NiceTicksResult(tickValues: [single], step: 1.0, precision: 0)
        }
        let n = max(2, count)
        let effectiveFactor = (factor != 0 && factor.isFinite) ? factor : 1.0
        let step = (upper - lower) / Double(n - 1)
        let scaledStep = abs(step / effectiveFactor)

        let displayPrecision: Int = {
            guard scaledStep > 0 else { return 0 }
            let exp = floor(log10(scaledStep))
            let base = max(0, Int(-exp))
            let scaledCheck = scaledStep * pow(10.0, Double(base))
            let frac = abs(scaledCheck - scaledCheck.rounded())
            return min(4, frac > 1e-3 ? base + 1 : base)
        }()

        var ticks: [Double] = []
        ticks.reserveCapacity(n)
        for i in 0..<n {
            var val = lower + Double(i) * step
            if abs(val) < step * 1e-9 {
                val = 0.0
            }
            ticks.append(val)
        }
        return NiceTicksResult(tickValues: ticks, step: step, precision: displayPrecision)
    }

    /// Dispatches between Auto nice ticks (`requestedCount <= 0`) and exact uniform ticks (`requestedCount >= 2`).
    public static func ticks(
        lower: Double,
        upper: Double,
        factor: Double = 1.0,
        requestedCount: Int
    ) -> NiceTicksResult {
        if requestedCount >= 2 {
            return exactUniformTicks(lower: lower, upper: upper, factor: factor, count: requestedCount)
        }
        return niceTicks(lower: lower, upper: upper, factor: factor, maxTicks: 5)
    }

    /// Generates minor tick values in original raw data coordinates between major ticks
    /// and optionally extending into outer margins within `[lower, upper]`.
    public static func minorTicks(
        majorTicks: [Double],
        step: Double,
        subdivisions: Int,
        lower: Double? = nil,
        upper: Double? = nil
    ) -> [Double] {
        guard subdivisions > 1, !majorTicks.isEmpty, step > 0 else { return [] }
        let subStep = step / Double(subdivisions)
        var result: [Double] = []
        let firstAnchor = majorTicks.first!
        let lastAnchor = majorTicks.last!

        if let lo = lower, lo < firstAnchor {
            var base = firstAnchor - step
            while base + step > lo {
                for k in 1..<subdivisions {
                    let val = base + Double(k) * subStep
                    if val > lo + subStep * 1e-6 && val < firstAnchor - subStep * 1e-6 {
                        result.append(val)
                    }
                }
                base -= step
            }
        }

        if majorTicks.count >= 2 {
            for i in 0..<(majorTicks.count - 1) {
                let start = majorTicks[i]
                for k in 1..<subdivisions {
                    let val = start + Double(k) * subStep
                    result.append(val)
                }
            }
        }

        if let hi = upper, hi > lastAnchor {
            var base = lastAnchor
            while base < hi {
                for k in 1..<subdivisions {
                    let val = base + Double(k) * subStep
                    if val > lastAnchor + subStep * 1e-6 && val < hi - subStep * 1e-6 {
                        result.append(val)
                    }
                }
                base += step
            }
        }

        return result.sorted()
    }
}
