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

    public init(dataRoot: String, defaultView: String = "tree", defaultPreset: String = "nature-single") {
        self.dataRoot = dataRoot
        self.defaultView = defaultView
        self.defaultPreset = defaultPreset
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
    static let supportedSchemaVersions: Set<Int> = [1, 2]
    static let currentSchemaVersion = 2
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

    static func serialize(_ settings: ProjectSettings) -> String {
        "schema_version: \(currentSchemaVersion)\n"
            + "data_root: \"\(settings.dataRoot)\"\n"
            + "default_view: \"\(settings.defaultView)\"\n"
            + "default_preset: \"\(settings.defaultPreset)\"\n"
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
        // Duplicate keys already fail closed inside YAMLParser; unknown keys
        // fail closed here against the schema key set.
        let allowedKeys: Set<String> = ["schema_version", "data_root", "default_view", "default_preset"]
        for entry in root.mapEntries ?? [] where !allowedKeys.contains(entry.key) {
            throw ProjectSettingsError(reason: "unknown settings key \"\(entry.key)\"; expected schema_version, data_root, default_view, default_preset.")
        }
        guard let versionStr = root.value(for: "schema_version")?.scalarValue,
              let version = Int(versionStr),
              supportedSchemaVersions.contains(version) else {
            throw ProjectSettingsError(reason: "schema_version must be 1 or 2; found \"\(root.value(for: "schema_version")?.scalarValue ?? "")\".")
        }
        guard let dataRoot = root.value(for: "data_root")?.scalarValue else {
            throw ProjectSettingsError(reason: "data_root is required and must be a quoted project-relative path.")
        }
        try validateDataRoot(dataRoot)
        guard let defaultView = root.value(for: "default_view")?.scalarValue, supportedDefaultViews.contains(defaultView) else {
            throw ProjectSettingsError(reason: "default_view must be \"tree\"; found \"\(root.value(for: "default_view")?.scalarValue ?? "")\".")
        }
        let defaultPreset = root.value(for: "default_preset")?.scalarValue ?? "nature-single"
        return ProjectSettings(dataRoot: dataRoot, defaultView: defaultView, defaultPreset: defaultPreset)
    }
}
