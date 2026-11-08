import Foundation

/// Parsed programmed sweep metadata for Keithley instruments.
/// Extracted from file comment / header without altering raw files.
public struct KeithleyMetadata: Sendable, Equatable {
    public let sweepPath: String
    public let voltageStep: String
    public let compliance: String
    public let rawVoltageCount: Int
    public let isValid: Bool
    public let warning: String?

    public init(
        sweepPath: String,
        voltageStep: String,
        compliance: String,
        rawVoltageCount: Int = 0,
        isValid: Bool = true,
        warning: String? = nil
    ) {
        self.sweepPath = sweepPath
        self.voltageStep = voltageStep
        self.compliance = compliance
        self.rawVoltageCount = rawVoltageCount
        self.isValid = isValid
        self.warning = warning
    }
}

public enum KeithleyMetadataParser {
    /// Maximum bytes to scan from file head for Comment line
    public static let maxScanBytes = 8192

    /// Extracts Keithley programmed sweep metadata from file URL.
    public static func extract(from url: URL) -> KeithleyMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxScanBytes),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }
        return extract(fromText: text)
    }

    /// Extracts Keithley programmed sweep metadata from header text or full text.
    public static func extract(fromText text: String) -> KeithleyMetadata? {
        // Look for "Voltage list:" or "Compliance level:"
        guard text.contains("Voltage list:") || text.contains("Compliance level:") else {
            return nil
        }

        // Find the line containing "Voltage list:"
        var targetLine = ""
        for line in text.components(separatedBy: .newlines) {
            if line.contains("Voltage list:") || line.contains("Compliance level:") {
                targetLine = line
                break
            }
        }
        guard !targetLine.isEmpty else { return nil }

        return parseLine(targetLine)
    }

    public static func parseLine(_ line: String) -> KeithleyMetadata {
        var voltageListPart: String? = nil
        var compliancePart: String? = nil

        // Split by pipe '|' if both exist, e.g.:
        // "Voltage list: 0.00;0.05;... | Compliance level: 0.000100"
        let segments = line.components(separatedBy: "|")
        for seg in segments {
            let trimmed = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = trimmed.range(of: "Voltage list:") {
                voltageListPart = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let range = trimmed.range(of: "Compliance level:") {
                compliancePart = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var sweepPath = ""
        var stepString = ""
        var rawCount = 0
        var isVoltageValid = true
        var voltageWarning: String? = nil

        if let vPart = voltageListPart {
            let tokens = vPart.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var doubles: [Double] = []
            var parseFailed = false
            for token in tokens {
                if let d = Double(token) {
                    doubles.append(d)
                } else {
                    parseFailed = true
                    break
                }
            }

            if parseFailed || doubles.isEmpty {
                isVoltageValid = false
                voltageWarning = "Malformed Voltage list tokens in comment"
                sweepPath = "Invalid path"
                stepString = "Invalid step"
            } else {
                rawCount = doubles.count
                sweepPath = deriveSweepPath(from: doubles)
                stepString = deriveVoltageStep(from: doubles)
            }
        } else {
            isVoltageValid = false
            voltageWarning = "Missing Voltage list in Keithley comment"
            sweepPath = "Unknown path"
            stepString = "Unknown step"
        }

        var complianceString = "Unknown"
        var isComplianceValid = true
        if let cPart = compliancePart {
            if let val = Double(cPart) {
                complianceString = formatCompliance(val)
            } else {
                isComplianceValid = false
                complianceString = "Invalid (\(cPart))"
            }
        }

        let overallValid = isVoltageValid && isComplianceValid
        let overallWarning = voltageWarning ?? (!isComplianceValid ? "Malformed Compliance level in comment" : nil)

        return KeithleyMetadata(
            sweepPath: sweepPath,
            voltageStep: stepString,
            compliance: complianceString,
            rawVoltageCount: rawCount,
            isValid: overallValid,
            warning: overallWarning
        )
    }

    /// Derives sweep path from ordered programmed voltage list: start, turning points, and end.
    /// E.g. [0, 0.5, 1.5, 1.0, -1.5, -0.5, 0] -> "0 → 1.5 → -1.5 → 0 V"
    public static func deriveSweepPath(from values: [Double]) -> String {
        guard !values.isEmpty else { return "0 V" }
        guard values.count > 1 else { return "\(formatVoltage(values[0])) V" }

        // Remove immediate consecutive identical values
        var deduped: [Double] = [values[0]]
        for v in values.dropFirst() {
            if abs(v - deduped.last!) > 1e-9 {
                deduped.append(v)
            }
        }
        guard deduped.count > 1 else { return "\(formatVoltage(deduped[0])) V" }

        var turningPoints: [Double] = [deduped[0]]

        for i in 1..<(deduped.count - 1) {
            let prev = deduped[i - 1]
            let curr = deduped[i]
            let next = deduped[i + 1]

            let diffPrev = curr - prev
            let diffNext = next - curr

            // A turning point occurs where direction reverses
            if (diffPrev > 0 && diffNext < 0) || (diffPrev < 0 && diffNext > 0) {
                turningPoints.append(curr)
            }
        }

        turningPoints.append(deduped.last!)

        let pathString = turningPoints.map(formatVoltage).joined(separator: " → ")
        return "\(pathString) V"
    }

    /// Derives voltage step from consecutive differences.
    /// Flags variable steps if consecutive differences are not uniform.
    public static func deriveVoltageStep(from values: [Double]) -> String {
        guard values.count >= 2 else { return "None" }

        var steps: [Double] = []
        for i in 0..<(values.count - 1) {
            steps.append(abs(values[i + 1] - values[i]))
        }

        // Filter out zero steps (holds)
        let nonZeroSteps = steps.filter { $0 > 1e-9 }
        guard !nonZeroSteps.isEmpty else { return "0 V" }

        let first = nonZeroSteps[0]
        let isUniform = nonZeroSteps.allSatisfy { abs($0 - first) < 1e-6 }

        if isUniform {
            return "\(formatVoltage(first)) V"
        } else {
            let minStep = nonZeroSteps.min() ?? 0.0
            let maxStep = nonZeroSteps.max() ?? 0.0
            return "Variable (\(formatVoltage(minStep)) – \(formatVoltage(maxStep)) V)"
        }
    }

    /// Formats compliance current nicely with profile-declared unit A.
    /// E.g. 0.0001 -> "100 µA" or "0.0001 A"
    public static func formatCompliance(_ amperes: Double) -> String {
        let absVal = abs(amperes)
        if absVal < 1e-12 {
            return "0 A"
        } else if absVal < 1e-6 {
            let nA = amperes * 1e9
            return String(format: "%.1f nA", nA)
        } else if absVal < 1e-3 {
            let uA = amperes * 1e6
            if abs(uA.rounded() - uA) < 1e-4 {
                return String(format: "%.0f µA", uA)
            } else {
                return String(format: "%.1f µA", uA)
            }
        } else if absVal < 1.0 {
            let mA = amperes * 1e3
            if abs(mA.rounded() - mA) < 1e-4 {
                return String(format: "%.0f mA", mA)
            } else {
                return String(format: "%.2f mA", mA)
            }
        } else {
            return String(format: "%.2f A", amperes)
        }
    }

    public static func formatVoltage(_ val: Double) -> String {
        if abs(val.rounded() - val) < 1e-6 {
            return String(format: "%.0f", val)
        }
        // Round to 3 decimal places without trailing zeroes
        let s = String(format: "%.3f", val)
        return s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
}
