import Foundation
import Observation

/// App-side mirror of the backend's provider catalog.
/// The backend (`providers/list`) is the single source of truth;
/// this store caches it for synchronous SwiftUI reads and proxies mutations back to the backend.
@MainActor
@Observable
final class AIProviderCatalog {
    static let shared = AIProviderCatalog()

    private(set) var providers: [BackendProviderSummary] = []
    private(set) var isLoading = false
    /// Non-nil when the sidecar can't be reached (e.g. executable missing).
    private(set) var backendError: String?

    private let disabledKey = "rawview_disabled_model_ids"

    private init() {}

    // MARK: - Queries (sync, over the cached snapshot)

    func provider(for id: String) -> BackendProviderSummary? {
        providers.first { $0.id == id }
    }

    var configuredProviders: [BackendProviderSummary] {
        providers.filter { provider in
            guard Preferences.shared.isProviderConnected(provider.id) else { return false }
            if provider.isLocal || provider.id == "opencode-go" { return !provider.models.isEmpty }
            if provider.id == "openai-codex" {
                let cacheExists = FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json").path)
                return (provider.auth.configured || cacheExists) && !provider.models.isEmpty
            }
            return provider.auth.configured && !provider.models.isEmpty
        }
    }

    var unconfiguredProviders: [BackendProviderSummary] {
        providers.filter { provider in
            !configuredProviders.contains(where: { $0.id == provider.id })
        }
    }

    /// All models from configured providers, minus user-disabled ones.
    var availableModels: [(provider: BackendProviderSummary, model: BackendModelSummary)] {
        configuredProviders.flatMap { provider in
            provider.models
                .filter { Preferences.shared.isModelEnabled($0.id) }
                .map { (provider: provider, model: $0) }
        }
    }

    /// The provider chat should actually use: the stored preference when it is
    /// configured, otherwise the first configured provider.
    func resolvedProviderId(preferred: String) -> String {
        if Preferences.shared.isProviderConnected(preferred),
           let p = provider(for: preferred),
           (p.auth.configured || p.isLocal || preferred == "opencode-go" || preferred == "openai-codex"),
           !p.models.isEmpty {
            return preferred
        }
        return configuredProviders.first?.id ?? preferred
    }

    /// Validated model id for a provider: the stored choice when it exists and is enabled,
    /// else the provider's default (if enabled), else the first enabled model, else stored.
    func resolvedModelId(providerId: String, stored: String) -> String {
        guard let info = provider(for: providerId) else { return stored }
        let enabled = info.models.filter { Preferences.shared.isModelEnabled($0.id) }
        if !stored.isEmpty, enabled.contains(where: { $0.id == stored }) { return stored }
        if let def = info.defaultModel, enabled.contains(where: { $0.id == def }) { return def }
        return enabled.first?.id ?? stored
    }

    func modelInfo(providerId: String, modelId: String) -> BackendModelSummary? {
        provider(for: providerId)?.models.first { $0.id == modelId }
    }

    // MARK: - Refresh

