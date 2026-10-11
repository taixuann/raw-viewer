import Foundation

public struct SourceGroup: Identifiable, Sendable, Equatable {
    public let label: String
    public let sourceIDs: [String]

    public var id: String { label }

    public init(label: String, sourceIDs: [String]) {
        self.label = label
        self.sourceIDs = sourceIDs
    }
}

public struct SourceGrouping: Sendable, Equatable {
    public let sampleDevice: [SourceGroup]
    public let instrument: [SourceGroup]
    public let category: [SourceGroup]
    public let measurementMode: [SourceGroup]
    public let dateBatch: [SourceGroup]
    public let status: [SourceGroup]

    public init(inspections: [SourceInspection]) {
        sampleDevice = Self.groups(inspections) { Self.clean($0.deviceID) }
        instrument = Self.instrumentGroups(inspections)
        category = Self.groups(inspections) { Self.clean($0.category) }
        measurementMode = Self.groups(inspections) { Self.clean($0.applicationMode) }
        dateBatch = Self.groups(inspections) { Self.date(from: $0.timestamp) }
        status = Self.groups(inspections) { inspection in
            [
                Self.clean(inspection.supportStatus).map { "Support: \($0)" },
                Self.clean(inspection.validationState).map { "Validation: \($0)" }
            ].compactMap { $0 }
        }
    }

    /// Instrument groups are keyed by stable instrumentID (falling back to name
    /// only when no ID exists) so two sources sharing one instrument stay in one
    /// group even when only one inspection carries the display name. The label is
    /// the display name when any member has one, otherwise the ID. Different IDs
    /// never merge, even when display names collide (colliding labels are
    /// qualified with the ID to keep group identities stable).
    private static func instrumentGroups(_ inspections: [SourceInspection]) -> [SourceGroup] {
        var sourcesByKey: [String: Set<String>] = [:]
        var displayByKey: [String: String] = [:]
        var idByKey: [String: String] = [:]
        for inspection in inspections {
            let id = clean(inspection.instrumentID)
            let name = clean(inspection.instrumentName)
            guard id != nil || name != nil else { continue }
            let key = id.map { "id:\($0)" } ?? "name:\(name!)"
            sourcesByKey[key, default: []].insert(inspection.source)
            if let id { idByKey[key] = id }
            if displayByKey[key] == nil {
                displayByKey[key] = name ?? id
            } else if let name, displayByKey[key] == id {
                displayByKey[key] = name
            }
        }
        var labelCounts: [String: Int] = [:]
        for key in sourcesByKey.keys { labelCounts[displayByKey[key] ?? key, default: 0] += 1 }
        return sourcesByKey.keys.sorted { (displayByKey[$0] ?? $0) < (displayByKey[$1] ?? $1) }.map { key in
            var label = displayByKey[key] ?? key
            if (labelCounts[label] ?? 0) > 1, let id = idByKey[key] {
                label = "\(label) (\(id))"
            }
            return SourceGroup(label: label, sourceIDs: sourcesByKey[key, default: []].sorted())
        }
    }

    private static func groups(
        _ inspections: [SourceInspection],
        labels: (SourceInspection) -> [String?]
    ) -> [SourceGroup] {
        var sourcesByLabel: [String: Set<String>] = [:]
        for inspection in inspections {
            for label in labels(inspection).compactMap({ $0 }) {
                sourcesByLabel[label, default: []].insert(inspection.source)
            }
        }
        return sourcesByLabel.keys.sorted().map { label in
            SourceGroup(label: label, sourceIDs: sourcesByLabel[label, default: []].sorted())
        }
    }

    private static func groups(
        _ inspections: [SourceInspection],
        label: (SourceInspection) -> String?
    ) -> [SourceGroup] {
        groups(inspections) { [label($0)] }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public static func date(from timestamp: String?) -> String? {
        guard let timestamp = clean(timestamp) else { return nil }
        if let iso = isoDate(from: timestamp) { return iso }
        return filenameDate(from: timestamp)
    }

    private static func isoDate(from timestamp: String) -> String? {
        guard timestamp.count >= 10 else { return nil }
        let date = String(timestamp.prefix(10))
        let bytes = Array(date.utf8)
        guard bytes.count == 10,
              bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48...57).contains(byte)
              }) else { return nil }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, date.count == 10 else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let parsed = calendar.date(from: components) else { return nil }
        let parsedParts = calendar.dateComponents([.year, .month, .day], from: parsed)
        guard parsedParts.year == parts[0], parsedParts.month == parts[1], parsedParts.day == parts[2] else { return nil }
        if timestamp.count > 10 && !timestamp.dropFirst(10).hasPrefix("T") { return nil }
        return date
    }

    /// Real filename convention `DDMMYY` with optional `-HHMMSS`, validated as
    /// a calendar date (years pivot to 2000–2099). Anything outside the
    /// convention stays unknown so it never groups.
    private static func filenameDate(from timestamp: String) -> String? {
        let datePart: Substring
        let timePart: Substring?
        if timestamp.count == 6 {
            datePart = timestamp[...]
            timePart = nil
        } else if timestamp.count == 13 {
            let dash = timestamp.index(timestamp.startIndex, offsetBy: 6)
            guard timestamp[dash] == "-" else { return nil }
            datePart = timestamp[..<dash]
            timePart = timestamp[timestamp.index(after: dash)...]
        } else {
            return nil
        }
        guard datePart.count == 6, datePart.allSatisfy(\.isNumber) else { return nil }
        guard let day = Int(datePart.prefix(2)), let month = Int(datePart.dropFirst(2).prefix(2)),
              let shortYear = Int(datePart.suffix(2)), (1...12).contains(month) else { return nil }
        if let timePart {
            guard timePart.count == 6, timePart.allSatisfy(\.isNumber),
                  let hour = Int(timePart.prefix(2)), let minute = Int(timePart.dropFirst(2).prefix(2)),
                  let second = Int(timePart.suffix(2)),
                  (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        }
        let year = 2000 + shortYear
        let calendar = Calendar(identifier: .gregorian)
        guard let parsed = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parsedParts = calendar.dateComponents([.year, .month, .day], from: parsed)
        guard parsedParts.year == year, parsedParts.month == month, parsedParts.day == day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
