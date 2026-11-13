import AppKit
import SwiftUI
import RawViewCore

/// Reusable interactive editor for tree grouping hierarchy and date granularity.
/// Displays an ordered list of grouping levels with up/down reordering, quick-add
/// pills for remaining grammar tokens, and a live breadcrumb preview.
public struct TreeHierarchyEditorView: View {
    public let availableFields: [String]
    @Binding public var selectedFields: [String]
    @Binding public var dateGranularity: String
    public var uiFontSize: Double = AppTypography.baselineFontSize
    public var fontFamily: String = "System"
    public var isCompact: Bool = false
    public var onChanged: (() -> Void)? = nil

    public init(
        availableFields: [String],
        selectedFields: Binding<[String]>,
        dateGranularity: Binding<String>,
        uiFontSize: Double = AppTypography.baselineFontSize,
        fontFamily: String = "System",
        isCompact: Bool = false,
        onChanged: (() -> Void)? = nil
    ) {
        self.availableFields = availableFields
        self._selectedFields = selectedFields
        self._dateGranularity = dateGranularity
        self.uiFontSize = uiFontSize
        self.fontFamily = fontFamily
        self.isCompact = isCompact
        self.onChanged = onChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Live Breadcrumb Preview
            breadcrumbPreview

            // Active Levels
            activeLevelsSection

            // Available Tokens to Add
            availableTokensSection

            // Date Granularity Picker
            dateGranularitySection

            // Reset action
            HStack {
                Button {
                    let defaults = ["device", "application-mode", "device-id", "date"]
                    let filtered = defaults.filter { availableFields.contains($0) }
                    selectedFields = filtered.isEmpty ? Array(availableFields.prefix(3)) : filtered
                    dateGranularity = "day"
                    onChanged?()
                } label: {
                    Label("Reset Default Hierarchy", systemImage: "arrow.counterclockwise")
                        .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Breadcrumb Preview

    private var breadcrumbPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("LIVE TREE FOLDER PREVIEW")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if selectedFields.isEmpty {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Flat List (No Folder Grouping)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedFields.indices, id: \.self) { idx in
                            let field = selectedFields[idx]
                            HStack(spacing: 3) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.accentColor.opacity(0.85))
                                Text(field == "date" ? "\(field) (\(dateGranularity))" : field)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))

                            Text("›")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }

                        HStack(spacing: 3) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text("sample_001.csv")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 5).padding(.vertical, 3)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    // MARK: - Active Levels

    private var activeLevelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ORDERED TREE LEVELS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selectedFields.count) level\(selectedFields.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if selectedFields.isEmpty {
                Text("No levels selected. Add tokens below to create grouping folders.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                VStack(spacing: 4) {
                    ForEach(selectedFields.indices, id: \.self) { idx in
                        levelRow(index: idx, field: selectedFields[idx])
                    }
                }
            }
        }
    }

    private func levelRow(index: Int, field: String) -> some View {
        HStack(spacing: 8) {
            Text("L\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.accentColor.opacity(0.12)))

            AppTokenPill(
                name: field,
                isOptional: false,
                isHighlighted: false,
                uiFontSize: uiFontSize
            )
            .fixedSize(horizontal: true, vertical: false)

            if field == "date" {
                Text("(\(dateGranularity))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Reorder controls
            HStack(spacing: 2) {
                Button {
                    guard index > 0 else { return }
                    selectedFields.swapAt(index, index - 1)
                    onChanged?()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .opacity(index == 0 ? 0.25 : 1.0)
                .help("Move level up")

                Button {
                    guard index < selectedFields.count - 1 else { return }
                    selectedFields.swapAt(index, index + 1)
                    onChanged?()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(index == selectedFields.count - 1)
                .opacity(index == selectedFields.count - 1 ? 0.25 : 1.0)
                .help("Move level down")

                Button {
                    selectedFields.remove(at: index)
                    onChanged?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Remove level")
            }
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    // MARK: - Available Tokens

    private var availableTokensSection: some View {
        let unselected = availableFields.filter { !selectedFields.contains($0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("ADD LEVEL FROM AVAILABLE TOKENS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            if unselected.isEmpty {
                Text("All detected grammar fields are currently included.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
            } else {
                AppFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(unselected, id: \.self) { field in
                        Button {
                            selectedFields.append(field)
                            onChanged?()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 8, weight: .bold))
                                Text(field)
                                    .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Add '\(field)' as Level \(selectedFields.count + 1)")
                    }
                }
            }
        }
    }

    // MARK: - Date Granularity

    private var dateGranularitySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("DATE GRANULARITY")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            HStack {
                Text("Group timestamps by:")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $dateGranularity) {
                    ForEach(DateGranularity.allCases) { gran in
                        Text(gran.label).tag(gran.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
                .onChange(of: dateGranularity) { _, _ in
                    onChanged?()
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }
}
