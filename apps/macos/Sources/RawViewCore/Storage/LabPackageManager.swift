import Foundation

/// Summary of a profile entry within a lab package.
public struct LabPackageProfileSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let filename: String

    public init(id: String, filename: String) {
        self.id = id
        self.filename = filename
    }
}

/// Representation of an optional lab package.
public struct LabPackageSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let version: String
    public let profiles: [LabPackageProfileSummary]
    public let storageURL: URL?
    public let isInstalled: Bool

    public init(
        id: String,
        displayName: String,
        version: String,
        profiles: [LabPackageProfileSummary],
        storageURL: URL?,
        isInstalled: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.profiles = profiles
        self.storageURL = storageURL
        self.isInstalled = isInstalled
    }
}

/// Error type for package management operations.
public enum LabPackageError: LocalizedError, Equatable {
    case invalidManifest(String)
    case packageNotFound(String)
    case ioError(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason):
            return "Invalid package manifest: \(reason)"
        case .packageNotFound(let id):
            return "Package '\(id)' not found."
        case .ioError(let detail):
            return "Package I/O failure: \(detail)"
        case .permissionDenied(let path):
            return "Permission denied accessing \(path)"
        }
    }
}

/// Coordinates installation, listing, and removal of lab packages in global storage.
public enum LabPackageManager {
    public static let manifestFileName = "manifest.yaml"
    public static let usthPackageID = "usth-lab"
    public static let usthPackageVersion = "0.1.0"
    public static let usthDisplayName = "USTH Clean Energy Lab Profiles"

    /// Profiles bundled with the USTH lab package.
    public static let usthProfiles: [LabPackageProfileSummary] = [
        LabPackageProfileSummary(id: "usth/keithley-2400", filename: "keithley-2400.yaml"),
        LabPackageProfileSummary(id: "usth/autolab-usth", filename: "autolab-usth.yaml"),
        LabPackageProfileSummary(id: "usth/horiba-labram", filename: "horiba-labram.yaml"),
        LabPackageProfileSummary(id: "usth/iop-hanoi", filename: "iop-hanoi.yaml")
    ]

    /// Lists all installed packages under `<globalConfigDir>/packages`.
    public static func listInstalledPackages(globalConfigDir: URL? = nil) -> [LabPackageSummary] {
        let base = globalConfigDir ?? GlobalPathResolver.resolveGlobalConfigDirectory()
        let packagesDir = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: base)
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(at: packagesDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var packages: [LabPackageSummary] = []
        for entry in entries {
            let manifestURL = entry.appendingPathComponent(manifestFileName)
            if let data = try? Data(contentsOf: manifestURL),
               let parsed = parseManifest(data: data, storageURL: entry) {
                packages.append(parsed)
            }
        }
        return packages.sorted { $0.id < $1.id }
    }

