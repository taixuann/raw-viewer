# Filename Visual Direct-Manipulation & Excel Coordinates Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Overhaul the Filename Tokens Studio with a prominent centered Hero Filename Canvas featuring visual pointer arrows (`↓`), interactive text segment selection, synchronized color-coding for mapped categories, a streamlined single-dropdown delimiter picker (including "None / No delimiter"), bottom-reordered cohort table, and explicit Excel column letter headers (`A, B, C...`) in the data stream.

**Architecture:**
1. In `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`:
   - Replace the cramped layout with a centered **Hero Filename Canvas** (16–18pt monospaced bold).
   - Display each segment of the sample filename with visual down-pointing arrow indicators (`↓`) and color-coded capsule badges.
   - Implement direct-click popover/menu with immediate color illumination for assigned roles (`Study / Category` = Purple, `Device ID` = Blue, `Date & Time` = Green, `Mode` = Pink, `Remarks` = Orange).
   - Replace cluttered toggle chips with a clean single-dropdown Delimiter Menu/Picker (`Underscore (_)`, `Hyphen (-)`, `Dot (.)`, `Space`, `None (No delimiter)`, `Custom...`).
   - Move the Cohort Token Matrix to the bottom of the studio with clear column headers.
2. In `Sources/RawViewApp/Editor/Grid/StreamHeaderCardView.swift`:
   - Add explicit Excel column letter badges `[ A ]`, `[ B ]`, `[ C ]`, ... `[ AA ]` above every column header card matching `A10`, `B2` coordinates.

**Tech Stack:** Swift 5.9+, SwiftUI (macOS 14+), RawViewCore.

**Spec:** User feedback on visual ergonomics, missing column letter references (`A, B, C`), tiny fonts, and cohort matrix prioritization.

## Global Constraints

- Never commit or merge to `master` without explicit user permission. All work remains in the isolated worktree `/Users/tai/agent-development/worktrees/raw-viewer-ergonomics`.
- Raw scientific data files are strictly read-only and immutable.
- Keep UI at 120 FPS performance: virtualization and bounded rows must not regress.
- All 236 unit tests and core checks (`./Scripts/check_core.sh`, `./Scripts/check_index_cli.sh`) must pass with zero regressions.

## Review Focus

1. **Spreadsheet coordinate parity**: Column letter calculation for high index columns (> 26 columns, e.g., 0 -> "A", 25 -> "Z", 26 -> "AA").
2. **"None" delimiter handling**: When "None" is selected, the whole basename is treated as a single token without crash or empty arrays.
3. **Dynamic color synchronization**: Mapped roles must immediately light up both the segment text in the filename and its indicator arrow badge.
4. **Empty filename / missing sample handling**: When no source file is selected, the studio displays a clean empty state rather than clipping.
5. **Cohort matrix alignment**: Variable token counts across cohort files must not shift columns or misalign category/device extraction.

---

### Task 1: Add Excel Column Letters (`A, B, C...`) to Stream Header Cards

**Files:**
- Modify: `Sources/RawViewApp/Editor/Grid/StreamHeaderCardView.swift`

**Interfaces:**
- Produces: `excelColumnLetter(for colIndex: Int) -> String` mapping 0 -> "A", 1 -> "B", 25 -> "Z", 26 -> "AA".

- [ ] **Step 1: Write helper function `excelColumnLetter(for colIndex: Int) -> String`**
  Implement letter calculation in `StreamHeaderCardView.swift`:
  ```swift
  func excelColumnLetter(for index: Int) -> String {
      var n = index
      var result = ""
      while n >= 0 {
          let rem = n % 26
          result = String(UnicodeScalar(65 + rem)!) + result
          n = (n / 26) - 1
      }
      return result
  }
  ```
- [ ] **Step 2: Update `rawHeaderModeView` and `configuredCardModeView` in `StreamHeaderCardView.swift`**
  Add a prominent spreadsheet header badge `[ A ]`, `[ B ]` at the top of every column header card with monospaced bold styling so users immediately identify column coordinates corresponding to `A10`, `B2`.
- [ ] **Step 3: Verify build and tests**
  Run `./Scripts/check_core.sh` in the worktree.
