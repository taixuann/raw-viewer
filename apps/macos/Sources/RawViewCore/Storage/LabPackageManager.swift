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
    case upgradeRefused(String)

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
        case .upgradeRefused(let reason):
            return "Upgrade refused: \(reason)"
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
                try bundledText(item.yaml).write(to: targetURL, atomically: true, encoding: .utf8)
            } catch {
                throw LabPackageError.ioError("Failed writing profile '\(filename)': \(error.localizedDescription)")
            }
        }

        // 2. Write manifest
        let entries = itemsToInstall.map { item in
            ManifestProfileEntry(
                id: item.id,
                filename: URL(fileURLWithPath: item.relativePath).lastPathComponent,
                sha256: sha256Hex(Data(bundledText(item.yaml).utf8))
            )
        }
        let manifestYAML = renderUSTHManifest(version: usthPackageVersion, entries: entries)
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

    // MARK: - Update planning (issue #121)

    /// Bundled profile text as it is written to disk. It ends with a newline, so its sha256
    /// matches the asset file that the Rust core ships.
    public static func bundledText(_ yaml: String) -> String {
        yaml.hasSuffix("\n") ? yaml : yaml + "\n"
    }

    /// The top-level `revision:` value of a profile document.
    public static func profileRevision(in text: String) -> Int? {
        guard let node = try? YAMLParser.parse(text, allowIndentlessSequences: false),
              let value = node.value(for: "revision")?.scalarValue else {
            return nil
        }
        return Int(value)
    }

    /// Compares installed state with bundled state. Mirrors `plan_update` in `core/src/package/mod.rs`.
    public static func planUpdate(
        installedVersion: String,
        installedEntries: [ManifestProfileEntry],
        installedFiles: [InstalledProfileFile],
        bundledVersion: String,
        bundled: [BundledProfileRecord],
        projectOverrides: Set<String>
    ) -> UpdatePlan {
        let packageUpdate: VersionChange? = (installedVersion != bundledVersion && isNewerVersion(bundledVersion, than: installedVersion))
            ? VersionChange(installed: installedVersion, bundled: bundledVersion)
            : nil

        var profiles: [ProfileUpdate] = []
        for record in bundled {
            let file = installedFiles.first { $0.id == record.id }
            let installedRevision = file?.revision
            let onDisk = file?.sha256
            let recorded = installedEntries.first { $0.id == record.id }?.sha256
            // A deleted file is also treated as edited, so replacing it still needs consent.
            let edited = recorded.map { onDisk != $0 } ?? (onDisk != nil)
            let state: ProfileUpdateState
            if projectOverrides.contains(record.id) {
                state = .projectOverride
            } else if edited {
                state = .locallyEdited
            } else if record.revision > (installedRevision ?? 0) {
                state = .updateAvailable
            } else {
                continue
            }
            profiles.append(ProfileUpdate(
                id: record.id,
                installedRevision: installedRevision,
                bundledRevision: record.revision,
                state: state
            ))
        }
        return UpdatePlan(packageID: usthPackageID, packageUpdate: packageUpdate, profiles: profiles)
    }

    /// Profile ids to write. An empty `only` means the whole package. A named profile that cannot
    /// be written throws before anything is written.
    public static func selectWrites(plan: UpdatePlan, only: Set<String>, replace: Set<String>) throws -> [String] {
        for id in only.sorted() {
            guard let update = plan.profiles.first(where: { $0.id == id }) else { continue }
            switch update.state {
            case .projectOverride:
                throw LabPackageError.upgradeRefused("\(id) is overridden by a project-local profile and is not changed")
            case .locallyEdited where !replace.contains(id):
                throw LabPackageError.upgradeRefused("\(id) was edited locally; pass --replace \(id) to replace it")
            default:
                continue
            }
        }
        return plan.profiles
            .filter { only.isEmpty || only.contains($0.id) }
            .filter { isWritable($0, replace: replace) }
            .map(\.id)
    }

    /// The manifest entries after an upgrade. Written profiles take their bundled sha256. Every other
    /// profile keeps the sha256 of the file still on disk.
    public static func upgradedEntries(
        installedEntries: [ManifestProfileEntry],
        bundled: [BundledProfileRecord],
        written: [String]
    ) -> [ManifestProfileEntry] {
        bundled.compactMap { (record) -> ManifestProfileEntry? in
            if written.contains(record.id) {
                return ManifestProfileEntry(id: record.id, filename: record.filename, sha256: record.sha256)
            }
            return installedEntries.first { $0.id == record.id }
        }
    }

    static func renderUSTHManifest(version: String, entries: [ManifestProfileEntry]) -> String {
        var lines = [
            "schema_version: 1",
            "id: \(usthPackageID)",
            "version: \"\(version)\"",
            "display_name: \"\(usthDisplayName)\"",
            "profiles:"
        ]
        for entry in entries {
            lines.append("  - id: \(entry.id)")
            lines.append("    path: profiles/\(entry.filename)")
            lines.append("    sha256: \(entry.sha256)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads the installed USTH manifest, including the sha256 recorded for each profile.
    public static func readInstalledUSTHManifest(globalConfigDir: URL? = nil) throws -> (version: String, entries: [ManifestProfileEntry]) {
        let base = globalConfigDir ?? GlobalPathResolver.resolveGlobalConfigDirectory()
        guard let data = try? Data(contentsOf: usthManifestURL(base)) else {
            throw LabPackageError.packageNotFound(usthPackageID)
        }
        guard let text = String(data: data, encoding: .utf8),
              let node = try? YAMLParser.parse(text, allowIndentlessSequences: false) else {
            throw LabPackageError.invalidManifest("usth-lab manifest is not valid YAML")
        }
        let version = node.value(for: "version")?.scalarValue ?? "0.0.0"
        var entries: [ManifestProfileEntry] = []
        for item in node.value(for: "profiles")?.listItems ?? [] {
            guard let id = item.value(for: "id")?.scalarValue,
                  let path = item.value(for: "path")?.scalarValue,
                  let sha = item.value(for: "sha256")?.scalarValue else {
                throw LabPackageError.invalidManifest("usth-lab profile entry needs id, path and sha256")
            }
            entries.append(ManifestProfileEntry(
                id: id,
                filename: URL(fileURLWithPath: path).lastPathComponent,
                sha256: sha
            ))
        }
        return (version, entries)
    }

    /// Plans an upgrade of the installed USTH package. Reads only.
    public static func planUSTHUpgrade(globalConfigDir: URL? = nil, projectRoot: URL? = nil) throws -> UpdatePlan {
        let inputs = try loadUpgradeInputs(globalConfigDir: globalConfigDir, projectRoot: projectRoot)
        return planUpdate(
            installedVersion: inputs.installedVersion,
            installedEntries: inputs.installedEntries,
            installedFiles: inputs.installedFiles,
            bundledVersion: usthPackageVersion,
            bundled: inputs.bundled,
            projectOverrides: inputs.overrides
        )
    }

    /// Upgrades the installed USTH package. `only` limits the upgrade to named profiles, and
    /// `replace` consents to replacing edited profiles. An edited profile without consent stays in
    /// place, and its bundled copy is staged under `usth-lab/staged/`.
    public static func upgradeUSTHLabPackage(
        globalConfigDir: URL? = nil,
        projectRoot: URL? = nil,
        only: Set<String> = [],
        replace: Set<String> = []
    ) throws -> UpgradeOutcome {
        let inputs = try loadUpgradeInputs(globalConfigDir: globalConfigDir, projectRoot: projectRoot)
        let plan = planUpdate(
            installedVersion: inputs.installedVersion,
            installedEntries: inputs.installedEntries,
            installedFiles: inputs.installedFiles,
            bundledVersion: usthPackageVersion,
            bundled: inputs.bundled,
            projectOverrides: inputs.overrides
        )
        let writes = try selectWrites(plan: plan, only: only, replace: replace)
        let kept = plan.profiles
            .filter { $0.state == .locallyEdited && !writes.contains($0.id) && (only.isEmpty || only.contains($0.id)) }
            .map(\.id)

        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: inputs.base).appendingPathComponent("usth", isDirectory: true)
        let packageDir = usthPackageDirectory(inputs.base)
        for record in inputs.bundled where writes.contains(record.id) {
            try writeText(record.text, to: profilesDir.appendingPathComponent(record.filename))
        }
        for record in inputs.bundled where kept.contains(record.id) {
            try writeText(record.text, to: packageDir.appendingPathComponent("staged", isDirectory: true).appendingPathComponent(record.filename))
        }
        // A single-profile upgrade leaves the package version alone, because other profiles stay old.
        let version = only.isEmpty ? usthPackageVersion : inputs.installedVersion
        let entries = upgradedEntries(installedEntries: inputs.installedEntries, bundled: inputs.bundled, written: writes)
        try writeText(renderUSTHManifest(version: version, entries: entries), to: usthManifestURL(inputs.base))
        return UpgradeOutcome(plan: plan, written: writes, kept: kept)
    }

    private struct UpgradeInputs {
        let base: URL
        let installedVersion: String
        let installedEntries: [ManifestProfileEntry]
        let installedFiles: [InstalledProfileFile]
        let bundled: [BundledProfileRecord]
        let overrides: Set<String>
    }

    private static func loadUpgradeInputs(globalConfigDir: URL?, projectRoot: URL?) throws -> UpgradeInputs {
        let base = globalConfigDir ?? GlobalPathResolver.resolveGlobalConfigDirectory()
        let installed = try readInstalledUSTHManifest(globalConfigDir: base)
        let fm = FileManager.default
        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: base).appendingPathComponent("usth", isDirectory: true)

        let bundled = BuiltinAssets.builtinProfiles.map { item -> BundledProfileRecord in
            let text = bundledText(item.yaml)
            return BundledProfileRecord(
                id: item.id,
                filename: URL(fileURLWithPath: item.relativePath).lastPathComponent,
                text: text,
                sha256: sha256Hex(Data(text.utf8)),
                revision: profileRevision(in: text) ?? 0
            )
        }

        let installedFiles = try bundled.map { record -> InstalledProfileFile in
            let url = profilesDir.appendingPathComponent(record.filename)
            guard fm.fileExists(atPath: url.path) else {
                return InstalledProfileFile(id: record.id, revision: nil, sha256: nil)
            }
            let data = try Data(contentsOf: url)
            return InstalledProfileFile(
                id: record.id,
                revision: profileRevision(in: String(decoding: data, as: UTF8.self)),
                sha256: sha256Hex(data)
            )
        }

        var overrides = Set<String>()
        if let projectRoot {
            guard fm.fileExists(atPath: projectRoot.path) else {
                throw LabPackageError.ioError("project path does not exist: \(projectRoot.path)")
            }
            for record in bundled {
                let candidates = [".raw-viewer/profiles", ".rawviewer/profiles"]
                    .map { projectRoot.appendingPathComponent("\($0)/\(record.id).yaml") }
                if candidates.contains(where: { fm.fileExists(atPath: $0.path) }) {
                    overrides.insert(record.id)
                }
            }
        }

        return UpgradeInputs(
            base: base,
            installedVersion: installed.version,
            installedEntries: installed.entries,
            installedFiles: installedFiles,
            bundled: bundled,
            overrides: overrides
        )
    }

    private static func isWritable(_ update: ProfileUpdate, replace: Set<String>) -> Bool {
        switch update.state {
        case .updateAvailable: return true
        case .locallyEdited: return replace.contains(update.id)
        case .projectOverride: return false
        }
    }

    /// Numeric comparison of dotted versions. A version with a non-numeric part compares as text.
    private static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            var out: [Int] = []
            for piece in version.split(separator: ".", omittingEmptySubsequences: false) {
                guard let value = Int(piece) else { return nil }
                out.append(value)
            }
            return out
        }
        guard let left = parts(candidate), let right = parts(current) else {
            return candidate != current
        }
        let length = max(left.count, right.count)
        let a = left + Array(repeating: 0, count: length - left.count)
        let b = right + Array(repeating: 0, count: length - right.count)
        return b.lexicographicallyPrecedes(a)
    }

    private static func usthPackageDirectory(_ base: URL) -> URL {
        GlobalPathResolver.globalPackagesDirectory(globalConfigDir: base)
            .appendingPathComponent(usthPackageID, isDirectory: true)
    }

    private static func usthManifestURL(_ base: URL) -> URL {
        usthPackageDirectory(base).appendingPathComponent(manifestFileName)
    }

    private static func writeText(_ text: String, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw LabPackageError.ioError("Failed writing \(url.lastPathComponent): \(error.localizedDescription)")
        }
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

