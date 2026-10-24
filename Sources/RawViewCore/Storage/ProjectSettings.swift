import Foundation

/// Portable project configuration stored at
/// Portable project configuration stored at
/// `<project>/.rawviewer/setting.yaml` (schema v2) or legacy
/// `<project>/.rawviewer/setting/setting.yaml` (schema v1). Settings are data only:
/// the owning project directory determines the absolute location, so no absolute
/// project path is ever stored and a whole-project move preserves identity.
public struct ProjectSettings: Sendable, Equatable {
    public let dataRoot: String
    public let defaultView: String
    public let defaultPreset: String
    /// Project-scoped Developer Mode. Older settings files predate the key
    /// and load as false; it is never a global default.
    public let developerMode: Bool
    /// Ordered project-only Explorer view references ((grammarID, variable)
    /// identity lives here, never in the grammar catalog). Empty means no
    /// semantic grouping views; Tree/None stay structural.
    public let explorerViews: [ExplorerViewDefinition]
    /// Optional per-grammar Explorer source-label rows. Absent in older
    /// files means no customization (exact filename display).
    public let sourceLabels: [SourceLabelLayout]

    public init(
        dataRoot: String, defaultView: String = "tree", defaultPreset: String = "nature-single",
        developerMode: Bool = false, explorerViews: [ExplorerViewDefinition] = [],
        sourceLabels: [SourceLabelLayout] = []
    ) {
        self.dataRoot = dataRoot
        self.defaultView = defaultView
        self.defaultPreset = defaultPreset
        self.developerMode = developerMode
        self.explorerViews = explorerViews
        self.sourceLabels = sourceLabels
    }
}

/// One Explorer view reference: a grammar variable shown as a grouping
/// view, in menu order. Labels reuse the variable name; no custom labels.
public struct ExplorerViewDefinition: Sendable, Equatable {
    public let grammarID: String
    public let variable: String

    public init(grammarID: String, variable: String) {
        self.grammarID = grammarID
        self.variable = variable
    }
}

/// One source-label row: ordered variable references joined with ` · `,
/// plus bounded presentation style. No template language, no free colors.
public struct SourceLabelRow: Sendable, Equatable {
    public let variables: [String]
    public let fontSize: Int
    public let weight: String
    public let font: String
    public let emphasis: String

    public init(
        variables: [String], fontSize: Int = 12,
        weight: String = "regular", font: String = "normal", emphasis: String = "primary"
    ) {
        self.variables = variables
        self.fontSize = fontSize
        self.weight = weight
        self.font = font
        self.emphasis = emphasis
    }
}

/// One grammar's label configuration, shared across Explorer views.
public struct SourceLabelLayout: Sendable, Equatable {
    public let grammarID: String
    public let rows: [SourceLabelRow]

    public init(grammarID: String, rows: [SourceLabelRow]) {
        self.grammarID = grammarID
        self.rows = rows
    }
}

/// Fail-closed settings failure carrying a corrective diagnostic. Corrupt
/// settings are surfaced to the caller; they never silently fall back to a
/// default root.
public struct ProjectSettingsError: Error, Equatable, LocalizedError {
    public let reason: String

    public init(reason: String) { self.reason = reason }

    public var errorDescription: String? { reason }
}

/// Loader/saver for settings documents. Parsing reuses the fail-closed
/// YAMLParser subset shared with instrument profiles: duplicate keys, unknown
/// keys, unsupported versions, absolute or non-normalized paths, and symlinked
/// namespaces are rejections, never guesses.
public enum ProjectSettingsStore {
    public static let maximumFileBytes = 64 * 1024
    public static let relativePath = ".rawviewer/setting.yaml"
    public static let legacyRelativePath = ".rawviewer/setting/setting.yaml"
    static let supportedSchemaVersions: Set<Int> = [1, 2, 3]
    static let currentSchemaVersion = 3
    /// Schema v1 and v2 define exactly one navigator view.
    static let supportedDefaultViews: Set<String> = ["tree"]

    /// RawView-owned viewer metadata and snapshot namespaces. A configured
    /// data root may never equal or sit beneath one of them, and every
    /// traversal (source inventory and manifest scanning) excludes them for
    /// every data root, not only for ".".
    public static let viewerMetadataNamespaces = [".rawviewer", "data/.rawview", "data/snapshot"]

