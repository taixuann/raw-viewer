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
    public static func installUSTHLabPackage(
        globalConfigDir: URL? = nil,
        selectedProfileIDs: Set<String>? = nil
    ) throws {
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

        let itemsToInstall = BuiltinAssets.builtinProfiles.filter { item in
            selectedProfileIDs == nil || selectedProfileIDs!.contains(item.id)
        }

        // 1. Write the profiles
        for item in itemsToInstall {
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
        for item in itemsToInstall {
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

    // MARK: - Profile Discovery & Export

    public static func listAllDiscoveredProfiles(projectRoot: URL? = nil) -> [DiscoveredProfileSummary] {
        var results: [DiscoveredProfileSummary] = []
        var seenIDs = Set<String>()

        // 1. Project-local profiles
        if let projectRoot = projectRoot {
            let candidateDirs = [
                projectRoot.appendingPathComponent(".raw-viewer/profiles"),
                projectRoot.appendingPathComponent(".rawviewer/profiles"),
                projectRoot.appendingPathComponent(".rawviewer/instrument")
            ]
            for dir in candidateDirs {
                guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for file in entries where file.pathExtension.lowercased() == "yaml" || file.pathExtension.lowercased() == "yml" {
                    if let text = try? String(contentsOf: file, encoding: .utf8),
                       let parsed = try? YAMLParser.parse(text, allowIndentlessSequences: false) {
                        let id = parsed.value(for: "id")?.scalarValue
                            ?? parsed.value(for: "profile_id")?.scalarValue
                            ?? file.deletingPathExtension().lastPathComponent
                        guard !seenIDs.contains(id) else { continue }
                        seenIDs.insert(id)
                        let name = parsed.value(for: "name")?.scalarValue
                            ?? parsed.value(for: "instrument_name")?.scalarValue
                            ?? id
                        var modes: [String] = []
                        if let modesList = parsed.value(for: "modes")?.listItems {
                            for m in modesList {
                                if let mid = m.value(for: "id")?.scalarValue {
                                    modes.append(mid)
                                }
                            }
                        }
                        results.append(DiscoveredProfileSummary(
                            id: id,
                            name: name,
                            modes: modes,
                            origin: "Project",
                            fileURL: file
                        ))
                    }
                }
            }
        }

        // 2. Global profiles
        let globalProfiles = GlobalPathResolver.globalProfilesDirectory()
        if let entries = try? FileManager.default.contentsOfDirectory(at: globalProfiles, includingPropertiesForKeys: nil) {
            for entry in entries {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                    let pkgName = entry.lastPathComponent
                    if let files = try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                        for file in files where file.pathExtension.lowercased() == "yaml" || file.pathExtension.lowercased() == "yml" {
                            if let text = try? String(contentsOf: file, encoding: .utf8),
                               let parsed = try? YAMLParser.parse(text, allowIndentlessSequences: false) {
                                let id = parsed.value(for: "id")?.scalarValue
                                    ?? parsed.value(for: "profile_id")?.scalarValue
                                    ?? file.deletingPathExtension().lastPathComponent
                                guard !seenIDs.contains(id) else { continue }
                                seenIDs.insert(id)
                                let name = parsed.value(for: "name")?.scalarValue
                                    ?? parsed.value(for: "instrument_name")?.scalarValue
                                    ?? id
                                var modes: [String] = []
                                if let modesList = parsed.value(for: "modes")?.listItems {
                                    for m in modesList {
                                        if let mid = m.value(for: "id")?.scalarValue {
                                            modes.append(mid)
                                        }
                                    }
                                }
                                results.append(DiscoveredProfileSummary(
                                    id: id,
                                    name: name,
                                    modes: modes,
                                    origin: "Global (\(pkgName))",
                                    fileURL: file
                                ))
                            }
                        }
                    }
                } else if entry.pathExtension.lowercased() == "yaml" || entry.pathExtension.lowercased() == "yml" {
                    if let text = try? String(contentsOf: entry, encoding: .utf8),
                       let parsed = try? YAMLParser.parse(text, allowIndentlessSequences: false) {
                        let id = parsed.value(for: "id")?.scalarValue
                            ?? parsed.value(for: "profile_id")?.scalarValue
                            ?? entry.deletingPathExtension().lastPathComponent
                        guard !seenIDs.contains(id) else { continue }
                        seenIDs.insert(id)
                        let name = parsed.value(for: "name")?.scalarValue
                            ?? parsed.value(for: "instrument_name")?.scalarValue
                            ?? id
                        var modes: [String] = []
                        if let modesList = parsed.value(for: "modes")?.listItems {
                            for m in modesList {
                                if let mid = m.value(for: "id")?.scalarValue {
                                    modes.append(mid)
                                }
                            }
                        }
                        results.append(DiscoveredProfileSummary(
                            id: id,
                            name: name,
                            modes: modes,
                            origin: "Global",
                            fileURL: entry
                        ))
                    }
                }
            }
        }

        // 3. Built-in profiles
        for item in BuiltinAssets.builtinProfiles {
            guard !seenIDs.contains(item.id) else { continue }
            seenIDs.insert(item.id)
            if let parsed = try? YAMLParser.parse(item.yaml, allowIndentlessSequences: false) {
                let name = parsed.value(for: "name")?.scalarValue
                    ?? parsed.value(for: "instrument_name")?.scalarValue
                    ?? item.id
                var modes: [String] = []
                if let modesList = parsed.value(for: "modes")?.listItems {
                    for m in modesList {
                        if let mid = m.value(for: "id")?.scalarValue {
                            modes.append(mid)
                        }
                    }
                }
                results.append(DiscoveredProfileSummary(
                    id: item.id,
                    name: name,
                    modes: modes,
                    origin: "Built-in",
                    fileURL: nil
                ))
            }
        }

        return results.sorted { $0.id < $1.id }
    }

    public static func loadProfileYAML(id: String, projectRoot: URL? = nil) -> String? {
        if let projectRoot = projectRoot {
            for dir in [".raw-viewer/profiles", ".rawviewer/profiles", ".rawviewer/instrument"] {
                let candidate = projectRoot.appendingPathComponent(dir).appendingPathComponent("\(id).yaml")
                if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                    return text
                }
            }
        }
        let globalDir = GlobalPathResolver.globalProfilesDirectory()
        if let entries = try? FileManager.default.contentsOfDirectory(at: globalDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                let candidate = entry.appendingPathComponent("\(id).yaml")
                if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                    return text
                }
            }
        }
        let directCandidate = globalDir.appendingPathComponent("\(id).yaml")
        if let text = try? String(contentsOf: directCandidate, encoding: .utf8) {
            return text
        }
        if let builtin = BuiltinAssets.builtinProfiles.first(where: { $0.id == id }) {
            return builtin.yaml
        }
        return nil
    }
}

public struct DiscoveredProfileSummary: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let modes: [String]
    public let origin: String
    public let fileURL: URL?

    public init(id: String, name: String, modes: [String], origin: String, fileURL: URL? = nil) {
        self.id = id
        self.name = name
        self.modes = modes
        self.origin = origin
        self.fileURL = fileURL
    }
}
