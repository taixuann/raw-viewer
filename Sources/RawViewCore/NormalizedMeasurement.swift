import Foundation

public enum ContractError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalid(String)
}

public struct SourceIdentity: Decodable, Sendable, Equatable {
    public let path: String
    public let sha256: String
}

public struct InstrumentIdentity: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    /// Descriptive identity from the selected profile; nil when not declared.
    public let vendor: String?
    public let model: String?

    init(id: String, name: String, vendor: String? = nil, model: String? = nil) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.model = model
    }
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
    public let quantity: String?
    /// Row-aligned samples in acquisition order. `nil` is a preserved gap (blank,
    /// NaN, or Infinity in the source cell): the row is kept, finite values are
    /// bitwise exact, and plots break the line at gaps instead of interpolating.
    public let values: [Double?]
    /// Parallel gap classification: `nil` where the value is finite. Blank
    /// cells, recorded NaN/infinity tokens, and overflow saturation stay
    /// distinguishable; external JSON nulls without a recorded reason decode
    /// as `.unknown`.
    public let gapReasons: [GapReason?]

    public init(name: String, label: String, unit: String, quantity: String?, values: [Double?], gapReasons: [GapReason?]? = nil) {
        self.name = name
        self.label = label
        self.unit = unit
        self.quantity = quantity
        self.values = values
        self.gapReasons = gapReasons ?? values.map { $0 == nil ? .unknown : nil }
    }

    enum CodingKeys: String, CodingKey {
        case name, label, unit, quantity, values, gapReasons = "gap_reasons"
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = try box.decode(String.self, forKey: .name)
        label = try box.decode(String.self, forKey: .label)
        unit = try box.decode(String.self, forKey: .unit)
        quantity = try box.decodeIfPresent(String.self, forKey: .quantity)
        values = try box.decode([Double?].self, forKey: .values)
        if let reasons = try box.decodeIfPresent([GapReason?].self, forKey: .gapReasons) {
            guard reasons.count == values.count else {
                throw DecodingError.dataCorruptedError(forKey: .gapReasons, in: box, debugDescription: "gap_reasons length (\(reasons.count)) must match values length (\(values.count))")
            }
            gapReasons = reasons
        } else {
            gapReasons = values.map { $0 == nil ? .unknown : nil }
        }
    }

    /// Number of preserved acquisition rows (including gaps).
    public var rowCount: Int { values.count }
    /// Number of gap cells in this channel.
    public var gapCount: Int { values.filter({ $0 == nil }).count }

    /// Ordered-table cell text: the formatted number, or the gap marker for
    /// the recorded reason.
    public func text(at index: Int) -> String {
        if let value = values[index] { return NumberLabel.format(value) }
        return gapReasons[index]?.marker ?? GapReason.unknown.marker
    }
}

public enum GapReason: String, Codable, Sendable {
    case blank
    case nan
    case infinite
    case saturated
    case unknown

    /// Ordered-table marker distinguishing recorded gap reasons.
    public var marker: String {
        switch self {
        case .blank: "—"
        case .nan: "NaN"
        case .infinite: "∞"
        case .saturated: "sat"
        case .unknown: "—"
        }
    }
}

public struct MetadataField: Decodable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let value: JSONValue
    public let unit: String?
    public let kind: String

    init(key: String, label: String, value: JSONValue, unit: String?, kind: String) {
        self.key = key
        self.label = label
        self.value = value
        self.unit = unit
        self.kind = kind
    }
}

public enum JSONValue: Codable, Sendable {
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

    init(title: String, fields: [MetadataField]) {
        self.title = title
        self.fields = fields
    }
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

    init(source: SourceIdentity, instrument: InstrumentIdentity, applicationMode: String?, view: MeasurementView,
         channels: [MeasurementChannel], metadataSections: [MetadataSection], warnings: [String],
         supportStatus: String, provenance: [String: String]) {
        self.source = source
        self.instrument = instrument
        self.applicationMode = applicationMode
        self.view = view
        self.channels = channels
        self.metadataSections = metadataSections
        self.warnings = warnings
        self.supportStatus = supportStatus
        self.provenance = provenance
    }

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
        guard ["xy", "timeseries", "spectrum", "table", "metadata-only", "regions"].contains(envelope.view.kind) else {
            throw ContractError.invalid("Unknown view kind \(envelope.view.kind)")
        }
        guard Set(envelope.channels.map(\.name)).count == envelope.channels.count else {
            throw ContractError.invalid("Channel names must be unique")
        }
        guard envelope.channels.allSatisfy({ channel in
            channel.values.allSatisfy({ $0 == nil || $0!.isFinite })
        }) else {
            throw ContractError.invalid("Channels must contain only finite values or null gaps")
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
    public static func values(_ input: [Double?], absolute: Bool, scale: AxisScale) -> Result<[Double?], AxisTransformError> {
        var transformed: [Double?] = []
        transformed.reserveCapacity(input.count)
        for sample in input {
            guard let sample else { transformed.append(nil); continue }
            transformed.append(absolute ? abs(sample) : sample)
        }
        guard transformed.allSatisfy({ $0 == nil || $0!.isFinite }) else { return .failure(.nonFinite) }
        if scale == .logarithmic {
            guard transformed.allSatisfy({ $0 == nil || $0! > 0 }) else { return .failure(.invalidLogDomain) }
            return .success(transformed.map { $0 == nil ? nil : log10($0!) })
        }
        return .success(transformed)
    }

    /// Segments of contiguous valid indices for native path drawing. A gap in
    /// either x or y breaks the line; no interpolation or sorting is applied.
    public static func segments(x: [Double?], y: [Double?]) -> [[Int]] {
        var runs: [[Int]] = []
        var current: [Int] = []
        for index in x.indices where y.indices.contains(index) {
            if x[index] != nil && y[index] != nil {
                current.append(index)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

public enum NumberLabel {
    public static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value != 0 && (abs(value) < 0.001 || abs(value) >= 1000) {
            return value.formatted(.number.precision(.significantDigits(3...3)).notation(.scientific))
        }
        return value.formatted(.number.precision(.significantDigits(1...3)))
    }
    public static func format(_ value: Double) -> String {
        format(Optional(value))
    }
}
