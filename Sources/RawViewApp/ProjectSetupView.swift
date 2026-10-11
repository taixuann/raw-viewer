import AppKit
import SwiftUI
import RawViewCore

struct ProjectSetupView: View {
    let projectRoot: URL
    let initialDiagnostic: String?
    let onOpen: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var selectedDataRoot: String
    @State private var persistSettings: Bool = true
    @State private var diagnostic: String?

    init(
        projectRoot: URL,
        initialDiagnostic: String? = nil,
        suggestedDataRoot: String? = nil,
        onOpen: @escaping (String, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.projectRoot = projectRoot
        self.initialDiagnostic = initialDiagnostic
        self.onOpen = onOpen
        self.onCancel = onCancel

        let initial: String
        if let suggested = suggestedDataRoot, !suggested.isEmpty {
            initial = suggested
        } else {
            let dataRaw = projectRoot.appendingPathComponent("data/raw")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dataRaw.path, isDirectory: &isDir), isDir.boolValue {
                initial = "data/raw"
            } else {
                initial = "."
            }
        }
        _selectedDataRoot = State(initialValue: initial)
        _diagnostic = State(initialValue: initialDiagnostic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project Setup")
                        .font(.headline)
                    Text("Configure the measurement data folder for this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project folder:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(projectRoot.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(projectRoot.path)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Data folder:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text(selectedDataRoot == "." ? ". (Project root directory)" : selectedDataRoot)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

                        Button("Change…") {
                            pickDataFolder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                suggestionsView

                Toggle("Save configuration in .rawviewer/setting.yaml", isOn: $persistSettings)
                    .font(.caption)
                    .padding(.top, 4)

                if let diag = diagnostic {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(diag)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                }
            }

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Open without saving") {
                    validateAndOpen(persist: false)
                }
                .buttonStyle(.bordered)

                Button("Open Project") {
                    validateAndOpen(persist: persistSettings)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    @ViewBuilder
    private var suggestionsView: some View {
        let hasDataRaw = FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("data/raw").path)
        if hasDataRaw && selectedDataRoot != "data/raw" {
            HStack(spacing: 6) {
                Text("Suggestion:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Use 'data/raw'") {
                    selectedDataRoot = "data/raw"
                    diagnostic = nil
                }
                .buttonStyle(.plain)
                .font(.caption2.bold())
                .foregroundStyle(Color.accentColor)
            }
        } else if !hasDataRaw && selectedDataRoot != "." {
            HStack(spacing: 6) {
                Text("Suggestion:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Use project root '.'") {
                    selectedDataRoot = "."
                    diagnostic = nil
                }
                .buttonStyle(.plain)
                .font(.caption2.bold())
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func pickDataFolder() {
        let panel = NSOpenPanel()
        panel.directoryURL = projectRoot
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Data Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let canonicalProject = projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalChosen = url.resolvingSymlinksInPath().standardizedFileURL.path

        if canonicalChosen == canonicalProject {
            selectedDataRoot = "."
            diagnostic = nil
        } else if canonicalChosen.hasPrefix(canonicalProject + "/") {
            let rel = String(canonicalChosen.dropFirst(canonicalProject.count + 1))
            selectedDataRoot = rel
            diagnostic = nil
        } else {
            diagnostic = "Selected folder must be located inside the project."
        }
    }

    private func validateAndOpen(persist: Bool) {
        do {
            try ProjectSettingsStore.validateDataRoot(selectedDataRoot)
            _ = try ProjectContext.open(projectRoot, dataRootRelativePath: selectedDataRoot)
            diagnostic = nil
            onOpen(selectedDataRoot, persist)
        } catch {
            diagnostic = "Invalid data root: \(error.localizedDescription)"
        }
    }
}
