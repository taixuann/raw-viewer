import AppKit
import SwiftUI
import RawViewCore

/// Right-panel Global AI Assistant Chat for RawViewApp.
/// Direct 1:1 reproduction of OakReader's clean AIChatView:
/// - Minimal header with History drawer toggle [ :≡ ] and New Chat [ 📝 ]
/// - Clean white canvas when empty (no bulky cards or pre-filled action buttons)
/// - Floating rounded composer card with:
///   - Top: Multi-line auto-expanding input
///   - Bottom row: "+" action menu, Model dropdown picker [ Model ⌵ ], and circular Send [ ↑ ]
/// - Dual subprocess execution: OpenCode CLI and Codex CLI
/// - Append-only JSONL session persistence under `.rawviewer/session/<YYYY-MM-DD>/<session-id>.jsonl`
struct AIAssistantPane: View {
    @ObservedObject var model: RawViewModel
    @StateObject private var agent = AIAgentController()
    @ObservedObject private var prefs = Preferences.shared

    @State private var showHistory: Bool = false
    @State private var inputText: String = ""
    @State private var showSlashMenu: Bool = false
    @State private var slashSelectedIndex: Int = 0
    @State private var showMentionMenu: Bool = false
    @State private var mentionSelectedIndex: Int = 0
    @State private var cachedMentionItems: [FileMentionItem] = []
    @State private var filteredMentions: [FileMentionItem] = []

    init(model: RawViewModel) {
        self.model = model
    }

    private var sessionId: UUID {
        get { model.aiChatSessionId }
        nonmutating set { model.aiChatSessionId = newValue }
    }

    private var turns: [ChatTurn] {
        get { model.aiChatTurns }
        nonmutating set { model.aiChatTurns = newValue }
    }

    private var currentModelDisplayName: String {
        let catalog = AIProviderCatalog.shared
        let providerId = Preferences.shared.aiProviderId
        let storedModelId = Preferences.shared.aiModel
        let resolvedId = catalog.resolvedModelId(providerId: providerId, stored: storedModelId)
        if let p = catalog.provider(for: providerId),
           let m = p.models.first(where: { $0.id == resolvedId }) {
            return m.name
        }
        if let first = catalog.configuredProviders.first,
           let m = first.models.first(where: { Preferences.shared.isModelEnabled($0.id) }) {
            return m.name
        }
        return "Select Model"
    }

    private var modelEffortLabel: String {
        if AIProviderCatalog.shared.configuredProviders.isEmpty {
            return "No Provider Connected"
        }
        let effort = Preferences.shared.thinkingEffort
        if effort == "off" || effort == "medium" {
            return currentModelDisplayName
        }
        return "\(currentModelDisplayName) · \(effort.capitalized)"
    }

