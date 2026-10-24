# Implementation Plan: OakReader Sidecar Backend & ChatGPT Subscription Integration

- **Spec**: `docs/superpowers/specs/2026-10-16-oak-backend-sidecar-integration-design.md`
- **Goal**: Integrate OakReader's compiled sidecar daemon (`oak-backend`) and Swift RPC layer (`NodeBackend`, `RPCTransport`, `BackendProtocol`, `AIProviderCatalog`) into RawView, enabling real-time streaming, dynamic model catalog, and native ChatGPT subscription OAuth.

---

## Tasks

### Task 1: Port RPC Client Infrastructure from OakReader to RawViewApp
- **Files**:
  - `Sources/RawViewApp/Services/Backend/NodeBackend.swift`
  - `Sources/RawViewApp/Services/Backend/RPCTransport.swift`
  - `Sources/RawViewApp/Services/Backend/BackendProtocol.swift`
  - `Sources/RawViewApp/Services/Backend/BackendProtocol.generated.swift`
  - `Sources/RawViewApp/Services/Backend/AIProviderCatalog.swift`
- **Actions**:
  - Copy and adapt these 5 files from `/Users/tai/oakreader-src/app/Services/Backend/` into `Sources/RawViewApp/Services/Backend/`.
  - Update imports and paths so they work within `RawViewApp` (e.g. storage paths point to `~/.rawviewer/` or app support, and fallback binary discovery locates `/Users/tai/oakreader-src/backend/dist/oak-backend` or bundled resource).
- **Verification**: `swift build` passes without missing symbols.

---

### Task 2: Package `oak-backend` Binary into RawView.app
- **Files**:
  - `Scripts/package_app.sh`
- **Actions**:
  - Update `package_app.sh` to copy `/Users/tai/oakreader-src/backend/dist/oak-backend` into `/tmp/RawView.app/Contents/Resources/oak-backend` and `chmod +x`.
  - Ensure `codesign` signs the inner binary before packaging the app bundle.
- **Verification**: `./Scripts/package_app.sh` packages `/tmp/RawView.app` containing `Contents/Resources/oak-backend`.

---

### Task 3: Initialize `NodeBackend` and Load Dynamic Providers on App Launch
- **Files**:
  - `Sources/RawViewApp/RawViewApp.swift`
- **Actions**:
  - In `RawViewApp.init()` or `.task`, call `_ = NodeBackend.shared` and `await AIProviderCatalog.shared.refresh()`.
  - Verify that `oak-backend` launches and responds to `providers/list` RPC.
- **Verification**: Check app startup logs to confirm `oak-backend` started and loaded providers.

---

### Task 4: Connect `SettingsView.swift` to `AIProviderCatalog` and ChatGPT OAuth
- **Files**:
  - `Sources/RawViewApp/SettingsView.swift`
- **Actions**:
  - Update `aiTab` in `SettingsView.swift` to display providers from `AIProviderCatalog.shared.providers`.
  - Add "Connect ChatGPT Subscription" section:
    - Triggers `oauth/login` with `providerId: "openai-codex"`.
    - Handles `oauth/notify` (displays the 8-character device code and clickable link to `https://auth.openai.com/codex/device`).
    - Handles `oauth/prompt` and completion.
    - Displays connected subscription status (e.g., "Active ChatGPT Subscription").
- **Verification**: Open Settings > AI, verify providers list dynamically loaded from backend, and test OAuth device code trigger.

---

### Task 5: Wire `AIAssistantPane.swift` to `NodeBackend` for Live Streaming & Tools
- **Files**:
  - `Sources/RawViewApp/Explorer/AIAssistantPane.swift`
- **Actions**:
  - Replace the old CLI subprocess runner with streaming RPC via `NodeBackend.shared` or `BackendChatEngine`.
  - Populate the composer model dropdown directly from `AIProviderCatalog.shared.availableModels`.
  - Stream assistant responses character by character / chunk by chunk into `turns`.
  - Retain skill execution (`/setup-grammar`, `/setup-profile`, `/explain`, `/reindex`) and session persistence in `.rawviewer/session/<YYYY-MM-DD>/<session-id>.jsonl`.
- **Verification**: Send chat messages via `AIAssistantPane` and verify real-time streaming output.

---

### Task 6: Full Verification & Integration Test
- **Actions**:
  - Run `swift test`.
  - Run `./Scripts/check_core.sh`.
  - Run `./Scripts/check_index_cli.sh`.
  - Run `./Scripts/package_app.sh`.
  - Relaunch `/tmp/RawView.app` and test end-to-end chat and settings.
- **Verification**: Complete without errors.
