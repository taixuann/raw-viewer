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
- [ ] **Task 3: Redesign FilenameTokensStudioView into Grammar Pattern Studio**
- [ ] **Task 4: Connect Cohort Table & Run Independent Code Reviews**