    private var filteredSlashCommands: [SlashCommandItem] {
        if inputText.hasPrefix("/") {
            let query = String(inputText.dropFirst()).lowercased()
            if query.isEmpty {
                return SlashCommandItem.defaultItems
            }
            return SlashCommandItem.defaultItems.filter {
                $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query)
            }
        }
        return []
    }

    private func rebuildMentionCache() {
        cachedMentionItems = model.sources.map { source in
            FileMentionItem(
                id: source.id,
                name: source.url.lastPathComponent,
                path: source.url.deletingLastPathComponent().lastPathComponent
            )
        }
    }

    private var focusedSource: RawSource? {
        if let id = model.focusedSourceID,
           let match = model.sources.first(where: { $0.id == id }) {
            return match
        }
        if let firstId = model.selectedSourceIDs.first,
           let match = model.sources.first(where: { $0.id == firstId }) {
            return match
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Minimal Header (OakReader style)
            header

            // Main Content: History Drawer or Chat Stream
            Group {
                if showHistory {
                    ChatHistoryDrawer(model: model) { selectedId in
                        loadSession(selectedId)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showHistory = false
                        }
                    }
                    .transition(.opacity)
                } else {
                    chatContent
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showHistory)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            rebuildMentionCache()
        }
        .onChange(of: model.sources.count) { _, _ in
            rebuildMentionCache()
        }
    }

    // MARK: - Header (OakReader style: Left History, Right New Chat)

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showHistory.toggle()
                }
            }) {
                Image(systemName: showHistory ? "xmark" : "list.bullet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showHistory ? "Close History" : "Chat History")

            if showHistory {
                Text("History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button(action: startNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Chat")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Chat Content

    private var chatContent: some View {
        VStack(spacing: 0) {
            if turns.isEmpty {
                // Pure OakReader clean canvas: empty is clean blank space
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(turns) { turn in
                                ChatTurnRow(turn: turn)
                            }
                            Color.clear.frame(height: 1).id("chat-bottom")
                        }
                        .padding(12)
                    }
                    .onChange(of: turns.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                }
            }

            // Floating Autocomplete Popovers
            if showMentionMenu && !filteredMentions.isEmpty {
                FileMentionCompletionMenu(
                    items: filteredMentions,
                    selectedIndex: mentionSelectedIndex,
                    onSelect: selectMention
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if showSlashMenu && !filteredSlashCommands.isEmpty {
                SlashCompletionMenu(
                    items: filteredSlashCommands,
                    selectedIndex: slashSelectedIndex,
                    onSelect: selectSlashCommand
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Floating Composer Card (OakReader style)
            composerCard
        }
    }

    // MARK: - Floating Composer Card

    private var composerCard: some View {
        VStack(spacing: 6) {
            // Text Input Field (Multi-line auto expanding)
            TextField("Ask a question... (type @ to mention a file)", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .onChange(of: inputText) { _, newValue in
                    handleInputChange(newValue)
                }
                .onSubmit {
                    if showMentionMenu && !filteredMentions.isEmpty {
                        selectMention(filteredMentions[mentionSelectedIndex])
                    } else if showSlashMenu && !filteredSlashCommands.isEmpty {
                        selectSlashCommand(filteredSlashCommands[slashSelectedIndex])
                    } else {
                        submitInput()
                    }
                }
                .onKeyPress(.downArrow) {
                    if showMentionMenu && !filteredMentions.isEmpty {
                        mentionSelectedIndex = (mentionSelectedIndex + 1) % filteredMentions.count
                        return .handled
                    }
                    if showSlashMenu && !filteredSlashCommands.isEmpty {
                        slashSelectedIndex = (slashSelectedIndex + 1) % filteredSlashCommands.count
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.upArrow) {
                    if showMentionMenu && !filteredMentions.isEmpty {
                        mentionSelectedIndex = (mentionSelectedIndex - 1 + filteredMentions.count) % filteredMentions.count
                        return .handled
                    }
                    if showSlashMenu && !filteredSlashCommands.isEmpty {
                        slashSelectedIndex = (slashSelectedIndex - 1 + filteredSlashCommands.count) % filteredSlashCommands.count
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.escape) {
                    if showMentionMenu {
                        showMentionMenu = false
                        return .handled
                    }
                    if showSlashMenu {
                        showSlashMenu = false
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.tab) {
                    if showMentionMenu && !filteredMentions.isEmpty {
                        selectMention(filteredMentions[mentionSelectedIndex])
                        return .handled
                    }
                    if showSlashMenu && !filteredSlashCommands.isEmpty {
                        selectSlashCommand(filteredSlashCommands[slashSelectedIndex])
                        return .handled
                    }
                    return .ignored
                }

            // Bottom Controls Row: [+] Button ... [Model ⌵] [Send ↑]
            HStack(spacing: 8) {
                // "+" Button with Action / Skill Menu
                Menu {
                    Section("Scientific Skills") {
                        Button {
                            runQuickCommand("/setup-grammar")
                        } label: {
                            Label("/setup-grammar — Grammar & Labels", systemImage: "text.textalignment.left")
                        }

                        Button {
                            runQuickCommand("/setup-profile")
                        } label: {
                            Label("/setup-profile — Instrument Profile", systemImage: "waveform.path.ecg")
                        }

                        Button {
                            runQuickCommand("/explain")
                        } label: {
                            Label("/explain — Analyze Curve", systemImage: "chart.xyaxis.line")
                        }

                        Button {
                            runQuickCommand("/reindex")
                        } label: {
                            Label("/reindex — Reindex Sources", systemImage: "arrow.clockwise")
                        }
                    }

                    if let selected = focusedSource {
                        Section("Context") {
                            Button {
                                if !inputText.isEmpty && !inputText.hasSuffix(" ") {
                                    inputText += " "
                                }
                                inputText += "@\(selected.url.lastPathComponent) "
                            } label: {
                                Label("Mention @\(selected.url.lastPathComponent)", systemImage: "at")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Add action or mention context")

                Spacer()

                // Model & Reasoning Selection Menu (OakReader style)
                Menu {
                    modelMenuContent
                } label: {
                    HStack(spacing: 4) {
                        Text(modelEffortLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Select AI Model & Reasoning Effort")

                // Send / Stop Button
                if agent.isRunning {
                    Button(action: { agent.stop() }) {
                        ZStack {
                            Circle()
                                .fill(Color.primary)
                                .frame(width: 26, height: 26)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .frame(width: 9, height: 9)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    Button(action: submitInput) {
                        ZStack {
                            Circle()
                                .fill(canSubmit ? Color.primary : Color.gray.opacity(0.3))
                                .frame(width: 26, height: 26)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .help("Send message (↩)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agent.isRunning
    }

    // MARK: - Model & Reasoning Menu

    @ViewBuilder
    private var modelMenuContent: some View {
        if AIProviderCatalog.shared.configuredProviders.isEmpty {
            Text("No Connected Providers")
            Text("Configure providers in Settings (⌘,) to enable AI models.")
                .font(.caption)
        } else {
            reasoningSection
            providersSection
        }
    }

    private var selectedModelSummary: BackendModelSummary? {
        AIProviderCatalog.shared.modelInfo(providerId: prefs.aiProviderId, modelId: prefs.aiModel)
    }

    @ViewBuilder
    private var reasoningSection: some View {
        if let model = selectedModelSummary, model.reasoning {
            let efforts: [String] = {
                if let supported = model.supportedReasoningEfforts, !supported.isEmpty {
                    return ["off"] + supported
                }
                return ["off", "on"]
            }()

            Section("Reasoning Level") {
                ForEach(efforts, id: \.self) { level in
                    Button {
                        prefs.thinkingEffort = level
                    } label: {
                        HStack {
                            Text(level == "off" ? "Off" : level.capitalized)
                            if prefs.thinkingEffort.lowercased() == level.lowercased() {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }

    private var providersSection: some View {
        ForEach(AIProviderCatalog.shared.configuredProviders) { p in
            let models = p.models.filter { Preferences.shared.isModelEnabled($0.id) }
            if !models.isEmpty {
                Section(p.name) {
                    ForEach(models) { m in
                        Button {
                            prefs.aiProviderId = p.id
                            prefs.aiModel = m.id
                        } label: {
                            HStack {
                                Text(m.name)
                                if prefs.aiModel == m.id && prefs.aiProviderId == p.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions & Logic

    private func handleInputChange(_ text: String) {
        if let lastAt = text.lastIndex(of: "@") {
            let sub = text[lastAt...]
            if !sub.contains(" ") {
                let query = String(sub.dropFirst()).lowercased()
                if query.isEmpty {
                    filteredMentions = Array(cachedMentionItems.prefix(8))
                } else {
                    filteredMentions = Array(cachedMentionItems.filter {
                        $0.name.lowercased().contains(query) || $0.path.lowercased().contains(query)
                    }.prefix(8))
                }
                showMentionMenu = !filteredMentions.isEmpty
                mentionSelectedIndex = 0
                showSlashMenu = false
                return
            }
        }
        showMentionMenu = false
        filteredMentions = []

        if text.hasPrefix("/") {
            showSlashMenu = true
            slashSelectedIndex = 0
        } else {
            showSlashMenu = false
        }
    }

    private func selectMention(_ item: FileMentionItem) {
        if let lastAt = inputText.lastIndex(of: "@") {
            let prefix = String(inputText[..<lastAt])
            let rest = inputText[lastAt...]
            let suffix: String
            if let spaceIndex = rest.firstIndex(of: " ") {
                suffix = String(rest[spaceIndex...])
            } else {
                suffix = ""
            }
            inputText = prefix + "@" + item.name + " " + suffix.trimmingCharacters(in: .whitespaces)
        } else {
            inputText += "@" + item.name + " "
        }
        showMentionMenu = false
    }

    private func selectSlashCommand(_ item: SlashCommandItem) {
        inputText = item.name + " "
        showSlashMenu = false
        submitInput()
    }

    private func runQuickCommand(_ cmd: String) {
        inputText = cmd
        submitInput()
    }

    private func submitInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !agent.isRunning else { return }

        inputText = ""
        showSlashMenu = false
        showMentionMenu = false

        var metadata: [String: String] = [:]
        // Only attach source file context if explicitly @mentioned in prompt
        for source in model.sources {
            let fileName = source.url.lastPathComponent
            if trimmed.contains("@\(fileName)") {
                metadata["focused_source_name"] = fileName
                metadata["focused_source_path"] = source.url.path
                break
            }
        }

        let userTurn = ChatTurn(role: "user", content: trimmed, metadata: metadata)
        turns.append(userTurn)
        persistTurn(userTurn)

        dispatchAgentAction(trimmed, metadata: metadata)
    }

    private func startNewChat() {
        sessionId = UUID()
        turns = []
        inputText = ""
        showSlashMenu = false
        showHistory = false
    }

    private func loadSession(_ id: UUID) {
        guard let project = model.project else { return }
        sessionId = id
        let store = SessionStore(projectRoot: project.root)
        Task {
            if let loaded = try? await store.loadTurns(sessionId: id) {
                await MainActor.run {
                    self.turns = loaded
                }
            }
        }
    }

    private func persistTurn(_ turn: ChatTurn) {
        guard let project = model.project else { return }
        let store = SessionStore(projectRoot: project.root)
        let sId = sessionId
        Task {
            try? await store.appendTurn(turn, sessionId: sId)
        }
    }

    private func dispatchAgentAction(_ text: String, metadata: [String: String]) {
        guard let project = model.project else {
            let errorTurn = ChatTurn(role: "assistant", content: "No open project available to execute AI actions.")
            turns.append(errorTurn)
            persistTurn(errorTurn)
            return
        }

        var promptToRun = text
        var toolName = "opencode-chat"

        if text.hasPrefix("/setup-grammar") {
            toolName = "rawview-setup-grammar"
            let sampleFiles = model.sources.prefix(20).map { $0.url.lastPathComponent }
            promptToRun = """
            Use skill rawview-setup-grammar to inspect the project at \(project.root.path).
            Data root: \(project.rawRoot.path)
            Representative filenames from data root:
            \(sampleFiles.joined(separator: "\n"))

            Generate or update .rawviewer/grammar.yaml with schema_version: 1 and matching fields.
            Also configure source_labels in .rawviewer/setting.yaml so Explorer displays clear multi-row labels.
            """
        } else if text.hasPrefix("/setup-profile") {
            toolName = "rawview-setup-profile"
            if let focusedPath = metadata["focused_source_path"] {
                let sourceURL = URL(fileURLWithPath: focusedPath)
                let preview = loadSampleHead(url: sourceURL, lines: 40)
                promptToRun = """
                Use skill rawview-setup-profile to create or update an Instrument Profile for \(sourceURL.lastPathComponent).
                Project root: \(project.root.path)
                Target file path: \(sourceURL.path)

                First 40 lines of file:
                \(preview)

                Generate a strict schema_version: 3 YAML under .rawviewer/instrument/ with proper encoding, delimiter, header_lines, data_start, and channel mappings.
                """
            }
        } else if text.hasPrefix("/explain") {
            toolName = "explain-curve"
            if let focusedPath = metadata["focused_source_path"] {
                let sourceURL = URL(fileURLWithPath: focusedPath)
                let preview = loadSampleHead(url: sourceURL, lines: 30)
                promptToRun = """
                Explain the measurement characteristics of file: \(sourceURL.lastPathComponent).
                Preview:
                \(preview)
                Summarize physical dimensions, observable ranges, and physical interpretation.
                """
            }
        } else if text.hasPrefix("/reindex") {
            Task { @MainActor in
                model.refreshExplorerViews()
                model.reindexAllSources()
                let doneTurn = ChatTurn(role: "assistant", content: "✅ Re-indexing triggered for \(model.sources.count) sources.")
                turns.append(doneTurn)
                persistTurn(doneTurn)
            }
            return
        }

        if let focusedPath = metadata["focused_source_path"], !text.hasPrefix("/") {
            let sourceURL = URL(fileURLWithPath: focusedPath)
            let preview = loadSampleHead(url: sourceURL, lines: 30)
            promptToRun += "\n\n[Context: \(sourceURL.lastPathComponent)]\n\(preview)"
        }

        let runningTurnId = UUID()
        let initialAssistantTurn = ChatTurn(
            id: runningTurnId,
            role: "assistant",
            content: "",
            toolUses: [
                ToolUseRecord(id: UUID().uuidString, name: toolName, status: "running")
            ]
        )
        turns.append(initialAssistantTurn)

        let preferredProviderId = prefs.aiProviderId
        let configured = AIProviderCatalog.shared.configuredProviders
        let effectiveProviderId = configured.isEmpty ? "opencode" : AIProviderCatalog.shared.resolvedProviderId(preferred: preferredProviderId)
        let effectiveModel = AIProviderCatalog.shared.resolvedModelId(
            providerId: effectiveProviderId,
            stored: prefs.aiModel
        )
        let effectiveModelSummary = AIProviderCatalog.shared.modelInfo(
            providerId: effectiveProviderId,
            modelId: effectiveModel
        )
        let isReasoning = effectiveModelSummary?.reasoning ?? false
        let effort = isReasoning ? prefs.thinkingEffort : "off"

        if configured.isEmpty || effectiveProviderId == "opencode" || effectiveProviderId == "opencode-go" {
            dispatchViaAgentController(
                prompt: promptToRun,
                provider: "OpenCode CLI",
                model: effectiveModel,
                reasoningEffort: effort,
                runningTurnId: runningTurnId,
                toolName: toolName
            )
        } else {
            Task {
                await dispatchViaNodeBackend(
                    prompt: promptToRun,
                    providerId: effectiveProviderId,
                    model: effectiveModel,
                    reasoningEffort: effort,
                    runningTurnId: runningTurnId,
                    toolName: toolName
                )
            }
        }
    }

    private func dispatchViaNodeBackend(
        prompt: String,
        providerId: String,
        model: String,
        reasoningEffort: String,
        runningTurnId: UUID,
        toolName: String
    ) async {
        let isRunning = await NodeBackend.shared.ensureRunning()
        guard isRunning else {
            await MainActor.run {
                dispatchViaAgentController(
                    prompt: prompt,
                    provider: "OpenCode CLI",
                    model: model,
                    reasoningEffort: reasoningEffort,
                    runningTurnId: runningTurnId,
                    toolName: toolName
                )
            }
            return
        }

        var historyMessages: [WireMessage] = []
        for t in turns where t.id != runningTurnId {
            if t.role == "user" {
                historyMessages.append(.user(parts: [.text(t.content)]))
            } else if t.role == "assistant" {
                historyMessages.append(.assistant(text: t.content, thinking: nil, toolCalls: []))
            }
        }
        historyMessages.append(.user(parts: [.text(prompt)]))

        let params = RPC.ChatParams(
            providerId: providerId,
            model: model,
            system: "You are an expert scientific data assistant in RawView.",
            messages: historyMessages,
            tools: nil,
            maxTokens: nil,
            reasoning: reasoningEffort == "off" ? nil : reasoningEffort,
            maxIterations: 5
        )

        do {
            for try await event in await NodeBackend.shared.stream(RPC.Method.chat, params: params) {
                if case .notification(let method, let raw) = event {
                    switch method {
                    case RPC.Method.chatDelta:
                        if let delta = try? RPCCoding.decode(RPC.ChatDeltaParams.self, from: raw) {
                            await MainActor.run {
                                if let idx = turns.firstIndex(where: { $0.id == runningTurnId }) {
                                    turns[idx].content += delta.text
                                }
                            }
                        }
                    case RPC.Method.chatAssistant:
                        if let assistant = try? RPCCoding.decode(RPC.ChatAssistantParams.self, from: raw) {
                            await MainActor.run {
                                if let idx = turns.firstIndex(where: { $0.id == runningTurnId }) {
                                    turns[idx].content = assistant.text
                                    turns[idx].toolUses = [ToolUseRecord(id: UUID().uuidString, name: toolName, status: "success")]
                                    persistTurn(turns[idx])

                                    if toolName.contains("grammar") || toolName.contains("profile") {
                                        self.model.refreshExplorerViews()
                                        self.model.reindexAllSources()
                                    }
                                }
                            }
                        }
                    default:
                        break
                    }
                }
            }
        } catch {
            await MainActor.run {
                dispatchViaAgentController(
                    prompt: prompt,
                    provider: "OpenCode CLI",
                    model: model,
                    reasoningEffort: reasoningEffort,
                    runningTurnId: runningTurnId,
                    toolName: toolName
                )
            }
        }
    }

    private func dispatchViaAgentController(
        prompt: String,
        provider: String,
        model: String,
        reasoningEffort: String,
        runningTurnId: UUID,
        toolName: String
    ) {
        guard let project = self.model.project else { return }
        agent.run(
            prompt: prompt,
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
            projectRoot: project.root
        ) { result in
            Task { @MainActor in
                if let idx = turns.firstIndex(where: { $0.id == runningTurnId }) {
                    turns.remove(at: idx)
                }

                let assistantTurn: ChatTurn
                switch result {
                case .success(let output):
                    let toolRecord = ToolUseRecord(id: UUID().uuidString, name: toolName, status: "success", output: output)
                    assistantTurn = ChatTurn(
                        role: "assistant",
                        content: output.isEmpty ? "Operation completed successfully." : output,
                        toolUses: [toolRecord]
                    )

                    // Auto-refresh models/views
                    if toolName.contains("grammar") || toolName.contains("profile") {
                        self.model.refreshExplorerViews()
                        self.model.reindexAllSources()
                    }

                case .failure(let error):
                    let toolRecord = ToolUseRecord(id: UUID().uuidString, name: toolName, status: "failure", output: error.localizedDescription)
                    assistantTurn = ChatTurn(
                        role: "assistant",
                        content: "Error: \(error.localizedDescription)",
                        toolUses: [toolRecord],
                        error: error.localizedDescription
                    )
                }

                turns.append(assistantTurn)
                persistTurn(assistantTurn)
            }
        }
    }

    private func loadSampleHead(url: URL, lines: Int) -> String {
        FilePreviewReader.loadSampleHead(url: url, lines: lines)
    }
}

// MARK: - Chat Turn Bubble Row (OakReader 1:1 Style)

struct ChatTurnRow: View {
    let turn: ChatTurn

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if turn.role == "user" {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(turn.content)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 16,
                                bottomLeadingRadius: 16,
                                bottomTrailingRadius: 4,
                                topTrailingRadius: 16
                            )
                            .fill(Color.primary.opacity(0.06))
                        )

                    if let source = turn.metadata["focused_source_name"] {
                        Text("Source: \(source)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let toolUses = turn.toolUses, !toolUses.isEmpty {
                        ForEach(toolUses) { tool in
                            if tool.status == "running" {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(tool.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                            } else if tool.status == "failure" {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                    Text("Tool failed: \(tool.name)")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                            }
                            // Settled successful tools display zero pill clutter, sitting cleanly on canvas
                        }
                    }

                    if let error = turn.error {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    AIMarkdownView(content: turn.content, isError: turn.error != nil)
                }
                Spacer(minLength: 4)
            }
        }
    }
}
