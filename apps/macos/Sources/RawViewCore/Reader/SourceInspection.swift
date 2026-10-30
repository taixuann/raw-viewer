import Foundation

public struct SourceInspection: Identifiable, Sendable, Equatable, Codable {
    public var id: String { source }
    public let source: String
    public let size: Int64?
    public let instrumentID: String?
    public let instrumentName: String?
    public let applicationMode: String?
    public let timestamp: String?
    public let deviceID: String?
    public let category: String?
    public let supportStatus: String?
    public let validationState: String?
    public let readerVersion: String?
    public let profileID: String?
    public let profileHash: String?
    public let error: String?
}

public enum InspectionDisposition: String, Sendable, Codable, Equatable {
    case profileMatched = "profile_matched"
    case structuralCandidate = "structural_candidate"
    case deterministicBlocked = "deterministic_blocked"
    case transientFailure = "transient_failure"
    case cancelled = "cancelled"
}

public struct SourceInspectionResult: Identifiable, Sendable {
    public var id: String { source.relativePath }
    public let source: RawSource
    public let inspection: SourceInspection?
    public let disposition: InspectionDisposition
    public let error: String?

    public init(
        source: RawSource,
        inspection: SourceInspection?,
        disposition: InspectionDisposition = .profileMatched,
        error: String?
    ) {
        self.source = source
        self.inspection = inspection
        self.disposition = disposition
        self.error = error
    }
}
