import Foundation
@testable import RawViewCore

/// Writes USTH installs into a temporary global config dir for the lab package update tests.
enum LabPackageTestFixtures {
    static let keithleyID = "usth/keithley-2400"
    static let autolabID = "usth/autolab-usth"

    /// Writes every bundled profile and a manifest. `files` overrides the on-disk text of a
    /// profile, and `recorded` overrides the text whose sha256 the manifest records for it.
    static func makeInstall(
        global: URL,
        version: String = LabPackageManager.usthPackageVersion,
        files: [String: String] = [:],
        recorded: [String: String] = [:]
    ) throws {
        let profilesDir = GlobalPathResolver.globalProfilesDirectory(globalConfigDir: global).appendingPathComponent("usth", isDirectory: true)
        let packageDir = GlobalPathResolver.globalPackagesDirectory(globalConfigDir: global).appendingPathComponent("usth-lab", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        var entries: [ManifestProfileEntry] = []
        for item in BuiltinAssets.builtinProfiles {
            let filename = URL(fileURLWithPath: item.relativePath).lastPathComponent
            let onDisk = files[item.id] ?? LabPackageManager.bundledText(item.yaml)
            try onDisk.write(to: profilesDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
            let recordedText = recorded[item.id] ?? onDisk
            entries.append(ManifestProfileEntry(id: item.id, filename: filename, sha256: sha256Hex(Data(recordedText.utf8))))
        }
        try LabPackageManager.renderUSTHManifest(version: version, entries: entries)
            .write(to: packageDir.appendingPathComponent("manifest.yaml"), atomically: true, encoding: .utf8)
    }

    /// The bundled text of a profile with its revision lowered by one, as an older install has it.
    static func olderRevision(of bundledYAML: String) -> String {
        let bundled = LabPackageManager.bundledText(bundledYAML)
        let revision = LabPackageManager.profileRevision(in: bundled) ?? 1
        return bundled.replacingOccurrences(of: "revision: \(revision)", with: "revision: \(revision - 1)")
    }

    static func profilesDirectory(global: URL) -> URL {
        GlobalPathResolver.globalProfilesDirectory(globalConfigDir: global).appendingPathComponent("usth", isDirectory: true)
    }

    static func packageDirectory(global: URL) -> URL {
        GlobalPathResolver.globalPackagesDirectory(globalConfigDir: global).appendingPathComponent("usth-lab", isDirectory: true)
    }
}
