# OakReader Native Chat and Model Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Overview
Replaces the initial prototype chat pane with a 1:1 reproduction of **OakReader's clean chat interface** (`~/oakreader-src/app/Views/RightPanel/AIChatView.swift`) and introduces a dynamic **AI Model Registry** in Global Settings (`SettingsView.swift`) that allows users to toggle which models are visible in the composer dropdown, add custom models, and seamlessly execute via either **OpenCode CLI** or **Codex CLI**.

---

## File Structure

```
Sources/RawViewCore/
└── Storage/
    ├── AIModelRegistry.swift             # New: Model configuration registry with enable/disable toggles & persistence
    └── SessionStore.swift                # Existing: Session file persistence

Sources/RawViewApp/
├── AI/
    ├── AIAgentController.swift           # New/Extracted: Subprocess execution engine supporting both OpenCode & Codex
    └── SlashCommandCompleter.swift       # Existing: Slash completion items
├── Explorer/
    ├── AIAssistantPane.swift             # Refactor: 1:1 OakReader UI layout (minimal header, clean canvas, floating composer card)
    └── ChatHistoryDrawer.swift           # New: Drawer listing past saved sessions from .rawviewer/session/
└── SettingsView.swift                    # Refactor: Model management UI with toggles, custom model add/delete, engine selection

Tests/RawViewCoreTests/
└── AIModelRegistryTests.swift            # New: Tests for model registry persistence, filtering, and customization
```

---

## Tasks

### Task 1: AI Model Registry & Dynamic Persistence (Core)
- [ ] Create `Sources/RawViewCore/Storage/AIModelRegistry.swift`:
  - `AIModelConfig`: `Identifiable`, `Codable`, `Equatable`, `Hashable`, `Sendable` with properties `id: String`, `name: String`, `provider: String` ("OpenCode" / "Codex"), `isEnabled: Bool`, `isCustom: Bool`.
  - `AIModelRegistry`: Actor / Observable class reading and writing to `UserDefaults.standard` under key `rawview_ai_models`.
  - Default preset models:
    - OpenCode: `opencode-go/deepseek-v4.1-flash#max` ("DeepSeek v4.1 Flash Max"), `opencode-go/glm-5.3-flash#max` ("GLM-5.3 Flash Max"), `opencode-go/muse-spark-1.3-contributor#xhigh` ("Muse Spark 1.3 Contributor").
    - Codex: `gpt-4o` ("GPT-4o"), `o3-mini` ("o3-mini"), `claude-3-7-sonnet` ("Claude 3.7 Sonnet").
  - Methods: `loadModels() -> [AIModelConfig]`, `saveModels(_ models: [AIModelConfig])`, `enabledModels() -> [AIModelConfig]`, `toggleModel(id: String, isEnabled: Bool)`, `addCustomModel(id: String, name: String, provider: String)`, `removeCustomModel(id: String)`, `resetDefaults()`.
- [ ] Create `Tests/RawViewCoreTests/AIModelRegistryTests.swift`:
  - Test default model population.
  - Test toggling model visibility.
  - Test adding custom model and verifying it appears in `enabledModels()`.
  - Test removing custom model.
- [ ] Verify with `swift test --filter AIModelRegistryTests`.

### Task 2: Subprocess Execution Engine (OpenCode CLI & Codex CLI)
- [ ] Create `Sources/RawViewApp/AI/AIAgentController.swift`:
  - `ExecutionEngine`: enum with `.openCode` and `.codex`.
  - Support detection for `/opt/homebrew/bin/opencode` and `/opt/homebrew/bin/codex`.
  - When engine is `.openCode`: run `["run", "--auto", "--model", model, prompt]` with working directory set to project root.
  - When engine is `.codex`: run `["exec", "--cd", projectRoot.path, "-m", model, "--dangerously-bypass-approvals-and-sandbox", prompt]`.
  - Stream stdout and stderr asynchronously via `AsyncStream` / notifications.
  - Update turn state and tool status chips live.
