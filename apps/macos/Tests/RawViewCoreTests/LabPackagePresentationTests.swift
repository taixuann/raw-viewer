import XCTest
@testable import RawViewCore

/// Pure mapping from the update plan to the Lab Packages list (issue #121, Settings surface).
final class LabPackagePresentationTests: XCTestCase {
    private let keithley = LabPackageTestFixtures.keithleyID
    private let autolab = LabPackageTestFixtures.autolabID

    private func package(version: String = "0.1.1", profiles: [String]) -> LabPackageSummary {
        LabPackageSummary(
            id: "usth-lab",
            displayName: LabPackageManager.usthDisplayName,
            version: version,
            profiles: profiles.map { id in
                LabPackageProfileSummary(id: id, filename: String(id.dropFirst("usth/".count)) + ".yaml")
            },
            storageURL: nil,
            isInstalled: true
        )
    }

    private func plan(packageUpdate: VersionChange? = nil, profiles: [ProfileUpdate] = []) -> UpdatePlan {
        UpdatePlan(packageID: "usth-lab", packageUpdate: packageUpdate, profiles: profiles)
    }

    func testCurrentPackageSaysUpToDateAndOffersNoPackageUpdate() {
        let section = LabPackagePresentation.section(for: package(profiles: [keithley, autolab]), plan: plan())

        XCTAssertEqual(section.packageStatusText, "Up to date")
        XCTAssertFalse(section.canUpdatePackage)
        XCTAssertNil(section.problemText)
        XCTAssertEqual(section.rows, [
            LabPackageUpdateRow(profileID: keithley, kind: .current, revisionText: nil, statusText: "Current"),
            LabPackageUpdateRow(profileID: autolab, kind: .current, revisionText: nil, statusText: "Current")
        ])
    }

    func testNewerBundledVersionShowsVersionChangeAndEnablesPackageUpdate() {
        let section = LabPackagePresentation.section(
            for: package(version: "0.1.0", profiles: []),
            plan: plan(packageUpdate: VersionChange(installed: "0.1.0", bundled: "0.1.1"))
        )

        XCTAssertEqual(section.packageStatusText, "Update available: 0.1.0 → 0.1.1")
        XCTAssertTrue(section.canUpdatePackage)
    }

    func testUpdateAvailableProfileShowsRevisionArrowStatusAndUpdateButton() {
        let section = LabPackagePresentation.section(
            for: package(profiles: [keithley]),
            plan: plan(profiles: [ProfileUpdate(id: keithley, installedRevision: 1, bundledRevision: 2, state: .updateAvailable)])
        )

        XCTAssertEqual(section.rows, [
            LabPackageUpdateRow(profileID: keithley, kind: .updateAvailable, revisionText: "rev 1 → 2", statusText: "Update available")
        ])
        XCTAssertTrue(section.rows[0].hasUpdateButton)
        XCTAssertTrue(section.canUpdatePackage)
    }

    func testEditedProfileShowsEditedLocallyWithUpdateButtonAndSameRevision() {
        let section = LabPackagePresentation.section(
            for: package(profiles: [keithley]),
            plan: plan(profiles: [ProfileUpdate(id: keithley, installedRevision: 1, bundledRevision: 1, state: .locallyEdited)])
        )

        XCTAssertEqual(section.rows, [
            LabPackageUpdateRow(profileID: keithley, kind: .editedLocally, revisionText: "rev 1", statusText: "Edited locally")
        ])
        XCTAssertTrue(section.rows[0].hasUpdateButton)
        XCTAssertFalse(section.canUpdatePackage)
    }

    func testEditedProfileWithNewerRevisionShowsBothRevisions() {
        let section = LabPackagePresentation.section(
            for: package(profiles: [keithley]),
            plan: plan(profiles: [ProfileUpdate(id: keithley, installedRevision: 1, bundledRevision: 2, state: .locallyEdited)])
        )

        XCTAssertEqual(section.rows.map(\.revisionText), ["rev 1 → 2"])
    }

    func testProjectOverrideProfileShowsOverriddenAndNoButton() {
        let section = LabPackagePresentation.section(
            for: package(profiles: [keithley]),
            plan: plan(profiles: [ProfileUpdate(id: keithley, installedRevision: 1, bundledRevision: 2, state: .projectOverride)])
        )

        XCTAssertEqual(section.rows, [
            LabPackageUpdateRow(profileID: keithley, kind: .projectOverride, revisionText: "rev 1 → 2", statusText: "Overridden by project")
        ])
        XCTAssertFalse(section.rows[0].hasUpdateButton)
        XCTAssertFalse(section.canUpdatePackage)
    }

