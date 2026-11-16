import SwiftUI
import RawViewCore

/// Update status and buttons for one installed lab package in Settings.
struct LabPackagesUpdateView: View {
    let package: LabPackageSummary
    let projectRoot: URL?
    let onChanged: () -> Void

    @AppStorage("uiFontFamily") private var uiFontFamily: String = "System"
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0

    @State private var section: LabPackageUpdateSection?
    @State private var resultText: String?
    @State private var resultIsError = false
    @State private var editedProfileID: String?

    var body: some View {
        if package.id == LabPackageManager.usthPackageID {
            VStack(alignment: .leading, spacing: 6) {
                if let section {
                    content(for: section)
                }
                if let resultText {
                    Text(resultText)
                        .font(AppTypography.caption(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                        .foregroundStyle(resultIsError ? Color.red : Color.green)
                }
            }
            .task { reload() }
            .onChange(of: package) { reload() }
            .confirmationDialog(
                editedDialogTitle,
                isPresented: Binding(
                    get: { editedProfileID != nil },
                    set: { if !$0 { editedProfileID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Replace", role: .destructive) {
                    if let id = editedProfileID { run(.replaceEditedProfile(id)) }
                }
                Button("Keep both") {
                    if let id = editedProfileID { run(.keepBothEditedProfile(id)) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Replace uses the new bundled version. Keep both leaves your edited file as it is and saves the new version beside it.")
            }
        }
    }

    @ViewBuilder
    private func content(for section: LabPackageUpdateSection) -> some View {
        if let problem = section.problemText {
            Text(problem)
                .font(AppTypography.caption(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                .foregroundStyle(.orange)
        }

        if let status = section.packageStatusText {
            HStack {
                Text(status)
                    .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                Spacer()
                if section.canUpdatePackage {
                    Button("Update package") { run(.updatePackage) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            if section.canUpdatePackage {
                Text("Updates every profile that has a newer version.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(section.rows) { row in
            HStack(spacing: 8) {
                Text(row.profileID)
                    .font(AppTypography.monoCell(uiFontSize: uiFontSize))
                if let revision = row.revisionText {
                    Text(revision)
                        .font(AppTypography.caption(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                        .foregroundStyle(.secondary)
                }
                Text(row.statusText)
                    .font(AppTypography.caption(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                    .foregroundStyle(row.kind == .current ? Color.secondary : Color.orange)
                Spacer()
                if row.hasUpdateButton {
                    Button("Update") {
                        if row.kind == .editedLocally {
                            editedProfileID = row.profileID
                        } else {
                            run(.updateProfile(row.profileID))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var editedDialogTitle: String {
        guard let id = editedProfileID else { return "" }
        return "\(id) was edited on this Mac"
    }

    private func reload() {
        do {
            let plan = try LabPackagePresentation.plan(projectRoot: projectRoot)
            section = LabPackagePresentation.section(for: package, plan: plan)
        } catch {
            section = LabPackagePresentation.unavailableSection(for: error)
        }
    }

    private func run(_ command: LabPackageUpdateCommand) {
        editedProfileID = nil
        do {
            let outcome = try LabPackagePresentation.run(command, projectRoot: projectRoot)
            resultText = LabPackagePresentation.successLine(for: outcome, command: command)
            resultIsError = false
        } catch {
            resultText = LabPackagePresentation.errorLine(for: error)
            resultIsError = true
        }
        reload()
        onChanged()
    }
}
