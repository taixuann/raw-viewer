import Foundation

public enum ContractError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalid(String)
}

public struct SourceIdentity: Decodable, Sendable {
    public let path: String
    public let sha256: String
}

public struct InstrumentIdentity: Decodable, Sendable {
    public let id: String
    public let name: String
}

public struct MeasurementView: Decodable, Sendable {
    enum CodingKeys: String, CodingKey { case kind, x, y, preserveOrder = "preserve_order" }
    public let kind: String
    public let x: String?
    public let y: [String]?
    public let preserveOrder: Bool
}

public struct MeasurementChannel: Decodable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let label: String
    public let unit: String
    public let values: [Double]
}

public struct MetadataField: Decodable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let value: JSONValue
    public let unit: String?
    public let kind: String
}

public enum JSONValue: Decodable, Sendable {
    case string(String), number(Double), boolean(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .boolean(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }

    public var displayText: String {
        switch self {
        case .string(let value): value
        case .number(let value): NumberLabel.format(value)
        case .boolean(let value): value ? "Yes" : "No"
        case .null: "Unknown"
        }
    }
}

public struct MetadataSection: Decodable, Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let fields: [MetadataField]
}

private struct ContractVersionEnvelope: Decodable {
    enum CodingKeys: String, CodingKey { case contractVersion = "contract_version" }
    let contractVersion: Int
}

private struct MeasurementEnvelope: Decodable {
    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version", source, instrument
        case applicationMode = "application_mode", view, channels
        case metadataSections = "metadata_sections", warnings
        case supportStatus = "support_status", provenance
    }
    let contractVersion: Int
    let source: SourceIdentity
    let instrument: InstrumentIdentity
    let applicationMode: String?
    let view: MeasurementView
    let channels: [MeasurementChannel]
    let metadataSections: [MetadataSection]
    let warnings: [String]
    let supportStatus: String
    let provenance: [String: String]?
}

public struct NormalizedMeasurement: Sendable {
    public let source: SourceIdentity
    public let instrument: InstrumentIdentity
    public let applicationMode: String?
    public let view: MeasurementView
    public let channels: [MeasurementChannel]
    public let metadataSections: [MetadataSection]
    public let warnings: [String]
    public let supportStatus: String
    public let provenance: [String: String]

    public func channel(named name: String) -> MeasurementChannel? {
        channels.first { $0.name == name }
    }

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        let version: ContractVersionEnvelope
        do { version = try decoder.decode(ContractVersionEnvelope.self, from: data) }
        catch { throw ContractError.invalid("Missing or malformed contract version: \(error)") }
        guard version.contractVersion == 1 else { throw ContractError.unsupportedVersion(version.contractVersion) }
        let envelope: MeasurementEnvelope
        do { envelope = try decoder.decode(MeasurementEnvelope.self, from: data) }
        catch { throw ContractError.invalid("Malformed normalized measurement: \(error)") }
        let validSHA = envelope.source.sha256.count == 64 && envelope.source.sha256.allSatisfy(\.isHexDigit)
        guard !envelope.source.path.isEmpty, validSHA else {
            throw ContractError.invalid("Source path or SHA-256 is missing or malformed")
        }
        guard ["xy", "timeseries", "spectrum", "regions", "table", "metadata-only"].contains(envelope.view.kind) else {
            throw ContractError.invalid("Unknown view kind \(envelope.view.kind)")
        }
        guard Set(envelope.channels.map(\.name)).count == envelope.channels.count else {
            throw ContractError.invalid("Channel names must be unique")
        }
        guard envelope.channels.allSatisfy({ $0.values.allSatisfy(\.isFinite) }) else {
            throw ContractError.invalid("Channels must contain only finite values")
        }
        if let count = envelope.channels.first?.values.count,
           !envelope.channels.allSatisfy({ $0.values.count == count }) {
            throw ContractError.invalid("Channel lengths differ; row alignment is unknown")
        }
        if envelope.view.kind != "metadata-only" {
            guard envelope.view.preserveOrder, let x = envelope.view.x, let y = envelope.view.y,
                  envelope.channels.contains(where: { $0.name == x }),
                  !y.isEmpty, y.allSatisfy({ name in envelope.channels.contains(where: { $0.name == name }) }) else {
                throw ContractError.invalid("View channels are missing or acquisition ordering is not declared")
            }
        }
        return Self(source: envelope.source, instrument: envelope.instrument,
                    applicationMode: envelope.applicationMode, view: envelope.view,
                    channels: envelope.channels, metadataSections: envelope.metadataSections,
                    warnings: envelope.warnings, supportStatus: envelope.supportStatus,
                    provenance: envelope.provenance ?? [:])
    }
}

public enum AxisScale: String, Sendable, Equatable { case linear, logarithmic }

public enum AxisTransformError: Error, Sendable, Equatable {
    case nonFinite
    case invalidLogDomain

    public var message: String {
        switch self {
        case .nonFinite: "Channel contains a non-finite value"
        case .invalidLogDomain: "Log scale requires positive values. Turn Absolute on explicitly to display magnitudes."
        }
    }
}

public enum AxisTransform {
    public static func values(_ input: [Double], absolute: Bool, scale: AxisScale) -> Result<[Double], AxisTransformError> {
        let transformed = input.map { absolute ? abs($0) : $0 }
        guard transformed.allSatisfy(\.isFinite) else { return .failure(.nonFinite) }
        if scale == .logarithmic {
            guard transformed.allSatisfy({ $0 > 0 }) else { return .failure(.invalidLogDomain) }
            return .success(transformed.map(log10))
        }
        return .success(transformed)
    }
}

public enum NumberLabel {
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value != 0 && (abs(value) < 0.001 || abs(value) >= 1000) {
            return value.formatted(.number.precision(.significantDigits(3...3)).notation(.scientific))
        }
        return value.formatted(.number.precision(.significantDigits(1...3)))
    }
}