- [ ] Type-check via `./Scripts/check_core.sh`.

### Task 3: OakReader 1:1 Clean Chat UI Redesign (`AIAssistantPane.swift`)
- [ ] Refactor `Sources/RawViewApp/Explorer/AIAssistantPane.swift`:
  - **Header**:
    - Left: Button `[ :≡ ]` (`list.bullet`) toggling `showHistory` with smooth opacity transition.
    - Center: If `showHistory`, text `"History"`. Otherwise clean whitespace.
    - Right: Button `[ 📝 ]` (`square.and.pencil`) with tooltip `"New Chat"`.
    - Eliminate all bulky text headers, green status dots, and close `✕` buttons.
  - **Body**:
    - When `showHistory == true`: render `ChatHistoryDrawer(model: model, onSelectSession: { ... })`.
    - When `turns.isEmpty`: render clean `Spacer()` (OakReader zero-clutter canvas).
    - When `turns` has messages: render message turn list with user bubbles, assistant bubbles, and tool chips.
  - **Floating Composer Card (`inputBar`)**:
    - Container: `RoundedRectangle(cornerRadius: 16)` with subtle border and drop shadow (`radius: 10, y: 3`).
    - Top: Expanding text editor/field with placeholder `"Ask a question..."`.
    - Bottom controls row:
      - Left: `+` button (`Image(systemName: "plus")`) opening menu for:
        - `/setup-grammar` (Filename Grammar & Sidebar Labels)
        - `/setup-profile` (Create Schema v3 Instrument Profile)
        - `/explain` (Analyze Focused Measurement)
        - `/reindex` (Reindex All Sources)
        - Attach Focused Source Path snapshot.
      - `Spacer()`.
      - Right: Model selector dropdown button: `Text("\(currentModelName) ⌵")`.
        - Menu populated strictly by `enabledModels` from `AIModelRegistry`.
        - Changing model updates active model on the fly.
      - Send button: Circular `↑` button (or stop `■` when streaming/running).
- [ ] Implement `Sources/RawViewApp/Explorer/ChatHistoryDrawer.swift`:
  - Scans `.rawviewer/session/` folders, sorts sessions by date descending.
  - Displays session timestamp and preview snippet.
  - Tapping a session loads its turns into `model.aiChatTurns` and switches back to chat view.

### Task 4: Global AI Settings with Model Visibility Editor (`SettingsView.swift`)
- [ ] Refactor `aiTab` in `Sources/RawViewApp/SettingsView.swift`:
  - **Engine Selector**: Toggle between `OpenCode CLI` and `Codex CLI`.
  - **Live Detection**: Status pills for `/opt/homebrew/bin/opencode` and `/opt/homebrew/bin/codex`.
  - **Model Visibility & Custom Models List**:
    - Section "Available Models in Chat":
      - Each model displayed with a `Toggle` (`isOn: isEnabled`) so the user can show/hide any model from the chat composer dropdown.
      - Provider badge (OpenCode / Codex).
    - Section "Add Custom Model":
      - TextFields for `Model ID` and `Display Name`, Engine picker, and "Add Model" button.
    - Button to "Reset Models to Defaults".
- [ ] Verify settings changes instantly reflect in `AIAssistantPane` composer menu.

### Task 5: End-to-End Verification, App Packaging & Review
- [ ] Run `swift test` across all 15 test suites.
- [ ] Run `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh`.
- [ ] Run `./Scripts/package_app.sh` to produce `/tmp/RawView.app`.
- [ ] Launch `/tmp/RawView.app` and verify live:
  - Header is ultra-clean with history `[ :≡ ]` and new chat `[ 📝 ]`.
  - Canvas is clean without clutter cards.
  - Composer card matches OakReader floating design with `+` menu, Model dropdown (`Model ⌵`), and circular send `↑`.
  - Settings allows toggling which models appear in the dropdown and adding custom models.
  - Both OpenCode and Codex execution work as configured.
