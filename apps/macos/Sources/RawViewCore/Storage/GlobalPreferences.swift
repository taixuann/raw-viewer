import Foundation

/// Curated scientific color palettes for multi-curve plots.
public enum ColorPalettePreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case classicScientific
    case okabeIto
    case natureNPG
    case viridisDiscrete

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classicScientific:
            return "Classic Scientific"
        case .okabeIto:
            return "Okabe-Ito (Colorblind Safe)"
        case .natureNPG:
            return "Nature / NPG"
        case .viridisDiscrete:
            return "Viridis Discrete"
        }
    }

    public var rgbValues: [[Int]] {
        switch self {
        case .classicScientific:
            return [[0, 64, 255], [225, 38, 0], [0, 158, 115], [230, 159, 0], [123, 44, 191], [102, 102, 102], [0, 0, 0]]
        case .okabeIto:
            return [[0, 114, 178], [213, 94, 0], [0, 158, 115], [204, 121, 167], [230, 159, 0], [86, 180, 233], [0, 0, 0]]
        case .natureNPG:
            return [[230, 75, 53], [77, 187, 213], [0, 160, 135], [60, 84, 136], [243, 155, 127], [132, 145, 180], [145, 209, 194]]
        case .viridisDiscrete:
            return [[68, 1, 84], [65, 68, 135], [42, 120, 142], [34, 168, 132], [122, 209, 81], [253, 231, 37]]
        }
    }

    public static func from(id: String) -> ColorPalettePreset {
        ColorPalettePreset(rawValue: id) ?? .classicScientific
    }
}

/// User-editable global defaults persisted in `~/.config/raw-viewer/config.yaml`.
public struct GlobalPreferences: Equatable, Sendable {
    public var schemaVersion: Int

    // Plot Style
    public var defaultPresetID: String
    public var defaultLineWidth: Double
    public var defaultMarkerSize: Double
    public var defaultMarkType: String
    public var defaultInterpolation: String
    public var defaultShowLegend: Bool
    public var defaultLegendScale: Double
    public var defaultPaletteID: String

    // Axes & Padding
    public var defaultXPaddingPercent: Double
    public var defaultYPaddingPercent: Double
    public var defaultXMajorTicks: Int
    public var defaultYMajorTicks: Int
    public var defaultXMinorTicks: Int
    public var defaultYMinorTicks: Int
    public var defaultShowMajorGrid: Bool
    public var defaultShowMinorGrid: Bool
    public var defaultShowZeroLine: Bool
    public var defaultShowCursor: Bool

    // Export
    public var defaultSnapshotDPI: Int
    public var defaultExportFormat: String
    public var defaultSnapshotSubdir: String

    // Workspace & Performance
    public var defaultTreeDateGranularity: String
    public var lazyInspectionEnabled: Bool
    public var maxComparisonAutoLoad: Int
    public var cacheLimitMB: Int

    public init(
        schemaVersion: Int = 1,
        defaultPresetID: String = "nature-single",
        defaultLineWidth: Double = 1.4,
        defaultMarkerSize: Double = 4.5,
        defaultMarkType: String = "line",
        defaultInterpolation: String = "linear",
        defaultShowLegend: Bool = true,
        defaultLegendScale: Double = 1.0,
        defaultPaletteID: String = ColorPalettePreset.classicScientific.rawValue,
        defaultXPaddingPercent: Double = 4.0,
        defaultYPaddingPercent: Double = 4.0,
        defaultXMajorTicks: Int = 0,
        defaultYMajorTicks: Int = 0,
        defaultXMinorTicks: Int = 0,
        defaultYMinorTicks: Int = 0,
        defaultShowMajorGrid: Bool = false,
        defaultShowMinorGrid: Bool = false,
        defaultShowZeroLine: Bool = false,
        defaultShowCursor: Bool = false,
        defaultSnapshotDPI: Int = 300,
        defaultExportFormat: String = "png",
        defaultSnapshotSubdir: String = "data/snapshot",
        defaultTreeDateGranularity: String = "day",
        lazyInspectionEnabled: Bool = true,
        maxComparisonAutoLoad: Int = 15,
        cacheLimitMB: Int = 512
    ) {
        self.schemaVersion = schemaVersion
        self.defaultPresetID = defaultPresetID
        self.defaultLineWidth = defaultLineWidth
        self.defaultMarkerSize = defaultMarkerSize
        self.defaultMarkType = defaultMarkType
        self.defaultInterpolation = defaultInterpolation
        self.defaultShowLegend = defaultShowLegend
        self.defaultLegendScale = defaultLegendScale
        self.defaultPaletteID = defaultPaletteID
        self.defaultXPaddingPercent = defaultXPaddingPercent
        self.defaultYPaddingPercent = defaultYPaddingPercent
        self.defaultXMajorTicks = defaultXMajorTicks
        self.defaultYMajorTicks = defaultYMajorTicks
        self.defaultXMinorTicks = defaultXMinorTicks
        self.defaultYMinorTicks = defaultYMinorTicks
        self.defaultShowMajorGrid = defaultShowMajorGrid
        self.defaultShowMinorGrid = defaultShowMinorGrid
        self.defaultShowZeroLine = defaultShowZeroLine
        self.defaultShowCursor = defaultShowCursor
        self.defaultSnapshotDPI = defaultSnapshotDPI
        self.defaultExportFormat = defaultExportFormat
        self.defaultSnapshotSubdir = defaultSnapshotSubdir
        self.defaultTreeDateGranularity = defaultTreeDateGranularity
        self.lazyInspectionEnabled = lazyInspectionEnabled
        self.maxComparisonAutoLoad = maxComparisonAutoLoad
        self.cacheLimitMB = cacheLimitMB
    }

