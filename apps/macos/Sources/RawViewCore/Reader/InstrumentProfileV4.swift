import Foundation

// MARK: - Schema v4 flat profile document

enum ProfileV4Error: Error, LocalizedError, Equatable {
    case invalid(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        }
    }
}

struct ProfileDocumentV4: Sendable, Equatable {
    var profileID: String
    var revision: String?
    var instrumentID: String
    var instrumentName: String
    var vendor: String?
    var model: String?
    var when: WhenClauseV4?
    var variants: [String: ProfileVariantV4]
}

struct WhenClauseV4: Sendable, Equatable {
    var tokens: [String: String] = [:]
    var contentContainsAny: [String]?
    var contentStartsWith: [String]?
    var filenameContainsAll: [String]?
}

struct ProfileVariantV4: Sendable, Equatable {
    var when: WhenClauseV4?
    var format: StreamFormatV4
    var rows: RowsBlockV4
    var metadata: [MetadataEntryV4]
    var columns: [String: ColumnDefinitionV4]
    var plot: PlotSpecV4
}

struct StreamFormatV4: Sendable, Equatable {
    var kind: String
    var extensions: [String]
    var delimiter: Character
    var encodingNames: [String]
    var decimalSeparator: Character
}

struct RowsBlockV4: Sendable, Equatable {
    var metadataRows: [RowSpanV4] = []
    var skipRows: [RowSpanV4] = []
    var headerRow: Int?
    var dataStartRow: Int?
    var namesPrefix: String?
    var dataPrefix: String?
}

struct RowSpanV4: Sendable, Equatable {
    var start: Int
    var end: Int
}

enum MetadataEntryV4: Sendable, Equatable {
    case rowKeyValue(row: Int, key: String, valueType: String, format: String?)
    case cellKey(column: Int, row: Int, key: String)
}

enum ColumnRoleV4: Sendable, Equatable {
    case channel
    case progression
    case skip
}

struct ColumnProgressionV4: Sendable, Equatable {
    var progressionType: String
    var behavior: String?
}

struct ColumnDefinitionV4: Sendable, Equatable {
    var role: ColumnRoleV4
    var label: String?
    var quantity: String?
    var unit: String?
    var header: String?
    var aliases: [String]
    var required: Bool
    var progression: ColumnProgressionV4?
}

struct PlotSpecV4: Sendable, Equatable {
    var x: String
    var y: [String]
}

enum ProfileV4Codec {
    static func parse(text: String) throws -> ProfileDocumentV4 {
        let root: YAMLNode
        do {
            root = try YAMLParser.parse(text, allowIndentlessSequences: false)
        } catch let error as YAMLParseError {
            throw ProfileV4Error.invalid(reason: "Profile YAML parse error \(error.localizedDescription)")
        }
        guard root.mapEntries != nil else {
            throw ProfileV4Error.invalid(reason: "The profile document must be a mapping.")
        }
        let doc = try decode(root)
        try validateStructure(doc)
        return doc
    }

    static func decode(_ root: YAMLNode) throws -> ProfileDocumentV4 {
        try rejectUnknown(root, allowed: ["schema_version", "id", "revision", "instrument", "when", "variants"], scope: "")
        guard root.value(for: "schema_version")?.scalarValue == "4" else {
            throw ProfileV4Error.invalid(reason: "schema_version must be 4 for a flat profile document.")
        }
        let profileID = try scalarRequired(root, key: "id", field: "id")
        guard let instrument = root.value(for: "instrument"), instrument.mapEntries != nil else {
            throw ProfileV4Error.invalid(reason: "instrument mapping is required.")
        }
        try rejectUnknown(instrument, allowed: ["id", "name", "vendor", "model"], scope: "instrument")
        let instrumentID = try scalarRequired(instrument, key: "id", field: "instrument.id")
        let instrumentName = try scalarRequired(instrument, key: "name", field: "instrument.name")
        guard let variantsNode = root.value(for: "variants"), let variantEntries = variantsNode.mapEntries else {
            throw ProfileV4Error.invalid(reason: "variants must be a mapping keyed by application-mode.")
        }
        var variants: [String: ProfileVariantV4] = [:]
        for entry in variantEntries {
            let field = "variants.\(entry.key)"
            variants[entry.key] = try decodeVariant(entry.value, field: field)
        }
        return ProfileDocumentV4(
            profileID: profileID,
            revision: optionalScalar(root, key: "revision"),
            instrumentID: instrumentID,
            instrumentName: instrumentName,
            vendor: optionalScalar(instrument, key: "vendor"),
            model: optionalScalar(instrument, key: "model"),
            when: try decodeWhen(root.value(for: "when"), field: "when"),
            variants: variants
        )
    }

