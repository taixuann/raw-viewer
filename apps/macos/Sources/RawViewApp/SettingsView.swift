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
    @State private var grammarTestFilename = ""
    @State private var builderTemplate: String = ""
    @State private var builderGrammarID: String = ""
    @State private var builderGrammarName: String = ""
    @State private var builderFields: [GrammarField] = []
    @State private var grammarActionMessage: String?
    @State private var grammarErrorMessage: String?
    @State private var isCustomizingGrammar: Bool = false
    @State private var cacheClearedMessage: String?
    @State private var packageActionMessage: String?
    @State private var packageErrorMessage: String?
    @State private var installedPackages: [LabPackageSummary] = []
    @State private var selectedUSTHProfiles: Set<String> = Set(BuiltinAssets.builtinProfiles.map(\.id))
    @ObservedObject private var hotkeyManager = HotkeyManager.shared

    enum SettingsTab: String, Identifiable, CaseIterable {
        case project
        case grammar
        case packages
        case profiles
        case appearance
        case plotDefaults
        case performance
        case storage
        case hotkeys

        var id: String { rawValue }

        var label: String {
            switch self {
            case .project: return "Project"
            case .grammar: return "Grammar"
            case .packages: return "Lab Packages"
            case .profiles: return "Profiles"
            case .appearance: return "Appearance"
            case .plotDefaults: return "Plot Defaults"
            case .performance: return "Performance"
            case .storage: return "Storage"
            case .hotkeys: return "Hotkeys"
            }
        }

        var icon: String {
            switch self {
            case .project: return "folder"
            case .grammar: return "character.textbox"
            case .packages: return "shippingbox"
            case .profiles: return "slider.horizontal.3"
            case .appearance: return "paintbrush"
            case .plotDefaults: return "chart.xyaxis.line"
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
                    Section("Workspace & Data") {
                        tabRow(.project)
                        tabRow(.grammar)
                        tabRow(.packages)
                        tabRow(.profiles)
                    }

                    Section("Plot & Appearance") {
                        tabRow(.appearance)
                        tabRow(.plotDefaults)
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
        .frame(minWidth: 840, idealWidth: 900, maxWidth: 1020, minHeight: 540, idealHeight: 600, maxHeight: 720)
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
        case .plotDefaults:
            plotDefaultsTab
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
                            var updated = model.globalPreferences
                            updated.cacheLimitMB = newMB
                            model.saveGlobalPreferences(updated)
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

    // MARK: - Grammar Tab & Builder

    private var grammarTab: some View {
        let activeGrammar = model.explorerCatalog?.activeGrammar ?? model.explorerCatalog?.grammars.first
        let testerGrammar: FilenameGrammar? = isCustomizingGrammar ? draftGrammar : activeGrammar
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                grammarOriginCard
                patternCard(activeGrammar: activeGrammar, testerGrammar: testerGrammar)
                hierarchyCard(testerGrammar: testerGrammar)
            }
            .padding(20)
        }
    }

    /// The template as edited in the builder. The tester and hierarchy use it while editing.
    private var draftGrammar: FilenameGrammar {
        FilenameGrammar(
            id: builderGrammarID.isEmpty ? "draft" : builderGrammarID,
            name: builderGrammarName.isEmpty ? "Draft" : builderGrammarName,
            template: builderTemplate,
            fields: builderFields,
            isDefault: false
        )
    }

    private var grammarOriginCard: some View {
        let origin = FilenameGrammarEngine.detectOrigin(project: model.project)
        let tint: Color = origin == .project ? .green : (origin == .global ? .blue : .secondary)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: origin == .project ? "folder.badge.gearshape" : (origin == .global ? "globe" : "shippingbox"))
                    .font(.system(size: 22))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Active scope")
                            .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                        Text(origin.rawValue)
                            .font(AppTypography.badge(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
                    }
                    Text(origin == .project ? "Using the project grammar in .raw-viewer/grammar.yaml." : (origin == .global ? "Using the global grammar in ~/.config/raw-viewer/grammar.yaml." : "Using the built-in fallback grammar."))
                        .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                HStack(spacing: 8) {
                    if !isCustomizingGrammar {
                        Button("Customize Grammar…") {
                            initBuilderFromActiveGrammar()
                            isCustomizingGrammar = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("Close Builder") {
                            isCustomizingGrammar = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if origin == .project {
                        Button("Reset to Default") {
                            resetProjectGrammar()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if let msg = grammarActionMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                    .foregroundStyle(.green)
            }
            if let err = grammarErrorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    }

    // MARK: Pattern: template, tester, tokens

    private func patternCard(activeGrammar: FilenameGrammar?, testerGrammar: FilenameGrammar?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pattern")
                    .font(AppTypography.sectionHeadline(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                Spacer()
                if isCustomizingGrammar {
                    HStack(spacing: 8) {
                        Button("Save to Project") {
                            saveGrammarToProject()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Save as Global Default") {
                            saveGrammarAsGlobal()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Template")
                    .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                if isCustomizingGrammar {
                    TextField("e.g. {date}_{instrument}.{mode}_[{device-id}]", text: $builderTemplate)
                        .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: builderTemplate) { _, _ in
                            syncBuilderFieldsWithTemplate()
                        }
                    Text("Write each token as {name}. Brackets are literal characters in the filename: _[{device-id}]_ expects square brackets around the value. Opt lets a filename omit a token.")
                        .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                        .foregroundStyle(.secondary)
                } else if let grammar = activeGrammar {
                    Text(grammar.template)
                        .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                        .textSelection(.enabled)
                } else {
                    Text("No filename grammar is active.")
                        .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                        .foregroundStyle(.secondary)
                }
            }

            testerSection(grammar: testerGrammar)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))

            Divider()

            tokensSection(grammar: isCustomizingGrammar ? nil : activeGrammar)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    }

    private func testerSection(grammar: FilenameGrammar?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Test a filename")
                    .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                Spacer()
                if let grammar {
                    Button(isCustomizingGrammar ? "From Template" : "From Active") {
                        grammarTestFilename = synthesizeSampleFilename(for: grammar)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Fill the field with a sample filename built from the template")
                }
            }

            TextField("Paste a filename from the project", text: $grammarTestFilename)
                .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                .textFieldStyle(.roundedBorder)

            if let grammar {
                testerResult(grammar: grammar)
            }
        }
        .onAppear {
            if grammarTestFilename.isEmpty, let grammar {
                grammarTestFilename = synthesizeSampleFilename(for: grammar)
            }
        }
    }

    @ViewBuilder
    private func testerResult(grammar: FilenameGrammar) -> some View {
        let filename = grammarTestFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        if filename.isEmpty {
            Text("Type or paste a filename to see which part of it matches each token.")
                .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                .foregroundStyle(.secondary)
        } else {
            let facts = FilenameGrammarEngine.extract(from: filename, grammar: grammar)
            if facts.isMatched {
                Label("Matched \(facts.extractedFields.count) tokens", systemImage: "checkmark.circle.fill")
                    .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                    .foregroundStyle(.green)

                if let spans = FilenameGrammarEngine.tokenSpans(filename: filename, grammar: grammar) {
                    GrammarTokenSegmentsView(
                        pieces: FilenameGrammarEngine.filenamePieces(filename: filename, spans: spans),
                        fields: grammar.fields,
                        uiFontSize: uiFontSize,
                        fontFamily: uiFontFamily
                    )
                } else {
                    Text("Only the leading tokens matched, so the filename cannot be split into segments.")
                        .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                        .foregroundStyle(.secondary)
                }

                extractedValues(facts: facts, grammar: grammar)
            } else {
                Label("Not matched: \(facts.unmatchedReason ?? "pattern mismatch")", systemImage: "xmark.circle.fill")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                    .foregroundStyle(.red)
            }
        }
    }

    private func extractedValues(facts: ExtractedGrammarFacts, grammar: FilenameGrammar) -> some View {
        let granularity = DateGranularity(rawValue: treeDateGranularity) ?? .day
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(grammar.fields.filter { facts.extractedFields[$0.name] != nil }) { field in
                let value = facts.extractedFields[field.name] ?? ""
                HStack(spacing: 8) {
                    AppTokenPill(field: field, uiFontSize: uiFontSize)
                    Text(value)
                        .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    if field.isVariantKey {
                        Text("Variant")
                            .font(AppTypography.badge(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
                    }
                    if field.type == .datetime || field.name == "date" {
                        let normalized = FilenameGrammarEngine.normalizeDate(value, formatHint: field.formatHint, granularity: granularity)
                        Text("Normalized (\(granularity.label)): \(normalized)")
                            .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                            .foregroundStyle(GrammarTokenFamily.time.tint)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Token list. Read-only chips when not editing; the full token table in the builder.
    private func tokensSection(grammar: FilenameGrammar?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tokens")
                .font(AppTypography.bodySemibold(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
            Text("Variant marks a token as the key that tells measurement variants apart. Facet marks a token as an Explorer filter field. Tree marks a token as a folder level, and saving the grammar uses those marks.")
                .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isCustomizingGrammar {
                tokenTable
            } else if let grammar, !grammar.fields.isEmpty {
                AppFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(grammar.fields) { field in
                        AppTokenPill(field: field, uiFontSize: uiFontSize)
                    }
                }
                .padding(.top, 2)
            } else {
                Text("The active grammar has no tokens.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var tokenTable: some View {
        if builderFields.isEmpty {
            Text("No tokens yet. Add one in curly braces, such as {instrument}, to the template.")
                .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    tableHeader("Token", help: "The name used in the template")
                    tableHeader("Type", help: "How the filename value is read")
                    tableHeader("Format", help: "Optional date or number pattern, such as yyMMdd")
                    tableHeader("Variant", help: "Marks this token as the variant key, such as a mode")
                        .gridColumnAlignment(.center)
                    tableHeader("Opt", help: "The filename may omit this token")
                        .gridColumnAlignment(.center)
                    tableHeader("Facet", help: "Marks this token as an Explorer filter field")
                        .gridColumnAlignment(.center)
                    tableHeader("Tree", help: "Marks this token as a tree level when the grammar is saved")
                        .gridColumnAlignment(.center)
                }

                Divider()
                    .gridCellUnsizedAxes(.horizontal)

                ForEach(builderFields.indices, id: \.self) { idx in
                    tokenConfigRow(idx)
                }
            }
            .padding(.top, 2)
        }
    }

    private func tableHeader(_ title: String, help: String) -> some View {
        Text(title)
            .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily).weight(.semibold))
            .foregroundStyle(.secondary)
            .help(help)
    }

    // MARK: Hierarchy

    private func hierarchyCard(testerGrammar: FilenameGrammar?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hierarchy")
                    .font(AppTypography.sectionHeadline(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                Text("Each level is a folder in the Tree view. A level can hold several tokens, joined with a dot in folder names, such as device-a.mode-b.")
                    .font(AppTypography.helperText(uiFontSize: uiFontSize, fontFamily: uiFontFamily))
                    .foregroundStyle(.secondary)
            }

            TreeHierarchyEditorView(
                grammar: testerGrammar,
                sources: Array(model.sources.prefix(400)),
                selectedFields: $model.treeGroupingFields,
                dateGranularity: $treeDateGranularity,
                uiFontSize: uiFontSize,
                fontFamily: uiFontFamily,
                isCompact: false,
                onChanged: {
                    model.saveTreeGrouping(model.treeGroupingFields)
                    var updated = model.globalPreferences
                    updated.defaultTreeGrouping = model.treeGroupingFields
                    updated.defaultTreeDateGranularity = treeDateGranularity
                    model.saveGlobalPreferences(updated)
                }
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    }

    private func tokenConfigRow(_ idx: Int) -> some View {
        GridRow {
            AppTokenPill(field: builderFields[idx], uiFontSize: uiFontSize)
                .fixedSize(horizontal: true, vertical: false)
                .gridColumnAlignment(.leading)

            Picker("", selection: $builderFields[idx].type) {
                Text("String").tag(GrammarFieldType.string)
                Text("Date/Time").tag(GrammarFieldType.datetime)
                Text("Number").tag(GrammarFieldType.number)
            }
            .labelsHidden()
            .frame(width: 102)
            .controlSize(.small)

            TextField("e.g. DDMMYY-HHmmSS", text: $builderFields[idx].formatHint)
                .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 150, maxWidth: .infinity)

            Toggle("", isOn: $builderFields[idx].isVariantKey)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Variant: marks this token as the variant key")

            Toggle("", isOn: $builderFields[idx].isOptional)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Opt: the filename may omit this token")

            Toggle("", isOn: $builderFields[idx].isFacet)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Facet: marks this token as an Explorer filter field")

            Toggle("", isOn: $builderFields[idx].isGroupingLevel)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Tree: marks this token as a tree level when the grammar is saved")
        }
    }

    /// A sample filename built from the template, for the tester. Values are generic
    /// placeholders, not instrument data.
    private func synthesizeSampleFilename(for grammar: FilenameGrammar) -> String {
        var sample = grammar.template
        for field in grammar.fields {
            let tokenPattern = "{" + field.name + "}"
            let replacement: String
            switch field.type {
            case .datetime:
                replacement = "110526-000000"
            case .number:
                replacement = "001"
            case .string:
                switch field.name.lowercased() {
                case "device", "instrument": replacement = "device-a"
                case "application-mode", "mode", "variant": replacement = "mode-b"
                case "device-id": replacement = "id-1"
                case "library": replacement = "library-c"
                case "study": replacement = "study-d"
                case "remarks": replacement = "note"
                case "flags": replacement = "none"
                default: replacement = field.name
                }
            }
            sample = sample.replacingOccurrences(of: tokenPattern, with: replacement)
        }
        return sample.hasSuffix(".txt") ? sample : "\(sample).txt"
    }

    private func initBuilderFromActiveGrammar() {
        let active = model.explorerCatalog?.activeGrammar ?? model.explorerCatalog?.grammars.first ?? FilenameGrammarCatalog.standardDefaults.first!
        builderGrammarID = active.id
        builderGrammarName = active.name
        builderTemplate = active.template
        builderFields = active.fields
    }

    private func syncBuilderFieldsWithTemplate() {
        let tokenNames = FilenameGrammarEngine.extractTokens(from: builderTemplate)
        var updated: [GrammarField] = []
        for name in tokenNames {
            if let existing = builderFields.first(where: { $0.name == name }) {
                updated.append(existing)
            } else {
                let isDate = name.contains("date") || name.contains("time")
                let isNum = name.contains("batch") || name.contains("index") || name.contains("num")
                let isMode = name == "mode" || name == "application-mode" || name == "variant"
                let isOptional = builderTemplate.contains("[{\(name)}]")
                let type: GrammarFieldType = isDate ? .datetime : (isNum ? .number : .string)
                let hint = isDate ? "DDMMYY-HHmmss" : (isNum ? "001" : "")
                updated.append(GrammarField(
                    name: name,
                    role: name.capitalized,
                    type: type,
                    formatHint: hint,
                    isOptional: isOptional,
                    isFacet: true,
                    isVariantKey: isMode,
                    isGroupingLevel: true
                ))
            }
        }
        builderFields = updated
    }

    private func saveGrammarToProject() {
        guard let project = model.project else {
            grammarErrorMessage = "No project open to save project grammar."
            return
        }
        syncBuilderFieldsWithTemplate()
        let grammar = FilenameGrammar(
            id: builderGrammarID.isEmpty ? "custom-project" : builderGrammarID,
            name: builderGrammarName.isEmpty ? "Project Filename Pattern" : builderGrammarName,
            template: builderTemplate,
            fields: builderFields,
            isDefault: true
        )
        let catalog = FilenameGrammarCatalog(grammars: [grammar], activeGrammarID: grammar.id)
        do {
            try FilenameGrammarEngine.saveToProject(catalog: catalog, project: project)
            syncTreeGroupingFromBuilder()
            model.reloadGrammar()
            grammarActionMessage = "Saved grammar to .raw-viewer/grammar.yaml"
            grammarErrorMessage = nil
        } catch {
            grammarErrorMessage = error.localizedDescription
            grammarActionMessage = nil
        }
    }

    private func saveGrammarAsGlobal() {
        syncBuilderFieldsWithTemplate()
        let grammar = FilenameGrammar(
            id: builderGrammarID.isEmpty ? "custom-global" : builderGrammarID,
            name: builderGrammarName.isEmpty ? "Global Filename Pattern" : builderGrammarName,
            template: builderTemplate,
            fields: builderFields,
            isDefault: true
        )
        let catalog = FilenameGrammarCatalog(grammars: [grammar], activeGrammarID: grammar.id)
        do {
            try FilenameGrammarEngine.saveAsGlobalDefault(catalog: catalog)
            syncTreeGroupingFromBuilder()
            model.reloadGrammar()
            grammarActionMessage = "Saved grammar as global default in ~/.config/raw-viewer/grammar.yaml"
            grammarErrorMessage = nil
        } catch {
            grammarErrorMessage = error.localizedDescription
            grammarActionMessage = nil
        }
    }

    private func syncTreeGroupingFromBuilder() {
        let selected = builderFields.filter(\.isGroupingLevel).map(\.name)
        if !selected.isEmpty {
            model.saveTreeGrouping(selected)
        }
    }

    private func resetProjectGrammar() {
        guard let project = model.project else { return }
        do {
            try FilenameGrammarEngine.resetProjectGrammar(project: project)
            model.reloadGrammar()
            initBuilderFromActiveGrammar()
            grammarActionMessage = "Reverted to global/built-in grammar."
            grammarErrorMessage = nil
        } catch {
            grammarErrorMessage = error.localizedDescription
            grammarActionMessage = nil
        }
    }

    // MARK: - Plot Defaults Tab

    private func globalPrefBinding<Value>(_ keyPath: WritableKeyPath<GlobalPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.globalPreferences[keyPath: keyPath] },
            set: { newValue in
                var updated = model.globalPreferences
                updated[keyPath: keyPath] = newValue
                model.saveGlobalPreferences(updated)
            }
        )
    }

    private var plotDefaultsTab: some View {
        Form {
            Section("Plot Style Defaults") {
                Picker("Default Preset:", selection: globalPrefBinding(\.defaultPresetID)) {
                    ForEach(ScientificPreset.allCases) { preset in
                        Text("\(preset.displayName) (\(preset.publisher))").tag(preset.id)
                    }
                }

                Picker("Color Palette:", selection: globalPrefBinding(\.defaultPaletteID)) {
                    ForEach(ColorPalettePreset.allCases) { palette in
                        Text(palette.displayName).tag(palette.id)
                    }
                }

                Picker("Mark Type:", selection: globalPrefBinding(\.defaultMarkType)) {
                    Text("Line").tag("line")
                    Text("Dots").tag("dots")
                    Text("Both").tag("both")
                }
                .pickerStyle(.segmented)

                Picker("Interpolation:", selection: globalPrefBinding(\.defaultInterpolation)) {
                    Text("Linear").tag("linear")
                    Text("Spline").tag("spline")
                    Text("Step").tag("step")
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Line Width:")
                    Spacer()
                    Text(String(format: "%.1f pt", model.globalPreferences.defaultLineWidth))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper("", value: globalPrefBinding(\.defaultLineWidth), in: 0.2...10.0, step: 0.1)
                        .labelsHidden()
                }

                HStack {
                    Text("Marker Size:")
                    Spacer()
                    Text(String(format: "%.1f pt", model.globalPreferences.defaultMarkerSize))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper("", value: globalPrefBinding(\.defaultMarkerSize), in: 1.0...16.0, step: 0.5)
                        .labelsHidden()
                }

                Toggle("Show Legend by Default", isOn: globalPrefBinding(\.defaultShowLegend))

                HStack {
                    Text("Legend Scale:")
                    Spacer()
                    Text(String(format: "%.2fx", model.globalPreferences.defaultLegendScale))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper("", value: globalPrefBinding(\.defaultLegendScale), in: 0.5...2.0, step: 0.05)
                        .labelsHidden()
                }
            }

            Section("Axes & Padding Defaults") {
                HStack {
                    Text("X Padding:")
                    Spacer()
                    Text(String(format: "%.0f%%", model.globalPreferences.defaultXPaddingPercent))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper("", value: globalPrefBinding(\.defaultXPaddingPercent), in: 0.0...50.0, step: 1.0)
                        .labelsHidden()
                }

                HStack {
                    Text("Y Padding:")
                    Spacer()
                    Text(String(format: "%.0f%%", model.globalPreferences.defaultYPaddingPercent))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper("", value: globalPrefBinding(\.defaultYPaddingPercent), in: 0.0...50.0, step: 1.0)
                        .labelsHidden()
                }

                HStack {
                    Text("X Major Ticks (0 = Auto):")
                    Spacer()
                    Text(model.globalPreferences.defaultXMajorTicks == 0 ? "Auto" : "\(model.globalPreferences.defaultXMajorTicks)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper("", value: globalPrefBinding(\.defaultXMajorTicks), in: 0...20, step: 1)
                        .labelsHidden()
                }

                HStack {
                    Text("Y Major Ticks (0 = Auto):")
                    Spacer()
                    Text(model.globalPreferences.defaultYMajorTicks == 0 ? "Auto" : "\(model.globalPreferences.defaultYMajorTicks)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper("", value: globalPrefBinding(\.defaultYMajorTicks), in: 0...20, step: 1)
                        .labelsHidden()
                }

                HStack {
                    Text("X Minor Ticks:")
                    Spacer()
                    Text("\(model.globalPreferences.defaultXMinorTicks)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper("", value: globalPrefBinding(\.defaultXMinorTicks), in: 0...20, step: 1)
                        .labelsHidden()
                }

                HStack {
                    Text("Y Minor Ticks:")
                    Spacer()
                    Text("\(model.globalPreferences.defaultYMinorTicks)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper("", value: globalPrefBinding(\.defaultYMinorTicks), in: 0...20, step: 1)
                        .labelsHidden()
                }

                Toggle("Show Major Grid", isOn: globalPrefBinding(\.defaultShowMajorGrid))
                Toggle("Show Minor Grid", isOn: globalPrefBinding(\.defaultShowMinorGrid))
                Toggle("Show Zero Line", isOn: globalPrefBinding(\.defaultShowZeroLine))
                Toggle("Show Cursor", isOn: globalPrefBinding(\.defaultShowCursor))
            }

            Section("Export Defaults") {
                Picker("Snapshot DPI:", selection: globalPrefBinding(\.defaultSnapshotDPI)) {
                    Text("150 DPI").tag(150)
                    Text("300 DPI (Default)").tag(300)
                    Text("600 DPI").tag(600)
                }

                Picker("Default Export Format:", selection: globalPrefBinding(\.defaultExportFormat)) {
                    Text("PNG").tag("png")
                    Text("PDF").tag("pdf")
                    Text("SVG").tag("svg")
                }
                .pickerStyle(.segmented)

                TextField("Snapshot Subdirectory:", text: globalPrefBinding(\.defaultSnapshotSubdir))
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Apply to Current Plot") {
                        model.applyGlobalPlotDefaults()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Save Current Plot as Default") {
                        model.saveCurrentPlotAsGlobalDefaults()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Reset to Factory") {
                        model.resetGlobalPreferencesToFactory()
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("Actions")
            } footer: {
                Text("Saved to \(GlobalPathResolver.globalConfigFile().path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
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
                .onChange(of: isLazyInspectionEnabled) { _, newValue in
                    var updated = model.globalPreferences
                    updated.lazyInspectionEnabled = newValue
                    model.saveGlobalPreferences(updated)
                }

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
                .onChange(of: maxComparisonAutoLoad) { _, newValue in
                    var updated = model.globalPreferences
                    updated.maxComparisonAutoLoad = newValue
                    model.saveGlobalPreferences(updated)
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
