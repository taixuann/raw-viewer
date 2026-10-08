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
        if abs(scaled) < 1e-9 {
            return "0.0"
        }
        let formatStr = "%.\(max(0, precision))f"
        return String(format: formatStr, scaled)
    }
}
