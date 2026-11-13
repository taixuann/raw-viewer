import Foundation
import Testing
@testable import RawViewCore

private func makeTempConfigDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-prefs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func missingFileReturnsFactoryDefaults() throws {
    let dir = try makeTempConfigDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let loaded = GlobalPreferencesStore.load(globalConfigDir: dir)
    #expect(loaded == GlobalPreferences())
}

@Test func saveAndLoadRoundtripPreservesAllFields() throws {
    let dir = try makeTempConfigDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let custom = GlobalPreferences(
        schemaVersion: 1,
        defaultPresetID: "ieee-double",
        defaultLineWidth: 2.25,
        defaultMarkerSize: 6.5,
        defaultMarkType: "scatter",
        defaultInterpolation: "step",
        defaultShowLegend: false,
        defaultLegendScale: 1.5,
        defaultPaletteID: ColorPalettePreset.okabeIto.rawValue,
        defaultXPaddingPercent: 8.0,
        defaultYPaddingPercent: 12.5,
        defaultXMajorTicks: 6,
        defaultYMajorTicks: 5,
        defaultXMinorTicks: 4,
        defaultYMinorTicks: 2,
        defaultShowMajorGrid: true,
        defaultShowMinorGrid: true,
        defaultShowZeroLine: true,
        defaultShowCursor: true,
        defaultSnapshotDPI: 600,
        defaultExportFormat: "svg",
        defaultSnapshotSubdir: "exports/figures",
        defaultTreeGrouping: ["study", "device", "date"],
        defaultTreeDateGranularity: "month",
        lazyInspectionEnabled: false,
        maxComparisonAutoLoad: 42,
        cacheLimitMB: 2048
    )

    try GlobalPreferencesStore.save(custom, globalConfigDir: dir)
    let loaded = GlobalPreferencesStore.load(globalConfigDir: dir)
    #expect(loaded == custom)
}

@Test func partialYAMLFileMergesWithDefaults() throws {
    let partialYAML = """
    schema_version: 1
    default_line_width: 3.0
    default_palette_id: "natureNPG"
    default_show_major_grid: true
    default_snapshot_dpi: 450
    """

    let parsed = try GlobalPreferencesStore.parse(yaml: partialYAML)
    var expected = GlobalPreferences()
    expected.defaultLineWidth = 3.0
    expected.defaultPaletteID = ColorPalettePreset.natureNPG.rawValue
    expected.defaultShowMajorGrid = true
    expected.defaultSnapshotDPI = 450

    #expect(parsed == expected)
}

@Test func outOfRangeNumericValuesAreClamped() throws {
    let dir = try makeTempConfigDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let extremeLow = GlobalPreferences(
        defaultLineWidth: -5.0,
        defaultMarkerSize: 0.0,
        defaultLegendScale: 0.1,
        defaultXPaddingPercent: -10.0,
        defaultYPaddingPercent: -1.0,
        defaultXMajorTicks: -3,
        defaultYMajorTicks: -1,
        defaultXMinorTicks: -2,
        defaultYMinorTicks: -9,
        defaultSnapshotDPI: 10,
        maxComparisonAutoLoad: 0,
        cacheLimitMB: 8
    )

    try GlobalPreferencesStore.save(extremeLow, globalConfigDir: dir)
    let loadedLow = GlobalPreferencesStore.load(globalConfigDir: dir)
    #expect(loadedLow.defaultLineWidth == 0.2)
    #expect(loadedLow.defaultMarkerSize == 1.0)
    #expect(loadedLow.defaultLegendScale == 0.5)
    #expect(loadedLow.defaultXPaddingPercent == 0.0)
    #expect(loadedLow.defaultYPaddingPercent == 0.0)
    #expect(loadedLow.defaultXMajorTicks == 0)
    #expect(loadedLow.defaultYMajorTicks == 0)
    #expect(loadedLow.defaultXMinorTicks == 0)
    #expect(loadedLow.defaultYMinorTicks == 0)
    #expect(loadedLow.defaultSnapshotDPI == 72)
    #expect(loadedLow.maxComparisonAutoLoad == 1)
    #expect(loadedLow.cacheLimitMB == 64)

    let extremeHighYAML = """
    default_line_width: 99.0
    default_marker_size: 40.0
    default_legend_scale: 9.0
    default_x_padding_percent: 80.0
    default_y_padding_percent: 120.0
    default_x_major_ticks: 50
    default_y_major_ticks: 99
    default_x_minor_ticks: 30
    default_y_minor_ticks: 21
    default_snapshot_dpi: 2400
    max_comparison_auto_load: 500
    cache_limit_mb: 32768
    """

    let parsedHigh = try GlobalPreferencesStore.parse(yaml: extremeHighYAML)
    #expect(parsedHigh.defaultLineWidth == 10.0)
    #expect(parsedHigh.defaultMarkerSize == 16.0)
    #expect(parsedHigh.defaultLegendScale == 2.0)
    #expect(parsedHigh.defaultXPaddingPercent == 50.0)
    #expect(parsedHigh.defaultYPaddingPercent == 50.0)
    #expect(parsedHigh.defaultXMajorTicks == 20)
    #expect(parsedHigh.defaultYMajorTicks == 20)
    #expect(parsedHigh.defaultXMinorTicks == 20)
    #expect(parsedHigh.defaultYMinorTicks == 20)
    #expect(parsedHigh.defaultSnapshotDPI == 1200)
    #expect(parsedHigh.maxComparisonAutoLoad == 200)
    #expect(parsedHigh.cacheLimitMB == 8192)
}

@Test func colorPalettePresetsHaveValidRGBTriplets() {
    for preset in ColorPalettePreset.allCases {
        #expect(!preset.displayName.isEmpty)
        #expect(!preset.rgbValues.isEmpty)
        #expect(ColorPalettePreset.from(id: preset.id) == preset)
        for rgb in preset.rgbValues {
            #expect(rgb.count == 3)
            for channel in rgb {
                #expect((0...255).contains(channel))
            }
        }
    }
    #expect(ColorPalettePreset.from(id: "unknown-palette") == .classicScientific)
}
