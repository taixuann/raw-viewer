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
    public let study: [SourceGroup]
    public let measurementMode: [SourceGroup]
    public let dateBatch: [SourceGroup]
    public let status: [SourceGroup]

    public init(inspections: [SourceInspection]) {
        sampleDevice = Self.groups(inspections) { Self.clean($0.deviceID) }
        instrument = Self.groups(inspections) { Self.clean($0.instrumentName) ?? Self.clean($0.instrumentID) }
        study = Self.groups(inspections) { Self.clean($0.studyToken) }
        measurementMode = Self.groups(inspections) { Self.clean($0.applicationMode) }
        dateBatch = Self.groups(inspections) { Self.date(from: $0.timestamp) }
        status = Self.groups(inspections) { inspection in
            [
                Self.clean(inspection.supportStatus).map { "Support: \($0)" },
                Self.clean(inspection.validationState).map { "Validation: \($0)" }
            ].compactMap { $0 }
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
        guard let timestamp = clean(timestamp), timestamp.count >= 10 else { return nil }
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
}
