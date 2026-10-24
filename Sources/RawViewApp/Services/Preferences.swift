import Foundation
import Combine

/// Central user preferences for AI providers, models, and UI defaults.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let aiProvider = "rawview_ai_provider_id"
        static let aiModel = "rawview_ai_model"
        static let disabledModelIds = "rawview_disabled_model_ids"
        static let thinkingEffort = "rawview_thinking_effort"
        static let connectedProviderIds = "rawview_connected_provider_ids"
    }

    var aiProviderId: String {
        get { defaults.string(forKey: Keys.aiProvider) ?? "openai-codex" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.aiProvider)
        }
    }

    var aiModel: String {
        get { defaults.string(forKey: Keys.aiModel) ?? "" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.aiModel)
        }
    }

    var thinkingEffort: String {
        get { defaults.string(forKey: Keys.thinkingEffort) ?? "medium" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.thinkingEffort)
        }
    }

    var disabledModelIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.disabledModelIds) ?? []) }
        set {
            objectWillChange.send()
            defaults.set(Array(newValue), forKey: Keys.disabledModelIds)
        }
    }

    var connectedProviderIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.connectedProviderIds) ?? []) }
        set {
            objectWillChange.send()
            defaults.set(Array(newValue), forKey: Keys.connectedProviderIds)
        }
    }

    func isProviderConnected(_ providerId: String) -> Bool {
        if providerId == "opencode-go" { return true }
        if providerId == "openai-codex" {
            let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
            if FileManager.default.fileExists(atPath: cache.path) { return true }
        }
        return connectedProviderIds.contains(providerId)
    }

    func setProviderConnected(_ providerId: String, connected: Bool) {
        var ids = connectedProviderIds
        if connected {
            ids.insert(providerId)
        } else {
            ids.remove(providerId)
        }
        connectedProviderIds = ids
    }

    func isModelEnabled(_ modelId: String) -> Bool {
        !disabledModelIds.contains(modelId)
    }

    func setModel(_ modelId: String, enabled: Bool) {
        var disabled = disabledModelIds
        if enabled {
            disabled.remove(modelId)
        } else {
            disabled.insert(modelId)
        }
        disabledModelIds = disabled
    }

    func apiKey(for providerId: String) -> String? {
        defaults.string(forKey: "rawview_api_key_\(providerId)")
    }

    func setAPIKey(_ key: String?, for providerId: String) {
        if let key = key, !key.isEmpty {
            defaults.set(key, forKey: "rawview_api_key_\(providerId)")
        } else {
            defaults.removeObject(forKey: "rawview_api_key_\(providerId)")
        }
    }
}
