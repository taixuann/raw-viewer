# Fast File Mention, OakReader Chat UI, and Live Model Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 
1. Fix missing models by synchronizing OpenAI Codex OAuth models (`gpt-6.1-sol`, `gpt-6-luna`, `gpt-6-astra`, `gpt-6-sol`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`) directly from `~/.codex/models_cache.json` and registering `opencode-go` provider with allowlist models into `~/.rawviewer/agent/models.json` and `AIProviderCatalog.swift`.
2. Eliminate file mention latency via memoized metadata caching and 16KB zero-copy FileHandle I/O.
3. Upgrade AI chat UI to replicate OakReader 1:1 (borderless assistant canvas on Color.clear, subtle uneven-rounded user bubbles, removal of raw `(success)` badges, and ChatComposerStyle 16pt/0.10 opacity borders).

**Architecture:** 
1. **Model Discovery & Catalog:** Sync `~/.rawviewer/agent/models.json` automatically on catalog refresh or startup. Parse `~/.codex/models_cache.json` (created by OpenAI Codex subscription OAuth) to dynamically expose `gpt-6.1-sol` (Flagship), `gpt-6-luna`, `gpt-6-astra`, `gpt-6-sol`, `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`. Expose `opencode-go` provider with operator allowlist routes (`muse-spark-1.3-contributor`, `deepseek-v4.1-flash`, `glm-5.3-flash`, `mimo-v2.6-flash`).
2. **Zero-Copy File Preview:** Replace full-file `Data(contentsOf: url)` with `FileHandle.read(upToCount: 16384)` for constant-time (<0.1ms) header extraction.
3. **Memoized Mention Autocomplete:** Cache `[FileMentionItem]` once when sources load/change and maintain an actively filtered `@State private var filteredMentions` updated solely during input changes, removing all repeated O(N) URL operations from SwiftUI render passes.
4. **OakReader 1:1 Chat Styling:** Match OakReader's `ChatBubbleView`: borderless transparent assistant responses, subtle `Color.primary.opacity(0.06)` user bubbles with `UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16)`, eliminate `(success)` pill clutter, and style composer with `ChatComposerStyle` (16pt radius, 0.10 border opacity).

**Tech Stack:** Swift 5.9, SwiftUI, Foundation (`FileHandle`), AppKit, RawViewCore.

---

## Global Constraints

- Storage Invariant: Writable index stays at `<project>/.rawviewer/index.db`; sessions stay at `<project>/.rawviewer/session/<YYYY-MM-DD>/<session-id>.jsonl`; agent models stay at `~/.rawviewer/agent/models.json`. Raw scientific data files remain strictly read-only and untouched.
- Performance Invariant: All keystrokes in the composer must execute in O(1) time without blocking the Main Thread. File preview extraction must never load entire multi-megabyte files into memory.
- UI Style Invariant: Clean canvas presentation mirroring OakReader: zero borders/backgrounds on assistant text, subtle grey user bubbles with uneven corners, borderless tool states.
- Verification Invariant: Must pass `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh` with zero warnings or regressions.

---

### Task 1: Live Codex OAuth Models and OpenCode-Go Provider Synchronization

**Files:**
- Modify: `Sources/RawViewApp/Services/Backend/ModelFetchService.swift`
- Modify: `Sources/RawViewApp/Services/Backend/AIProviderCatalog.swift`
- Test: `Tests/RawViewCoreTests/AIModelRegistryTests.swift`

**Interfaces:**
- Consumes: `~/.codex/models_cache.json`, `~/.rawviewer/agent/models.json`
- Produces: Updated `AIProviderCatalog.providers` containing `gpt-6.1-sol`, `gpt-6-luna`, `gpt-6-astra`, `gpt-5.6-sol`, and `opencode-go` provider with allowlist models.

- [ ] **Step 1: Update `ModelFetchService.swift` to ensure live Codex and OpenCode-Go models are defined**
  - In `fetchCodexModels`: check `~/.codex/models_cache.json` and fallback to modern models: `gpt-6.1-sol`, `gpt-6-luna`, `gpt-6-astra`, `gpt-6-sol`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`.
  - Add helper `syncDefaultModelsFile()` to populate/update `~/.rawviewer/agent/models.json` with `openai-codex` and `opencode-go` entries.