    @MainActor
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        // 1. Ensure models.json has up-to-date definitions for codex & opencode-go
        ModelFetchService.syncDefaultModelsFile()

        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.providersList, params: RPC.ProvidersListParams(),
                as: RPC.ProvidersListResult.self)

            var list = result.providers

            // 2. Ensure openai-codex has modern models (gpt-6.1-sol, gpt-6-luna, gpt-6-astra, etc.) first
            let codexModels = ModelFetchService.getCodexModelsSnapshot()
            if let idx = list.firstIndex(where: { $0.id == "openai-codex" }) {
                var p = list[idx]
                var orderedModels: [BackendModelSummary] = []
                for cm in codexModels {
                    if let existing = p.models.first(where: { $0.id == cm.id }) {
                        var updated = existing
                        updated.name = cm.name
                        updated.reasoning = cm.reasoning ?? true
                        updated.contextWindow = cm.contextWindow
                        updated.maxTokens = cm.maxTokens
                        updated.vision = cm.vision ?? false
                        updated.supportedReasoningEfforts = cm.supportedReasoningEfforts
                        updated.inputModalities = cm.inputModalities
                        orderedModels.append(updated)
                    } else {
                        orderedModels.append(BackendModelSummary(
                            id: cm.id,
                            name: cm.name,
                            reasoning: cm.reasoning ?? true,
                            contextWindow: cm.contextWindow,
                            maxTokens: cm.maxTokens,
                            vision: cm.vision ?? false,
                            supportedReasoningEfforts: cm.supportedReasoningEfforts,
                            inputModalities: cm.inputModalities
                        ))
                    }
                }
                for m in p.models {
                    if !orderedModels.contains(where: { $0.id == m.id }) {
                        orderedModels.append(m)
                    }
                }
                p.models = orderedModels
                list[idx] = p
            }

            // 3. Ensure opencode-go is present in providers list
            let goModels = ModelFetchService.getOpenCodeGoModelsSnapshot()
            let goSummaries = goModels.map {
                BackendModelSummary(
                    id: $0.id,
                    name: $0.name,
                    reasoning: $0.reasoning ?? true,
                    contextWindow: $0.contextWindow,
                    maxTokens: $0.maxTokens,
                    vision: $0.vision ?? false,
                    supportedReasoningEfforts: $0.supportedReasoningEfforts,
                    inputModalities: $0.inputModalities
                )
            }
            if !goModels.isEmpty {
                if let idx = list.firstIndex(where: { $0.id == "opencode-go" }) {
                    var p = list[idx]
                    p.models = goSummaries
                    p.name = "OpenCode Go"
                    p.auth = BackendProviderAuth(kind: "none", oauthAvailable: false, configured: true, source: "Active")
                    list[idx] = p
                } else {
                    let goProvider = BackendProviderSummary(
                        id: "opencode-go",
                        name: "OpenCode Go",
                        models: goSummaries,
                        defaultModel: nil,
                        auth: BackendProviderAuth(kind: "none", oauthAvailable: false, configured: true, source: "Active (Dynamic)"),
                        isLocal: false,
                        custom: true,
                        baseUrlOverride: nil,
                        localUrl: nil
                    )
                    list.append(goProvider)
                }
            }

            // 4. Default connect openai-codex & opencode-go if available
            let codexCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
            if FileManager.default.fileExists(atPath: codexCache.path) && !codexModels.isEmpty && !Preferences.shared.connectedProviderIds.contains("openai-codex") {
                Preferences.shared.setProviderConnected("openai-codex", connected: true)
            }
            if !Preferences.shared.connectedProviderIds.contains("opencode-go") {
                Preferences.shared.setProviderConnected("opencode-go", connected: true)
            }

            providers = list
            backendError = nil
        } catch {
            backendError = error.localizedDescription
        }
    }

    // MARK: - Mutations (proxy to backend, then refresh)

    @discardableResult
    @MainActor
    private func mutate<P: Encodable>(_ method: String, _ params: P) async -> String? {
        do {
            try await NodeBackend.shared.call(method, params: params)
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns an error message, or nil on success.
    @MainActor
    func setAPIKey(_ key: String, providerId: String) async -> String? {
        await mutate(RPC.Method.credentialsSet,
                     RPC.CredentialsSetParams(providerId: providerId, key: key))
    }

    @MainActor
    func connectAndFetchModels(providerId: String, apiKey: String?, baseUrl: String? = nil) async throws -> Int {
        // 1. Fetch live models from provider API
        let fetched = try await ModelFetchService.shared.fetchModels(
            providerId: providerId,
            apiKey: apiKey,
            baseUrl: baseUrl
        )
        guard !fetched.isEmpty else {
            throw NSError(domain: "AIProviderCatalog", code: 404, userInfo: [NSLocalizedDescriptionKey: "No models returned by provider."])
        }

        // 2. Persist fetched models into ~/.rawviewer/agent/models.json
        try ModelFetchService.persistFetchedModels(providerId: providerId, models: fetched, baseUrl: baseUrl)

        // 3. Persist API Key in backend credentials if provided
        if let key = apiKey, !key.isEmpty {
            _ = await mutate(RPC.Method.credentialsSet,
                             RPC.CredentialsSetParams(providerId: providerId, key: key))
        }

        // 4. Mark provider as connected in user preferences
        Preferences.shared.setProviderConnected(providerId, connected: true)

        // 5. Refresh sidecar provider/model snapshot
        await refresh()

        return fetched.count
    }

    @MainActor
    func disconnectProvider(providerId: String) async {
        Preferences.shared.setProviderConnected(providerId, connected: false)
        try? ModelFetchService.removeFetchedModels(providerId: providerId)
        _ = await deleteCredential(providerId: providerId)
        _ = await setBaseUrl(nil, providerId: providerId)
        await refresh()
    }

    @MainActor
    func deleteCredential(providerId: String) async -> String? {
        Preferences.shared.setProviderConnected(providerId, connected: false)
        try? ModelFetchService.removeFetchedModels(providerId: providerId)
        return await mutate(RPC.Method.credentialsDelete,
                            RPC.CredentialsDeleteParams(providerId: providerId))
    }

    /// Empty/nil clears the override.
    @MainActor
    func setBaseUrl(_ baseUrl: String?, providerId: String) async -> String? {
        await mutate(RPC.Method.configSetBaseUrl,
                     RPC.ConfigSetBaseUrlParams(providerId: providerId, baseUrl: baseUrl))
    }

    @MainActor
    func setLocalUrl(_ baseUrl: String, providerId: String) async -> String? {
        if let error = await mutate(RPC.Method.configSetLocalUrl,
                                    RPC.ConfigSetLocalUrlParams(providerId: providerId, baseUrl: baseUrl)) {
            return error
        }
        return await refreshModels(providerId: providerId)
    }

    @MainActor
    func refreshModels(providerId: String? = nil) async -> String? {
        await mutate(RPC.Method.modelsRefresh,
                     RPC.ModelsRefreshParams(providerId: providerId))
    }

    /// Where the user's `models.json` lives, and why its last load fell short.
    /// Pass `create` to have the sidecar write a commented template first.
    @MainActor
    func modelsFile(create: Bool = false) async -> RPC.ConfigModelsFileResult? {
        try? await NodeBackend.shared.call(
            RPC.Method.configModelsFile, params: RPC.ConfigModelsFileParams(create: create),
            as: RPC.ConfigModelsFileResult.self)
    }

    /// Raw stored/resolved API key.
    static func apiKey(for providerId: String) async -> String? {
        let result = try? await NodeBackend.shared.call(
            RPC.Method.credentialsGet, params: RPC.CredentialsGetParams(providerId: providerId),
            as: RPC.CredentialsGetResult.self)
        return result?.apiKey
    }
}