    static func validateStructure(_ doc: ProfileDocumentV4) throws {
        try nonEmpty(doc.profileID, field: "id")
        try nonEmpty(doc.instrumentID, field: "instrument.id")
        try nonEmpty(doc.instrumentName, field: "instrument.name")
        guard !doc.variants.isEmpty else {
            throw ProfileV4Error.invalid(reason: "variants must contain at least one application-mode.")
        }
        for key in doc.variants.keys.sorted() {
            guard let variant = doc.variants[key] else { continue }
            try validateVariant(modeKey: key, variant: variant)
        }
    }

    static func compileInstrumentProfile(
        _ doc: ProfileDocumentV4, relativePath: String, sha256: String
    ) throws -> InstrumentProfile {
        var formats: [ProfileFormat] = []
        var modes: [ProfileMode] = []
        for modeID in doc.variants.keys.sorted() {
            guard let variant = doc.variants[modeID] else { continue }
            formats.append(try compileFormat(formatID: modeID, variant: variant))
            modes.append(try compileMode(modeID: modeID, variant: variant))
        }
        return InstrumentProfile(
            profileID: doc.profileID,
            instrumentID: doc.instrumentID,
            instrumentName: doc.instrumentName,
            vendor: doc.vendor,
            model: doc.model,
            formats: formats,
            modes: modes,
            relativePath: relativePath,
            sha256: sha256,
            schemaVersion: 4
        )
    }

    static func lenientV4Extensions(_ root: YAMLNode) -> [String] {
        var extensions: [String] = []
        guard let variantEntries = root.value(for: "variants")?.mapEntries else { return [] }
        for entry in variantEntries {
            guard let extensionNodes = entry.value.value(for: "format")?.value(for: "extensions")?.listItems else { continue }
            for node in extensionNodes {
                guard let value = node.scalarValue?.lowercased(), value.hasPrefix(".") else { continue }
                extensions.append(value)
            }
        }
        return Array(Set(extensions)).sorted()
    }

    // MARK: - compile

    private static func compileFormat(formatID: String, variant: ProfileVariantV4) throws -> ProfileFormat {
        var columns: [ProfileColumn] = []
        for key in variant.columns.keys.sorted() {
            guard let col = variant.columns[key] else { continue }
            if col.role == .skip { continue }
            let quantity = col.quantity ?? "unknown"
            let unit = col.unit ?? "unspecified"
            let label = col.label ?? profileV4Humanized(key)
            guard let header = col.header else {
                throw ProfileV4Error.invalid(
                    reason: "variants.\(formatID).columns.\(key) must declare header for reader compilation.")
            }
            columns.append(ProfileColumn(
                key: key, header: header, aliases: col.aliases, quantity: quantity, unit: unit,
                label: label, index: nil, required: col.required))
        }
        var encodings: [String.Encoding] = []
        for name in variant.format.encodingNames {
            guard let encoding = ProfileSchema.encoding(named: name) else {
                throw ProfileV4Error.invalid(
                    reason: "variants.\(formatID).format.encoding entry \"\(name)\" is not supported; use utf-8, windows-1252, iso-8859-1, or ascii.")
            }
            encodings.append(encoding)
        }
        return ProfileFormat(
            id: formatID,
            kind: variant.format.kind,
            extensions: variant.format.extensions.map { $0.lowercased() },
            delimiter: variant.format.delimiter,
            encodings: encodings,
            encodingNames: variant.format.encodingNames,
            decimalSeparator: variant.format.decimalSeparator,
            namesPrefix: variant.rows.namesPrefix,
            dataPrefix: variant.rows.dataPrefix,
            columns: columns
        )
    }

    private static func compileMode(modeID: String, variant: ProfileVariantV4) throws -> ProfileMode {
        let when = variant.when
        let detect = when?.contentContainsAny?.filter { !$0.isEmpty } ?? []
        if detect.isEmpty {
            throw ProfileV4Error.invalid(
                reason: "variants.\(modeID).when.content_contains_any must list at least one selector for reader compilation.")
        }
        return ProfileMode(
            id: modeID,
            formatID: modeID,
            detect: detect,
            filenameContainsAll: when?.filenameContainsAll,
            x: variant.plot.x,
            y: variant.plot.y
        )
    }

