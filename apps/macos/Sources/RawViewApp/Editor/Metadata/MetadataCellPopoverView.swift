import SwiftUI
import RawViewCore

/// Interactive popover for assigning or editing semantic metadata tags on raw data cells.
/// Features Smart Auto-Inference & Excel-Style Coordinate Binding:
/// - Coordinate Bar: Displays Excel-style coordinate (e.g. `Row 2, Col B (L2:Col 2)`).
/// - Key Coordinate Input: Allows entering/editing the Key token coordinate or text directly.
/// - Value Coordinate: Shows target value and allows custom overriding.
/// - 1-tap quick suggestions & auto-inferred parameter names from adjacent tokens.
/// - Synchronized role color linking: Links Key and Value cells visually.
public struct MetadataCellPopoverView: View {
    public let target: CellTarget
    public let existingTag: MetadataCellTag?
    public let adjacentTokens: [String]
    public let onSave: (MetadataCellTag) -> Void
    public let onRemove: () -> Void
    public let onDismiss: () -> Void

    @State private var selectedEntity: MetadataCellTag.EntityType
    @State private var parameterKeyText: String
    @State private var keyLineText: String
    @State private var keyColText: String
    @State private var customFormatText: String
    @State private var suggestedKeys: [String] = []

    public init(
        target: CellTarget,
        existingTag: MetadataCellTag?,
        adjacentTokens: [String],
        onSave: @escaping (MetadataCellTag) -> Void,
        onRemove: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.target = target
        self.existingTag = existingTag
        self.adjacentTokens = adjacentTokens
        self.onSave = onSave
        self.onRemove = onRemove
        self.onDismiss = onDismiss

        // Smart Heuristic Auto-Inference
        var initialKey = existingTag?.parameterKey ?? existingTag?.customKey ?? ""
        var initialEntity = existingTag?.entityType ?? .parameter
        var initialFormat = existingTag?.format ?? ""
        var suggestions: [String] = []

        let raw = target.token.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Check if token itself contains key:value (e.g. "Scan Rate: 100 mV/s" or "Temp=25C")
        if let colonIdx = raw.firstIndex(of: ":") {
            let potentialKey = String(raw[..<colonIdx]).trimmingCharacters(in: CharacterSet.alphanumerics.inverted.union(.whitespaces))
            if !potentialKey.isEmpty && initialKey.isEmpty {
                initialKey = potentialKey
            }
        } else if let eqIdx = raw.firstIndex(of: "=") {
            let potentialKey = String(raw[..<eqIdx]).trimmingCharacters(in: CharacterSet.alphanumerics.inverted.union(.whitespaces))
            if !potentialKey.isEmpty && initialKey.isEmpty {
                initialKey = potentialKey
            }
        }

        // 2. Check adjacent tokens (left neighbor is typically the parameter key!)
        for adj in adjacentTokens {
            let clean = adj.replacingOccurrences(of: ":", with: "")
                           .replacingOccurrences(of: "=", with: "")
                           .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !suggestions.contains(clean) && clean != raw {
                suggestions.append(clean)
            }
        }

        if initialKey.isEmpty, let firstSug = suggestions.first {
            initialKey = firstSug
        }

        // 3. Smart Entity Inference from text value
        if existingTag == nil {
            if raw.contains("-") && raw.count >= 8 && raw.rangeOfCharacter(from: .decimalDigits) != nil {
                initialEntity = .dateTime
                initialFormat = "YYYY-MM-DD"
            } else if raw.contains(":") && raw.count <= 8 && raw.rangeOfCharacter(from: .decimalDigits) != nil {
                initialEntity = .timeOnly
                initialFormat = "HH:mm:ss"
            } else if Double(raw.components(separatedBy: CharacterSet(charactersIn: " +-eE0123456789.").inverted).first ?? "") != nil {
                initialEntity = .parameter
            } else {
                initialEntity = .sampleName
            }
        }

        let defaultKeyCol = max(0, target.tokenIdx - 1)
        _selectedEntity = State(initialValue: initialEntity)
        _parameterKeyText = State(initialValue: initialKey)
        _keyLineText = State(initialValue: "\(existingTag?.parameterLineIndex.map { $0 + 1 } ?? (target.lineIdx + 1))")
        _keyColText = State(initialValue: "\(existingTag?.parameterTokenIndex.map { $0 + 1 } ?? (defaultKeyCol + 1))")
        _customFormatText = State(initialValue: initialFormat)
        _suggestedKeys = State(initialValue: suggestions)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(Color.purple)
                    .font(.system(size: 12))
                Text("Metadata Parameter Pair")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text(excelCoord(row: target.lineIdx + 1, col: target.tokenIdx + 1))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Capsule())
            }

            Divider()

            // Target Value & Cell Coordinate
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Target Value Cell:")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Row \(target.lineIdx + 1), Col \(target.tokenIdx + 1)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Text(target.token.isEmpty ? "— (empty)" : target.token)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Text(selectedEntity.rawValue)
                        .font(.system(size: 8.5, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12))
                        .foregroundStyle(Color.purple)
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.2), lineWidth: 0.8))
            }

            // Key Coordinate & Parameter Name Input
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Parameter Key (Name):")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !parameterKeyText.isEmpty {
                        Text("Linked Pair")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }

                TextField("e.g. Scan Rate, Temperature, pH", text: $parameterKeyText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                // Excel-style Row / Col coordinates for Key
                HStack(spacing: 6) {
                    Text("Key Cell Coord:")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 2) {
                        Text("Row").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                        TextField("Row", text: $keyLineText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 9.5, design: .monospaced))
                            .frame(width: 44)
                    }

                    HStack(spacing: 2) {
                        Text("Col").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                        TextField("Col", text: $keyColText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 9.5, design: .monospaced))
                            .frame(width: 44)
                    }

                    if let r = Int(keyLineText), let c = Int(keyColText) {
                        Text(excelCoord(row: r, col: c))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.purple)
                    }
                }

                // Quick suggestions chips
                if !suggestedKeys.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Detected suggestions:")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                        FlowPillsView(pills: suggestedKeys) { sug in
                            parameterKeyText = sug
                        }
                    }
                }
            }

            // Category Type Buttons
            VStack(alignment: .leading, spacing: 3) {
                Text("Category Type:")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    entityPill(.parameter, label: "Numeric Parameter", icon: "slider.horizontal.3")
                    entityPill(.sampleName, label: "Sample / Text", icon: "tag.text.purple")
                    entityPill(.dateTime, label: "Date / Time", icon: "calendar")
                }
            }

            // Optional Format (for Date/Time)
            if selectedEntity == .dateTime || selectedEntity == .dateOnly || selectedEntity == .timeOnly {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Format (Optional):")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("e.g. yyyy-MM-dd HH:mm:ss", text: $customFormatText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10.5, design: .monospaced))
                }
            }

            Divider()

            // Actions
            HStack(spacing: 8) {
                if existingTag != nil {
                    Button("Clear Tag", role: .destructive) {
                        onRemove()
                        onDismiss()
                    }
                    .font(.system(size: 10.5))
                    .controlSize(.small)
                }

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }
                .font(.system(size: 10.5))
                .controlSize(.small)

                Button("Assign Tag") {
                    let key = parameterKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let pLine = Int(keyLineText).map { max(0, $0 - 1) }
                    let pCol = Int(keyColText).map { max(0, $0 - 1) }

                    let tag = MetadataCellTag(
                        lineIndex: target.lineIdx,
                        tokenIndex: target.tokenIdx,
                        rawValue: target.token,
                        entityType: selectedEntity,
                        customKey: key.isEmpty ? nil : key,
                        format: customFormatText.isEmpty ? nil : customFormatText,
                        parameterKey: key.isEmpty ? nil : key,
                        parameterLineIndex: pLine,
                        parameterTokenIndex: pCol
                    )
                    onSave(tag)
                    onDismiss()
                }
                .font(.system(size: 10.5, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 310)
    }

    private func excelCoord(row: Int, col: Int) -> String {
        let colLetter = colLetterForIndex(col)
        return "\(colLetter)\(row)"
    }

    private func colLetterForIndex(_ col: Int) -> String {
        guard col > 0 else { return "A" }
        var n = col
        var s = ""
        while n > 0 {
            let rem = (n - 1) % 26
            s = String(UnicodeScalar(65 + rem)!) + s
            n = (n - 1) / 26
        }
        return s
    }

    @ViewBuilder
    private func entityPill(_ type: MetadataCellTag.EntityType, label: String, icon: String) -> some View {
        Button {
            selectedEntity = type
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8.5))
                Text(label)
                    .font(.system(size: 8.5, weight: selectedEntity == type ? .bold : .regular))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(selectedEntity == type ? Color.purple.opacity(0.18) : Color(NSColor.controlBackgroundColor))
            .foregroundStyle(selectedEntity == type ? Color.purple : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selectedEntity == type ? Color.purple : Color.secondary.opacity(0.2), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

/// Helper view for rendering suggestion pills cleanly
fileprivate struct FlowPillsView: View {
    let pills: [String]
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(pills.prefix(4), id: \.self) { pill in
                Button {
                    onSelect(pill)
                } label: {
                    Text(pill)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.08))
                        .foregroundStyle(Color.blue)
                        .cornerRadius(3)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.blue.opacity(0.2), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
