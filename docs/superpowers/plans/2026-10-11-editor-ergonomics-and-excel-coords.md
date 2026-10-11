# Editor Ergonomics, Excel Column Coordinates, and Filename Token Studio Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide clear Excel-style column headers (`A, B, C...`) in Raw Stream Studio and totally overhaul the Filename Tokens Studio with prominent sample filename inspection, large token chips mapped to actual word segments, cleaner delimiter picker, and reordered cohort table.

**Architecture:** 
1. Add an explicit spreadsheet coordinate header row displaying Excel column letters (`A`, `B`, `C`, ... `Z`, `AA`) directly above each column in `StreamHeaderCardView.swift` and `StreamRowView.swift`.
2. Redesign `FilenameTokensStudioView.swift`:
   - Feature the active sample filename prominently in the hero section (15pt bold monospaced with visual segment highlights).
   - Replace cluttered toggle chips with a clean single-select Delimiter Menu/Picker (`Underscore (_)`, `Hyphen (-)`, `Dot (.)`, `Space`, `None / No delimiter`, `Custom...`).
   - Enlarge token chips with clear font sizing (13–14pt), showing exact token word text, position index, and assigned scientific semantic role.
   - Move the Cohort Token Matrix to the bottom of the studio with explicit token column headers aligning words across project samples.

**Tech Stack:** Swift 5.9+, SwiftUI (macOS 14+), RawViewCore.

**Spec:** User feedback on visual ergonomics, missing column letter references (`A, B, C`), tiny fonts, and cohort matrix prioritization.

## Global Constraints

- Never commit or merge to `master` without explicit user permission. All work remains in the isolated worktree `/Users/tai/agent-development/worktrees/raw-viewer-ergonomics`.
- Raw scientific data files are strictly read-only and immutable.
- Keep UI at 120 FPS performance: virtualization and bounded rows must not regress.
- All 236 unit tests and core checks (`./Scripts/check_core.sh`, `./Scripts/check_index_cli.sh`) must pass with zero regressions.

## Review Focus

1. **Spreadsheet coordinate parity**: Column letter calculation for high index columns (> 26 columns, e.g., `Z` -> `AA`, `AB`).
2. **"None" delimiter handling**: When "None" is selected, the whole basename is treated as a single token without crash or empty arrays.
3. **Empty filename / missing sample handling**: When no source file is selected, the studio displays a clean empty state rather than clipping.
4. **Interactive role assignment reactivity**: Selecting a role on a large token chip updates immediately in `model.semanticElements` and reflects on the highlighted filename preview.
5. **Cohort matrix alignment**: Variable token counts across cohort files must not shift columns or misalign category/device extraction.

---

### Task 1: Add Excel Column Letters (`A, B, C...`) to Stream Header Cards

**Files:**
- Modify: `Sources/RawViewApp/Editor/Grid/StreamHeaderCardView.swift`
- Test: `Tests/RawViewCoreTests/DiscoveryTests.swift` (or dedicated UI logic test)

**Interfaces:**
- Produces: `excelColumnLetter(for colIndex: Int) -> String` mapping 0 -> "A", 1 -> "B", 25 -> "Z", 26 -> "AA".

- [ ] **Step 1: Write helper function `excelColumnLetter(for colIndex: Int) -> String`**
  Implement conversion in `StreamHeaderCardView.swift` (or shared helper).
- [ ] **Step 2: Update `rawHeaderModeView` and `configuredCardModeView` in `StreamHeaderCardView.swift`**
  Add a prominent spreadsheet header badge `[ A ]`, `[ B ]` at the top of every column header card with monospaced bold styling so users immediately identify column coordinates corresponding to `A10`, `B2`.
- [ ] **Step 3: Verify build and tests**
  Run `./Scripts/check_core.sh`.
- [ ] **Step 4: Commit**
  `git commit -am "feat(editor): display Excel column letters A, B, C on stream header cards"`

---

### Task 2: Redesign Filename Tokens Studio Hero Section & Delimiter Selector

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`

**Interfaces:**
- Consumes: `EditorWorkspaceViewModel.selectedSource`, `EditorWorkspaceViewModel.tokens`, `EditorWorkspaceViewModel.editor.tokenDelimiters`.
- Produces: Clean Delimiter Picker with options (`_`, `-`, `.`, ` `, `None`, `Custom...`) and Hero Basename Banner.

- [ ] **Step 1: Replace tiny right-side sample text with large Hero Sample Banner**
  Place the sample filename prominently at the top of the canvas: 14-15pt bold monospaced font, clear contrast, icon, and clickable action to switch file.
- [ ] **Step 2: Display interactive colored segment breakdown of the actual filename**
  Under the filename, display the basename rendered as colored segments showing exactly which substring corresponds to which token.
- [ ] **Step 3: Convert delimiter toggles to clean Delimiter Picker**
  Provide options: `Underscore (_)`, `Hyphen (-)`, `Dot (.)`, `Space`, `None (No delimiter)`, and `Custom...` with clear selection state.
- [ ] **Step 4: Verify build and type-check**
  Run `./Scripts/check_core.sh`.
- [ ] **Step 5: Commit**
  `git commit -am "feat(tokens): hero sample banner and simplified delimiter picker in FilenameTokensStudio"`

---

### Task 3: Enlarge Token Chips & Map Clear Word Labels

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`

**Interfaces:**
- Consumes: `model.tokens`, `model.semanticElements`, `model.addElement(...)`.

- [ ] **Step 1: Enlarge Token Chips from 10pt to 13–14pt bold**
  Redesign each token chip into a large, easy-to-click card showing:
  - Exact token word string in high-contrast monospaced font.
  - Position indicator: `Token #1`, `Token #2` (replacing obscure `Col 1`).
  - Active semantic role badge (e.g. `[ Category / Study ]`, `[ Device ID ]`, `[ Date / Time ]`, `[ Unassigned ]`).
- [ ] **Step 2: Add 1-click Quick Map dropdown menu**
  Clicking the large chip opens clear role assignments with immediate color badge feedback.
- [ ] **Step 3: Verify build**
  Run `./Scripts/check_core.sh`.
- [ ] **Step 4: Commit**
  `git commit -am "feat(tokens): prominent large token chips with clear word labels and role badges"`

---

### Task 4: Reorder Layout and Position Cohort Matrix at the Bottom

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`

**Interfaces:**
- Consumes: `model.sources`, `CategoryRuleEngine`.

- [ ] **Step 1: Reorder layout blocks in `FilenameTokensStudioView`**
  1. Hero Sample & Segmented Preview (Top)
  2. Token Delimiters & Large Interactive Token Chips (Middle)
  3. Configured Token Elements Table (Middle)
  4. Cohort Token Matrix Table (Bottom)
- [ ] **Step 2: Enhance Cohort Matrix column headers**
  Display clear column headers aligning filenames with extracted Category and Device ID.
- [ ] **Step 3: Verify full test suite and package app**
  Run `./Scripts/check_core.sh`, `swift test --parallel`, and `./Scripts/package_app.sh`.
- [ ] **Step 4: Commit**
  `git commit -am "feat(tokens): reorder cohort matrix to bottom and finalize ergonomics"`
