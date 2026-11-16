import Foundation

/// Min/max-per-column reduction for dense line plots. Keeps the extremes of
/// every pixel column so spikes stay visible while far fewer points are stroked.
public enum PlotDownsampler {
    /// Reduction starts when a run holds more than this many points per pixel column.
    public static let pointsPerColumnThreshold = 4

    public static func needsDownsampling(pointCount: Int, plotWidth: Int) -> Bool {
        pointCount > pointsPerColumnThreshold * max(1, plotWidth)
    }

    /// Ascending indices into the input arrays. Keeps the lowest and highest y
    /// in each of `columns` equal-width x buckets, plus the first and last sample
    /// so a drawn run keeps its endpoints.
    public static func keptIndices(x: [Double], y: [Double], columns: Int) -> [Int] {
        precondition(x.count == y.count, "x and y must have the same length")
        let count = x.count
        guard count > 2, columns > 0 else { return Array(0..<count) }

        let minX = x.min() ?? 0
        let span = (x.max() ?? 0) - minX
        var lowest = [Int](repeating: -1, count: columns)
        var highest = [Int](repeating: -1, count: columns)
        for index in 0..<count {
            let fraction = span > 0 ? (x[index] - minX) / span : 0
            let column = fraction.isFinite ? min(columns - 1, max(0, Int(fraction * Double(columns)))) : 0
            if lowest[column] < 0 || y[index] < y[lowest[column]] { lowest[column] = index }
            if highest[column] < 0 || y[index] > y[highest[column]] { highest[column] = index }
        }

        var kept: Set<Int> = [0, count - 1]
        for column in 0..<columns where lowest[column] >= 0 {
            kept.insert(lowest[column])
            kept.insert(highest[column])
        }
        return kept.sorted()
    }
}