    /// Checks if the USTH package is installed.
    public static func isUSTHPackageInstalled(globalConfigDir: URL? = nil) -> Bool {
        let base = globalConfigDir ?? GlobalPathResolver.resolveGlobalConfigDirectory()
        let pkgDir = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: base).appendingPathComponent(usthPackageID)
        let manifestURL = pkgDir.appendingPathComponent(manifestFileName)
        return FileManager.default.fileExists(atPath: manifestURL.path)
    }

    /// Installs the USTH Lab Package globally.
    /// Writes manifest to `<globalConfigDir>/packages/usth-lab/manifest.yaml`
    /// and profiles to `<globalConfigDir>/profiles/usth/`.
    /// Note: Does NOT activate or alter any filename grammar.
    public static func installUSTHLabPackage(globalConfigDir: URL? = nil) throws {
        let base = globalConfigDir ?? GlobalPathResolver.resolveGlobalConfigDirectory()
        let packagesDir = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: base)
        let pkgDir = packagesDir.appendingPathComponent(usthPackageID, isDirectory: true)
        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: base)
        let usthProfilesDir = profilesDir.appendingPathComponent("usth", isDirectory: true)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: pkgDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: usthProfilesDir, withIntermediateDirectories: true)
        } catch {
            throw LabPackageError.ioError("Failed to create package directories: \(error.localizedDescription)")
        }

        // 1. Write the profiles
        for item in BuiltinAssets.builtinProfiles {
            let filename = URL(fileURLWithPath: item.relativePath).lastPathComponent
            let targetURL = usthProfilesDir.appendingPathComponent(filename)
            do {
                try item.yaml.write(to: targetURL, atomically: true, encoding: .utf8)
            } catch {
                throw LabPackageError.ioError("Failed writing profile '\(filename)': \(error.localizedDescription)")
            }
        }

        // 2. Write manifest
        var manifestLines = [
            "schema_version: 1",
            "id: \(usthPackageID)",
            "version: \"\(usthPackageVersion)\"",
            "display_name: \"\(usthDisplayName)\"",
            "profiles:"
        ]
        for item in BuiltinAssets.builtinProfiles {
            let filename = URL(fileURLWithPath: item.relativePath).lastPathComponent
            let sha = sha256Hex(item.yaml.data(using: .utf8) ?? Data())
            manifestLines.append("  - id: \(item.id)")
            manifestLines.append("    path: profiles/\(filename)")
            manifestLines.append("    sha256: \(sha)")
        }
        let manifestYAML = manifestLines.joined(separator: "\n") + "\n"
        let manifestURL = pkgDir.appendingPathComponent(manifestFileName)
        do {
            try manifestYAML.write(to: manifestURL, atomically: true, encoding: .utf8)
        } catch {
            throw LabPackageError.ioError("Failed writing manifest: \(error.localizedDescription)")
        }
    }

    /// Removes an installed package and its corresponding global profiles.
    public static func removePackage(id: String, globalConfigDir: URL? = nil) throws {
        let base = globalConfigDir ?? GlobalPathResolver.resolveGlobalConfigDirectory()
        let pkgDir = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: base).appendingPathComponent(id)
        let fm = FileManager.default

        guard fm.fileExists(atPath: pkgDir.path) else {
            throw LabPackageError.packageNotFound(id)
        }

        // If USTH, clean up the global usth profiles dir
        if id == usthPackageID {
            let usthProfilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: base).appendingPathComponent("usth")
            _ = try? fm.removeItem(at: usthProfilesDir)
        }

        do {
            try fm.removeItem(at: pkgDir)
        } catch {
            throw LabPackageError.ioError("Failed to remove package directory: \(error.localizedDescription)")
        }
    }

    /// Checks if a package profile conflicts with a project-local profile.
    public static func detectProjectConflicts(
        package: LabPackageSummary,
        projectRoot: URL
    ) -> [String] {
        let fm = FileManager.default
        var conflicts: [String] = []

        let primaryProfilesDir = projectRoot.appendingPathComponent(".raw-viewer/profiles")
        let legacyProfilesDir = projectRoot.appendingPathComponent(".rawviewer/profiles")

        for prof in package.profiles {
            let primaryFile = primaryProfilesDir.appendingPathComponent("\(prof.id).yaml")
            let legacyFile = legacyProfilesDir.appendingPathComponent("\(prof.id).yaml")
            if fm.fileExists(atPath: primaryFile.path) || fm.fileExists(atPath: legacyFile.path) {
                conflicts.append(prof.id)
            }
        }
        return conflicts
    }

    // MARK: - Manifest Parser

    private static func parseManifest(data: Data, storageURL: URL) -> LabPackageSummary? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let node = try? YAMLParser.parse(text, allowIndentlessSequences: false) else { return nil }

        guard let id = node.value(for: "id")?.scalarValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        let version = node.value(for: "version")?.scalarValue ?? "0.0.0"
        let displayName = node.value(for: "display_name")?.scalarValue ?? id

        var profiles: [LabPackageProfileSummary] = []
        if let profSeq = node.value(for: "profiles")?.listItems {
            for item in profSeq {
                if let pid = item.value(for: "id")?.scalarValue,
                   let ppath = item.value(for: "path")?.scalarValue {
                    let fname = URL(fileURLWithPath: ppath).lastPathComponent
                    profiles.append(LabPackageProfileSummary(id: pid, filename: fname))
                }
            }
        }

        return LabPackageSummary(
            id: id,
            displayName: displayName,
            version: version,
            profiles: profiles,
            storageURL: storageURL,
            isInstalled: true
        )
    }
}
