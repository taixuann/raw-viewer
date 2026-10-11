import Foundation

/// Scans and loads custom FigRecipe/RawView scientific presets from `<project>/.rawviewer/preset/*.yaml`.
public struct PresetCatalog: Sendable {
    public static func load(project: ProjectContext) -> [ScientificPreset] {
        let presetDirectory = project.root.appendingPathComponent(".rawviewer/preset", isDirectory: true)
        var customPresets: [ScientificPreset] = []

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: presetDirectory.path, isDirectory: &isDir),
           isDir.boolValue,
           FileManager.default.isReadableFile(atPath: presetDirectory.path) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: presetDirectory.path)) ?? []
            for file in files.sorted() {
                let lower = file.lowercased()
                guard lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") else { continue }
                let url = presetDirectory.appendingPathComponent(file)
                if let preset = parsePresetFile(at: url) {
                    customPresets.append(preset)
                }
            }
        }

        // Merge custom presets with standard built-in presets
        var result = customPresets
        for standard in ScientificPreset.allCases {
            if !result.contains(where: { $0.id == standard.id }) {
                result.append(standard)
            }
        }
        return result
    }

    public static func parsePresetFile(at url: URL) -> ScientificPreset? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let node = try? YAMLParser.parse(text) else {
            return nil
        }
        return parsePresetNode(node, fallbackID: url.deletingPathExtension().lastPathComponent)
    }

    static func parsePresetNode(_ node: YAMLNode, fallbackID: String) -> ScientificPreset? {
        let id = node.value(for: "id")?.scalarValue ?? fallbackID
        let displayName = node.value(for: "name")?.scalarValue
            ?? node.value(for: "display_name")?.scalarValue
            ?? id.replacingOccurrences(of: "-", with: " ").capitalized
        let publisher = node.value(for: "publisher")?.scalarValue ?? "Custom"

        let widthMM = Double(node.value(for: "width_mm")?.scalarValue ?? "") ?? 59.1
        let heightMM = Double(node.value(for: "height_mm")?.scalarValue ?? "") ?? 50.0
        let isOpenFrame = (node.value(for: "open_frame")?.scalarValue?.lowercased() == "true")
            || (node.value(for: "is_open_frame")?.scalarValue?.lowercased() == "true")
        let isSerif = (node.value(for: "serif")?.scalarValue?.lowercased() == "true")
            || (node.value(for: "is_serif")?.scalarValue?.lowercased() == "true")

        let spineThicknessPt = Double(node.value(for: "spine_thickness_pt")?.scalarValue ?? "") ?? 0.8
        let tickLengthPt = Double(node.value(for: "tick_length_pt")?.scalarValue ?? "") ?? 4.25
        let titlePt = Double(node.value(for: "title_pt")?.scalarValue ?? "") ?? 8.5
        let axisLabelPt = Double(node.value(for: "axis_label_pt")?.scalarValue ?? "") ?? 8.0
        let tickLabelPt = Double(node.value(for: "tick_label_pt")?.scalarValue ?? "") ?? 7.5
        let legendPt = Double(node.value(for: "legend_pt")?.scalarValue ?? "") ?? 7.0

        return ScientificPreset(
            id: id,
            displayName: displayName,
            publisher: publisher,
            widthMM: widthMM,
            heightMM: heightMM,
            isOpenFrame: isOpenFrame,
            isSerif: isSerif,
            spineThicknessPt: spineThicknessPt,
            tickLengthPt: tickLengthPt,
            titlePt: titlePt,
            axisLabelPt: axisLabelPt,
            tickLabelPt: tickLabelPt,
            legendPt: legendPt
        )
    }
}
