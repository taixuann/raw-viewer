import AppKit
import SwiftUI
import RawViewCore

/// Editor for the tree grouping hierarchy. Each level is a row of grammar token chips,
/// and a level may hold several tokens. Chips move by drag and drop, or from each chip's
/// menu, which works with the keyboard and VoiceOver. The preview shows folder names built
/// from real project files.
public struct TreeHierarchyEditorView: View {
    public let grammar: FilenameGrammar?
    /// Project files for the live folder preview. Only the first few are shown.
    public let sources: [RawSource]
    /// Stored form: one `+`-joined string per level.
    @Binding public var selectedFields: [String]
    @Binding public var dateGranularity: String
    public var uiFontSize: Double = AppTypography.baselineFontSize
    public var fontFamily: String = "System"
    public var isCompact: Bool = false
    public var onChanged: (() -> Void)? = nil

    @State private var targetedLevel: Int?
    @State private var newLevelTargeted = false

    public init(
        grammar: FilenameGrammar?,
        sources: [RawSource],
        selectedFields: Binding<[String]>,
        dateGranularity: Binding<String>,
        uiFontSize: Double = AppTypography.baselineFontSize,
        fontFamily: String = "System",
        isCompact: Bool = false,
        onChanged: (() -> Void)? = nil
    ) {
        self.grammar = grammar
        self.sources = sources
        self._selectedFields = selectedFields
        self._dateGranularity = dateGranularity
        self.uiFontSize = uiFontSize
        self.fontFamily = fontFamily
        self.isCompact = isCompact
        self.onChanged = onChanged
    }

    private var levels: [[String]] { TreeLevels.levels(stored: selectedFields) }

    private var grammarFields: [GrammarField] { grammar?.fields ?? [] }

    private var grammarTokens: [String] { grammarFields.map(\.name) }

    private var unplacedTokens: [String] {
        let placed = Set(levels.flatMap { $0 })
        return grammarTokens.filter { !placed.contains($0) }
    }