    public func clamped() -> GlobalPreferences {
        var copy = self
        copy.defaultLineWidth = Self.clamp(defaultLineWidth, to: 0.2...10.0, fallback: 1.4)
        copy.defaultMarkerSize = Self.clamp(defaultMarkerSize, to: 1.0...16.0, fallback: 4.5)
        copy.defaultLegendScale = Self.clamp(defaultLegendScale, to: 0.5...2.0, fallback: 1.0)
        copy.defaultXPaddingPercent = Self.clamp(defaultXPaddingPercent, to: 0.0...50.0, fallback: 4.0)
        copy.defaultYPaddingPercent = Self.clamp(defaultYPaddingPercent, to: 0.0...50.0, fallback: 4.0)
        copy.defaultXMajorTicks = Self.clamp(defaultXMajorTicks, to: 0...20)
        copy.defaultYMajorTicks = Self.clamp(defaultYMajorTicks, to: 0...20)
        copy.defaultXMinorTicks = Self.clamp(defaultXMinorTicks, to: 0...20)
        copy.defaultYMinorTicks = Self.clamp(defaultYMinorTicks, to: 0...20)
        copy.defaultSnapshotDPI = Self.clamp(defaultSnapshotDPI, to: 72...1200)
        copy.maxComparisonAutoLoad = Self.clamp(maxComparisonAutoLoad, to: 1...200)
        copy.cacheLimitMB = Self.clamp(cacheLimitMB, to: 64...8192)
        return copy
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

public enum GlobalPreferencesError: Error, Equatable, LocalizedError {
    case invalidYAML(String)
    case invalidRoot

    public var errorDescription: String? {
        switch self {
        case .invalidYAML(let message):
            return "Global preferences YAML parse error: \(message)"
        case .invalidRoot:
            return "Global preferences document must be a YAML mapping."
        }
    }
}

/// Persistence boundary for `GlobalPreferences` at `<globalConfigDir>/config.yaml`.
public enum GlobalPreferencesStore {
    public static func load(globalConfigDir: URL? = nil) -> GlobalPreferences {
        let fileURL = GlobalPathResolver.globalConfigFile(globalConfigDir: globalConfigDir)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8),
              let parsed = try? parse(yaml: text) else {
            return GlobalPreferences()
        }
        return parsed
    }

    public static func save(_ prefs: GlobalPreferences, globalConfigDir: URL? = nil) throws {
        let fileURL = GlobalPathResolver.globalConfigFile(globalConfigDir: globalConfigDir)
        let dirURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let normalized = prefs.clamped()
        let yaml = serialize(normalized)
        try Data(yaml.utf8).write(to: fileURL, options: [.atomic])
    }

    public static func parse(yaml: String) throws -> GlobalPreferences {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return GlobalPreferences() }

        let root: YAMLNode
        do {
            root = try YAMLParser.parse(yaml, allowIndentlessSequences: false)
        } catch let error as YAMLParseError {
            throw GlobalPreferencesError.invalidYAML(error.localizedDescription)
        } catch {
            throw GlobalPreferencesError.invalidYAML(error.localizedDescription)
        }

        guard root.mapEntries != nil else {
            throw GlobalPreferencesError.invalidRoot
        }

        var prefs = GlobalPreferences()
        if let v = intValue(root, key: "schema_version") { prefs.schemaVersion = v }

        // Plot Style
        if let v = stringValue(root, key: "default_preset_id") { prefs.defaultPresetID = v }
        if let v = doubleValue(root, key: "default_line_width") { prefs.defaultLineWidth = v }
        if let v = doubleValue(root, key: "default_marker_size") { prefs.defaultMarkerSize = v }
        if let v = stringValue(root, key: "default_mark_type") { prefs.defaultMarkType = v }
        if let v = stringValue(root, key: "default_interpolation") { prefs.defaultInterpolation = v }
        if let v = boolValue(root, key: "default_show_legend") { prefs.defaultShowLegend = v }
        if let v = doubleValue(root, key: "default_legend_scale") { prefs.defaultLegendScale = v }
        if let v = stringValue(root, key: "default_palette_id") { prefs.defaultPaletteID = v }

        // Axes & Padding
        if let v = doubleValue(root, key: "default_x_padding_percent") { prefs.defaultXPaddingPercent = v }
        if let v = doubleValue(root, key: "default_y_padding_percent") { prefs.defaultYPaddingPercent = v }
        if let v = intValue(root, key: "default_x_major_ticks") { prefs.defaultXMajorTicks = v }
        if let v = intValue(root, key: "default_y_major_ticks") { prefs.defaultYMajorTicks = v }
        if let v = intValue(root, key: "default_x_minor_ticks") { prefs.defaultXMinorTicks = v }
        if let v = intValue(root, key: "default_y_minor_ticks") { prefs.defaultYMinorTicks = v }
        if let v = boolValue(root, key: "default_show_major_grid") { prefs.defaultShowMajorGrid = v }
        if let v = boolValue(root, key: "default_show_minor_grid") { prefs.defaultShowMinorGrid = v }
        if let v = boolValue(root, key: "default_show_zero_line") { prefs.defaultShowZeroLine = v }
        if let v = boolValue(root, key: "default_show_cursor") { prefs.defaultShowCursor = v }

        // Export
        if let v = intValue(root, key: "default_snapshot_dpi") { prefs.defaultSnapshotDPI = v }
        if let v = stringValue(root, key: "default_export_format") { prefs.defaultExportFormat = v }
        if let v = stringValue(root, key: "default_snapshot_subdir") { prefs.defaultSnapshotSubdir = v }

        // Workspace & Performance
        if let v = stringValue(root, key: "default_tree_date_granularity") { prefs.defaultTreeDateGranularity = v }
        if let v = boolValue(root, key: "lazy_inspection_enabled") { prefs.lazyInspectionEnabled = v }
        if let v = intValue(root, key: "max_comparison_auto_load") { prefs.maxComparisonAutoLoad = v }
        if let v = intValue(root, key: "cache_limit_mb") { prefs.cacheLimitMB = v }

        return prefs.clamped()
    }

