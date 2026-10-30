import Foundation

/// Canonical JSON form of `NormalizedMeasurement` for cross-language golden tests.
/// Finite samples are encoded as IEEE-754 `bitPattern` hex (not decimal literals).
public enum NormalizedMeasurementGoldenEncoder {
    public static func encode(_ measurement: NormalizedMeasurement) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(GoldenDocument(measurement: measurement))
    }
}

private struct GoldenDocument: Encodable {
    let measurement: NormalizedMeasurement

    init(measurement: NormalizedMeasurement) {
        self.measurement = measurement
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let mode = measurement.applicationMode {
            try container.encode(mode, forKey: .applicationMode)
        }
        try container.encode(measurement.channels.map(GoldenChannel.init), forKey: .channels)
        try container.encode(1, forKey: .contractVersion)
        try container.encode(GoldenInstrument(measurement.instrument), forKey: .instrument)
        try container.encode(measurement.metadataSections.map(GoldenMetadataSection.init), forKey: .metadataSections)
        try container.encode(GoldenStringMap(measurement.provenance), forKey: .provenance)
        try container.encode(GoldenSource(measurement.source), forKey: .source)
        try container.encode(measurement.supportStatus, forKey: .supportStatus)
        try container.encode(GoldenView(measurement.view), forKey: .view)
        try container.encode(measurement.warnings, forKey: .warnings)
    }

    enum CodingKeys: String, CodingKey {
        case applicationMode = "application_mode"
        case channels
        case contractVersion = "contract_version"
        case instrument
        case metadataSections = "metadata_sections"
        case provenance
        case source
        case supportStatus = "support_status"
        case view
        case warnings
    }
}

private struct GoldenSource: Encodable {
    let path: String
    let sha256: String

    init(_ source: SourceIdentity) {
        path = source.path
        sha256 = source.sha256
    }
}

private struct GoldenInstrument: Encodable {
    let id: String
    let name: String
    let vendor: String?
    let model: String?

    init(_ instrument: InstrumentIdentity) {
        id = instrument.id
        name = instrument.name
        vendor = instrument.vendor
        model = instrument.model
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let model { try container.encode(model, forKey: .model) }
        try container.encode(name, forKey: .name)
        if let vendor { try container.encode(vendor, forKey: .vendor) }
    }

    enum CodingKeys: String, CodingKey {
        case id, model, name, vendor
    }
}

private struct GoldenView: Encodable {
    let kind: String
    let preserveOrder: Bool
    let x: String?
    let y: [String]?

    init(_ view: MeasurementView) {
        kind = view.kind
        preserveOrder = view.preserveOrder
        x = view.x
        y = view.y
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(preserveOrder, forKey: .preserveOrder)
        if let x { try container.encode(x, forKey: .x) }
        if let y { try container.encode(y, forKey: .y) }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case preserveOrder = "preserve_order"
        case x, y
    }
}

private struct GoldenChannel: Encodable {
    let channel: MeasurementChannel

    init(_ channel: MeasurementChannel) {
        self.channel = channel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(channel.label, forKey: .label)
        try container.encode(channel.name, forKey: .name)
        if let quantity = channel.quantity {
            try container.encode(quantity, forKey: .quantity)
        }
        try container.encode(channel.unit, forKey: .unit)
        try container.encode(channel.gapReasons.map { reason -> String? in
            reason?.rawValue
        }, forKey: .gapReasons)
        try container.encode(channel.values.map(GoldenSample.init), forKey: .values)
    }

    enum CodingKeys: String, CodingKey {
        case label, name, quantity, unit
        case gapReasons = "gap_reasons"
        case values
    }
}

private enum GoldenSample: Encodable {
    case gap
    case finite(UInt64)

    init(_ value: Double?) {
        if let value {
            self = .finite(value.bitPattern)
        } else {
            self = .gap
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .gap:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .finite(let bits):
            var container = encoder.singleValueContainer()
            try container.encode(GoldenBits(bits: String(format: "%016x", bits)))
        }
    }
}

private struct GoldenBits: Encodable {
    let bits: String
}

private struct GoldenMetadataSection: Encodable {
    let title: String
    let fields: [GoldenMetadataField]

    init(_ section: MetadataSection) {
        title = section.title
        fields = section.fields.map(GoldenMetadataField.init)
    }
}

private struct GoldenMetadataField: Encodable {
    let field: MetadataField

    init(_ field: MetadataField) {
        self.field = field
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field.key, forKey: .key)
        try container.encode(field.kind, forKey: .kind)
        try container.encode(field.label, forKey: .label)
        if let unit = field.unit {
            try container.encode(unit, forKey: .unit)
        }
        try container.encode(GoldenJSONValue(field.value), forKey: .value)
    }

    enum CodingKeys: String, CodingKey {
        case key, kind, label, unit, value
    }
}

private enum GoldenJSONValue: Encodable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(_ value: JSONValue) {
        switch value {
        case .string(let text): self = .string(text)
        case .number(let number): self = .number(number)
        case .boolean(let flag): self = .boolean(flag)
        case .null: self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        case .boolean(let flag): try container.encode(flag)
        case .null: try container.encodeNil()
        }
    }
}

/// Sorted-key JSON object wrapper for `[String: String]` provenance maps.
private struct GoldenStringMap: Encodable {
    let entries: [(key: String, value: String)]

    init(_ map: [String: String]) {
        entries = map.sorted(by: { $0.key < $1.key }).map { (key: $0.key, value: $0.value) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for entry in entries {
            try container.encode(entry.value, forKey: DynamicKey(entry.key))
        }
    }
}

private struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
