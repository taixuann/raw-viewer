import AppKit
import SwiftUI
import RawViewCore

struct SettingsView: View {
    @ObservedObject var model: RawViewModel
    @AppStorage("appTheme") private var appTheme: String = "System"
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0
    @AppStorage("isLazyInspectionEnabled") private var isLazyInspectionEnabled: Bool = true
    @AppStorage("maxComparisonAutoLoad") private var maxComparisonAutoLoad: Int = 15
    @AppStorage("cacheLimitMB") private var cacheLimitMB: Int = 2048
    @State private var cacheClearedMessage: String?
    @ObservedObject private var hotkeyManager = HotkeyManager.shared


    enum SettingsTab: String, Identifiable, CaseIterable {
        case project
        case appearance
        case ai
        case performance
        case storage
        case hotkeys

        var id: String { rawValue }

        var label: String {
            switch self {
            case .project: return "Project"
            case .appearance: return "Appearance"
            case .ai: return "LLM & AI Models"
            case .performance: return "Performance"
            case .storage: return "Storage"
            case .hotkeys: return "Hotkeys"
            }
        }

        var icon: String {
            switch self {
            case .project: return "folder"
            case .appearance: return "paintbrush"
            case .ai: return "sparkles"
            case .performance: return "bolt.fill"
            case .storage: return "internaldrive"
            case .hotkeys: return "keyboard"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .ai

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedTab) {
                    Section("General") {
                        tabRow(.project)
                        tabRow(.appearance)
                    }

                    Section("Intelligence") {
                        tabRow(.ai)
                    }

                    Section("System") {
                        tabRow(.performance)
                        tabRow(.storage)
                        tabRow(.hotkeys)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 200)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            }

            VStack(alignment: .leading, spacing: 0) {
                detailContent
                    .id(selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 720, idealWidth: 760, maxWidth: 820, minHeight: 480, idealHeight: 520, maxHeight: 600)
    }

    @ViewBuilder
    private func tabRow(_ tab: SettingsTab) -> some View {
        Label(tab.label, systemImage: tab.icon)
            .tag(tab)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .project:
            projectTab
        case .appearance:
            appearanceTab
        case .ai:
            AISettingsView()
        case .performance:
            performanceTab
        case .storage:
            storageTab
        case .hotkeys:
            hotkeysTab
        }
    }

