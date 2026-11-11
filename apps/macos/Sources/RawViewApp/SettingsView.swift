import AppKit
import SwiftUI
import RawViewCore

struct SettingsView: View {
    @ObservedObject var model: RawViewModel
    @AppStorage("appTheme") private var appTheme: String = "System"
    @AppStorage("uiFontFamily") private var uiFontFamily: String = "System"
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0
    @AppStorage("isLazyInspectionEnabled") private var isLazyInspectionEnabled: Bool = true
    @AppStorage("maxComparisonAutoLoad") private var maxComparisonAutoLoad: Int = 15
    @AppStorage("treeDateGranularity") private var treeDateGranularity: String = "day"
    @State private var grammarTestFilename = "100826-102100_autolab-usth.ca_sampleA_r.[test]_f.[none]_b1.txt"
    @State private var cacheClearedMessage: String?
    @State private var packageActionMessage: String?
    @State private var packageErrorMessage: String?
    @State private var installedPackages: [LabPackageSummary] = []
    @State private var selectedUSTHProfiles: Set<String> = Set(BuiltinAssets.builtinProfiles.map(\.id))
    @ObservedObject private var hotkeyManager = HotkeyManager.shared

    enum SettingsTab: String, Identifiable, CaseIterable {
        case project
        case appearance
        case grammar
        case packages
        case profiles
        case performance
        case storage
        case hotkeys

        var id: String { rawValue }

        var label: String {
            switch self {
            case .project: return "Project"
            case .appearance: return "Appearance"
            case .grammar: return "Grammar"
            case .packages: return "Lab Packages"
            case .profiles: return "Profiles"
            case .performance: return "Performance"
            case .storage: return "Storage"
            case .hotkeys: return "Hotkeys"
            }
        }

