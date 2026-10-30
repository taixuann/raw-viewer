import Foundation

/// Represents a configurable AI model in RawView.
public struct AIModelConfig: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var provider: String // "OpenCode" or "Codex"
    public var isEnabled: Bool
    public var isCustom: Bool

    public init(id: String, name: String, provider: String, isEnabled: Bool = true, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.provider = provider
        self.isEnabled = isEnabled
        self.isCustom = isCustom
    }
}

/// Registry managing AI models, user visibility toggles, and custom model entries.
/// Mirrors OakReader's preferences and model filtering.
public final class AIModelRegistry: @unchecked Sendable {
    public static let shared = AIModelRegistry()
    private let key = "rawview_ai_models"
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public static let defaultModels: [AIModelConfig] = [
        // OpenCode models
        AIModelConfig(id: "opencode-go/deepseek-v4.1-flash#max", name: "DeepSeek v4.1 Flash Max", provider: "OpenCode", isEnabled: true),
        AIModelConfig(id: "opencode-go/glm-5.3-flash#max", name: "GLM-5.3 Flash Max", provider: "OpenCode", isEnabled: true),
        AIModelConfig(id: "opencode-go/muse-spark-1.3-contributor#xhigh", name: "Muse Spark 1.3 Contributor", provider: "OpenCode", isEnabled: true),
        AIModelConfig(id: "opencode-go/mimo-v2.6-flash", name: "MIMO v2.6 Flash", provider: "OpenCode", isEnabled: true),
        AIModelConfig(id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", provider: "OpenCode", isEnabled: false),
        AIModelConfig(id: "deepseek-r1-0528", name: "DeepSeek R1 0528", provider: "OpenCode", isEnabled: false),
        AIModelConfig(id: "glm-5.3", name: "GLM-5.3 Flagship", provider: "OpenCode", isEnabled: false),
        AIModelConfig(id: "qwen3.7-plus", name: "Qwen 3.7 Plus", provider: "OpenCode", isEnabled: false),
        AIModelConfig(id: "qwen3.6-plus", name: "Qwen 3.6 Plus", provider: "OpenCode", isEnabled: false),
        AIModelConfig(id: "kimi/kimi-k2.5", name: "Kimi k2.5 Agent", provider: "OpenCode", isEnabled: false),
        AIModelConfig(id: "MiniMax/MiniMax-M2.7", name: "MiniMax M2.7", provider: "OpenCode", isEnabled: false),

        // OpenAI Codex Subscription models (chatgpt.com/backend-api)
        AIModelConfig(id: "gpt-6.1-sol", name: "GPT-6.1 Sol (Flagship)", provider: "Codex", isEnabled: true),
        AIModelConfig(id: "gpt-6-astra", name: "GPT-6 Astra", provider: "Codex", isEnabled: true),
        AIModelConfig(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", provider: "Codex", isEnabled: true),
        AIModelConfig(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", provider: "Codex", isEnabled: true),
        AIModelConfig(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", provider: "Codex", isEnabled: true),
        AIModelConfig(id: "gpt-5.5", name: "GPT-5.5", provider: "Codex", isEnabled: true),
        AIModelConfig(id: "gpt-5.4", name: "GPT-5.4", provider: "Codex", isEnabled: true),
        AIModelConfig(id: "gpt-5.4-mini", name: "GPT-5.4 mini", provider: "Codex", isEnabled: false),
        AIModelConfig(id: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark", provider: "Codex", isEnabled: true),
        AIModelConfig(id: "o3", name: "OpenAI o3", provider: "Codex", isEnabled: true),
        AIModelConfig(id: "o3-mini", name: "OpenAI o3-mini", provider: "Codex", isEnabled: false),
        AIModelConfig(id: "o1", name: "OpenAI o1", provider: "Codex", isEnabled: false)
    ]

    public func loadModels() -> [AIModelConfig] {
        guard let data = userDefaults.data(forKey: key),
              let list = try? JSONDecoder().decode([AIModelConfig].self, from: data),
              !list.isEmpty else {
            return Self.defaultModels
        }
        var merged = list
        for def in Self.defaultModels {
            if !merged.contains(where: { $0.id == def.id }) {
                merged.append(def)
            }
        }
        return merged
    }

    public func saveModels(_ models: [AIModelConfig]) {
        if let data = try? JSONEncoder().encode(models) {
            userDefaults.set(data, forKey: key)
        }
    }

    public func enabledModels(forProvider provider: String? = nil) -> [AIModelConfig] {
        let all = loadModels()
        return all.filter { model in
            model.isEnabled && (provider == nil || model.provider.lowercased() == provider?.lowercased())
        }
    }

    public func toggleModel(id: String, isEnabled: Bool) {
        var models = loadModels()
        if let idx = models.firstIndex(where: { $0.id == id }) {
            models[idx].isEnabled = isEnabled
            saveModels(models)
        }
    }

    public func addCustomModel(id: String, name: String, provider: String) {
        var models = loadModels()
        if let idx = models.firstIndex(where: { $0.id == id }) {
            models[idx].name = name
            models[idx].provider = provider
            models[idx].isEnabled = true
        } else {
            models.append(AIModelConfig(id: id, name: name, provider: provider, isEnabled: true, isCustom: true))
        }
        saveModels(models)
    }

    public func removeCustomModel(id: String) {
        var models = loadModels()
        models.removeAll(where: { $0.id == id && $0.isCustom })
        saveModels(models)
    }

    public func resetDefaults() {
        saveModels(Self.defaultModels)
    }
}
