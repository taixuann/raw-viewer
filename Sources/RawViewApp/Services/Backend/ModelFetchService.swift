import Foundation

/// Represents a model fetched live from a provider's API.
struct FetchedModel: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    var contextWindow: Int?
    var maxTokens: Int?
    var reasoning: Bool?
    var vision: Bool?
    var supportedReasoningEfforts: [String]?
    var inputModalities: [String]?
}

/// Service that executes live network requests to fetch active models from LLM providers.
actor ModelFetchService {
    static let shared = ModelFetchService()

    private init() {}

    /// Fetches the live list of models directly from the provider's API.
    func fetchModels(providerId: String, apiKey: String?, baseUrl: String? = nil) async throws -> [FetchedModel] {
        switch providerId {
        case "anthropic":
            return try await fetchAnthropicModels(apiKey: apiKey, baseUrl: baseUrl)
        case "google":
            return try await fetchGoogleModels(apiKey: apiKey)
        case "openai-codex":
            return try await fetchCodexModels(baseUrl: baseUrl)
        case "opencode-go":
            let snapshot = ModelFetchService.getOpenCodeGoModelsSnapshot()
            if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                do {
                    return try await fetchOpenAICompatibleModels(providerId: providerId, apiKey: key, baseUrl: baseUrl)
                } catch {
                    return snapshot
                }
            }
            return snapshot
        default:
            return try await fetchOpenAICompatibleModels(providerId: providerId, apiKey: apiKey, baseUrl: baseUrl)
        }
    }

    // MARK: - OpenAI / Compatible Providers

    private func defaultBaseUrl(for providerId: String) -> String {
        switch providerId {
        case "openai": return "https://api.openai.com/v1"
        case "deepseek": return "https://api.deepseek.com"
        case "groq": return "https://api.groq.com/openai/v1"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "mistral": return "https://api.mistral.ai/v1"
        case "together": return "https://api.together.xyz/v1"
        case "fireworks": return "https://api.fireworks.ai/inference/v1"
        case "cerebras": return "https://api.cerebras.ai/v1"
        case "moonshotai", "kimi": return "https://api.moonshot.cn/v1"
        case "minimax": return "https://api.minimax.chat/v1"
        case "opencode-go": return "https://opencode.ai/zen/go/v1"
        case "ollama": return "http://localhost:11434/v1"
        case "lmstudio": return "http://localhost:1234/v1"
        default: return "https://api.openai.com/v1"
        }
    }

    private func fetchOpenAICompatibleModels(providerId: String, apiKey: String?, baseUrl: String?) async throws -> [FetchedModel] {
        let base = (baseUrl?.isEmpty == false ? baseUrl! : defaultBaseUrl(for: providerId)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/models") else {
            throw NSError(domain: "ModelFetchService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid API Base URL: \(base)"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "ModelFetchService", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Provider returned HTTP \(httpResponse.statusCode): \(errorMsg)"])
        }

        struct ResponseData: Decodable {
            struct Item: Decodable {
                let id: String
                let name: String?
                let context_length: Int?
            }
            let data: [Item]?
        }

        let decoded = try JSONDecoder().decode(ResponseData.self, from: data)
        guard let items = decoded.data, !items.isEmpty else {
            throw NSError(domain: "ModelFetchService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No models returned by provider."])
        }

        return items.map { item in
            let isReasoning = item.id.contains("r1") || item.id.contains("reasoner") || item.id.contains("o1") || item.id.contains("o3")
            let hasVision = item.id.contains("vision") || item.id.contains("4o")
            return FetchedModel(
                id: item.id,
                name: item.name ?? item.id,
                contextWindow: item.context_length,
                maxTokens: nil,
                reasoning: isReasoning,
                vision: hasVision,
                supportedReasoningEfforts: nil,
                inputModalities: hasVision ? ["text", "image"] : ["text"]
            )
        }
    }

    // MARK: - Anthropic

    private func fetchAnthropicModels(apiKey: String?, baseUrl: String?) async throws -> [FetchedModel] {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw NSError(domain: "ModelFetchService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Anthropic API Key is required."])
        }

        let base = (baseUrl?.isEmpty == false ? baseUrl! : "https://api.anthropic.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/v1/models") else {
            throw NSError(domain: "ModelFetchService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Anthropic URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "ModelFetchService", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Anthropic API error \(httpResponse.statusCode): \(errorMsg)"])
        }

        struct AnthropicResponse: Decodable {
            struct Item: Decodable {
                let id: String
                let display_name: String?
            }
            let data: [Item]?
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let items = decoded.data, !items.isEmpty else {
            throw NSError(domain: "ModelFetchService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No Anthropic models returned."])
        }

        return items.map { item in
            let isReasoning = item.id.contains("3-7") || item.id.contains("thinking")
            let hasVision = item.id.contains("claude-3") || item.id.contains("claude-3-5") || item.id.contains("claude-3-7")
            return FetchedModel(
                id: item.id,
                name: item.display_name ?? item.id,
                contextWindow: nil,
                maxTokens: nil,
                reasoning: isReasoning,
                vision: hasVision,
                supportedReasoningEfforts: isReasoning ? ["low", "medium", "high", "max"] : nil,
                inputModalities: hasVision ? ["text", "image"] : ["text"]
            )
        }
    }

    // MARK: - Google Gemini

    private func fetchGoogleModels(apiKey: String?) async throws -> [FetchedModel] {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw NSError(domain: "ModelFetchService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Google Gemini API Key is required."])
        }

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)") else {
            throw NSError(domain: "ModelFetchService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Google API URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "ModelFetchService", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Google API error \(httpResponse.statusCode): \(errorMsg)"])
        }

        struct GoogleResponse: Decodable {
            struct Item: Decodable {
                let name: String
                let displayName: String?
                let inputTokenLimit: Int?
                let outputTokenLimit: Int?
                let supportedGenerationMethods: [String]?
            }
            let models: [Item]?
        }

        let decoded = try JSONDecoder().decode(GoogleResponse.self, from: data)
        guard let items = decoded.models, !items.isEmpty else {
            throw NSError(domain: "ModelFetchService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No Gemini models returned."])
        }

        // Filter models that support content generation
        let generateModels = items.filter { item in
            item.supportedGenerationMethods?.contains("generateContent") ?? true
        }

        return generateModels.map { item in
            let cleanId = item.name.hasPrefix("models/") ? String(item.name.dropFirst(7)) : item.name
            let isThinking = cleanId.contains("thinking") || cleanId.contains("2.0-flash-thinking")
            return FetchedModel(
                id: cleanId,
                name: item.displayName ?? cleanId,
                contextWindow: item.inputTokenLimit,
                maxTokens: item.outputTokenLimit,
                reasoning: isThinking,
                vision: true,
                supportedReasoningEfforts: isThinking ? ["low", "medium", "high"] : nil,
                inputModalities: ["text", "image"]
            )
        }
    }

    // MARK: - OpenAI Codex / ChatGPT Subscription

    private func fetchCodexModels(baseUrl: String?) async throws -> [FetchedModel] {
        let models = Self.getCodexModelsSnapshot()
        guard !models.isEmpty else {
            throw NSError(domain: "ModelFetchService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No active OpenAI Codex models found in ~/.codex/models_cache.json."])
        }
        return models
    }

    // MARK: - Model Snapshots & Default Synchronization

    /// Dynamic snapshot of OpenAI Codex / ChatGPT subscription models parsed directly from ~/.codex/models_cache.json.
    static func getCodexModelsSnapshot() -> [FetchedModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheFile = home.appendingPathComponent(".codex/models_cache.json")
        guard FileManager.default.fileExists(atPath: cacheFile.path),
              let data = try? Data(contentsOf: cacheFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsList = json["models"] as? [[String: Any]], !modelsList.isEmpty else {
            return []
        }

        var result: [FetchedModel] = []
        for item in modelsList {
            guard let slug = (item["slug"] as? String) ?? (item["id"] as? String), !slug.isEmpty else { continue }
            if slug == "codex-auto-review" { continue }
            let name = (item["display_name"] as? String) ?? slug
            let ctx = item["context_window"] as? Int
            let maxOut = item["max_output_tokens"] as? Int

            var supportedEfforts: [String]? = nil
            if let levels = item["supported_reasoning_levels"] as? [[String: Any]] {
                let parsed = levels.compactMap { $0["effort"] as? String }
                if !parsed.isEmpty {
                    supportedEfforts = parsed
                }
            } else if let levels = item["supported_reasoning_levels"] as? [String] {
                supportedEfforts = levels
            } else if let levels = item["reasoning_effort_levels"] as? [String] {
                supportedEfforts = levels
            }

            let inputMods = item["input_modalities"] as? [String] ?? []
            let hasVision = inputMods.contains("image")
            let isReasoning = (supportedEfforts != nil && !supportedEfforts!.isEmpty) || slug.contains("o1") || slug.contains("o3") || slug.contains("sol") || slug.contains("astra")

            result.append(FetchedModel(
                id: slug,
                name: name,
                contextWindow: ctx,
                maxTokens: maxOut,
                reasoning: isReasoning,
                vision: hasVision,
                supportedReasoningEfforts: supportedEfforts,
                inputModalities: inputMods.isEmpty ? nil : inputMods
            ))
        }

        if let idx = result.firstIndex(where: { $0.id == "gpt-6.1-sol" }) {
            let flagship = result.remove(at: idx)
            result.insert(flagship, at: 0)
        }
        return result
    }

    /// Dynamic snapshot of OpenCode Go models parsed directly from ~/.cache/opencode/models.json.
    static func getOpenCodeGoModelsSnapshot() -> [FetchedModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheFile = home.appendingPathComponent(".cache/opencode/models.json")
        guard FileManager.default.fileExists(atPath: cacheFile.path),
              let data = try? Data(contentsOf: cacheFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providerObj = json["opencode-go"] as? [String: Any],
              let modelsDict = providerObj["models"] as? [String: [String: Any]], !modelsDict.isEmpty else {
            return []
        }

        var result: [FetchedModel] = []
        for (key, item) in modelsDict {
            let id = "opencode-go/\(key)"
            let name = (item["name"] as? String) ?? key
            let limit = item["limit"] as? [String: Any]
            let ctx = limit?["context"] as? Int
            let maxOut = limit?["output"] as? Int
            let isReasoning = (item["reasoning"] as? Bool) ?? false

            var supportedEfforts: [String]? = nil
            if let options = item["reasoning_options"] as? [[String: Any]] {
                for opt in options {
                    if (opt["type"] as? String) == "effort", let values = opt["values"] as? [String], !values.isEmpty {
                        supportedEfforts = values
                        break
                    }
                }
            }

            let modalities = item["modalities"] as? [String: Any]
            let inputMods = modalities?["input"] as? [String] ?? []
            let hasVision = inputMods.contains("image")

            result.append(FetchedModel(
                id: id,
                name: name,
                contextWindow: ctx,
                maxTokens: maxOut,
                reasoning: isReasoning,
                vision: hasVision,
                supportedReasoningEfforts: supportedEfforts,
                inputModalities: inputMods.isEmpty ? nil : inputMods
            ))
        }

        // Priority sorting: flagship & popular models first
        let priorityPrefixes = ["deepseek", "glm", "muse-spark", "qwen", "mimo", "kimi", "gpt", "grok"]
        result.sort { a, b in
            let aKey = a.id.replacingOccurrences(of: "opencode-go/", with: "")
            let bKey = b.id.replacingOccurrences(of: "opencode-go/", with: "")
            let aPriority = priorityPrefixes.firstIndex(where: { aKey.hasPrefix($0) }) ?? 999
            let bPriority = priorityPrefixes.firstIndex(where: { bKey.hasPrefix($0) }) ?? 999
            if aPriority != bPriority {
                return aPriority < bPriority
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return result
    }

    /// Synchronizes default model definitions for OpenAI Codex and OpenCode Go into ~/.rawviewer/agent/models.json.
    static func syncDefaultModelsFile() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agentDir = home.appendingPathComponent(".rawviewer/agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

        let modelsFile = agentDir.appendingPathComponent("models.json")
        var rootObj: [String: Any] = [:]

        if FileManager.default.fileExists(atPath: modelsFile.path),
           let data = try? Data(contentsOf: modelsFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rootObj = json
        }

        var providers = rootObj["providers"] as? [String: Any] ?? [:]

        // Update openai-codex models
        let codexModels = getCodexModelsSnapshot()
        if !codexModels.isEmpty {
            var codexEntry = providers["openai-codex"] as? [String: Any] ?? [:]
            codexEntry["models"] = codexModels.map { m in
                var dict: [String: Any] = [
                    "id": m.id,
                    "name": m.name,
                    "reasoning": m.reasoning ?? false,
                    "input": m.inputModalities ?? ((m.vision ?? false) ? ["text", "image"] : ["text"])
                ]
                if let ctx = m.contextWindow { dict["contextWindow"] = ctx }
                if let maxOut = m.maxTokens { dict["maxTokens"] = maxOut }
                if let efforts = m.supportedReasoningEfforts { dict["supportedReasoningEfforts"] = efforts }
                return dict
            }
            providers["openai-codex"] = codexEntry
        }

        // Update opencode-go entry
        let goModels = getOpenCodeGoModelsSnapshot()
        if !goModels.isEmpty {
            var goEntry = providers["opencode-go"] as? [String: Any] ?? [:]
            goEntry["name"] = "OpenCode Go"
            goEntry["baseUrl"] = "https://opencode.ai/zen/go/v1"
            goEntry["api"] = "openai-completions"
            goEntry["models"] = goModels.map { m in
                var dict: [String: Any] = [
                    "id": m.id,
                    "name": m.name,
                    "reasoning": m.reasoning ?? false,
                    "input": m.inputModalities ?? ((m.vision ?? false) ? ["text", "image"] : ["text"])
                ]
                if let ctx = m.contextWindow { dict["contextWindow"] = ctx }
                if let maxOut = m.maxTokens { dict["maxTokens"] = maxOut }
                if let efforts = m.supportedReasoningEfforts { dict["supportedReasoningEfforts"] = efforts }
                return dict
            }
            providers["opencode-go"] = goEntry
        }

        rootObj["providers"] = providers

        if let formattedData = try? JSONSerialization.data(withJSONObject: rootObj, options: [.prettyPrinted, .sortedKeys]) {
            try? formattedData.write(to: modelsFile, options: .atomic)
        }
    }

    // MARK: - Persistence into ~/.rawviewer/agent/models.json

    /// Writes the fetched models into ~/.rawviewer/agent/models.json under the provider's entry.
    static func persistFetchedModels(providerId: String, models: [FetchedModel], baseUrl: String? = nil) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agentDir = home.appendingPathComponent(".rawviewer/agent", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

        let modelsFile = agentDir.appendingPathComponent("models.json")
        var rootObj: [String: Any] = [:]

        if FileManager.default.fileExists(atPath: modelsFile.path),
           let data = try? Data(contentsOf: modelsFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rootObj = json
        }

        var providers = rootObj["providers"] as? [String: Any] ?? [:]
        var provEntry = providers[providerId] as? [String: Any] ?? [:]

        if let baseUrl, !baseUrl.isEmpty {
            provEntry["baseUrl"] = baseUrl
        }

        let modelsArray: [[String: Any]] = models.map { m in
            var dict: [String: Any] = [
                "id": m.id,
                "name": m.name,
                "reasoning": m.reasoning ?? false,
                "input": m.inputModalities ?? ((m.vision ?? false) ? ["text", "image"] : ["text"])
            ]
            if let ctx = m.contextWindow { dict["contextWindow"] = ctx }
            if let maxOut = m.maxTokens { dict["maxTokens"] = maxOut }
            if let efforts = m.supportedReasoningEfforts { dict["supportedReasoningEfforts"] = efforts }
            return dict
        }

        provEntry["models"] = modelsArray
        providers[providerId] = provEntry
        rootObj["providers"] = providers

        let formattedData = try JSONSerialization.data(withJSONObject: rootObj, options: [.prettyPrinted, .sortedKeys])
        try formattedData.write(to: modelsFile, options: .atomic)
    }

    /// Removes a provider's models from ~/.rawviewer/agent/models.json.
    static func removeFetchedModels(providerId: String) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let modelsFile = home.appendingPathComponent(".rawviewer/agent/models.json")
        guard FileManager.default.fileExists(atPath: modelsFile.path),
              let data = try? Data(contentsOf: modelsFile),
              var rootObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var providers = rootObj["providers"] as? [String: Any] else {
            return
        }

        providers.removeValue(forKey: providerId)
        rootObj["providers"] = providers

        let formattedData = try JSONSerialization.data(withJSONObject: rootObj, options: [.prettyPrinted, .sortedKeys])
        try formattedData.write(to: modelsFile, options: .atomic)
    }
}
