# SDD ledger — plan: docs/superpowers/plans/2026-10-11-filename-grammar-engine.md

## Status
- Branch: `fix-editor-ergonomics-and-excel-coords`
- Worktree: `/Users/tai/agent-development/worktrees/raw-viewer-ergonomics`
- Strict Rule: NEVER merge or push to master without explicit authorization.

## Tasks
- [x] **Task 1: Core FilenameGrammar Engine & YAML Storage (`RawViewCore`)**
  - Added `Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift` with `FilenameGrammar`, `GrammarField`, `FilenameGrammarCatalog`, `ExtractedGrammarFacts`, `FilenameGrammarEngine.compile()`, `FilenameGrammarEngine.extract()`, `FilenameGrammarEngine.save()`, and `FilenameGrammarEngine.load()`.
  - Added unit test suite `Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift`.
  - Tests: 3/3 passed.
- [x] **Task 2: ViewModel Grammar State & Persistence Integration**
  - Integrated `grammarCatalog`, `activeGrammarID`, `activeTemplate`, `sampleExtractedFacts`, and `grammarMatchError` in `EditorWorkspaceViewModel`.
  - Added methods `loadGrammarCatalog()`, `saveGrammarCatalog()`, `selectGrammar()`, `addNewGrammar()`, `updateActiveTemplate()`, `updateGrammarField()`, and `recalculateGrammarExtraction()`.
  - Hooked catalog auto-persistence into `saveProfileAndRules()`.
  - Verified with `./Scripts/check_core.sh` (passed core self-check & app layer type-check).
- [x] **Task 3: Redesign FilenameTokensStudioView into Grammar Pattern Studio**
  - Added Grammar Catalog preset bar with active convention picker (`[ Autolab Scientific Pattern ▾ ]`) and `[+ New Grammar]` modal sheet.
  - Implemented Pattern Template Hero Editor with monospaced `TextField` and 1-tap variable pill insertion (`{date}`, `{instrument}`, `{mode}`, `[{device-id}]`, `{study}`, `r.[{remarks}]`, `{batch}`).
  - Built Smart Pattern Match Status banner (`✅ MATCHED PATTERN` vs `⚠️ PATTERN MISMATCH` with descriptive diagnostics).
  - Built Extracted Variables & Semantic Roles mapping table with role dropdowns (Date & Time, Instrument, Mode, Device ID, Study, Remarks, Skip) and format hints / `Strip [ ]` toggles.
  - Verified with `./Scripts/check_core.sh`.
- [x] **Task 4: Connect Cohort Table & Run Independent Code Reviews**
  - Connected Cohort Validation Matrix displaying `Match` / `Miss` status badges and extracted fields across all project files.
  - Added live `X/Y Matched (Z%)` badge in Cohort Validation header.
  - Polished YAML quote/backslash escaping, pathExtension stripping, and deterministic declared field order.
  - Added horizontal scroll view to variable insertion pills for compact windows.
  - Verified:
    - `./Scripts/check_core.sh`: passed.
    - `./Scripts/check_index_cli.sh`: passed.
    - `swift test --parallel`: all 239 unit tests passed across 11 suites.
    - `./Scripts/package_app.sh`: production bundle built, signed, and verified.
  - Independent Code Reviews:
    - Impeccable UX Reviewer: Approved (`Ready & Impeccable`).
    - Senior Code Reviewer: Approved (`Ready to proceed`).
    - Ponytail Reviewer: Simplified bracket checks and deterministic field loops.