    private var appearanceTab: some View {
        Form {
            Section("Interface Theme & Sizing") {
                Picker("Theme:", selection: $appTheme) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Font Size Preset:")
                    Slider(value: $uiFontSize, in: 10...16, step: 1)
                    Text("\(Int(uiFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var performanceTab: some View {
        Form {
            Section("File Discovery & Inspection") {
                Picker("Loading Mode:", selection: $isLazyInspectionEnabled) {
                    Text("Lazy (Inspect on demand - Instant startup)").tag(true)
                    Text("Eager (Inspect all files in background)").tag(false)
                }
                .pickerStyle(.radioGroup)

                Text("Lazy mode instantly opens large folders with thousands of files without background disk thrashing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Multi-Source Comparison") {
                Picker("Max Auto-Loaded Series:", selection: $maxComparisonAutoLoad) {
                    Text("5 series").tag(5)
                    Text("10 series").tag(10)
                    Text("15 series (Default)").tag(15)
                    Text("25 series").tag(25)
                    Text("50 series").tag(50)
                }

                Text("Caps concurrent loading to prevent memory spikes and freezes when selecting large cohorts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var storageTab: some View {
        Form {
            Section("Database Index (SQLite WAL)") {
                if let stats = model.databaseStats {
                    LabeledContent("Active Project:", value: model.project?.root.lastPathComponent ?? "–")
                    LabeledContent("Database Size:", value: ByteCountFormatter.string(fromByteCount: stats.fileSizeBytes, countStyle: .file))
                    LabeledContent("Indexed Records:", value: "\(stats.indexedCount) of \(stats.totalSources) sources")

                    HStack {
                        if model.isInspecting {
                            ProgressView(value: Double(model.inspectedSources), total: Double(max(1, model.inspectionTotal))) {
                                Text("Inspecting \(model.inspectedSources) of \(model.inspectionTotal)…")
                                    .font(.caption)
                            }
                        } else {
                            Button("Re-index Project") {
                                model.reindexAllSources()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 4)
                } else {
                    Text("No project currently open. Open a project to inspect its SQLite database index.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Disk & Memory Cache Limits") {
                HStack {
                    Text("Max Cache Limit:")
                    Picker("", selection: $cacheLimitMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("2 GB (Default)").tag(2048)
                        Text("4 GB").tag(4096)
                        Text("8 GB").tag(8192)
                    }
                    .onChange(of: cacheLimitMB) { _, newMB in
                        let bytes = Int64(newMB) * 1024 * 1024
                        model.cacheLimitBytes = bytes
                    }
                }

                if let usage = model.cacheUsage {
                    LabeledContent("Cache Usage:", value: "\(ByteCountFormatter.string(fromByteCount: usage.usedBytes, countStyle: .file)) across \(usage.entryCount) files")
                }

                HStack {
                    Button("Clear Cache Files") {
                        model.clearCacheFiles()
                        cacheClearedMessage = "Cache cleared successfully."
                    }
                    .buttonStyle(.bordered)

                    if let message = cacheClearedMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.top, 2)
            }
        }
        .formStyle(.grouped)
    }

    private var projectTab: some View {
        Form {
            Section("Active Project & Data Location") {
                if let project = model.project {
                    LabeledContent("Project Path:", value: project.root.path)
                    LabeledContent("Data Root:", value: project.dataRootRelativePath == "." ? ". (Project Root)" : project.dataRootRelativePath)

                    HStack {
                        Button("Change Data Root…") {
                            pickNewDataRoot(for: project)
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        let hasSettings = (try? ProjectSettingsStore.load(projectRoot: project.root)) != nil
                        Text(hasSettings ? "Saved in .rawviewer/setting" : "Unsaved (session only)")
                            .font(.caption)
                            .foregroundStyle(hasSettings ? .green : .secondary)
                    }

                    LabeledContent("Writable Index:", value: project.indexDatabaseURL.path)
                    LabeledContent("Storage Mode:", value: "Owner-Private App-Local (Application Support)")
                } else {
                    Text("No project currently open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Task 6: project-scoped Developer Mode. Disabled without a
            // project; the toggle rolls back visibly when the write fails and
            // never touches a global default.
            Section("Developer Mode") {
                Toggle("Developer Mode", isOn: Binding(
                    get: { model.developerMode },
                    set: { model.setDeveloperMode($0) }
                ))
                .disabled(model.project == nil)
                .help("Adds Profile YAML and grammar YAML source editors for this project only.")
                Text("Project-only source editors for the whole profile document and the whole grammar catalog. Invalid drafts never reach disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickNewDataRoot(for project: ProjectContext) {
        let panel = NSOpenPanel()
        panel.directoryURL = project.root
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose New Data Root"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let canonicalProject = project.root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalChosen = url.resolvingSymlinksInPath().standardizedFileURL.path

        let rel: String
        if canonicalChosen == canonicalProject {
            rel = "."
        } else if canonicalChosen.hasPrefix(canonicalProject + "/") {
            rel = String(canonicalChosen.dropFirst(canonicalProject.count + 1))
        } else {
            return
        }

        Task {
            do {
                try await model.changeDataRoot(to: rel, persist: true)
            } catch {
                model.error = "Failed to change data root: \(error.localizedDescription)"
            }
        }
    }

    private var hotkeysTab: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keyboard Shortcuts & Gestures")
                            .font(.headline)
                        Text("Configured shortcuts update dynamically across all buttons and contextual badges.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore Defaults") {
                        hotkeyManager.resetToDefaults()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            let categories = ["Navigation", "Profile Studio", "View", "Export"]
            ForEach(categories, id: \.self) { cat in
                let items = hotkeyManager.hotkeys.filter { $0.category == cat }
                if !items.isEmpty {
                    Section(cat) {
                        ForEach(items) { hk in
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hk.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(hk.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ShortcutBadge(hk.id)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
