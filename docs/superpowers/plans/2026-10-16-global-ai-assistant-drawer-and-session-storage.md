# Global AI Assistant Drawer, Native Chat with Slash Commands, and Session Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform RawView's AI integration into a clean macOS-native experience: a global toolbar icon opening a slide-out AI Assistant drawer, full turn-based native chat with `/` slash-command autocomplete, configurable AI models in Settings, and append-only session storage in `.rawviewer/session/<YYYY-MM-DD>/<session-id>.jsonl`.

**Architecture:** 
1. **Window Shell**: Remove `.searchable` from the top-right window toolbar; remove the cramped `Right Panel Mode` segmented control from the Inspector column; add a global `✨` Sparkles toolbar item that toggles a slide-out AI drawer across both Explorer and Editor.
2. **Native Chat & Slash Commands**: Implement a native turn-based conversation surface (`AIChatView`) with chat bubbles, markdown rendering, tool execution chips, and an interactive composer featuring a `/` slash completion popup (listing `/setup-grammar`, `/setup-profile`, `/explain`, `/reindex`).
3. **Session Persistence**: Follow OakReader's proven JSONL `SessionStore` architecture, writing turn-by-turn records to `<project>/.rawviewer/session/<YYYY-MM-DD>/<session-id>.jsonl`.
4. **Settings & Runner**: Add an AI Model section in `SettingsView.swift` allowing provider and model selection (`deepseek-v4.1-flash#max`, `glm-5.3-flash#max`, etc.) via OpenCode/Codex CLI subprocess runner.

**Tech Stack:** Swift, SwiftUI, AppKit, JSONL (Foundation JSONEncoder/Decoder), OpenCode CLI (`/opt/homebrew/bin/opencode`).

---

## Global Constraints

- Respect the plain register: short imperative sentences, active voice.
- Never delete or split existing source files without explicit human authorization.
- Raw scientific data files under project data roots are strictly read-only and immutable.
- Keep session logs inside project `.rawviewer/session/<YYYY-MM-DD>/` as append-only `.jsonl`.
- Verify with `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh` before declaring completion.
- OpenCode model selection adheres to the flat-rate operator allowlist (`deepseek-v4.1-flash#max`, `glm-5.3-flash#max`, `muse-spark-1.3-contributor#xhigh`).

---

## File Structure & Map

- `Sources/RawViewApp/AI/SessionStore.swift`: Actor handling append-only JSONL persistence in `.rawviewer/session/<YYYY-MM-DD>/<session-id>.jsonl`.
- `Sources/RawViewApp/AI/AIChatView.swift`: Native chat surface with turn bubbles, markdown/code rendering, and tool execution status badges.
- `Sources/RawViewApp/AI/SlashCommandCompleter.swift`: Autocomplete popover for `/` slash commands (`/setup-grammar`, `/setup-profile`, `/explain`, `/reindex`).
- `Sources/RawViewApp/Explorer/ExplorerSidebarView.swift`: Remove `.searchable` to clean up the window titlebar.
- `Sources/RawViewApp/SettingsView.swift`: Add AI Model Configuration tab/section (Provider, Model dropdown, CLI connection check).
- `Sources/RawViewApp/RawViewApp.swift`: Add global `✨` toolbar button, remove `RightPaneMode` segmented control from Inspector, mount global slide-out drawer.
- `Tests/RawViewCoreTests/SessionStoreTests.swift`: Unit tests for JSONL append, daily folder routing, and turn decoding.

---

## Implementation Tasks

### Task 1: SessionStore and JSONL Persistence

**Files:** `Sources/RawViewApp/AI/SessionStore.swift`, `Tests/RawViewCoreTests/SessionStoreTests.swift`

- [ ] Write unit tests `testAppendAndLoadTurnsInDailyFolder` and `testCorruptedLineIsSkippedGracefully` asserting turns persist under `.rawviewer/session/<YYYY-MM-DD>/<session-id>.jsonl`.
- [ ] Run `swift test --filter SessionStoreTests` to observe RED.
- [ ] Implement `SessionStore`:
  - `init(projectRoot: URL)`: resolves `.rawviewer/session/<YYYY-MM-DD>/` based on current date.
  - `appendTurn(_ turn: ChatTurn, sessionId: UUID)`: atomically appends a line of JSON followed by `\n`.
  - `loadTurns(sessionId: UUID) -> [ChatTurn]`: parses line-by-line using `JSONDecoder`.