- [ ] **Step 2: Update `AIProviderCatalog.swift` to merge live models and register `opencode-go`**
  - In `refresh()`: call `ModelFetchService.syncDefaultModelsFile()` before or after `providers/list`.
  - Merge the dynamic models for `openai-codex` so `gpt-6.1-sol` and `gpt-6-luna` are present in `provider.models`.
  - If `opencode-go` is not yet returned by backend, inject it into `providers` using its allowlist models so it is visible and configurable in Settings.

- [ ] **Step 3: Verify build and tests pass**
  Run `./Scripts/check_core.sh`

---

### Task 2: Zero-Copy File Preview Extraction (16KB FileHandle)

**Files:**
- Modify: `Sources/RawViewApp/Explorer/AIAssistantPane.swift`
- Test: `Tests/RawViewCoreTests/FilePreviewPerformanceTests.swift`

- [ ] **Step 1: Write unit test for bounded 16KB file reading**
- [ ] **Step 2: Run test to verify behavior**
- [ ] **Step 3: Update `loadSampleHead` in `AIAssistantPane.swift` to use `FileHandle` reading up to 16,384 bytes**
- [ ] **Step 4: Verify test passes and core checks pass**

---

### Task 3: Memoized Mention Cache and Fast Keystroke Filtering

**Files:**
- Modify: `Sources/RawViewApp/Explorer/AIAssistantPane.swift`

- [ ] **Step 1: Add `@State private var cachedMentionItems: [FileMentionItem] = []` and `@State private var filteredMentions: [FileMentionItem] = []`**
- [ ] **Step 2: Implement `rebuildMentionCache()` on `.onAppear` and `.onChange(of: model.sources.count)`**
- [ ] **Step 3: Update `handleInputChange(_ text: String)` to filter from `cachedMentionItems` with `.prefix(8)`**
- [ ] **Step 4: Verify build with `./Scripts/check_core.sh`**

---

### Task 4: OakReader 1:1 Chat Bubble and Typography Upgrade

**Files:**
- Modify: `Sources/RawViewApp/Explorer/AIAssistantPane.swift`

- [ ] **Step 1: Upgrade `ChatTurnRow` user bubble to OakReader specification**
  - Shape: `UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16)`
  - Fill: `Color.primary.opacity(0.06)`
  - Text: `Color(nsColor: .labelColor)`, font `.system(size: 13)`
  - Padding: horizontal 14, vertical 10
  - Trailing alignment with `Spacer(minLength: 40)`

- [ ] **Step 2: Upgrade `ChatTurnRow` assistant response to OakReader specification**
  - Background: `Color.clear` with zero borders/strokes (borderless transparent canvas)
  - Text: `Color(nsColor: .labelColor)`, font `.system(size: 13)`
  - Eliminate the `opencode-chat (success)` / `(success)` pill badge on settled assistant turns
  - Show subtle indicator ONLY when actively running: `ProgressView().controlSize(.small)`
  - Show clean red error banner if failed: `Image(systemName: "exclamationmark.triangle.fill")`

- [ ] **Step 3: Align composer card border with OakReader `ChatComposerStyle`**
  - Corner radius: `16`
  - Border: `Color.primary.opacity(0.10)`, line width `1`
  - Background: `Color(nsColor: .controlBackgroundColor)`

- [ ] **Step 4: Run `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh`**

---

### Task 5: Package, Live Visual Verification and Screenshot Capture

- [ ] **Step 1: Package app with `./Scripts/package_app.sh`**
- [ ] **Step 2: Launch `/tmp/RawView.app` and verify:**
  - In Settings -> Providers -> OpenAI Codex: `gpt-6.1-sol`, `gpt-6-luna`, `gpt-6-astra` are present and toggleable.
  - In Settings -> Providers: `opencode-go` is present with allowlist models.
  - In AI Chat Drawer: typing `@` is instant ($O(1)$ Main Thread filtering).
  - Selecting a file and sending prompt starts immediately without I/O freeze.
  - User message shows OakReader uneven-rounded bubble (`UnevenRoundedRectangle`).
  - Assistant response is completely borderless on white canvas with zero `(success)` badge.
- [ ] **Step 3: Capture screenshot of updated UI and verify visual fidelity**
