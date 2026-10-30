import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RawViewCore

/// High-resolution figure and clean CSV data exporter.
@MainActor
enum FigureExporter {
    enum ExportError: LocalizedError {
        case bitmapConversionFailed
        case pdfContextFailed
        case noDataToExport

        var errorDescription: String? {
            switch self {
            case .bitmapConversionFailed: return "Failed to generate high-resolution PNG bitmap."
            case .pdfContextFailed: return "Failed to generate vector PDF figure."
            case .noDataToExport: return "No data is currently available to export."
            }
        }
    }

    /// Renders any SwiftUI view as a high-resolution PNG image at specified scale (default 3x Retina, 300+ DPI).
    static func exportPNG<V: View>(view: V, size: CGSize, scale: CGFloat = 3.0, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let nsImage = renderer.nsImage else {
            throw ExportError.bitmapConversionFailed
        }
        guard let tiffData = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw ExportError.bitmapConversionFailed
        }
        try pngData.write(to: url, options: .atomic)
    }

    /// Renders any SwiftUI view as a vector PDF.
    static func exportPDF<V: View>(view: V, size: CGSize, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        var renderError: Error?
        renderer.render { _, renderInContext in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                renderError = ExportError.pdfContextFailed
                return
            }
            pdfContext.beginPDFPage(nil)
            renderInContext(pdfContext)
            pdfContext.endPDFPage()
            pdfContext.closePDF()
        }
        if let renderError {
            throw renderError
        }
    }

    /// Exports clean CSV table from NormalizedMeasurement
    static func exportCSV(measurement: NormalizedMeasurement, to url: URL) throws {
        var lines: [String] = []
        lines.append("# RawView Data Export")
        lines.append("# Source: \(measurement.source.path)")
        lines.append("# Instrument: \(measurement.instrument.name)")
        if let vendor = measurement.instrument.vendor, let model = measurement.instrument.model {
            lines.append("# Device: \(vendor) \(model)")
        }

        let headers = measurement.channels.map { ch -> String in
            let label = ch.label.isEmpty ? ch.name : ch.label
            let unitStr = ch.unit.isEmpty ? "" : " (\(ch.unit))"
            let title = "\(label)\(unitStr)"
            return "\"\(title.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        lines.append(headers.joined(separator: ","))

        let rowCount = measurement.channels.first?.values.count ?? 0
        for r in 0..<rowCount {
            let row = measurement.channels.map { ch -> String in
                guard r < ch.values.count, let val = ch.values[r] else { return "" }
                return String(format: "%.9g", val)
            }
            lines.append(row.joined(separator: ","))
        }

        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Presents NSSavePanel for Figure Export (PNG / PDF)
    static func promptExportFigure<V: View>(view: V, defaultName: String, size: CGSize = CGSize(width: 960, height: 600)) {
        let panel = NSSavePanel()
        panel.title = "Export Figure"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.png, .pdf]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "pdf" {
                try exportPDF(view: view, size: size, to: url)
            } else {
                try exportPNG(view: view, size: size, to: url)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Presents NSSavePanel for CSV Data Export
    static func promptExportData(measurement: NormalizedMeasurement?, defaultName: String) {
        guard let measurement else {
            let alert = NSAlert()
            alert.messageText = "No Measurement Data"
            alert.informativeText = "Please select a valid measurement to export."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Clean Data (CSV)"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportCSV(measurement: measurement, to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Exports a self-contained snapshot package to `data/snapshot/<packageName>/`
    /// containing `list.yaml`, `figure.png` (300 DPI Retina), and `figure.pdf` (vector PDF).
    static func exportSnapshotPackage<V: View>(
        projectRoot: URL,
        packageName: String,
        sourcePaths: [String],
        view: V,
        size: CGSize = CGSize(width: 960, height: 600)
    ) throws -> URL {
        let snapshotDir = projectRoot.appendingPathComponent("data/snapshot").appendingPathComponent(packageName)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let pngURL = snapshotDir.appendingPathComponent("figure.png")
        let pdfURL = snapshotDir.appendingPathComponent("figure.pdf")
        let yamlURL = snapshotDir.appendingPathComponent("list.yaml")

        try exportPNG(view: view, size: size, scale: 3.0, to: pngURL)
        try exportPDF(view: view, size: size, to: pdfURL)

        let isoDate = ISO8601DateFormatter().string(from: Date())
        var yamlLines: [String] = []
        yamlLines.append("# RawView Snapshot Package")
        yamlLines.append("snapshot: \"\(packageName)\"")
        yamlLines.append("created_at: \"\(isoDate)\"")
        yamlLines.append("images:")
        yamlLines.append("  - figure.png")
        yamlLines.append("  - figure.pdf")
        yamlLines.append("sources:")
        for src in sourcePaths {
            yamlLines.append("  - \(src)")
        }
        let yamlContent = yamlLines.joined(separator: "\n") + "\n"
        try yamlContent.write(to: yamlURL, atomically: true, encoding: .utf8)

        return snapshotDir
    }
}