    private var granularity: DateGranularity {
        DateGranularity(rawValue: dateGranularity) ?? .day
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 10 : 14) {
            folderPreview
            levelsSection
            availableSection
            dateGranularitySection
        }
    }

    // MARK: - Folder preview

    /// The preview rebuilds a tree on each redraw, so it reads only a bounded sample of files.
    private static let previewSourceLimit = 400

    private var folderPreview: some View {
        let paths = TreeLevels.previewPaths(
            sources: Array(sources.prefix(Self.previewSourceLimit)),
            grammar: grammar,
            groupingFields: selectedFields,
            dateGranularity: granularity,
            limit: 3
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text("Folder preview")
                .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: fontFamily))
            if paths.isEmpty {
                Text(selectedFields.isEmpty
                     ? "Flat list: files are not grouped into folders."
                     : "No project files to preview yet. Folder names appear once files are indexed.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                        previewRow(path)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
        }
    }

    /// Folders wrap onto more lines rather than scrolling, so narrow popovers still show every name.
    private func previewRow(_ path: [String]) -> some View {
        let folders = path.dropLast()
        let file = path.last ?? ""
        return AppFlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Array(folders.enumerated()), id: \.offset) { _, folder in
                HStack(spacing: 3) {
                    Image(systemName: "folder.fill")
                        .font(AppTypography.chevron(uiFontSize: uiFontSize, fontFamily: fontFamily))
                        .foregroundStyle(Color.accentColor)
                    Text(folder)
                        .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                Text("/")
                    .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
            }
            // A flow layout measures children unbounded, so the width cap is what makes long names wrap.
            Text(file)
                .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: 420, alignment: .leading)
        }
    }

    // MARK: - Levels

    private var levelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Levels")
                    .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: fontFamily))
                Spacer()
                Text("\(levels.count) \(levels.count == 1 ? "level" : "levels")")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
            }

            if levels.isEmpty {
                Text("No levels. Drag a token here, or add one below.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(levels.enumerated()), id: \.offset) { index, tokens in
                        levelRow(index: index, tokens: tokens)
                    }
                }
            }

            newLevelZone
        }
    }

    private func levelRow(index: Int, tokens: [String]) -> some View {
        let isTargeted = targetedLevel == index
        return HStack(alignment: .center, spacing: 8) {
            Text("L\(index + 1)")
                .font(AppTypography.badge(uiFontSize: uiFontSize, fontFamily: fontFamily))
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 26, minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                .accessibilityLabel("Level \(index + 1)")

            AppFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(tokens, id: \.self) { token in
                    chip(token, level: index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            levelControls(index: index)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isTargeted ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isTargeted ? 1.2 : 0.5)
        )
        .dropDestination(for: String.self) { items, _ in
            accept(items, destination: .level(index))
        } isTargeted: { hovering in
            targetedLevel = hovering ? index : (targetedLevel == index ? nil : targetedLevel)
        }
    }

    private func levelControls(index: Int) -> some View {
        HStack(spacing: 2) {
            Button {
                commit(swapLevels(index, index - 1))
            } label: {
                Image(systemName: "arrow.up")
                    .font(AppTypography.chevron(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .help("Move level up")
            .accessibilityLabel("Move level \(index + 1) up")

            Button {
                commit(swapLevels(index, index + 1))
            } label: {
                Image(systemName: "arrow.down")
                    .font(AppTypography.chevron(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(index >= levels.count - 1)
            .help("Move level down")
            .accessibilityLabel("Move level \(index + 1) down")

            Button {
                commit(levels.enumerated().filter { $0.offset != index }.map(\.element))
            } label: {
                Image(systemName: "xmark")
                    .font(AppTypography.chevron(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Remove level. Its tokens return to the available list.")
            .accessibilityLabel("Remove level \(index + 1)")
        }
        .padding(.horizontal, 3).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
    }

    private var newLevelZone: some View {
        Text("Drop a token here for a new level")
            .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
            .foregroundStyle(newLevelTargeted ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(newLevelTargeted ? Color.accentColor : Color.primary.opacity(0.15),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .dropDestination(for: String.self) { items, _ in
                accept(items, destination: .newLevel(at: levels.count))
            } isTargeted: { hovering in
                newLevelTargeted = hovering
            }
    }

    // MARK: - Available tokens

    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Available tokens")
                .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: fontFamily))

            if grammarFields.isEmpty {
                Text("The active grammar has no tokens to group by.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
            } else if unplacedTokens.isEmpty {
                Text("Every token is placed in a level.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
            } else {
                AppFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(unplacedTokens, id: \.self) { token in
                        chip(token, level: nil)
                    }
                }
                Text("Drag a token onto a level, or use its menu. Each token belongs to one level.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Chip

    /// A draggable token chip with a menu for the same moves. `level` is nil for tokens
    /// in the available list.
    private func chip(_ token: String, level: Int?) -> some View {
        let field = grammarFields.first(where: { $0.name == token })
        return HStack(spacing: 2) {
            AppTokenPill(
                name: token,
                role: field?.role,
                type: field?.type,
                isOptional: false,
                uiFontSize: uiFontSize
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(level.map { "\(token), level \($0 + 1)" } ?? "\(token), not in a level")

            Menu {
                chipMenu(token, level: level)
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppTypography.chevron(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move, split or remove \(token)")
            .accessibilityLabel("Actions for \(token)")
        }
        .draggable(token)
    }

    @ViewBuilder
    private func chipMenu(_ token: String, level: Int?) -> some View {
        ForEach(Array(levels.indices), id: \.self) { target in
            if target != level {
                Button("Move to Level \(target + 1)") {
                    move(token, to: .level(target))
                }
            }
        }
        Button("Move to New Level") {
            move(token, to: .newLevel(at: levels.count))
        }
        if let level, levels.indices.contains(level), levels[level].count > 1 {
            Button("Split to Own Level") {
                move(token, to: .newLevel(at: level + 1))
            }
        }
        if level != nil {
            Divider()
            Button("Remove from Tree", role: .destructive) {
                commit(TreeLevels.remove(token, from: levels))
            }
        }
    }

    // MARK: - Date granularity

    private var dateGranularitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Date granularity")
                .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: fontFamily))
            HStack {
                Text("Group timestamps by")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Date granularity", selection: $dateGranularity) {
                    ForEach(DateGranularity.allCases) { gran in
                        Text(gran.label).tag(gran.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
                .onChange(of: dateGranularity) { _, _ in
                    onChanged?()
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))

            if !selectedFields.isEmpty {
                Button("Clear all levels") {
                    commit([])
                }
                .buttonStyle(.plain)
                .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: fontFamily))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Mutations

    private func move(_ token: String, to destination: TreeLevelDestination) {
        commit(TreeLevels.move(token, in: levels, to: destination))
    }

    /// Accepts a dropped grammar token only. Other drags are refused.
    private func accept(_ items: [String], destination: TreeLevelDestination) -> Bool {
        guard let token = items.first(where: { grammarTokens.contains($0) }) else { return false }
        move(token, to: destination)
        return true
    }

    private func swapLevels(_ first: Int, _ second: Int) -> [[String]] {
        var next = levels
        guard next.indices.contains(first), next.indices.contains(second) else { return next }
        next.swapAt(first, second)
        return next
    }

    private func commit(_ newLevels: [[String]]) {
        selectedFields = TreeLevels.stored(levels: newLevels)
        onChanged?()
    }
}