    // MARK: - validate variant

    private static func validateVariant(modeKey: String, variant: ProfileVariantV4) throws {
        let field = "variants.\(modeKey)"
        try nonEmpty(variant.format.kind, field: "\(field).format.kind")
        if variant.format.extensions.isEmpty {
            throw ProfileV4Error.invalid(reason: "\(field).format.extensions must not be empty.")
        }
        try validateRows(variant.rows, field: "\(field).rows")
        if variant.columns.isEmpty {
            throw ProfileV4Error.invalid(reason: "\(field).columns must declare at least one column.")
        }
        try validatePlot(variant.plot, field: field, columns: variant.columns)
        for key in variant.columns.keys.sorted() {
            guard let col = variant.columns[key] else { continue }
            try validateColumn(col, field: "\(field).columns.\(key)")
        }
    }

    private static func validateRows(_ rows: RowsBlockV4, field: String) throws {
        var occupied: [RowSpanV4] = []
        for span in rows.metadataRows + rows.skipRows {
            try pushSpan(span, field: field, occupied: &occupied)
        }
        if let header = rows.headerRow {
            try pushSpan(RowSpanV4(start: header, end: header), field: field, occupied: &occupied)
        }
        if let dataStart = rows.dataStartRow {
            try pushSpan(RowSpanV4(start: dataStart, end: dataStart), field: field, occupied: &occupied)
        }
    }

    private static func pushSpan(_ span: RowSpanV4, field: String, occupied: inout [RowSpanV4]) throws {
        if span.start < 1 || span.end < span.start {
            throw ProfileV4Error.invalid(reason: "\(field) row span must be 1-based with end >= start.")
        }
        for other in occupied where spansOverlap(span, other) {
            throw ProfileV4Error.invalid(
                reason: "\(field) row assignments overlap between rows \(span.start)-\(span.end) and \(other.start)-\(other.end).")
        }
        occupied.append(span)
    }

    private static func spansOverlap(_ a: RowSpanV4, _ b: RowSpanV4) -> Bool {
        a.start <= b.end && b.start <= a.end
    }

    private static func validateColumn(_ col: ColumnDefinitionV4, field: String) throws {
        switch col.role {
        case .channel:
            try nonEmpty(col.quantity ?? "", field: "\(field).quantity")
            try nonEmpty(col.unit ?? "", field: "\(field).unit")
        case .progression:
            guard let prog = col.progression else {
                throw ProfileV4Error.invalid(reason: "\(field).progression is required when role is progression.")
            }
            let progType = prog.progressionType
            guard progType == "time" || progType == "index" || progType == "custom" else {
                throw ProfileV4Error.invalid(reason: "\(field).progression.type must be time, index, or custom.")
            }
            if let behavior = prog.behavior, behavior != "continuous", behavior != "discrete" {
                throw ProfileV4Error.invalid(reason: "\(field).progression.behavior must be continuous or discrete.")
            }
        case .skip:
            break
        }
    }

    private static func validatePlot(
        _ plot: PlotSpecV4, field: String, columns: [String: ColumnDefinitionV4]
    ) throws {
        if plot.y.isEmpty {
            throw ProfileV4Error.invalid(reason: "\(field).plot.y must name at least one column.")
        }
        let keys = Set(columns.keys)
        if !keys.contains(plot.x) {
            throw ProfileV4Error.invalid(reason: "\(field).plot.x \"\(plot.x)\" is not a declared column.")
        }
        for y in plot.y where !keys.contains(y) {
            throw ProfileV4Error.invalid(reason: "\(field).plot.y \"\(y)\" is not a declared column.")
        }
    }

    // MARK: - decode variant tree