- [ ] **Step 4: Commit**
  `git commit -am "feat(editor): display Excel column letters A, B, C on stream header cards"`

---

### Task 2: Implement Centered Hero Filename Canvas with Pointer Arrows & Color Highlights

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`

**Interfaces:**
- Consumes: `EditorWorkspaceViewModel.selectedSource`, `EditorWorkspaceViewModel.tokens`, `EditorWorkspaceViewModel.semanticElements`.
- Produces: Centered Hero Filename banner (16–18pt bold) with segment badges and visual pointer arrows (`↓`).

- [ ] **Step 1: Create the Centered Hero Filename Card**
  Render the active sample's basename prominently in the center of the studio:
  - Container: Centered, elevated card with subtle rounded border and clean shadow.
  - Basename text: 16pt monospaced bold with file icon and sample badge.
- [ ] **Step 2: Render Segments with Visual Pointer Arrows (`↓`) and Matching Color Highlights**
  Break the filename into interactive segment blocks:
  - Arrow indicator: `Image(systemName: "arrow.down")` or `↓` pointing from the segment to its assigned role.
  - Mapped role badge: If mapped to `Category` (Purple), `Device ID` (Blue), `Date` (Green), etc., highlight both the segment text and the badge in that synchronized color.
  - Unmapped role: Styled in neutral semi-transparent badge with a prompt "Tap to map role".
- [ ] **Step 3: Interactive Role Assignment Popover/Menu**
  Clicking any segment or arrow opens an instant menu:
  - `Map as Category / Study (Purple)`
  - `Map as Device / Legend (Blue)`
  - `Map as Date & Time (Green)`
  - `Map as Measurement Mode (Pink)`
  - `Map as Metadata Field (Orange)`
  - `Clear Mapping`
  Selecting an option immediately refreshes `model.semanticElements` and lights up the colors in real-time.
- [ ] **Step 4: Verify build and type-check**
  Run `./Scripts/check_core.sh`.
- [ ] **Step 5: Commit**
  `git commit -am "feat(tokens): centered hero filename canvas with pointer arrows and synchronized color highlights"`

---

### Task 3: Streamline Delimiter Configuration into Single Dropdown Picker

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`

**Interfaces:**
- Consumes: `model.editor.tokenDelimiters`.
- Produces: Single compact Delimiter Picker supporting `_`, `-`, `.`, space, `None`, and `Custom...`.

- [ ] **Step 1: Replace multi-chip toggles with a clean Delimiter Dropdown / Picker**
  Implement a segmented/menu picker:
  - `Underscore (_)`
  - `Hyphen (-)`
  - `Dot (.)`
  - `Space ( )`
  - `None (No delimiter - whole filename)`
  - `Custom...` (with inline text field)
- [ ] **Step 2: Handle "None" delimiter state cleanly**
  When "None" is chosen, `model.editor.tokenDelimiters = []`, causing `CategoryRuleEngine.tokenize` to treat the whole basename as a single token, ready for manual mapping.
- [ ] **Step 3: Verify build**
  Run `./Scripts/check_core.sh`.
- [ ] **Step 4: Commit**
  `git commit -am "feat(tokens): compact single dropdown delimiter picker with None option"`

---

### Task 4: Reorder Layout and Position Cohort Matrix at the Bottom

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`

**Interfaces:**
- Consumes: `model.sources`, `CategoryRuleEngine`.

- [ ] **Step 1: Reorder layout structure**
  Order sections logically:
  1. Centered Hero Filename & Pointer Arrow Segment Mapper (Top)
  2. Delimiter Picker & Configuration (Sub-bar)
  3. Configured Token Elements Table (Middle)
  4. Cohort Token Matrix Table (Bottom)
- [ ] **Step 2: Polish Cohort Token Matrix**
  Add explicit column headers (`Sample Filename`, `Matched Category`, `Matched Device ID`) and tooltip `.help(...)` on filenames.
- [ ] **Step 3: Verify full test suite and package app**
  Run `./Scripts/check_core.sh`, `swift test --parallel`, and `./Scripts/package_app.sh`.
- [ ] **Step 4: Commit**
  `git commit -am "feat(tokens): move cohort matrix to bottom and finalize ergonomics"`