    func testProfileWithoutInstalledRevisionShowsOnlyBundledRevision() {
        let section = LabPackagePresentation.section(
            for: package(profiles: [keithley]),
            plan: plan(profiles: [ProfileUpdate(id: keithley, installedRevision: nil, bundledRevision: 2, state: .updateAvailable)])
        )

        XCTAssertEqual(section.rows.map(\.revisionText), ["rev 2"])
    }

    func testBundledProfileThatIsNotInstalledIsNotListed() {
        let section = LabPackagePresentation.section(
            for: package(profiles: [keithley]),
            plan: plan(profiles: [ProfileUpdate(id: autolab, installedRevision: nil, bundledRevision: 2, state: .updateAvailable)])
        )

        XCTAssertEqual(section.rows, [
            LabPackageUpdateRow(profileID: keithley, kind: .current, revisionText: nil, statusText: "Current")
        ])
    }

    func testFailedCheckShowsPlainProblemAndNoRows() {
        let section = LabPackagePresentation.unavailableSection(for: LabPackageError.packageNotFound("usth-lab"))

        XCTAssertNil(section.packageStatusText)
        XCTAssertEqual(section.rows, [])
        XCTAssertFalse(section.canUpdatePackage)
        XCTAssertEqual(section.problemText, "Could not check for updates: Package 'usth-lab' not found.")
    }

    func testUpdatePackageCommandAsksForWholePackageWithNoProfileNames() {
        XCTAssertEqual(
            LabPackagePresentation.request(for: .updatePackage),
            LabPackageUpgradeRequest(only: [], replace: [], keepBoth: [])
        )
    }

    func testUpdateProfileCommandNamesOnlyThatProfile() {
        XCTAssertEqual(
            LabPackagePresentation.request(for: .updateProfile(keithley)),
            LabPackageUpgradeRequest(only: [keithley], replace: [], keepBoth: [])
        )
    }

    func testReplaceCommandNamesProfileForOnlyAndReplace() {
        XCTAssertEqual(
            LabPackagePresentation.request(for: .replaceEditedProfile(keithley)),
            LabPackageUpgradeRequest(only: [keithley], replace: [keithley], keepBoth: [])
        )
    }

    func testKeepBothCommandNamesProfileForOnlyAndKeepBothWithoutReplace() {
        XCTAssertEqual(
            LabPackagePresentation.request(for: .keepBothEditedProfile(keithley)),
            LabPackageUpgradeRequest(only: [keithley], replace: [], keepBoth: [keithley])
        )
    }

    func testSuccessLineNamesUpdatedProfile() {
        let outcome = UpgradeOutcome(
            plan: plan(profiles: [ProfileUpdate(id: keithley, installedRevision: 1, bundledRevision: 2, state: .updateAvailable)]),
            written: [keithley],
            kept: []
        )

        XCTAssertEqual(LabPackagePresentation.successLine(for: outcome, command: .updateProfile(keithley)), "Updated usth/keithley-2400.")
    }

    func testSuccessLineSaysEditedCopyWasKeptAndNewVersionIsStaged() {
        let outcome = UpgradeOutcome(
            plan: plan(profiles: [ProfileUpdate(id: autolab, installedRevision: 1, bundledRevision: 2, state: .locallyEdited)]),
            written: [],
            kept: [autolab]
        )

        XCTAssertEqual(
            LabPackagePresentation.successLine(for: outcome, command: .keepBothEditedProfile(autolab)),
            "Kept your edited copy of usth/autolab-usth. The new version is saved in the package's staged folder."
        )
    }

    func testSuccessLineReportsNewPackageVersionAfterPackageUpdate() {
        let outcome = UpgradeOutcome(
            plan: plan(
                packageUpdate: VersionChange(installed: "0.1.0", bundled: "0.1.1"),
                profiles: [ProfileUpdate(id: keithley, installedRevision: 1, bundledRevision: 2, state: .updateAvailable)]
            ),
            written: [keithley],
            kept: []
        )

        XCTAssertEqual(
            LabPackagePresentation.successLine(for: outcome, command: .updatePackage),
            "Updated usth/keithley-2400. Package is now version 0.1.1."
        )
    }

    func testSuccessLineSaysNothingToUpdateWhenNothingWasWritten() {
        let outcome = UpgradeOutcome(plan: plan(), written: [], kept: [])

        XCTAssertEqual(LabPackagePresentation.successLine(for: outcome, command: .updateProfile(keithley)), "Nothing to update.")
    }

    func testErrorLineStartsWithPlainPrefix() {
        XCTAssertEqual(
            LabPackagePresentation.errorLine(for: LabPackageError.ioError("disk full")),
            "Could not update: Package I/O failure: disk full"
        )
    }
}