    private static func decodeVariant(_ node: YAMLNode, field: String) throws -> ProfileVariantV4 {
        guard node.mapEntries != nil else {
            throw ProfileV4Error.invalid(reason: "\(field) must be a mapping.")
        }
        try rejectUnknown(node, allowed: ["when", "format", "rows", "metadata", "columns", "plot"], scope: field)
        guard let formatNode = node.value(for: "format"), formatNode.mapEntries != nil else {
            throw ProfileV4Error.invalid(reason: "\(field).format mapping is required.")
        }
        guard let rowsNode = node.value(for: "rows"), rowsNode.mapEntries != nil else {
            throw ProfileV4Error.invalid(reason: "\(field).rows mapping is required.")
        }
        guard let columnsNode = node.value(for: "columns"), let columnEntries = columnsNode.mapEntries else {
            throw ProfileV4Error.invalid(reason: "\(field).columns mapping is required.")
        }
        guard let plotNode = node.value(for: "plot"), plotNode.mapEntries != nil else {
            throw ProfileV4Error.invalid(reason: "\(field).plot mapping is required.")
        }
        var columns: [String: ColumnDefinitionV4] = [:]
        for entry in columnEntries {
            columns[entry.key] = try decodeColumn(entry.value, field: "\(field).columns.\(entry.key)")
        }
        return ProfileVariantV4(
            when: try decodeWhen(node.value(for: "when"), field: "\(field).when"),
            format: try decodeFormat(formatNode, field: "\(field).format"),
            rows: try decodeRows(rowsNode, field: "\(field).rows"),
            metadata: try decodeMetadata(node.value(for: "metadata"), field: field),
            columns: columns,
            plot: try decodePlot(plotNode, field: field)
        )
    }

    private static func decodeFormat(_ node: YAMLNode, field: String) throws -> StreamFormatV4 {
        try rejectUnknown(node, allowed: ["kind", "extensions", "delimiter", "encoding", "decimal"], scope: field)
        let kind = try scalarRequired(node, key: "kind", field: "\(field).kind")
        let extensions = try stringList(node.value(for: "extensions"), field: "\(field).extensions", allowEmpty: false) ?? []
        let delimiterText = try scalarRequired(node, key: "delimiter", field: "\(field).delimiter")
        guard delimiterText.count == 1 else {
            throw ProfileV4Error.invalid(reason: "\(field).delimiter must be a single character.")
        }
        let delimiter = Character(delimiterText)
        let encodingNames: [String]
        if let enc = node.value(for: "encoding") {
            encodingNames = try stringList(enc, field: "\(field).encoding", allowEmpty: false) ?? []
        } else {
            encodingNames = ["utf-8"]
        }
        let decimalSeparator: Character
        if let text = node.value(for: "decimal")?.scalarValue {
            guard text.count == 1, text == "." || text == "," else {
                throw ProfileV4Error.invalid(reason: "\(field).decimal must be \".\" or \",\".")
            }
            decimalSeparator = Character(text)
        } else {
            decimalSeparator = "."
        }
        if delimiter == ",", decimalSeparator == "," {
            throw ProfileV4Error.invalid(reason: "\(field).decimal \",\" conflicts with delimiter \",\".")
        }
        return StreamFormatV4(
            kind: kind, extensions: extensions, delimiter: delimiter,
            encodingNames: encodingNames, decimalSeparator: decimalSeparator
        )
    }

    private static func decodeRows(_ node: YAMLNode, field: String) throws -> RowsBlockV4 {
        try rejectUnknown(
            node,
            allowed: ["metadata", "skip", "header", "data_start", "names_prefix", "data_prefix"],
            scope: field
        )
        return RowsBlockV4(
            metadataRows: try decodeRowList(node.value(for: "metadata"), field: "\(field).metadata"),
            skipRows: try decodeRowList(node.value(for: "skip"), field: "\(field).skip"),
            headerRow: try optionalPositiveInt(node.value(for: "header"), field: "\(field).header"),
            dataStartRow: try optionalPositiveInt(node.value(for: "data_start"), field: "\(field).data_start"),
            namesPrefix: optionalScalar(node, key: "names_prefix"),
            dataPrefix: optionalScalar(node, key: "data_prefix")
        )
    }

    private static func decodeRowList(_ node: YAMLNode?, field: String) throws -> [RowSpanV4] {
        guard let node else { return [] }
        guard let items = node.listItems else {
            throw ProfileV4Error.invalid(reason: "\(field) must be a list of row numbers or ranges.")
        }
        var spans: [RowSpanV4] = []
        for (index, item) in items.enumerated() {
            let text: String
            if let scalar = item.scalarValue {
                text = scalar
            } else {
                throw ProfileV4Error.invalid(reason: "\(field)[\(index)] must be a string or integer.")
            }
            spans.append(try parseRowSpan(text, field: "\(field)[\(index)]"))
        }
        return spans
    }

