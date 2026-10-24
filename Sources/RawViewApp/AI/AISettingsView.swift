import SwiftUI
import AppKit

struct AISettingsView: View {
    // MARK: - State

    @ObservedObject private var prefs = Preferences.shared
    @State private var catalog = AIProviderCatalog.shared
    @State private var navigationPath = NavigationPath()
    @State private var modelsFile: RPC.ConfigModelsFileResult?

    // Chat LLM
    @State private var chatProviderId: String
    @State private var chatModel: String
    @State private var reasoningEffort: String

    // MARK: - Init

    init() {
        let prefs = Preferences.shared
        let pid = prefs.aiProviderId
        _chatProviderId = State(initialValue: pid)
        _chatModel = State(initialValue: AIProviderCatalog.shared.resolvedModelId(
            providerId: pid, stored: prefs.aiModel
        ))
        _reasoningEffort = State(initialValue: prefs.thinkingEffort)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                Form {
                    if let error = catalog.backendError {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    providersSection
                    chatSection
                    customModelsSection
                }
                .formStyle(.grouped)
                .frame(maxWidth: 540)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .navigationTitle("LLM & AI Providers")
            .navigationDestination(for: String.self) { providerId in
                AIProviderConfigView(providerId: providerId, onBack: {
                    if !navigationPath.isEmpty {
                        navigationPath.removeLast()
                    }
                })
            }
        }
        .task {
            await catalog.refresh()
            modelsFile = await catalog.modelsFile()
        }
        .onDisappear { save() }
    }

    // MARK: - Providers Section

    @ViewBuilder
    private var providersSection: some View {
        Section("Configured Providers") {
            if catalog.configuredProviders.isEmpty {
                Text("No AI providers connected yet. Add OpenAI Codex (ChatGPT Subscription), Anthropic, or a local provider below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(catalog.configuredProviders) { provider in
                    NavigationLink(value: provider.id) {
                        ProviderRow(provider: provider)
                    }
                }
            }

            Menu {
                if catalog.unconfiguredProviders.isEmpty {
                    Text("All supported providers are already connected.")
                } else {
                    let cloud = catalog.unconfiguredProviders.filter { !$0.isLocal }
                    let local = catalog.unconfiguredProviders.filter { $0.isLocal }

                    if !cloud.isEmpty {
                        Section("Cloud Providers") {
                            ForEach(cloud) { p in
                                Button(p.name) {
                                    navigationPath.append(p.id)
                                }
                            }
                        }
                    }
                    if !local.isEmpty {
                        Section("Local Servers") {
                            ForEach(local) { p in
                                Button(p.name) {
                                    navigationPath.append(p.id)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tint)
                    Text("Add Provider…")
                        .foregroundStyle(.tint)
                }
            }
            .menuStyle(.borderlessButton)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Custom Models Section

    @ViewBuilder
    private var customModelsSection: some View {
        Section("Custom Endpoints & Models") {
            LabeledContent("models.json") {
                Button("Open in Finder / Editor") {
                    Task { @MainActor in
                        if let file = await catalog.modelsFile(create: true) {
                            modelsFile = file
                            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                        }
                    }
                }
            }

            Text("Point a provider at custom proxies, local gateways, or declare extra model variants and reasoning budgets. Changes apply immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = modelsFile?.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Chat Section

    @ViewBuilder
    private var chatSection: some View {
        Section("Default Chat & Analysis Model") {
            if catalog.configuredProviders.isEmpty {
                Text("Connect a provider above to select a default LLM.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $chatProviderId) {
                    ForEach(catalog.configuredProviders) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .onChange(of: chatProviderId) { _, newValue in
                    chatModel = catalog.resolvedModelId(providerId: newValue, stored: "")
                    save()
                }

                if let provider = catalog.provider(for: chatProviderId) {
                    let enabledModels = provider.models.filter { Preferences.shared.isModelEnabled($0.id) }
                    if enabledModels.isEmpty {
                        Text("No models enabled for this provider. Enable models above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $chatModel) {
                            ForEach(enabledModels) { m in
                                Text(m.name).tag(m.id)
                            }
                        }
                        .onChange(of: chatModel) { _, newModel in
                            if let info = catalog.modelInfo(providerId: chatProviderId, modelId: newModel),
                               let supported = info.supportedReasoningEfforts, !supported.isEmpty {
                                if !supported.contains(reasoningEffort) {
                                    reasoningEffort = supported.first ?? "medium"
                                }
                            }
                            save()
                        }
                        .onAppear {
                            if !enabledModels.contains(where: { $0.id == chatModel }) {
                                if let first = enabledModels.first {
                                    chatModel = first.id
                                    save()
                                }
                            }
                        }
                    }
                }

                if let info = catalog.modelInfo(providerId: chatProviderId, modelId: chatModel) {
                    LabeledContent("Context Window", value: formatTokens(info.contextWindow))
                    LabeledContent("Max Output", value: formatTokens(info.maxTokens))
                    LabeledContent("Vision Support", value: info.vision ? "Yes" : "No")
                    LabeledContent("Reasoning Support", value: info.reasoning ? "Yes" : "No")

                    if info.reasoning {
                        let efforts: [String] = {
                            if let supported = info.supportedReasoningEfforts, !supported.isEmpty {
                                return supported
                            }
                            return ["on"]
                        }()

                        Picker("Reasoning Effort", selection: $reasoningEffort) {
                            ForEach(efforts, id: \.self) { effort in
                                Text(effort.capitalized).tag(effort)
                            }
                        }
                        .onChange(of: reasoningEffort) { _, newVal in
                            Preferences.shared.thinkingEffort = newVal
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatTokens(_ count: Int?) -> String {
        guard let count, count > 0 else { return "—" }
        if count >= 1_000_000 { return "\(count / 1_000_000)M tokens" }
        if count >= 1_000 { return "\(count / 1_000)K tokens" }
        return "\(count) tokens"
    }

    private func save() {
        let prefs = Preferences.shared
        prefs.aiProviderId = chatProviderId
        prefs.aiModel = chatModel
        prefs.thinkingEffort = reasoningEffort
    }
}

// MARK: - Provider Row

private struct ProviderRow: View {
    let provider: BackendProviderSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: provider.isLocal ? "desktopcomputer" : (provider.auth.kind == "oauth" ? "person.badge.key" : "cpu"))
                .font(.system(size: 16))
                .frame(width: 26, height: 26)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.body)
                Text(provider.statusSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(provider.needsAttention ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Provider Status Extension

extension BackendProviderSummary {
    var statusLabel: String {
        if id == "opencode-go" { return "Connected" }
        if isLocal { return localUrl ?? "Local server" }
        switch auth.source {
        case "OAuth": return "Signed in"
        case "stored credential": return "API key"
        case "Active", "Connected": return "Connected"
        case .some(let source) where source.hasPrefix("OAuth"): return "Sign in again"
        case .some(let envVar): return "API key from \(envVar)"
        case nil: return auth.configured ? "Connected" : "Not configured"
        }
    }

    var needsAttention: Bool {
        if id == "opencode-go" { return false }
        if isLocal { return false }
        guard let source = auth.source else { return !auth.configured }
        return source.hasPrefix("OAuth") && source != "OAuth"
    }

    var statusSummary: String {
        var parts = [statusLabel]
        if baseUrlOverride?.isEmpty == false { parts.append("custom endpoint") }
        parts.append(models.count == 1 ? "1 model" : "\(models.count) models")
        return parts.joined(separator: " · ")
    }
}