/// One profile line in a manifest, with the sha256 recorded for it.
public struct ManifestProfileEntry: Sendable, Equatable {
    public let id: String
    public let filename: String
    public let sha256: String
}

/// A profile file on disk. Nil fields mean the file is absent.
public struct InstalledProfileFile: Sendable, Equatable {
    public let id: String
    public let revision: Int?
    public let sha256: String?
}

/// A profile shipped with the app, with the bytes that would be written.
public struct BundledProfileRecord: Sendable, Equatable {
    public let id: String
    public let filename: String
    public let text: String
    public let sha256: String
    public let revision: Int
}

public enum ProfileUpdateState: Sendable, Equatable {
    case updateAvailable
    case locallyEdited
    case projectOverride
}

/// A profile that needs attention. Profiles already at the bundled revision are not listed.
public struct ProfileUpdate: Sendable, Equatable {
    public let id: String
    public let installedRevision: Int?
    public let bundledRevision: Int
    public let state: ProfileUpdateState
}

public struct VersionChange: Sendable, Equatable {
    public let installed: String
    public let bundled: String
}

public struct UpdatePlan: Sendable, Equatable {
    public let packageID: String
    public let packageUpdate: VersionChange?
    public let profiles: [ProfileUpdate]
}

public struct UpgradeOutcome: Sendable, Equatable {
    public let plan: UpdatePlan
    public let written: [String]
    public let kept: [String]
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
