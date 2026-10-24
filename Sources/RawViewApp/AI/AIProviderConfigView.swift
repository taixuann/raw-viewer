import SwiftUI
import AppKit

// MARK: - Provider Config View

struct AIProviderConfigView: View {
    let providerId: String
    var onBack: (() -> Void)? = nil

    var body: some View {
        ProviderDetailView(providerId: providerId, onBack: onBack)
    }
}

// MARK: - OAuth Flow State

private struct OAuthPrompt {
    let id: String
    let type: String
    let message: String
    let placeholder: String?
    let options: [BackendPromptOption]
}

@Observable
private final class OAuthFlowState {
    var isInProgress = false
    var error: String?
    var authURL: URL?
    var deviceCode: (userCode: String, verificationURI: String)?
    var pendingPrompt: OAuthPrompt?
    var promptInput = ""
    var requestId: String?
    var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        task = nil
        isInProgress = false
        error = nil
        authURL = nil
        deviceCode = nil
        pendingPrompt = nil
        promptInput = ""
        requestId = nil
    }
}

// MARK: - Provider Detail View

private struct ProviderDetailView: View {
    let providerId: String
    var onBack: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var catalog = AIProviderCatalog.shared
    @State private var apiKey: String = ""
    @State private var savedKey: String = ""
    @State private var testResult: String?
    @State private var isTesting: Bool = false
    @State private var oauthState = OAuthFlowState()
    @State private var baseURLOverride: String = ""

    // Local providers (Ollama, LM Studio)
    @State private var serverURL: String = ""
    @State private var isDiscovering: Bool = false
    @State private var discoverResult: String?
    @State private var showResetConfirm = false

    private var provider: BackendProviderSummary? {
        catalog.provider(for: providerId)
    }

    private var isConfigured: Bool {
        guard let provider else { return false }
        guard Preferences.shared.isProviderConnected(provider.id) else { return false }
        if provider.isLocal || provider.id == "opencode-go" { return !provider.models.isEmpty }
        if provider.id == "openai-codex" {
            let cacheExists = FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json").path)
            return (provider.auth.configured || cacheExists) && !provider.models.isEmpty
        }
        return provider.auth.configured && !provider.models.isEmpty
    }

    private var isOAuthProvider: Bool {
        provider?.auth.kind == "oauth" || providerId == "openai-codex"
    }

    private var displayTitle: String {
        provider?.name ?? "Provider"
    }