    private static func parseRowSpan(_ text: String, field: String) throws -> RowSpanV4 {
        if let value = Int(text) {
            guard value >= 1 else {
                throw ProfileV4Error.invalid(reason: "\(field) must be a 1-based row number.")
            }
            return RowSpanV4(start: value, end: value)
        }
        if let dash = text.firstIndex(of: "-") {
            let startText = text[..<dash].trimmingCharacters(in: .whitespaces)
            let endText = text[text.index(after: dash)...].trimmingCharacters(in: .whitespaces)
            guard let start = Int(startText), let end = Int(endText), start >= 1, end >= start else {
                throw ProfileV4Error.invalid(reason: "\(field) must be a valid 1-based range.")
            }
            return RowSpanV4(start: start, end: end)
        }
        throw ProfileV4Error.invalid(reason: "\(field) must be a row number or inclusive range such as \"1-9\".")
    }

    private static func decodeMetadata(_ node: YAMLNode?, field: String) throws -> [MetadataEntryV4] {
        guard let node else { return [] }
        guard let items = node.listItems else {
            throw ProfileV4Error.invalid(reason: "\(field).metadata must be a list.")
        }
        var out: [MetadataEntryV4] = []
        for (index, item) in items.enumerated() {
            let metaField = "\(field).metadata[\(index)]"
            guard item.mapEntries != nil else {
                throw ProfileV4Error.invalid(reason: "\(metaField) must be a mapping.")
            }
            if item.value(for: "column") != nil {
                try rejectUnknown(item, allowed: ["column", "row", "key"], scope: metaField)
                let column = try positiveInt(item.value(for: "column"), field: "\(metaField).column")
                let row = try positiveInt(item.value(for: "row"), field: "\(metaField).row")
                let key = try scalarRequired(item, key: "key", field: "\(metaField).key")
                out.append(.cellKey(column: column, row: row, key: key))
            } else {
                try rejectUnknown(item, allowed: ["row", "key", "type", "format"], scope: metaField)
                let row = try positiveInt(item.value(for: "row"), field: "\(metaField).row")
                let key = try scalarRequired(item, key: "key", field: "\(metaField).key")
                let valueType = try scalarRequired(item, key: "type", field: "\(metaField).type")
                out.append(.rowKeyValue(row: row, key: key, valueType: valueType, format: optionalScalar(item, key: "format")))
            }
        }
        return out
    }

    private static func decodePlot(_ node: YAMLNode, field: String) throws -> PlotSpecV4 {
        try rejectUnknown(node, allowed: ["x", "y"], scope: "\(field).plot")
        let x = try scalarRequired(node, key: "x", field: "\(field).plot.x")
        guard let yList = try stringList(node.value(for: "y"), field: "\(field).plot.y", allowEmpty: false), !yList.isEmpty else {
            throw ProfileV4Error.invalid(reason: "\(field).plot.y must be a non-empty list.")
        }
        return PlotSpecV4(x: x, y: yList)
    }

    private static func decodeColumn(_ node: YAMLNode, field: String) throws -> ColumnDefinitionV4 {
        guard node.mapEntries != nil else {
            throw ProfileV4Error.invalid(reason: "\(field) must be a mapping.")
        }
        try rejectUnknown(
            node,
            allowed: ["role", "label", "quantity", "unit", "header", "aliases", "required", "progression", "type", "behavior"],
            scope: field
        )
        let role: ColumnRoleV4
        if let text = node.value(for: "role")?.scalarValue {
            switch text {
            case "channel": role = .channel
            case "progression": role = .progression
            case "skip": role = .skip
            default:
                throw ProfileV4Error.invalid(reason: "\(field).role \"\(text)\" is not channel, progression, or skip.")
            }
        } else {
            role = .channel
        }
        var progression: ColumnProgressionV4?
        if let progNode = node.value(for: "progression") {
            progression = try decodeProgression(progNode, field: "\(field).progression")
        } else if role == .progression {
            guard let progType = node.value(for: "type")?.scalarValue else {
                throw ProfileV4Error.invalid(reason: "\(field).type is required for progression columns.")
            }
            progression = ColumnProgressionV4(progressionType: progType, behavior: optionalScalar(node, key: "behavior"))
        }
        let required: Bool
        if let text = node.value(for: "required")?.scalarValue {
            switch text {
            case "true": required = true
            case "false": required = false
            default:
                throw ProfileV4Error.invalid(reason: "\(field).required must be \"true\" or \"false\".")
            }
        } else {
            required = true
        }
        return ColumnDefinitionV4(
            role: role,
            label: optionalScalar(node, key: "label"),
            quantity: optionalScalar(node, key: "quantity"),
            unit: optionalScalar(node, key: "unit"),
            header: optionalScalar(node, key: "header"),
            aliases: try stringList(node.value(for: "aliases"), field: "\(field).aliases", allowEmpty: true) ?? [],
            required: required,
            progression: progression
        )
    }