- [ ] Re-run `swift test --filter SessionStoreTests` and ensure PASS.

---

### Task 2: Window Chrome Cleanup & Global Toolbar AI Button

**Files:** `Sources/RawViewApp/Explorer/ExplorerSidebarView.swift`, `Sources/RawViewApp/RawViewApp.swift`

- [ ] In `ExplorerSidebarView.swift`, remove `.searchable(text: $search, prompt: "Find a source or metadata")` to eliminate the search bar in the top-right titlebar.
- [ ] In `RawViewApp.swift`, remove the `RightPaneMode` segmented picker inside `RawViewShell`. Restore `inspector` as a pure, dedicated Inspector pane.
- [ ] In `RawViewModel`, add `@Published var showAIAssistant: Bool = false` and `func toggleAIAssistant() { showAIAssistant.toggle() }`.
- [ ] Add a global ToolbarItem at `.primaryAction` with `Button(action: model.toggleAIAssistant)` displaying `Image(systemName: "sparkles")` with `.keyboardShortcut("i", modifiers: [.command, .option])`.
- [ ] Mount a slide-out overlay or split drawer on the right side of `RawViewShell` that smoothly animates in when `model.showAIAssistant` is true.
- [ ] Run `./Scripts/check_core.sh` to ensure app layer type-check passes.

---

### Task 3: Native Chat UI with Markdown & Slash Autocomplete

**Files:** `Sources/RawViewApp/AI/AIChatView.swift`, `Sources/RawViewApp/AI/SlashCommandCompleter.swift`

- [ ] Create `SlashCommand` model with id, title, description, and icon:
  - `/setup-grammar`: "Auto-infer tokens & sidebar labels via rawview-setup-grammar"
  - `/setup-profile`: "Read raw data & generate Schema v3 profile via rawview-setup-profile"
  - `/explain`: "Analyze focused measurement curve characteristics"
  - `/reindex`: "Re-index project data sources"
- [ ] Implement `SlashCommandCompleter`:
  - Detects when composer input starts with `/` or cursor is after `/`.
  - Presents floating popover with filtered slash commands.
  - Supports keyboard navigation (Up, Down, Enter, Escape).
- [ ] Implement `AIChatView`:
  - ScrollViewReader with auto-scroll to bottom on new tokens.
  - Distinct User bubble and Assistant bubble styling.
  - Collapsible tool execution box showing status (Running/Success/Failed) and output logs.
  - Multi-line input composer integrating `SlashCommandCompleter`.
  - Integrates `SessionStore` to load past turns on open and persist new turns.
- [ ] Run `./Scripts/check_core.sh` to ensure clean type-check.

---

### Task 4: AI Model & Provider Configuration in Settings

**Files:** `Sources/RawViewApp/SettingsView.swift`, `Sources/RawViewCore/Storage/ProjectSettings.swift`

- [ ] Add AI configuration properties to settings schema or app defaults:
  - `ai_provider`: "opencode" | "codex"
  - `ai_model`: default `"opencode-go/deepseek-v4.1-flash#max"`
- [ ] In `SettingsView.swift`, add an **AI Assistant & Models** tab:
  - Provider Picker: OpenCode CLI (default) vs Codex.
  - Model Picker with allowable models (`deepseek-v4.1-flash#max`, `glm-5.3-flash#max`, `muse-spark-1.3-contributor#xhigh`).
  - Binary detection card showing CLI version status (`/opt/homebrew/bin/opencode` detected).
- [ ] Pass the configured model down to `AIAgentController` to format CLI arguments appropriately (`opencode run --auto --model <configured_model>`).
- [ ] Verify settings save and reload without altering existing project settings.

---

### Task 5: End-to-End Verification and Packaging

**Files:** All modified files, `./Scripts/package_app.sh`

- [ ] Run `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh`.
- [ ] Run full `swift test` suite (assert 377+ tests pass).
- [ ] Package app via `./Scripts/package_app.sh`.
- [ ] Launch `/tmp/RawView.app` and verify live:
  - Top-right window titlebar is clean (no search bar).
  - Sparkles icon toggles the slide-out AI Assistant drawer.
  - Inspector remains pure and uncluttered.
  - Typing `/` brings up the slash autocomplete menu.
  - Session turns are written to `.rawviewer/session/<YYYY-MM-DD>/<session-id>.jsonl`.
