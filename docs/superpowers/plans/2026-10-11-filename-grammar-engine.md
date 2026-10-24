# Filename Grammar Engine & Pattern Template Studio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a declarative, extensible Filename Grammar Engine backed by `.rawviewer/view/grammar.yaml` that compiles pattern templates (e.g. `{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]`) into named-capture regular expressions with bracket-stripping, auto-matching verification, and live role mapping in the Filename Tokens Studio.

**Architecture:**
1. In `Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift`:
   - Define `FilenameGrammar`, `GrammarField`, and `FilenameGrammarCatalog`.
   - Compiler transforms template `{variable}` strings into `NSRegularExpression` with named groups, auto-escaping literal tokens (`.`, `_`, `-`, `[]`, `()`).
   - Serializer / Deserializer for `.rawviewer/view/grammar.yaml`.
   - Extraction method `extract(filename: String, grammar: FilenameGrammar) -> ExtractedGrammarFacts`.
2. In `Sources/RawViewApp/Editor/EditorWorkspaceView.swift` (`EditorWorkspaceViewModel`):
   - State management for active grammars, current template, and live match results.
3. In `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`:
   - Grammar Catalog bar: Select preset, Add new grammar, Save to `grammar.yaml`.
   - Template Editor: Textfield for pattern input with 1-tap variable chips (`{date}`, `{instrument}`, `{device-id}`, `{study}`, `{mode}`, `{remarks}`, `{custom}`).
   - Smart Match Status banner (`✅ Matched` vs `⚠️ Unmatched`).
   - Dynamic Variable Mapping Table with Role & Format dropdowns.
   - Cohort Token Matrix updated to display match indicator and extracted attributes across 12+ files.

**Tech Stack:** Swift 5.9+, SwiftUI (macOS 14+), RawViewCore, YAMLParser.

**Spec:** User specification for `grammar.yaml` pattern templates (`{date}_{instrument}.{mode}_[{device-id}]_r.[{remarks}]`), smart matching, and profile/catalog persistence.

## Global Constraints

- Never commit or merge to `master` without explicit user permission. All work remains in the isolated worktree `/Users/tai/agent-development/worktrees/raw-viewer-ergonomics`.
- Raw scientific data files are strictly read-only and immutable.
- Keep UI at 120 FPS performance: virtualization and bounded rows must not regress.
- All 236 unit tests and core checks (`./Scripts/check_core.sh`, `./Scripts/check_index_cli.sh`) must pass with zero regressions.

## Review Focus

1. **Regex Escaping Correctness**: Bracketed expressions like `[{device-id}]` must escape outer brackets `\[` and `\]` while capturing the inner token cleanly.
2. **"None" or Empty Template Fallback**: When no template is defined, gracefully fallback to legacy tokenization without crashing.
3. **Invalid Regex Pattern Resilience**: If user types an unclosed `{` or invalid regex characters, the editor marks status as `Invalid syntax` without crashing.
4. **YAML Persistence Fidelity**: Reading and writing `.rawviewer/view/grammar.yaml` preserves all fields, roles, and format hints.
5. **Cohort Matching Performance**: Batch regex matching across cohort samples must be sub-millisecond per item.

---

### Task 1: Core FilenameGrammar Engine & YAML Storage (`RawViewCore`)

**Files:**
- Create: `Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift`
- Create: `Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift`

**Interfaces:**
- Produces: `FilenameGrammar`, `GrammarField`, `FilenameGrammarCatalog`, `FilenameGrammarEngine.compile(template:)`, `FilenameGrammarEngine.extract(from:grammar:)`, `FilenameGrammarEngine.load(project:)`, `FilenameGrammarEngine.save(catalog:project:)`.

- [ ] **Step 1: Write failing unit test `FilenameGrammarEngineTests`**
  Assert template compilation for `{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]` correctly extracts `date`, `instrument`, `mode`, `device-id`, `study`, `remarks` from `271125-000000_autolab-usth.cv_[au-pda]_cv.deposition_r.[100mv-ph-7.4].txt`.
- [ ] **Step 2: Run test to verify failure**
  Run `swift test --filter FilenameGrammarEngineTests`.
- [ ] **Step 3: Implement `FilenameGrammarEngine.swift`**
  Define types, regex compiler, extractor, and YAML serializer/deserializer.
- [ ] **Step 4: Run test to verify it passes**
  Run `swift test --filter FilenameGrammarEngineTests`.
- [ ] **Step 5: Commit**
  `git commit -am "feat(core): implement FilenameGrammarEngine with pattern template compiler and YAML persistence"`

---

### Task 2: ViewModel Grammar State & Persistence Integration

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`

**Interfaces:**
- Consumes: `FilenameGrammarEngine`, `FilenameGrammarCatalog`.
- Produces: `EditorWorkspaceViewModel.grammarCatalog`, `EditorWorkspaceViewModel.activeGrammar`, `EditorWorkspaceViewModel.testSampleMatch()`.

- [ ] **Step 1: Add grammar catalog properties to `EditorWorkspaceViewModel`**
  Add `@Published var grammarCatalog: FilenameGrammarCatalog`, `@Published var activeGrammarID: String?`, and load logic from `.rawviewer/view/grammar.yaml`.
- [ ] **Step 2: Add template matching and fact extraction actions**
  Add `updateActiveTemplate(_ template: String)`, `saveGrammarCatalog()`.
- [ ] **Step 3: Run check_core to verify type safety**
  Run `./Scripts/check_core.sh`.
- [ ] **Step 4: Commit**
  `git commit -am "feat(editor): integrate grammar catalog and pattern matching in EditorWorkspaceViewModel"`

---

### Task 3: Redesign FilenameTokensStudioView into Grammar Pattern Studio

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`

**Interfaces:**
- Consumes: `EditorWorkspaceViewModel.activeGrammar`, `FilenameGrammarEngine`.
- Produces: Interactive Template Input, Quick Variable Chips, Smart Match Status Banner, Variable Role Table.

- [ ] **Step 1: Add Grammar Catalog Selector & Preset Management Bar**
  Provide dropdown to switch between saved grammars, add new grammar, and save default grammar.
- [ ] **Step 2: Implement Template Input Editor with 1-tap variable chips**
  Add template `TextField` and quick chip buttons (`{date}`, `{instrument}`, `{device-id}`, `{study}`, `{mode}`, `{remarks}`).
- [ ] **Step 3: Add Smart Match Status Banner & Extracted Variables Table**
  Display `✅ MATCHED` or `⚠️ UNMATCHED`. Render extracted variables in clear rows with role picker and format picker.
- [ ] **Step 4: Run check_core to verify UI compilation**
  Run `./Scripts/check_core.sh`.
- [ ] **Step 5: Commit**
  `git commit -am "feat(tokens): grammar pattern studio UI with template input and smart match status"`

---

### Task 4: Connect Cohort Table & Run Independent Code Reviews

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`

**Interfaces:**
- Consumes: `FilenameGrammarEngine.extract`.

- [ ] **Step 1: Update Cohort Matrix to display live match badges and grammar extractions**
  For each project sample, display `✅` or `⚠️` and columns matching the active grammar fields.
- [ ] **Step 2: Verify full test suite and package app**
  Run `./Scripts/check_core.sh`, `swift test --parallel`, and `./Scripts/package_app.sh`.
- [ ] **Step 3: Dispatch independent subagent code review**
  Review diff against `HEAD`.
- [ ] **Step 4: Commit**
  `git commit -am "feat(tokens): connect cohort matrix to grammar engine and verify build"`
