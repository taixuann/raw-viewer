import Foundation

public struct SourceInspection: Decodable, Identifiable, Sendable {
    public var id: String { source }
    public let source: String
    public let size: Int64?
    public let instrumentID: String?
    public let instrumentName: String?
    public let applicationMode: String?
    public let timestamp: String?
    public let deviceID: String?
    public let studyToken: String?
    public let supportStatus: String?
    public let validationState: String?
    public let readerVersion: String?
    public let profileID: String?
    public let profileHash: String?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case source, size, timestamp, error
        case instrumentID = "instrument_id", instrumentName = "instrument_name"
        case applicationMode = "application_mode", deviceID = "device_id"
        case studyToken = "study_token", supportStatus = "support_status"
        case validationState = "validation_state", readerVersion = "reader_version"
        case profileID = "profile_id", profileHash = "profile_hash"
    }
}

public struct SourceInspectionResult: Identifiable, Sendable {
    public var id: String { source.relativePath }
    public let source: RawSource
    public let inspection: SourceInspection?
    public let error: String?
}

struct InspectionEnvelope: Decodable {
    let sources: [SourceInspection]

    static func decodeRows(_ data: Data) throws -> [InspectionResponseRow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["sources"] as? [Any] else { throw ReaderClientError.invalidReaderResponse }
        let decoder = JSONDecoder()
        return values.compactMap { value in
            guard JSONSerialization.isValidJSONObject(value),
                  let rowData = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            do {
                let inspection = try decoder.decode(SourceInspection.self, from: rowData)
                return InspectionResponseRow(source: inspection.source, inspection: inspection,
                                             error: inspection.error.map { String($0.prefix(4096)) })
            } catch {
                guard let row = value as? [String: Any], let source = row["source"] as? String else { return nil }
                return InspectionResponseRow(source: source, inspection: nil,
                                             error: "Malformed source inspection row: \(error.localizedDescription)")
            }
        }
    }
}

struct InspectionResponseRow: Sendable {
    let source: String
    let inspection: SourceInspection?
    let error: String?
}

enum InspectionBatch {
    static let maximumSize = 256
    static func chunks(_ sources: [RawSource]) -> [[RawSource]] {
        stride(from: 0, to: sources.count, by: maximumSize).map {
            Array(sources[$0..<min($0 + maximumSize, sources.count)])
        }
    }
}
