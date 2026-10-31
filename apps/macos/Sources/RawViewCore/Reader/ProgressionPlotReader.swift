import Foundation

/// Named segment of (x, y) points grouped by a progression dimension (cycle,
/// time window, etc.). Extracted from the former Profile Studio sandbox plot
/// so Explorer and future schema work can share one reader.
public struct ProgressionPlotSegment: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let points: [(x: Double, y: Double)]

    public init(name: String, points: [(x: Double, y: Double)]) {
        self.name = name
        self.points = points
    }

    public static func == (lhs: ProgressionPlotSegment, rhs: ProgressionPlotSegment) -> Bool {
        guard lhs.name == rhs.name, lhs.points.count == rhs.points.count else { return false }
        for index in lhs.points.indices {
            let left = lhs.points[index]
            let right = rhs.points[index]
            if left.x != right.x || left.y != right.y {
                return false
            }
        }
        return true
    }
}

public enum ProgressionPlotReader {
    /// Whether progression values behave as a continuous time/index range vs
    /// discrete cycles/steps. Mirrors the sandbox heuristics: explicit v3
    /// `behavior` wins; otherwise time-typed or high-cardinality numeric
    /// columns are treated as continuous.
    public static func isContinuousBehavior(column: ProfileColumnV3, distinctDiscreteKeys: Int) -> Bool {
        if let behavior = column.progression?.behavior {
            return behavior == .continuous
        }
        let nameLower = column.id.lowercased()
        let labelLower = column.label.lowercased()
        let isTimeNamed = column.progression?.type == .time
            || nameLower.contains("time")
            || labelLower.contains("time")
        let hasHighCardinality = distinctDiscreteKeys > 50
        return isTimeNamed || hasHighCardinality
    }

    /// Normalizes one progression cell into a stable segment key string.
    public static func discreteKey(from value: Double?) -> String {
        guard let value, value.isFinite else { return "1" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))"
        }
        return String(format: "%.3f", value)
    }

    public static func discreteKey(from string: String) -> String {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if let d = Double(normalized), d.isFinite {
            return discreteKey(from: d)
        }
        return normalized.isEmpty ? "1" : normalized
    }

    /// Builds plot segments for aligned x, y, and progression channel arrays.
    /// Nil x or y at a row skips that row. For continuous behavior, optional
    /// `timeStart`/`timeStop` filter on progression numeric values.
    public static func segments(
        x: [Double?],
        y: [Double?],
        progression: [Double?]?,
        column: ProfileColumnV3,
        selectedDiscreteKeys: Set<String> = [],
        timeStart: Double? = nil,
        timeStop: Double? = nil
    ) -> [ProgressionPlotSegment] {
        let count = min(x.count, y.count)
        guard count > 0 else { return [] }

        var progStrings: [String] = []
        progStrings.reserveCapacity(count)
        var continuousValues: [Double] = []
        for index in 0..<count {
            if let progression {
                if index < progression.count {
                    if let raw = progression[index], raw.isFinite {
                        continuousValues.append(raw)
                        progStrings.append(discreteKey(from: raw))
                    } else {
                        progStrings.append(discreteKey(from: ""))
                    }
                } else {
                    progStrings.append("default")
                }
            } else {
                progStrings.append("default")
            }
        }

        let distinctKeys = Set(progStrings.filter { $0 != "default" })
        let continuous = isContinuousBehavior(column: column, distinctDiscreteKeys: distinctKeys.count)

        if continuous {
            let startLimit = timeStart ?? continuousValues.min() ?? 0
            let stopLimit = timeStop ?? continuousValues.max() ?? 1
            var slice: [(Double, Double)] = []
            for index in 0..<count {
                guard let xVal = x[index], let yVal = y[index], xVal.isFinite, yVal.isFinite else { continue }
                if let progression, index < progression.count, let t = progression[index], t.isFinite {
                    if t < startLimit || t > stopLimit { continue }
                }
                slice.append((xVal, yVal))
            }
            return slice.isEmpty ? [] : [ProgressionPlotSegment(name: "Time Window", points: slice)]
        }

        var orderedKeys: [String] = []
        var seen: Set<String> = []
        var buckets: [String: [(Double, Double)]] = [:]
        for index in 0..<count {
            guard let xVal = x[index], let yVal = y[index], xVal.isFinite, yVal.isFinite else { continue }
            let key = progStrings[index]
            if !seen.contains(key) {
                seen.insert(key)
                orderedKeys.append(key)
            }
            buckets[key, default: []].append((xVal, yVal))
        }

        var segments: [ProgressionPlotSegment] = []
        for key in orderedKeys {
            if !selectedDiscreteKeys.isEmpty && !selectedDiscreteKeys.contains(key) { continue }
            guard let pts = buckets[key], !pts.isEmpty else { continue }
            let label = key == "default" ? "Data" : key
            segments.append(ProgressionPlotSegment(name: label, points: pts))
        }
        return segments
    }
}
