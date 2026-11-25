import Foundation

/// One installed profile in the Lab Packages list.
public struct LabPackageUpdateRow: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case current
        case updateAvailable
        case editedLocally
        case projectOverride
    }

    public var id: String { profileID }
    public let profileID: String
    public let kind: Kind
    /// Nil for a current profile, which shows no revision.
    public let revisionText: String?
    public let statusText: String

    /// An edited profile keeps the button, because it opens the Replace or Keep both choice.
    public var hasUpdateButton: Bool {
        kind == .updateAvailable || kind == .editedLocally
    }
}

/// What the Lab Packages list shows for one installed package.
public struct LabPackageUpdateSection: Equatable, Sendable {
    /// Nil when the check could not run.
    public let packageStatusText: String?
    public let rows: [LabPackageUpdateRow]
    public let canUpdatePackage: Bool
    /// Nil unless the check could not run.
    public let problemText: String?
}

/// A button click in the Lab Packages list.
public enum LabPackageUpdateCommand: Equatable, Sendable {
    case updatePackage
    case updateProfile(String)
    case replaceEditedProfile(String)
    case keepBothEditedProfile(String)
}

/// The arguments that one command sends to `LabPackageManager.upgradeUSTHLabPackage`.
public struct LabPackageUpgradeRequest: Equatable, Sendable {
    public let only: Set<String>
    public let replace: Set<String>
    public let keepBoth: Set<String>
}

public enum LabPackagePresentation {
    public static func plan(globalConfigDir: URL? = nil, projectRoot: URL? = nil) throws -> UpdatePlan {
        try LabPackageManager.planUSTHUpgrade(globalConfigDir: globalConfigDir, projectRoot: projectRoot)
    }

    /// Builds the list from the installed profiles. A bundled profile that is not installed is
    /// not listed, because the package never had it.
    public static func section(for package: LabPackageSummary, plan: UpdatePlan) -> LabPackageUpdateSection {
        let updates = Dictionary(plan.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = package.profiles.map { profile -> LabPackageUpdateRow in
            guard let update = updates[profile.id] else {
                return LabPackageUpdateRow(profileID: profile.id, kind: .current, revisionText: nil, statusText: "Current")
            }
            return row(for: update)
        }
        let statusText: String
        if let change = plan.packageUpdate {
            statusText = "Update available: \(change.installed) → \(change.bundled)"
        } else {
            statusText = "Up to date"
        }
        let canUpdatePackage = plan.packageUpdate != nil || plan.profiles.contains { $0.state == .updateAvailable }
        return LabPackageUpdateSection(packageStatusText: statusText, rows: rows, canUpdatePackage: canUpdatePackage, problemText: nil)
    }

    public static func unavailableSection(for error: Error) -> LabPackageUpdateSection {
        LabPackageUpdateSection(
            packageStatusText: nil,
            rows: [],
            canUpdatePackage: false,
            problemText: "Could not check for updates: \(error.localizedDescription)"
        )
    }

    public static func request(for command: LabPackageUpdateCommand) -> LabPackageUpgradeRequest {
        switch command {
        case .updatePackage:
            return LabPackageUpgradeRequest(only: [], replace: [], keepBoth: [])
        case .updateProfile(let id):
            return LabPackageUpgradeRequest(only: [id], replace: [], keepBoth: [])
        case .replaceEditedProfile(let id):
            return LabPackageUpgradeRequest(only: [id], replace: [id], keepBoth: [])
        case .keepBothEditedProfile(let id):
            return LabPackageUpgradeRequest(only: [id], replace: [], keepBoth: [id])
        }
    }

    /// Runs one command against the installed USTH package. It writes only what the command names.
    public static func run(_ command: LabPackageUpdateCommand, globalConfigDir: URL? = nil, projectRoot: URL? = nil) throws -> UpgradeOutcome {
        let request = request(for: command)
        return try LabPackageManager.upgradeUSTHLabPackage(
            globalConfigDir: globalConfigDir,
            projectRoot: projectRoot,
            only: request.only,
            replace: request.replace,
            keepBoth: request.keepBoth
        )
    }

    public static func successLine(for outcome: UpgradeOutcome, command: LabPackageUpdateCommand) -> String {
        var parts: [String] = []
        if !outcome.written.isEmpty {
            parts.append("Updated \(outcome.written.joined(separator: ", ")).")
        }
        if !outcome.kept.isEmpty {
            parts.append("Kept your edited copy of \(outcome.kept.joined(separator: ", ")). The new version is saved in the package's staged folder.")
        }
        if case .updatePackage = command, let change = outcome.plan.packageUpdate {
            parts.append("Package is now version \(change.bundled).")
        }
        return parts.isEmpty ? "Nothing to update." : parts.joined(separator: " ")
    }

    public static func errorLine(for error: Error) -> String {
        "Could not update: \(error.localizedDescription)"
    }

    private static func row(for update: ProfileUpdate) -> LabPackageUpdateRow {
        let installed = update.installedRevision.flatMap { $0 == update.bundledRevision ? nil : $0 }
        let revisionText = installed.map { "rev \($0) → \(update.bundledRevision)" } ?? "rev \(update.bundledRevision)"
        let kind: LabPackageUpdateRow.Kind
        let statusText: String
        switch update.state {
        case .updateAvailable:
            kind = .updateAvailable
            statusText = "Update available"
        case .locallyEdited:
            kind = .editedLocally
            statusText = "Edited locally"
        case .projectOverride:
            kind = .projectOverride
            statusText = "Overridden by project"
        }
        return LabPackageUpdateRow(profileID: update.id, kind: kind, revisionText: revisionText, statusText: statusText)
    }
}
