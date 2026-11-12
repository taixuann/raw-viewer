import AppKit
import SwiftUI
import RawViewCore

// MARK: - Native Overlay Palette

/// Shared color palette and font configuration for scientific overlays and plots.
enum NativeOverlayPalette {
    static let values: [[Int]] = {
        if let url = Bundle.main.url(forResource: "NativePlotStyle", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(OverlayPalettePayload.self, from: data),
           !payload.paletteRGB.isEmpty {
            return payload.paletteRGB
        }
        return [[0, 64, 255], [225, 38, 0], [0, 158, 115], [230, 159, 0], [123, 44, 191], [102, 102, 102], [0, 0, 0]]
    }()

    static let fontFamily: String = {
        if let url = Bundle.main.url(forResource: "NativePlotStyle", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(OverlayPalettePayload.self, from: data) {
            return payload.fontFamily
        }
        return "Helvetica Neue"
    }()

    static func colors(for palette: ColorPalettePreset) -> [Color] {
        palette.rgbValues.compactMap { rgb in
            guard rgb.count >= 3 else { return nil }
            return Color(.sRGB, red: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255,
                         blue: Double(rgb[2]) / 255, opacity: 1)
        }
    }

    static func color(_ index: Int, palette: ColorPalettePreset) -> Color {
        let paletteColors = colors(for: palette)
        guard !paletteColors.isEmpty else { return .blue }
        return paletteColors[abs(index) % paletteColors.count]
    }

    static func color(_ index: Int) -> Color {
        guard !values.isEmpty else { return .blue }
        let color = values[abs(index) % values.count]
        return Color(.sRGB, red: Double(color[0]) / 255, green: Double(color[1]) / 255,
                    blue: Double(color[2]) / 255, opacity: 1)
    }
}

private struct OverlayPalettePayload: Decodable {
    enum CodingKeys: String, CodingKey { case paletteRGB = "palette_rgb", fontFamily = "font_family" }
    let paletteRGB: [[Int]]
    let fontFamily: String
}
