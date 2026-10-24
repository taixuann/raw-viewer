# Implementation Plan: Fix Model Visibility Gating, Up-to-Date Codex Models, and @ Mention Chat

## 1. Context & User Requirements
1. **Toggle Visibility Sync**:
   - In Settings -> LLM & AI Models -> Default Chat & Analysis Model, the Model picker must ONLY show models that are currently toggled ON (`Preferences.shared.isModelEnabled(id)`).
   - If a selected model is toggled OFF, fallback to the first enabled model automatically.
2. **Up-to-Date OpenAI Codex / ChatGPT Subscription Models**:
   - Stop showing stale/fictional entries (`GPT-5.3 Codex Spark`, `GPT-5.1 Preview`).
   - Dynamically load actual subscription models from `~/.codex/models_cache.json` if available (`gpt-6.1-sol`, `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `o3-mini`, `o1`, `gpt-4o`, `gpt-4o-mini`).
   - Provide clean up-to-date fallback if cache is absent.
3. **Fix Chat 500 Error & Unified Provider Routing**:
   - Sync `AIAssistantPane` with `Preferences.shared.aiProviderId` and `Preferences.shared.aiModel`.
   - Dispatch to `NodeBackend` for all configured providers in `AIProviderCatalog`.
   - In `AIAgentController`, sanitize model variants so invalid tags like `#medium` are never sent to OpenCode CLI (which caused `UnexpectedStatus: 500`).
4. **Remove Auto-attached Sources & Implement `@` File Mention**:
   - Stop blindly attaching the active tree file (`Source: ...`) to every casual chat message like "hi".
   - Implement `@` mention autocomplete (`FileMentionCompletionMenu`) listing project source files.
   - When user types `@`, show completion menu. Selecting an item inserts `@<filename>`.
   - Only attach source context if the prompt explicitly mentions `@<filename>` or was added via `+` action.

## 2. Affected Files
1. `Sources/RawViewApp/Services/Backend/ModelFetchService.swift`
2. `Sources/RawViewApp/Services/Backend/AIProviderCatalog.swift`
3. `Sources/RawViewApp/AI/AISettingsView.swift`
4. `Sources/RawViewApp/AI/AIAgentController.swift`
5. `Sources/RawViewApp/Explorer/AIAssistantPane.swift`
6. `Sources/RawViewApp/AI/FileMentionCompleter.swift` (new helper)

## 3. Verification Steps
1. `./Scripts/check_core.sh`
2. `./Scripts/check_index_cli.sh`
3. Package and launch `/tmp/RawView.app`
4. Verify Model Picker in Settings only shows enabled models.
5. Verify OpenAI Codex shows up-to-date models.
6. Verify Chat: "hi" does NOT attach any source.
7. Verify typing `@` opens mention autocomplete and selecting a file mentions it.
8. Verify sending chat to connected provider completes without 500 error.