    private static func decodeProgression(_ node: YAMLNode, field: String) throws -> ColumnProgressionV4 {
        guard node.mapEntries != nil else {
            throw ProfileV4Error.invalid(reason: "\(field) must be a mapping.")
        }
        try rejectUnknown(node, allowed: ["type", "behavior"], scope: field)
        let progressionType = try scalarRequired(node, key: "type", field: "\(field).type")
        return ColumnProgressionV4(progressionType: progressionType, behavior: optionalScalar(node, key: "behavior"))
    }

    private static func decodeWhen(_ node: YAMLNode?, field: String) throws -> WhenClauseV4? {
        guard let node else { return nil }
        guard let entries = node.mapEntries else {
            throw ProfileV4Error.invalid(reason: "\(field) must be a mapping.")
        }
        var when = WhenClauseV4()
        for entry in entries {
            switch entry.key {
            case "content_contains_any":
                when.contentContainsAny = try stringList(entry.value, field: "\(field).content_contains_any", allowEmpty: false) ?? []
            case "content_starts_with":
                when.contentStartsWith = try stringList(entry.value, field: "\(field).content_starts_with", allowEmpty: false) ?? []
            case "filename_contains_all":
                when.filenameContainsAll = try stringList(entry.value, field: "\(field).filename_contains_all", allowEmpty: false) ?? []
            default:
                guard let scalar = entry.value.scalarValue else {
                    throw ProfileV4Error.invalid(reason: "\(field).\(entry.key) must be a scalar equality value.")
                }
                when.tokens[entry.key] = scalar
            }
        }
        return when
    }

    // MARK: - YAML helpers

    private static func rejectUnknown(_ node: YAMLNode?, allowed: Set<String>, scope: String) throws {
        guard let entries = node?.mapEntries else { return }
        for entry in entries where !allowed.contains(entry.key) {
            if scope.isEmpty {
                throw ProfileV4Error.invalid(reason: "unknown key \"\(entry.key)\" is not part of schema v4.")
            }
            throw ProfileV4Error.invalid(reason: "\(scope).\(entry.key) is not part of schema v4 (unknown key).")
        }
    }

    private static func scalarRequired(_ node: YAMLNode, key: String, field: String) throws -> String {
        guard let value = optionalScalar(node, key: key) else {
            throw ProfileV4Error.invalid(reason: "\(field) is required.")
        }
        return value
    }

    private static func optionalScalar(_ node: YAMLNode, key: String) -> String? {
        guard let value = node.value(for: key)?.scalarValue, !value.isEmpty else { return nil }
        return value
    }

    private static func stringList(_ node: YAMLNode?, field: String, allowEmpty: Bool) throws -> [String]? {
        guard let node else { return nil }
        guard let items = node.listItems else {
            throw ProfileV4Error.invalid(reason: "\(field) must be a list.")
        }
        if !allowEmpty && items.isEmpty {
            throw ProfileV4Error.invalid(reason: "\(field) must not be empty.")
        }
        var out: [String] = []
        for item in items {
            guard let value = item.scalarValue else {
                throw ProfileV4Error.invalid(reason: "\(field) must contain only strings.")
            }
            out.append(value)
        }
        return out
    }

    private static func positiveInt(_ node: YAMLNode?, field: String) throws -> Int {
        guard let text = node?.scalarValue, let value = Int(text), value >= 1 else {
            throw ProfileV4Error.invalid(reason: "\(field) must be a positive integer.")
        }
        return value
    }

    private static func optionalPositiveInt(_ node: YAMLNode?, field: String) throws -> Int? {
        guard node != nil else { return nil }
        return try positiveInt(node, field: field)
    }

    private static func nonEmpty(_ value: String, field: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProfileV4Error.invalid(reason: "\(field) must not be empty.")
        }
    }
}

private func profileV4Humanized(_ key: String) -> String {
    key.replacingOccurrences(of: "_", with: " ").capitalized
}
