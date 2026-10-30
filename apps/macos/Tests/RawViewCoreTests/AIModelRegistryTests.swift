import XCTest
@testable import RawViewCore

final class AIModelRegistryTests: XCTestCase {
    func testDefaultModelsAndFiltering() {
        let suiteName = "test-ai-models-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let registry = AIModelRegistry(userDefaults: defaults)
        let models = registry.loadModels()
        XCTAssertEqual(models.count, 23)
        XCTAssertTrue(models.contains(where: { $0.id == "opencode-go/deepseek-v4.1-flash#max" }))
        XCTAssertTrue(models.contains(where: { $0.id == "gpt-6.1-sol" }))
        XCTAssertTrue(models.contains(where: { $0.id == "o3" }))

        // Enabled models
        let enabled = registry.enabledModels()
        XCTAssertEqual(enabled.count, 13)

        // Filter by provider
        let openCodeModels = registry.enabledModels(forProvider: "OpenCode")
        XCTAssertEqual(openCodeModels.count, 4)

        let codexModels = registry.enabledModels(forProvider: "Codex")
        XCTAssertEqual(codexModels.count, 9)
    }

    func testToggleModel() {
        let suiteName = "test-ai-toggle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let registry = AIModelRegistry(userDefaults: defaults)
        registry.toggleModel(id: "gpt-6.1-sol", isEnabled: false)

        let enabled = registry.enabledModels()
        XCTAssertFalse(enabled.contains(where: { $0.id == "gpt-6.1-sol" }))
        XCTAssertEqual(enabled.count, 12)

        registry.toggleModel(id: "gpt-6.1-sol", isEnabled: true)
        XCTAssertTrue(registry.enabledModels().contains(where: { $0.id == "gpt-6.1-sol" }))
    }

    func testAddAndRemoveCustomModel() {
        let suiteName = "test-ai-custom-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let registry = AIModelRegistry(userDefaults: defaults)
        registry.addCustomModel(id: "custom-local-model", name: "My Local LLM", provider: "OpenCode")

        let models = registry.loadModels()
        XCTAssertEqual(models.count, 24)
        guard let custom = models.first(where: { $0.id == "custom-local-model" }) else {
            XCTFail("Custom model not found")
            return
        }
        XCTAssertEqual(custom.name, "My Local LLM")
        XCTAssertTrue(custom.isCustom)
        XCTAssertTrue(custom.isEnabled)

        // Remove custom model
        registry.removeCustomModel(id: "custom-local-model")
        XCTAssertEqual(registry.loadModels().count, 23)
        XCTAssertNil(registry.loadModels().first(where: { $0.id == "custom-local-model" }))
    }
}