    public static func serialize(_ prefs: GlobalPreferences) -> String {
        let p = prefs.clamped()
        let lines: [String] = [
            "schema_version: \(p.schemaVersion)",
            "default_preset_id: \(quoted(p.defaultPresetID))",
            "default_line_width: \(p.defaultLineWidth)",
            "default_marker_size: \(p.defaultMarkerSize)",
            "default_mark_type: \(quoted(p.defaultMarkType))",
            "default_interpolation: \(quoted(p.defaultInterpolation))",
            "default_show_legend: \(p.defaultShowLegend ? "true" : "false")",
            "default_legend_scale: \(p.defaultLegendScale)",
            "default_palette_id: \(quoted(p.defaultPaletteID))",
            "default_x_padding_percent: \(p.defaultXPaddingPercent)",
            "default_y_padding_percent: \(p.defaultYPaddingPercent)",
            "default_x_major_ticks: \(p.defaultXMajorTicks)",
            "default_y_major_ticks: \(p.defaultYMajorTicks)",
            "default_x_minor_ticks: \(p.defaultXMinorTicks)",
            "default_y_minor_ticks: \(p.defaultYMinorTicks)",
            "default_show_major_grid: \(p.defaultShowMajorGrid ? "true" : "false")",
            "default_show_minor_grid: \(p.defaultShowMinorGrid ? "true" : "false")",
            "default_show_zero_line: \(p.defaultShowZeroLine ? "true" : "false")",
            "default_show_cursor: \(p.defaultShowCursor ? "true" : "false")",
            "default_snapshot_dpi: \(p.defaultSnapshotDPI)",
            "default_export_format: \(quoted(p.defaultExportFormat))",
            "default_snapshot_subdir: \(quoted(p.defaultSnapshotSubdir))",
            "default_tree_date_granularity: \(quoted(p.defaultTreeDateGranularity))",
            "lazy_inspection_enabled: \(p.lazyInspectionEnabled ? "true" : "false")",
            "max_comparison_auto_load: \(p.maxComparisonAutoLoad)",
            "cache_limit_mb: \(p.cacheLimitMB)",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func stringValue(_ root: YAMLNode, key: String) -> String? {
        root.value(for: key)?.scalarValue
    }

    private static func intValue(_ root: YAMLNode, key: String) -> Int? {
        guard let raw = root.value(for: key)?.scalarValue else { return nil }
        return Int(raw)
    }

    private static func doubleValue(_ root: YAMLNode, key: String) -> Double? {
        guard let raw = root.value(for: key)?.scalarValue else { return nil }
        return Double(raw)
    }

    private static func boolValue(_ root: YAMLNode, key: String) -> Bool? {
        guard let raw = root.value(for: key)?.scalarValue else { return nil }
        switch raw.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