        var icon: String {
            switch self {
            case .project: return "folder"
            case .appearance: return "paintbrush"
            case .grammar: return "character.textbox"
            case .packages: return "shippingbox"
            case .profiles: return "slider.horizontal.3"
            case .performance: return "bolt.fill"
            case .storage: return "internaldrive"
            case .hotkeys: return "keyboard"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .project

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedTab) {
                    Section("General") {
                        tabRow(.project)
                        tabRow(.appearance)
                        tabRow(.grammar)
                        tabRow(.packages)
                        tabRow(.profiles)
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
        .frame(minWidth: 740, idealWidth: 780, maxWidth: 860, minHeight: 500, idealHeight: 540, maxHeight: 620)
        .onAppear {
            refreshInstalledPackages()
        }
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
        case .grammar:
            grammarTab
        case .performance:
            performanceTab
        case .storage:
            storageTab
        case .packages:
            packagesTab
        case .profiles:
            profilesTab
        case .hotkeys:
            hotkeysTab
        }
    }

    // MARK: - Project Tab

    private var projectTab: some View {
        Form {
            Section("Active Project & Data Location") {
                if let project = model.project {
                    pathRow(label: "Project Root:", path: project.root.path, url: project.root)

                    let dataRootAbs = project.dataRootRelativePath == "."
                        ? project.root.path
                        : project.root.appendingPathComponent(project.dataRootRelativePath).path
                    pathRow(
                        label: "Data Root:",
                        path: project.dataRootRelativePath == "." ? ". (Project Root)" : "\(project.dataRootRelativePath) (\(dataRootAbs))",
                        url: URL(fileURLWithPath: dataRootAbs)
                    )

                    HStack {
                        Button("Change Data Root…") {
                            pickNewDataRoot(for: project)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }

                    let projConfigURL = GlobalPathResolver.projectConfigFile(projectRoot: project.root)
                    let hasConfig = FileManager.default.fileExists(atPath: projConfigURL.path)
                    pathRow(
                        label: "Project Config:",
                        path: projConfigURL.path,
                        url: projConfigURL,
                        statusText: hasConfig ? "Saved (.raw-viewer/config.yaml)" : "Unsaved (session defaults)",
                        statusColor: hasConfig ? .green : .secondary
                    )
                } else {
                    Text("No project currently open. Open a folder to view and configure project paths.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Global Settings Scope") {
                let globalConfigURL = GlobalPathResolver.globalConfigFile()
                let globalExists = FileManager.default.fileExists(atPath: globalConfigURL.path)
                pathRow(
                    label: "Global Config:",
                    path: globalConfigURL.path,
                    url: globalConfigURL,
                    statusText: globalExists ? "Active" : "Default fallback (not yet created)",
                    statusColor: globalExists ? .green : .secondary
                )

                let globalGrammarURL = GlobalPathResolver.globalGrammarFile()
                let grammarExists = FileManager.default.fileExists(atPath: globalGrammarURL.path)
                pathRow(
                    label: "Global Grammar:",
                    path: globalGrammarURL.path,
                    url: globalGrammarURL,
                    statusText: grammarExists ? "Customized" : "Built-in defaults",
                    statusColor: grammarExists ? .green : .secondary
                )

                LabeledContent("Recent Projects:", value: "\(model.recentProjects.count) entries in session list")
                Text("Recent projects are remembered as a session list, not an app-managed project library.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

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

    // MARK: - Storage Tab

    private var storageTab: some View {
        Form {
            Section("Database Index (SQLite WAL)") {
                if let project = model.project, let stats = model.databaseStats {
                    pathRow(
                        label: "Index Database:",
                        path: project.indexDatabaseURL.path,
                        url: project.indexDatabaseURL
                    )
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

            Section("Measurement Payload Cache") {
                if let project = model.project {
                    let cacheURL = MeasurementCache.appLocalRoot(project: project)
                    pathRow(
                        label: "Cache Directory:",
                        path: cacheURL.path,
                        url: cacheURL
                    )
                }

                HStack {
                    Text("Max Cache Limit:")
                    Picker("", selection: Binding<Int>(
                        get: { Int(model.cacheLimitBytes / (1024 * 1024)) },
                        set: { newMB in
                            model.cacheLimitBytes = Int64(newMB) * 1024 * 1024
                        }
                    )) {
                        Text("512 MiB (Default)").tag(512)
                        Text("1 GiB").tag(1024)
                        Text("2 GiB").tag(2048)
                        Text("4 GiB").tag(4096)
                        Text("8 GiB").tag(8192)
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

                Text("Clearing cache safely deletes transient inspection payloads. Raw data, profiles, and database index are never touched.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Snapshots & Exports") {
                if let project = model.project {
                    let snapURL = GlobalPathResolver.snapshotDirectory(projectRoot: project.root)
                    pathRow(
                        label: "Project Snapshots:",
                        path: snapURL.path,
                        url: snapURL,
                        statusText: FileManager.default.fileExists(atPath: snapURL.path) ? "Created" : "Not yet generated",
                        statusColor: .secondary
                    )
                }
                Text("In-memory snapshots are transient. Saved snapshot packages persist under data/snapshot. File exports use standard macOS Save dialogs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Packages Tab

    private var packagesTab: some View {
        Form {
            Section("Lab Instrument Packages") {
                Text("Lab packages provide optional instrument profile definitions shared by the CLI and macOS app. Installing a package never activates or alters filename grammar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let packagesDir = GlobalPathResolver.globalPackagesDirectory()
                pathRow(
                    label: "Packages Location:",
                    path: packagesDir.path,
                    url: packagesDir
                )
            }

            Section("Installed Packages") {
                if installedPackages.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No lab packages installed.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("RawView operates in an honest empty profile state without mandatory built-in profiles. You can add project-local profiles or install an optional package below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(installedPackages) { pkg in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(pkg.displayName)
                                    .font(.headline)
                                Spacer()
                                Text("v\(pkg.version)")
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())

                                Button("Remove") {
                                    removePackage(id: pkg.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if let storage = pkg.storageURL {
                                Text(storage.path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            let conflicts = model.project.map { LabPackageManager.detectProjectConflicts(package: pkg, projectRoot: $0.root) } ?? []
                            if !conflicts.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption2)
                                    Text("Project profiles override package definitions for: \(conflicts.joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }

                            Text("Profiles: \(pkg.profiles.map(\.id).joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Available Optional Packages") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LabPackageManager.usthDisplayName)
                                .font(.headline)
                            Text("Select which instrument profiles to install:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        let isInstalled = LabPackageManager.isUSTHPackageInstalled()
                        Button(isInstalled ? "Reinstall Selected" : "Install Selected") {
                            installUSTHPackage()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(selectedUSTHProfiles.isEmpty)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(BuiltinAssets.builtinProfiles, id: \.id) { prof in
                            let isChecked = selectedUSTHProfiles.contains(prof.id)
                            Toggle(isOn: Binding(
                                get: { isChecked },
                                set: { val in
                                    if val { selectedUSTHProfiles.insert(prof.id) }
                                    else { selectedUSTHProfiles.remove(prof.id) }
                                }
                            )) {
                                Text("\(prof.id) (\(prof.relativePath))")
                                    .font(.caption)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.leading, 4)

                    if let message = packageActionMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if let err = packageErrorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private func refreshInstalledPackages() {
        installedPackages = LabPackageManager.listInstalledPackages()
    }

    private func installUSTHPackage() {
        packageErrorMessage = nil
        do {
            try LabPackageManager.installUSTHLabPackage(selectedProfileIDs: selectedUSTHProfiles)
            packageActionMessage = "USTH Lab Package installed successfully."
            refreshInstalledPackages()
        } catch {
            packageErrorMessage = error.localizedDescription
        }
    }

    private func removePackage(id: String) {
        packageErrorMessage = nil
        do {
            try LabPackageManager.removePackage(id: id)
            packageActionMessage = "Package '\(id)' removed."
            refreshInstalledPackages()
        } catch {
            packageErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Profiles Tab

    private var profilesTab: some View {
        Form {
            Section("Instrument Profiles") {
                Text("Manage instrument profiles recognized for scientific raw data parsing. Disabled profiles are ignored during file inspection and matching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let project = model.project {
                    let settings = (try? ProjectSettingsStore.load(projectRoot: project.root))
                    let profilesConfig = settings?.profiles ?? ProfilesConfig()
                    let discovered = LabPackageManager.listAllDiscoveredProfiles(projectRoot: project.root)

                    if discovered.isEmpty {
                        Text("No instrument profiles found.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(discovered) { prof in
                            let isEnabled = !profilesConfig.disabled.contains(prof.id)
                                && (profilesConfig.enabled == nil || profilesConfig.enabled!.contains(prof.id))
                            profileRow(
                                profile: prof,
                                isEnabled: isEnabled,
                                project: project,
                                settings: settings
                            )
                        }
                    }
                } else {
                    Text("Open a project to view and configure instrument profiles.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func profileRow(
        profile: DiscoveredProfileSummary,
        isEnabled: Bool,
        project: ProjectContext,
        settings: ProjectSettings?
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(profile.name.isEmpty ? profile.id : profile.name)
                        .font(.headline)
                    Text(profile.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(profile.origin)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                if !profile.modes.isEmpty {
                    Text("Modes: \(profile.modes.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Export…") {
                exportProfile(id: profile.id, project: project)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    toggleProfile(id: profile.id, enabled: newValue, project: project, settings: settings)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func exportProfile(id: String, project: ProjectContext) {
        guard let yaml = LabPackageManager.loadProfileYAML(id: id, projectRoot: project.root) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(id).yaml"
        panel.prompt = "Export"
        panel.message = "Export instrument profile YAML"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try yaml.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            packageErrorMessage = "Failed to export profile: \(error.localizedDescription)"
        }
    }

    private func toggleProfile(
        id: String,
        enabled: Bool,
        project: ProjectContext,
        settings: ProjectSettings?
    ) {
        var disabled = settings?.profiles.disabled ?? []
        var enabledList = settings?.profiles.enabled

        if enabled {
            disabled.removeAll { $0 == id }
            if enabledList != nil && !enabledList!.contains(id) {
                enabledList?.append(id)
            }
        } else {
            if !disabled.contains(id) {
                disabled.append(id)
            }
            enabledList?.removeAll { $0 == id }
        }

        let newProfilesConfig = ProfilesConfig(enabled: enabledList, disabled: disabled)
        let updated = ProjectSettings(
            dataRoot: settings?.dataRoot ?? project.dataRootRelativePath,
            defaultView: settings?.defaultView ?? "tree",
            defaultPreset: settings?.defaultPreset ?? "nature-single",
            developerMode: settings?.developerMode ?? false,
            explorerViews: settings?.explorerViews ?? [],
            sourceLabels: settings?.sourceLabels ?? [],
            profiles: newProfilesConfig,
            grammar: settings?.grammar,
            treeGrouping: settings?.treeGrouping
        )
        do {
            try ProjectSettingsStore.save(updated, projectRoot: project.root)
            model.openRecentProject(url: project.root)
        } catch {
            packageErrorMessage = "Failed to save profile setting: \(error.localizedDescription)"
        }
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        Form {
            Section("Interface Theme & Sizing") {
                Picker("Theme:", selection: $appTheme) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)

                Picker("UI Font Family:", selection: $uiFontFamily) {
                    ForEach(AppTypography.FontFamily.allCases) { family in
                        Text(family.label).tag(family.rawValue)
                    }
                }

                HStack {
                    Text("UI Font Size Preset:")
                    Slider(value: $uiFontSize, in: 10...16, step: 1)
                    Text("\(Int(uiFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }

                Text("Applies to app sidebar, inspector, settings, dialogs, and navigation controls. Scientific plot rendering and publication presets remain independently controlled.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Grammar Tab

    private var grammarTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section 1: Active Grammar & Precedence
                VStack(alignment: .leading, spacing: 8) {
                    Text("ACTIVE FILENAME GRAMMAR")
                        .font(AppTypography.sectionHeadline(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        let activeGrammar = model.explorerCatalog?.activeGrammar ?? model.explorerCatalog?.grammars.first
                        if let grammar = activeGrammar {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Color.accentColor)

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(grammar.id)
                                            .font(AppTypography.title(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                                        if let project = model.project {
                                            let localGrammar = project.root.appendingPathComponent(".raw-viewer/grammar.yaml")
                                            let isLocal = FileManager.default.fileExists(atPath: localGrammar.path)
                                            Text(isLocal ? "Project (.raw-viewer/grammar.yaml)" : "Global Built-in")
                                                .font(AppTypography.badge(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                                                .foregroundStyle(isLocal ? Color.green : Color.blue)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(RoundedRectangle(cornerRadius: 4).fill((isLocal ? Color.green : Color.blue).opacity(0.12)))
                                        }
                                    }

                                    if !grammar.description.isEmpty {
                                        Text(grammar.description)
                                            .font(AppTypography.body(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                                            .foregroundStyle(.secondary)
                                    }

                                    Text("Template: \(grammar.template)")
                                        .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                                        .padding(.vertical, 4)
                                        .foregroundStyle(.primary)

                                    // Token pills
                                    HStack(spacing: 6) {
                                        ForEach(grammar.fields) { field in
                                            AppTokenPill(
                                                name: field.name,
                                                isOptional: field.isOptional,
                                                uiFontSize: uiFontSize
                                            )
                                        }
                                    }
                                }
                            }
                        } else {
                            ContentUnavailableView(
                                "No Filename Grammar Configured",
                                systemImage: "character.textbox",
                                description: Text("Add a .raw-viewer/grammar.yaml file to your project to enable token parsing.")
                            )
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                }

                // Section 2: Date Granularity & Grouping
                VStack(alignment: .leading, spacing: 8) {
                    Text("TREE GROUPING & DATE GRANULARITY")
                        .font(AppTypography.sectionHeadline(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Date Grouping Granularity")
                                .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                            Text("Groups timestamp tokens into folders by Year, Month, or Day instead of splitting each file into its own folder.")
                                .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                                .foregroundStyle(.secondary)

                            Picker("", selection: $treeDateGranularity) {
                                ForEach(DateGranularity.allCases) { gran in
                                    Text(gran.label).tag(gran.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 420)
                            .onChange(of: treeDateGranularity) { _, _ in
                                model.updateSourceTree()
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Active Grouping Hierarchy")
                                .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                            Text(model.treeGroupingFields.joined(separator: "  →  "))
                                .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.1)))
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                }

                // Section 3: Interactive Tester Scratchpad
                VStack(alignment: .leading, spacing: 8) {
                    Text("LIVE GRAMMAR TESTER")
                        .font(AppTypography.sectionHeadline(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Test filename token extraction and date normalization in real time:")
                            .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                            .foregroundStyle(.secondary)

                        TextField("Enter filename to test...", text: $grammarTestFilename)
                            .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                            .textFieldStyle(.roundedBorder)

                        if let grammar = model.explorerCatalog?.activeGrammar ?? model.explorerCatalog?.grammars.first {
                            let facts = FilenameGrammarEngine.extract(from: grammarTestFilename, grammar: grammar)
                            if facts.isMatched {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    Text("Matched successfully").font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: uiFontFamily)).foregroundStyle(.green)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(facts.extractedFields.keys.sorted()), id: \.self) { key in
                                        if let val = facts.extractedFields[key] {
                                            HStack(spacing: 8) {
                                                AppTokenPill(name: key, uiFontSize: uiFontSize)
                                                Text("=")
                                                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                                                    .foregroundStyle(.secondary)
                                                Text(val)
                                                    .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                                                    .foregroundStyle(.primary)

                                                if key == "date" || grammar.fields.first(where: { $0.name == key })?.type == .datetime {
                                                    let gran = DateGranularity(rawValue: treeDateGranularity) ?? .day
                                                    let norm = FilenameGrammarEngine.normalizeDate(val, formatHint: grammar.fields.first(where: { $0.name == key })?.formatHint, granularity: gran)
                                                    Text("→ Normalized (\(gran.label)): \(norm)")
                                                        .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                                                        .foregroundStyle(.orange)
                                                }
                                                Spacer()
                                            }
                                        }
                                    }
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                    Text("Not matched: \(facts.unmatchedReason ?? "pattern mismatch")")
                                        .font(AppTypography.body(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                }
            }
            .padding(20)
        }
    }

    // MARK: - Performance Tab

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

    // MARK: - Hotkeys Tab

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

            let categories = ["Navigation", "View", "Export"]
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

    // MARK: - Helpers

    @ViewBuilder
    private func pathRow(
        label: String,
        path: String,
        url: URL,
        statusText: String? = nil,
        statusColor: Color = .secondary
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption.weight(.medium))
                Spacer()
                if let statusText {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
                Button {
                    copyToClipboard(path)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Copy path to clipboard")

                Button {
                    revealInFinder(url)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }

            Text(path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.activateFileViewerSelecting([parent])
            }
        }
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
}