    var body: some View {
        if let provider {
            VStack(spacing: 0) {
                // Impeccable native navigation header
                HStack(spacing: 8) {
                    Button {
                        if let onBack {
                            onBack()
                        } else {
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Providers")
                                .font(.subheadline)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Providers")
                    .keyboardShortcut("[", modifiers: .command)

                    Spacer()

                    if isConfigured {
                        HStack(spacing: 5) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Connected")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.12))
                        .clipShape(Capsule())
                    } else {
                        HStack(spacing: 5) {
                            Circle().fill(.secondary.opacity(0.5)).frame(width: 7, height: 7)
                            Text("Not Connected")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(provider.name)
                                .font(.title2.weight(.bold))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        Form { sections }
                            .formStyle(.grouped)
                            .frame(maxWidth: 540)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
            }
            .navigationBarBackButtonHidden(true)
            .navigationTitle("")
            .onAppear { loadState() }
            .onChange(of: providerId) { _, _ in loadState() }
        } else {
            ContentUnavailableView("Unknown Provider", systemImage: "questionmark.circle")
        }
    }

    @ViewBuilder
    private var sections: some View {
        if let provider {
            if isConfigured {
                configuredProviderContent(provider)
            } else {
                unconfiguredProviderContent(provider)
            }
            if showsSharedActionRow(provider) {
                sharedActionRow(provider)
            }
        }
    }

    private func showsSharedActionRow(_ provider: BackendProviderSummary) -> Bool {
        !provider.isLocal && !isOAuthProvider
    }

    // MARK: - Unconfigured Provider

    @ViewBuilder
    private func unconfiguredProviderContent(_ provider: BackendProviderSummary) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not Connected")
                        .font(.subheadline.weight(.medium))
                    Text("Enter an API key or sign in to verify the connection and fetch available models.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        if provider.isLocal {
            Section("Server") {
                localServerControls(provider, buttonTitle: "Connect")
            }
        } else {
            Section("Authentication") {
                if isOAuthProvider {
                    oauthSection(provider)
                } else {
                    apiKeyAuthSection(provider)
                    if provider.auth.oauthAvailable {
                        oauthSection(provider)
                    }
                }
            }

            if !isOAuthProvider {
                endpointSection(provider)
            }
        }
    }

    // MARK: - Endpoint Override

    @ViewBuilder
    private func endpointSection(_ provider: BackendProviderSummary) -> some View {
        Section("Endpoint") {
            titledField("Base URL") {
                TextField("Base URL", text: $baseURLOverride, prompt: Text("Default endpoint"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .labelsHidden()
            }

            Text("Point at a proxy or relay. Leave empty for default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Local Server Controls

    @ViewBuilder
    private func localServerControls(_ provider: BackendProviderSummary, buttonTitle: String) -> some View {
        titledField("Server URL") {
            TextField("Server URL", text: $serverURL, prompt: Text("Server URL"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .labelsHidden()
        }

        Text("OpenAI-compatible API base, e.g. http://localhost:11434/v1")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            Button(buttonTitle) { discoverAndSave(provider) }
                .disabled(serverURL.isEmpty || isDiscovering)

            if isDiscovering {
                ProgressView().controlSize(.small)
            }

            if let result = discoverResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("Found") ? .green : .red)
            }
        }
    }

    private func discoverAndSave(_ provider: BackendProviderSummary) {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed), base.scheme != nil else {
            discoverResult = "Invalid URL"
            return
        }
        isDiscovering = true
        discoverResult = nil

        Task { @MainActor in
            let error = await catalog.setLocalUrl(trimmed, providerId: provider.id)
            if let error {
                isDiscovering = false
                discoverResult = error
                return
            }
            do {
                let count = try await catalog.connectAndFetchModels(providerId: provider.id, apiKey: nil, baseUrl: trimmed)
                isDiscovering = false
                discoverResult = "Connected! Found \(count) model\(count == 1 ? "" : "s")"
            } catch {
                isDiscovering = false
                discoverResult = error.localizedDescription
            }
        }
    }

    // MARK: - Auth Sections

    @ViewBuilder
    private func apiKeyAuthSection(_ provider: BackendProviderSummary) -> some View {
        titledField("API Key") {
            SecureField("API Key", text: $apiKey, prompt: Text("API Key"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func oauthSection(_ provider: BackendProviderSummary) -> some View {
        if let deviceCode = oauthState.deviceCode {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter this code in your browser to authorize:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(deviceCode.userCode)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .textSelection(.enabled)
                if let url = URL(string: deviceCode.verificationURI) {
                    Link("Open \(deviceCode.verificationURI)", destination: url)
                        .font(.caption)
                }
            }
        } else if !oauthState.isInProgress {
            Button("Sign in with \(provider.name)...") {
                startOAuthLogin(provider)
            }
            .buttonStyle(.borderedProminent)
        }

        if oauthState.isInProgress, let url = oauthState.authURL {
            Link("Open sign-in page in browser", destination: url)
                .font(.caption)
        }

        if oauthState.isInProgress, let prompt = oauthState.pendingPrompt {
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if prompt.options.isEmpty {
                    HStack {
                        TextField(
                            "", text: Bindable(oauthState).promptInput,
                            prompt: prompt.placeholder.map { Text($0) }
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { submitPromptInput() }

                        Button("Submit") { submitPromptInput() }
                            .controlSize(.small)
                            .disabled(oauthState.promptInput.isEmpty)
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(prompt.options) { option in
                            Button(option.label) { answerPrompt(with: option.id) }
                                .controlSize(.regular)
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }

        if oauthState.isInProgress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for authorization...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { oauthState.reset() }
                    .controlSize(.small)
            }
        }

        if let error = oauthState.error {
            HStack(spacing: 6) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("Retry") { startOAuthLogin(provider) }
                    .controlSize(.small)
            }
        }
    }

    private func startOAuthLogin(_ provider: BackendProviderSummary) {
        oauthState.reset()
        oauthState.isInProgress = true

        oauthState.task = Task { @MainActor in
            do {
                for try await streamEvent in await NodeBackend.shared.stream(
                    RPC.Method.oAuthLogin, params: RPC.OAuthLoginParams(providerId: provider.id)
                ) {
                    switch streamEvent {
                    case .notification(let method, let raw):
                        guard method == RPC.Method.oAuthNotify,
                              let p = try? RPCCoding.decode(RPC.OAuthNotifyParams.self, from: raw)
                        else { break }
                        switch p.kind {
                        case "auth_url":
                            if let raw = p.url, let url = URL(string: raw) {
                                oauthState.authURL = url
                                NSWorkspace.shared.open(url)
                            }
                        case "device_code":
                            if let code = p.userCode, let uri = p.verificationUri {
                                oauthState.deviceCode = (code, uri)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                if let url = URL(string: uri) { NSWorkspace.shared.open(url) }
                            }
                        default:
                            break
                        }

                    case .request(let rpcId, let method, let raw):
                        guard method == RPC.Method.oAuthPrompt,
                              let p = try? RPCCoding.decode(RPC.OAuthPromptParams.self, from: raw)
                        else { break }
                        oauthState.pendingPrompt = OAuthPrompt(
                            id: rpcId, type: p.promptType, message: p.message,
                            placeholder: p.placeholder, options: p.options ?? [])
                        oauthState.promptInput = ""
                    }
                }
                oauthState.reset()
                do {
                    _ = try await catalog.connectAndFetchModels(providerId: provider.id, apiKey: nil, baseUrl: nil)
                } catch {
                    oauthState.error = error.localizedDescription
                }
            } catch {
                if !(error is CancellationError) {
                    let message = error.localizedDescription
                    oauthState.reset()
                    oauthState.error = message
                }
            }
        }
    }

    private func submitPromptInput() {
        let value = oauthState.promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        answerPrompt(with: value)
    }

    private func answerPrompt(with value: String) {
        guard let prompt = oauthState.pendingPrompt else { return }
        oauthState.pendingPrompt = nil
        oauthState.promptInput = ""
        Task {
            await NodeBackend.shared.respond(
                to: prompt.id, with: RPC.OAuthPromptResult(value: value))
        }
    }

    // MARK: - Configured Provider

    @ViewBuilder
    private func configuredProviderContent(_ provider: BackendProviderSummary) -> some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(provider.auth.source ?? "Connected")
                }
            }
        }

        if provider.isLocal {
            Section("Server") {
                localServerControls(provider, buttonTitle: "Refresh Models")
            }
        } else if !isOAuthProvider {
            Section("Authentication") {
                apiKeyAuthSection(provider)
            }
        }

        if !provider.isLocal && !isOAuthProvider {
            endpointSection(provider)
        }

        Section("Models (Toggle visibility)") {
            ForEach(provider.models) { model in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(.body)
                        HStack(spacing: 8) {
                            Text("\(formatTokens(model.contextWindow)) ctx")
                            Text("\(formatTokens(model.maxTokens)) out")
                            if model.vision {
                                Text("vision")
                            }
                            if model.reasoning {
                                Text("reasoning")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { Preferences.shared.isModelEnabled(model.id) },
                        set: { enabled in
                            Preferences.shared.setModel(model.id, enabled: enabled)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }

        Section {
            Button("Disconnect / Reset Provider", role: .destructive) {
                showResetConfirm = true
            }
        }
        .confirmationDialog(
            provider.isLocal ? "Remove this provider?" : "Disconnect this provider?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(provider.isLocal ? "Remove" : "Disconnect", role: .destructive) {
                Task { @MainActor in
                    await catalog.disconnectProvider(providerId: provider.id)
                    _ = await catalog.setBaseUrl(nil, providerId: provider.id)
                    apiKey = ""
                    savedKey = ""
                    testResult = nil
                    discoverResult = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(provider.isLocal
                 ? "This removes the local provider configuration."
                 : "Your saved API key and downloaded models for this provider will be removed.")
        }
    }

    // MARK: - Helpers

    private func loadState() {
        apiKey = ""
        savedKey = ""
        testResult = nil
        isTesting = false
        discoverResult = nil
        isDiscovering = false
        oauthState.reset()
        baseURLOverride = provider?.baseUrlOverride ?? ""
        if let provider, provider.isLocal {
            serverURL = provider.localUrl ?? ""
        }
        let pid = providerId
        Task { @MainActor in
            if let key = await AIProviderCatalog.apiKey(for: pid), providerId == pid {
                apiKey = key
                savedKey = key
            }
        }
    }

    private func formatTokens(_ count: Int?) -> String {
        guard let count, count > 0 else { return "—" }
        if count >= 1_000_000 { return "\(count / 1_000_000)M" }
        if count >= 1_000 { return "\(count / 1_000)K" }
        return "\(count)"
    }

    @ViewBuilder
    private func titledField(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        LabeledContent(title) { content() }
    }

    // MARK: - Shared Action Row

    @ViewBuilder
    private func sharedActionRow(_ provider: BackendProviderSummary) -> some View {
        Section {
            HStack(spacing: 8) {
                if isTesting {
                    ProgressView().controlSize(.small)
                }

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("Success") || result.hasPrefix("Saved") || result.hasPrefix("Connected") || result.hasPrefix("Refreshed") ? .green : .red)
                }

                Spacer()

                if isConfigured {
                    Button("Refresh Models") {
                        refreshModels(provider)
                    }
                    .disabled(isTesting)
                }

                Button("Reset to Default") { resetEndpoint(provider) }
                    .disabled(baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                if isConfigured {
                    Button("Save") { saveCredentials(provider) }
                        .buttonStyle(.bordered)
                        .disabled(isSaveDisabled(provider))
                } else {
                    Button("Connect & Fetch Models") {
                        connectAndFetch(provider)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                }
            }
        }
    }

    private func connectAndFetch(_ provider: BackendProviderSummary) {
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedKey.isEmpty else { return }

        isTesting = true
        testResult = nil

        Task { @MainActor in
            do {
                let count = try await catalog.connectAndFetchModels(
                    providerId: provider.id,
                    apiKey: typedKey,
                    baseUrl: typedBase.isEmpty ? nil : typedBase
                )
                savedKey = typedKey
                isTesting = false
                testResult = "Connected! Loaded \(count) models."
            } catch {
                isTesting = false
                testResult = error.localizedDescription
            }
        }
    }

    private func refreshModels(_ provider: BackendProviderSummary) {
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)

        isTesting = true
        testResult = nil

        Task { @MainActor in
            do {
                let count = try await catalog.connectAndFetchModels(
                    providerId: provider.id,
                    apiKey: typedKey.isEmpty ? nil : typedKey,
                    baseUrl: typedBase.isEmpty ? nil : typedBase
                )
                isTesting = false
                testResult = "Refreshed \(count) models."
            } catch {
                isTesting = false
                testResult = error.localizedDescription
            }
        }
    }

    private func isSaveDisabled(_ provider: BackendProviderSummary) -> Bool {
        if isTesting { return true }
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyChanged = typedKey != savedKey
        let baseChanged = typedBase != (provider.baseUrlOverride ?? "")
        return !keyChanged && !baseChanged
    }

    private func saveCredentials(_ provider: BackendProviderSummary) {
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            if !typedKey.isEmpty, typedKey != savedKey {
                if let error = await catalog.setAPIKey(typedKey, providerId: provider.id) {
                    testResult = error
                    return
                }
                savedKey = typedKey
            }
            if let error = await catalog.setBaseUrl(
                typedBase.isEmpty ? nil : typedBase, providerId: provider.id
            ) {
                testResult = error
                return
            }
            testResult = "Saved."
        }
    }

    private func resetEndpoint(_ provider: BackendProviderSummary) {
        Task { @MainActor in
            _ = await catalog.setBaseUrl(nil, providerId: provider.id)
            baseURLOverride = ""
            testResult = "Using default endpoint"
        }
    }
}