    public static func isViewerMetadataNamespace(_ relativePath: String) -> Bool {
        viewerMetadataNamespaces.contains { relativePath == $0 || relativePath.hasPrefix($0 + "/") }
    }

    public static func settingsURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(relativePath)
    }

    public static func legacySettingsURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(legacyRelativePath)
    }

    /// Loads saved settings; nil ONLY when the file is proven absent (ENOENT
    /// at the file itself for both current and legacy paths). Any other state —
    /// symlink, directory, unreadable, oversized, malformed, unsupported —
    /// throws so callers can never mistake corrupt configuration for missing
    /// configuration.
    public static func load(projectRoot: URL) throws -> ProjectSettings? {
        let currentURL = settingsURL(projectRoot: projectRoot)
        let legacyURL = legacySettingsURL(projectRoot: projectRoot)

        // Try primary path first: .rawviewer/setting.yaml
        if let settings = try loadSingle(from: currentURL, projectRoot: projectRoot, relative: relativePath, namespaceComponents: [".rawviewer"]) {
            return settings
        }

        // Fallback to legacy path: .rawviewer/setting/setting.yaml
        if let settings = try loadSingle(from: legacyURL, projectRoot: projectRoot, relative: legacyRelativePath, namespaceComponents: [".rawviewer", "setting"]) {
            return settings
        }

        return nil
    }

    private static func loadSingle(from url: URL, projectRoot: URL, relative: String, namespaceComponents: [String]) throws -> ProjectSettings? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else {
                throw ProjectSettingsError(reason: "\(relative) could not be examined (\(String(cString: strerror(errno)))).")
            }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ProjectSettingsError(reason: "\(relative) must be a regular file; symlinks and special entries are rejected.")
        }
        guard info.st_size <= Int64(maximumFileBytes) else {
            throw ProjectSettingsError(reason: "\(relative) exceeds the 64 KiB settings limit.")
        }
        if let symlinked = SecureFile.firstSymlinkedComponent(namespaceComponents, beneath: projectRoot.path) {
            throw ProjectSettingsError(reason: "\(symlinked) is a symlink; the settings namespace must be regular project directories.")
        }
        let handle: FileHandle
        do {
            handle = try SecureFile.openVerified(resolvedPath: url.path, beneath: projectRoot.path)
        } catch {
            throw ProjectSettingsError(reason: "\(relative) could not be opened without following links.")
        }
        defer { try? handle.close() }
        let raw: Data
        do {
            raw = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        } catch {
            throw ProjectSettingsError(reason: "\(relative) could not be read.")
        }
        guard raw.count <= maximumFileBytes else {
            throw ProjectSettingsError(reason: "\(relative) exceeds the 64 KiB settings limit.")
        }
        guard let text = String(data: raw, encoding: .utf8) else {
            throw ProjectSettingsError(reason: "\(relative) is not UTF-8 text.")
        }
        return try parse(text: text)
    }

    /// Atomic no-follow save: settings are validated first, the namespace is
    /// created when absent and refused when symlinked, and the bytes land via
    /// Foundation's atomic replace (write-to-temporary + rename), so a
    /// symlinked or concurrently swapped final component is replaced, never
    /// followed. Save failures throw; they are never swallowed.
    public static func save(_ settings: ProjectSettings, projectRoot: URL) throws {
        try validateDataRoot(settings.dataRoot)
        guard supportedDefaultViews.contains(settings.defaultView) else {
            throw ProjectSettingsError(reason: "default_view \"\(settings.defaultView)\" is not supported; use \"tree\".")
        }
        for view in settings.explorerViews {
            try validateViewToken(view.grammarID, field: "explorer_views grammar_id")
            try validateViewToken(view.variable, field: "explorer_views variable")
        }
        let seen = settings.explorerViews.map { "\($0.grammarID)\0\($0.variable)" }
        guard Set(seen).count == seen.count else {
            throw ProjectSettingsError(reason: "explorer_views must not repeat a (grammar_id, variable) reference.")
        }
        try validateSourceLabels(settings.sourceLabels)
        let data = Data(serialize(settings).utf8)
        guard data.count <= maximumFileBytes else {
            throw ProjectSettingsError(reason: "serialized settings exceed the 64 KiB settings limit.")
        }
        let namespace = projectRoot.appendingPathComponent(".rawviewer", isDirectory: true)
        if let symlinked = SecureFile.firstSymlinkedComponent([".rawviewer"], beneath: projectRoot.path) {
            throw ProjectSettingsError(reason: "\(symlinked) is a symlink; refusing to save settings through it.")
        }
        do {
            try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        } catch {
            throw ProjectSettingsError(reason: "settings directory could not be created: \(error.localizedDescription)")
        }
        let url = settingsURL(projectRoot: projectRoot)
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw ProjectSettingsError(reason: "\(relativePath) is a symlink; refusing to replace it.")
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ProjectSettingsError(reason: "settings could not be saved: \(error.localizedDescription)")
        }
    }

    /// Trust-boundary validation of a configured data root: project-relative,
    /// normalized, contained. Absolute paths and any `..`/`.`/empty component
    /// are rejected BEFORE normalization — the stored value is exactly the
    /// validated value, never a normalized approximation of it.
    public static func validateDataRoot(_ value: String) throws {
        guard !value.isEmpty else {
            throw ProjectSettingsError(reason: "data_root must not be empty.")
        }
        guard !value.hasPrefix("/") else {
            throw ProjectSettingsError(reason: "data_root \"\(value)\" must be project-relative, not absolute.")
        }
        guard value != "~", !value.hasPrefix("~/") else {
            throw ProjectSettingsError(reason: "data_root \"\(value)\" must be project-relative, not a home path.")
        }
        // A backslash would be re-serialized into the quoted YAML scalar
        // unescaped and re-read as an escape sequence (a different value, or a
        // rejected control character), so it can never round-trip.
        guard !value.contains("\""), !value.contains("\\"),
                !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ProjectSettingsError(reason: "data_root must not contain quotes, backslashes, or control characters.")
        }
        if value != "." {
            for component in value.split(separator: "/", omittingEmptySubsequences: false) {
                guard !component.isEmpty, component != ".", component != ".." else {
                    throw ProjectSettingsError(reason: "data_root \"\(value)\" must be normalized (no empty, \".\", or \"..\" components).")
                }
            }
        }
        guard !Self.isViewerMetadataNamespace(value) else {
            throw ProjectSettingsError(reason: "data_root \"\(value)\" is equal to or beneath a RawView viewer metadata or snapshot namespace (\(Self.viewerMetadataNamespaces.joined(separator: ", "))).")
        }
    }

    /// A view reference identifier must survive a YAML round-trip unchanged:
    /// nonempty, single-line, without quotes, backslashes or controls that
    /// would re-read as a different scalar.
    static func validateViewToken(_ value: String, field: String) throws {
        guard !value.isEmpty, !value.contains("\""), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !value.contains("\n"), !value.contains("\r") else {
            throw ProjectSettingsError(reason: "\(field) must be a nonempty single-line identifier without quotes, backslashes, or control characters.")
        }
    }

    /// Fail-closed source-label validation, shared by save and parse so
    /// invalid payloads are rejected before any write.
    static func validateSourceLabels(_ labels: [SourceLabelLayout]) throws {
        var seen = Set<String>()
        for layout in labels {
            try validateViewToken(layout.grammarID, field: "source_labels grammar_id")
            guard !layout.grammarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectSettingsError(reason: "source_labels grammar_id must not be blank.")
            }
            guard seen.insert(layout.grammarID).inserted else {
                throw ProjectSettingsError(reason: "source_labels must not repeat grammar_id \"\(layout.grammarID)\".")
            }
            guard !layout.rows.isEmpty else {
                throw ProjectSettingsError(reason: "source_labels rows for grammar_id \"\(layout.grammarID)\" must not be empty.")
            }
            for row in layout.rows {
                guard !row.variables.isEmpty else {
                    throw ProjectSettingsError(reason: "each source_labels row needs at least one variable.")
                }
                for variable in row.variables {
                    try validateViewToken(variable, field: "source_labels variable")
                    guard !variable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProjectSettingsError(reason: "source_labels variable must not be blank.")
                    }
                }
                guard (10...18).contains(row.fontSize) else {
                    throw ProjectSettingsError(reason: "source_labels font_size must be 10-18; found \"\(row.fontSize)\".")
                }
                guard row.weight == "regular" || row.weight == "medium" || row.weight == "semibold" else {
                    throw ProjectSettingsError(reason: "source_labels weight must be regular, medium or semibold; found \"\(row.weight)\".")
                }
                guard row.font == "normal" || row.font == "monospace" else {
                    throw ProjectSettingsError(reason: "source_labels font must be normal or monospace; found \"\(row.font)\".")
                }
                guard row.emphasis == "primary" || row.emphasis == "secondary" else {
                    throw ProjectSettingsError(reason: "source_labels emphasis must be primary or secondary; found \"\(row.emphasis)\".")
                }
            }
        }
    }

    static func serialize(_ settings: ProjectSettings) -> String {
        var text = "schema_version: \(currentSchemaVersion)\n"
            + "data_root: \"\(settings.dataRoot)\"\n"
            + "default_view: \"\(settings.defaultView)\"\n"
            + "default_preset: \"\(settings.defaultPreset)\"\n"
            + "developer_mode: \(settings.developerMode ? "true" : "false")\n"
        if settings.explorerViews.isEmpty {
            text += "explorer_views: []\n"
        } else {
            text += "explorer_views:\n"
            for view in settings.explorerViews {
                text += "  - grammar_id: \"\(view.grammarID)\"\n"
                    + "    variable: \"\(view.variable)\"\n"
            }
        }
        // Absent when empty: older files and older binaries keep their
        // meaning (no customization), and label-free files stay readable.
        if !settings.sourceLabels.isEmpty {
            text += "source_labels:\n"
            for layout in settings.sourceLabels {
                text += "  - grammar_id: \"\(layout.grammarID)\"\n"
                    + "    rows:\n"
                for row in layout.rows {
                    let vars = row.variables.map { "\"\($0)\"" }.joined(separator: ", ")
                    text += "      - variables: [\(vars)]\n"
                        + "        font_size: \(row.fontSize)\n"
                        + "        weight: \"\(row.weight)\"\n"
                        + "        font: \"\(row.font)\"\n"
                        + "        emphasis: \"\(row.emphasis)\"\n"
                }
            }
        }
        return text
    }

    static func parse(text: String) throws -> ProjectSettings {
        let root: YAMLNode
        do {
            root = try YAMLParser.parse(text, allowIndentlessSequences: false)
        } catch let error as YAMLParseError {
            throw ProjectSettingsError(reason: "settings YAML parse error \(error.localizedDescription).")
        } catch {
            throw ProjectSettingsError(reason: "settings could not be parsed as YAML.")
        }
        guard root.mapEntries != nil else {
            throw ProjectSettingsError(reason: "settings must be a YAML mapping.")
        }
        guard let versionStr = root.value(for: "schema_version")?.scalarValue,
              let version = Int(versionStr),
              supportedSchemaVersions.contains(version) else {
            throw ProjectSettingsError(reason: "schema_version must be 1, 2 or 3; found \"\(root.value(for: "schema_version")?.scalarValue ?? "")\".")
        }
        // Duplicate keys already fail closed inside YAMLParser; unknown keys
        // fail closed here against the per-version schema key set. The v3
        // keys are unknown outside v3, so older files keep their meaning and
        // older settings default to developerMode false with no views.
        var allowedKeys: Set<String> = ["schema_version", "data_root", "default_view", "default_preset"]
        if version == 3 {
            allowedKeys.insert("developer_mode")
            allowedKeys.insert("explorer_views")
            allowedKeys.insert("source_labels")
        }
        for entry in root.mapEntries ?? [] where !allowedKeys.contains(entry.key) {
            throw ProjectSettingsError(reason: "unknown settings key \"\(entry.key)\" for schema_version \(version).")
        }
        guard let dataRoot = root.value(for: "data_root")?.scalarValue else {
            throw ProjectSettingsError(reason: "data_root is required and must be a quoted project-relative path.")
        }
        try validateDataRoot(dataRoot)
        guard let defaultView = root.value(for: "default_view")?.scalarValue, supportedDefaultViews.contains(defaultView) else {
            throw ProjectSettingsError(reason: "default_view must be \"tree\"; found \"\(root.value(for: "default_view")?.scalarValue ?? "")\".")
        }
        let defaultPreset = root.value(for: "default_preset")?.scalarValue ?? "nature-single"
        var developerMode = false
        if let modeNode = root.value(for: "developer_mode") {
            guard let raw = modeNode.scalarValue, raw == "true" || raw == "false" else {
                throw ProjectSettingsError(reason: "developer_mode must be true or false.")
            }
            developerMode = (raw == "true")
        }
        var explorerViews: [ExplorerViewDefinition] = []
        if let viewsNode = root.value(for: "explorer_views") {
            guard let items = viewsNode.listItems else {
                throw ProjectSettingsError(reason: "explorer_views must be a YAML list of grammar_id/variable references.")
            }
            for item in items {
                guard let entries = item.mapEntries else {
                    throw ProjectSettingsError(reason: "each explorer_views entry must be a mapping with grammar_id and variable.")
                }
                for entry in entries where entry.key != "grammar_id" && entry.key != "variable" {
                    throw ProjectSettingsError(reason: "unknown explorer_views key \"\(entry.key)\"; expected grammar_id, variable.")
                }
                guard let grammarID = item.value(for: "grammar_id")?.scalarValue,
                      let variable = item.value(for: "variable")?.scalarValue else {
                    throw ProjectSettingsError(reason: "each explorer_views entry needs grammar_id and variable.")
                }
                try validateViewToken(grammarID, field: "explorer_views grammar_id")
                try validateViewToken(variable, field: "explorer_views variable")
                explorerViews.append(ExplorerViewDefinition(grammarID: grammarID, variable: variable))
            }
            let seen = explorerViews.map { "\($0.grammarID)\0\($0.variable)" }
            guard Set(seen).count == seen.count else {
                throw ProjectSettingsError(reason: "explorer_views must not repeat a (grammar_id, variable) reference.")
            }
        }
        var sourceLabels: [SourceLabelLayout] = []
        if let labelsNode = root.value(for: "source_labels") {
            guard let items = labelsNode.listItems else {
                throw ProjectSettingsError(reason: "source_labels must be a YAML list of grammar layouts.")
            }
            for item in items {
                guard item.mapEntries != nil else {
                    throw ProjectSettingsError(reason: "each source_labels entry must be a mapping with grammar_id and rows.")
                }
                for entry in item.mapEntries ?? [] where entry.key != "grammar_id" && entry.key != "rows" {
                    throw ProjectSettingsError(reason: "unknown source_labels key \"\(entry.key)\"; expected grammar_id, rows.")
                }
                guard let grammarID = item.value(for: "grammar_id")?.scalarValue,
                      let rowsNode = item.value(for: "rows"),
                      let rowItems = rowsNode.listItems else {
                    throw ProjectSettingsError(reason: "each source_labels entry needs grammar_id and rows.")
                }
                var rows: [SourceLabelRow] = []
                for rowItem in rowItems {
                    guard rowItem.mapEntries != nil else {
                        throw ProjectSettingsError(reason: "each source_labels row must be a mapping with variables, font_size, weight, font, emphasis.")
                    }
                    for entry in rowItem.mapEntries ?? []
                        where entry.key != "variables" && entry.key != "font_size" && entry.key != "weight"
                            && entry.key != "font" && entry.key != "emphasis" {
                        throw ProjectSettingsError(reason: "unknown source_labels row key \"\(entry.key)\"; expected variables, font_size, weight, font, emphasis.")
                    }
                    guard let varsNode = rowItem.value(for: "variables"),
                          let varItems = varsNode.listItems else {
                        throw ProjectSettingsError(reason: "each source_labels row needs variables, font_size, weight, font, emphasis.")
                    }
                    var variables: [String] = []
                    for varItem in varItems {
                        guard let name = varItem.scalarValue else {
                            throw ProjectSettingsError(reason: "source_labels variable must be a nonempty identifier.")
                        }
                        variables.append(name)
                    }
                    guard let sizeStr = rowItem.value(for: "font_size")?.scalarValue,
                          let fontSize = Int(sizeStr),
                          let weight = rowItem.value(for: "weight")?.scalarValue,
                          let font = rowItem.value(for: "font")?.scalarValue,
                          let emphasis = rowItem.value(for: "emphasis")?.scalarValue else {
                        throw ProjectSettingsError(reason: "each source_labels row needs variables, font_size, weight, font, emphasis.")
                    }
                    rows.append(SourceLabelRow(
                        variables: variables, fontSize: fontSize,
                        weight: weight, font: font, emphasis: emphasis))
                }
                sourceLabels.append(SourceLabelLayout(grammarID: grammarID, rows: rows))
            }
            try validateSourceLabels(sourceLabels)
        }
        return ProjectSettings(
            dataRoot: dataRoot, defaultView: defaultView, defaultPreset: defaultPreset,
            developerMode: developerMode, explorerViews: explorerViews, sourceLabels: sourceLabels)
    }
}
