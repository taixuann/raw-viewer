import Foundation

/// Builds Keithley-2400 LVM text in the instrument's export format.
/// The sweep sits in the Comment cell of the first data row.
enum KeithleySweepFixtures {
    /// Sweep of 0 → +1.5 → -1.5 → 0 V in 0.02 V steps: 301 points.
    static func sampleVoltageTokens() -> [String] {
        voltageTokens(stepIndices: Array(0...75) + Array((-75...74).reversed()) + Array(-74...0))
    }

    /// Sweep of 0 → +25 → -25 → 0 V in 0.02 V steps: 5,001 points (over 8 KB as text).
    static func longVoltageTokens() -> [String] {
        voltageTokens(stepIndices: Array(0...1250) + Array((-1250...1249).reversed()) + Array(-1249...0))
    }

    /// Each index counts 0.02 V steps from 0 V.
    private static func voltageTokens(stepIndices: [Int]) -> [String] {
        stepIndices.map { String(format: "%.2f", Double($0) * 0.02) }
    }

    static func comment(tokens: [String], compliance: String = "0.000100") -> String {
        "Voltage list: " + tokens.joined(separator: ";") + " | Compliance level: " + compliance
    }

    /// Header row, then a first data row whose fourth data cell is the comment.
    static func lvmText(comment: String) -> String {
        "X_Value\tUntitled\tUntitled 1\tUntitled 2\tComment\n"
            + "\t-1.768762E-5\t7.555332E-9\t6697.824219\t" + comment + "\n"
            + "\t0.049996\t3.624409E-8\t6697.908203\t\n"
    }

    static func writeTemp(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keithley-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
