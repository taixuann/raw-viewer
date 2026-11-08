import Foundation

/// Resolves authoritative application and project paths, keeping global and project
/// scope strictly separated and matching `core::paths`.
public enum GlobalPathResolver {
    public static let appDirectoryName = "raw-viewer"
    public static let projectConfigDirectoryName = ".raw-viewer"
    public static let projectConfigFileName = "config.yaml"
    public static let legacyProjectDirectoryName = ".rawviewer"
    public static let legacyProjectFileName = "setting.yaml"

    /// Resolves the authoritative global configuration directory.
    /// Checks:
    /// 1. $XDG_CONFIG_HOME/raw-viewer (if directory exists)
    /// 2. $HOME/.config/raw-viewer (if directory exists)
    /// 3. Platform default: ~/Library/Application Support/raw-viewer on macOS
    public static func resolveGlobalConfigDirectory(
        home: URL? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let homeDir = home ?? FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        // 1. XDG_CONFIG_HOME
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty, xdg.hasPrefix("/") {
            let xdgURL = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent(appDirectoryName, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: xdgURL.path, isDirectory: &isDir), isDir.boolValue {
                return xdgURL
            }
        }

        // 2. ~/.config/raw-viewer
        let dotConfigURL = homeDir.appendingPathComponent(".config", isDirectory: true).appendingPathComponent(appDirectoryName, isDirectory: true)
        var isDotConfigDir: ObjCBool = false
        if fm.fileExists(atPath: dotConfigURL.path, isDirectory: &isDotConfigDir), isDotConfigDir.boolValue {
            return dotConfigURL
        }

        // 3. Platform default: ~/Library/Application Support/raw-viewer
        return homeDir
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(appDirectoryName, isDirectory: true)
    }

    /// Global configuration file: `<globalConfigDir>/config.yaml`
    public static func globalConfigFile(globalConfigDir: URL? = nil) -> URL {
        let dir = globalConfigDir ?? resolveGlobalConfigDirectory()
        return dir.appendingPathComponent(projectConfigFileName)
    }

    /// Global grammar file: `<globalConfigDir>/grammar.yaml`
    public static func globalGrammarFile(globalConfigDir: URL? = nil) -> URL {
        let dir = globalConfigDir ?? resolveGlobalConfigDirectory()
        return dir.appendingPathComponent("grammar.yaml")
    }

    /// Global packages directory: `<globalConfigDir>/packages`
    public static func globalPackagesDirectory(globalConfigDir: URL? = nil) -> URL {
        let dir = globalConfigDir ?? resolveGlobalConfigDirectory()
        return dir.appendingPathComponent("packages", isDirectory: true)
    }

    /// Global profiles directory: `<globalConfigDir>/profiles`
    public static func globalProfilesDirectory(globalConfigDir: URL? = nil) -> URL {
        let dir = globalConfigDir ?? resolveGlobalConfigDirectory()
        return dir.appendingPathComponent("profiles", isDirectory: true)
    }

    /// Project metadata directory: `<projectRoot>/.raw-viewer`
    public static func projectConfigDirectory(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(projectConfigDirectoryName, isDirectory: true)
    }

    /// Project configuration file: `<projectRoot>/.raw-viewer/config.yaml`
    public static func projectConfigFile(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(projectConfigDirectoryName).appendingPathComponent(projectConfigFileName)
    }

    /// Snapshot packages directory: `<projectRoot>/data/snapshot`
    public static func snapshotDirectory(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent("data", isDirectory: true).appendingPathComponent("snapshot", isDirectory: true)
    }
}
