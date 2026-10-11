# Deep-Nested Tree Selection & Impeccable Visual Profile Editor Studio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix tree row selection for arbitrary nested directories and build an Impeccable Visual Profile Editor Studio with direct 1-click intake from Explorer, smart laboratory format auto-detection, spreadsheet-style interactive data matrix, and live quick-plot sandbox preview.

**Architecture:** 
1. Flatten recursive tree traversal into an iterative sequence of top-level List items (`FlattenedTreeItem`) supporting arbitrary nested folder depth and immediate single-click file focus/selection.
2. Bridge Explorer and Profile Editor by adding a "Build Profile from This File" action on the active file in Explorer, eliminating external file dialogs and focusing 100% on active project assets.
3. Implement a smart auto-detection heuristic engine distinguishing column separators (`\t`, `;`, whitespace, `,`) from decimal delimiters (`.`, `,`), extracting `<key>: <value>` metadata, header labels, and numeric data matrix boundaries.
4. Replace line-only text editing with an Impeccable Visual Profile Editor Studio: Top Command Bar, Metadata Summary Card, Data Matrix Spreadsheet Grid with interactive Column Header Cards (X/Y/Aux/Units), and an embedded Live Quick-Plot Sandbox Preview.

**Tech Stack:** Swift 6 tools / Swift 5 language mode, macOS 14+, SwiftUI, SQLite3, fail-closed YAML.

**Spec:** `docs/superpowers/specs/2026-10-10-tree-nested-selection-and-visual-editor-dual-view-design.md`

## Global Constraints

- No third-party dependencies outside Apple platforms and standard Swift libraries.
- Zero source file mutation: raw measurement data files remain strictly read-only and immutable.
- Tree navigation must support arbitrarily deep directory hierarchies (depth >= 10) without recursion stack overflow or collapsed row bugs.
- Editor Mode must operate on real laboratory files pushed directly from Explorer.
- All core and app layer checks must pass via `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh`.

## Review Focus

1. Clicking any file node in a deep-nested tree immediately sets `focusedSourceID` and displays its scientific plot.
2. Clicking a directory node toggles folder expansion without deselecting currently focused files.
3. "Build Profile from This File" from Explorer transfers the exact file URL and seamlessly switches workspace modes.
4. Smart Auto-Detect correctly distinguishes column separators from decimal delimiters and parses `<key>: <value>` metadata.
5. Live Quick-Plot Sandbox immediately draws curves upon assigning X and Y channels.

---

### Task 1: Flattened Tree Navigation Engine for Arbitrary Nested Directories

**Files:**
- Modify: `Sources/RawViewCore/Discovery/SourceTree.swift`
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift`
- Create: `Tests/RawViewCoreTests/FlattenedTreeTests.swift`

**Interfaces:**
- `SourceTree.flatten(expandedIDs: Set<String>, search: String, filter: SourceFilter) -> [FlattenedTreeItem]`
- `FlattenedTreeItem: Identifiable, Sendable`:
  - `id: String`
  - `node: SourceTreeNode`
  - `depth: Int`
  - `isDirectory: Bool`

- [ ] **Step 1: Write failing test for tree flattening with arbitrary depth**
  - Test `testFlattenTreeTraversesDeepNestedHierarchy`: creates a 5-level nested synthetic tree (`dir1/dir2/dir3/dir4/file.csv`). Verifies that when all folders are expanded, `flatten` returns each node at its correct depth. Verifies that collapsing `dir2` omits `dir3`, `dir4`, and `file.csv`.
- [ ] **Step 2: Run test to verify failure**
  - Run: `./Scripts/check_core.sh`
  - Expected: FAIL.
- [ ] **Step 3: Implement tree flattening in SourceTree.swift**
  - Add `FlattenedTreeItem` struct and recursive flattening algorithm.
- [ ] **Step 4: Update ProjectGalleryViews.swift treeView**
  - Replace recursive `treeNodeRow` `VStack` with a flat `ForEach(flattenedItems)` directly inside `List(selection: $selectedSourceIDs)`.
  - Add explicit `.onTapGesture` on file rows to immediately set `focusedSourceID = source.id` and `selectedSourceIDs = [source.id]`.
  - Add `.onTapGesture` on directory rows to toggle `expandedDirectoryIDs`.
- [ ] **Step 5: Run tests and type-check**
  - Run: `./Scripts/check_core.sh`
  - Expected: PASS.

---

### Task 2: Explorer ⇄ Profile Editor Direct 1-Click Bridge

**Files:**
- Modify: `Sources/RawViewApp/RawViewModel.swift`
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift`
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`

**Interfaces:**
- `RawViewModel.buildProfileForSource(sourceID: String?)`: sets `activeWorkspaceMode = .editor`, loads sample URL into editor model.
- Explorer UI:
  - Sidebar row context menu: "✨ Build Profile from This File".
  - Inspector pane button: "✨ Build Profile from This File".

- [ ] **Step 1: Implement bridge method in RawViewModel**
  - Add `func buildProfileForSource(sourceID: String?)` in `RawViewModel`.
- [ ] **Step 2: Add "Build Profile from This File" to Explorer UI**
  - In `ProjectGalleryViews.swift` (Inspector pane & right-click context menu on `sourceRow`), add button "Build Profile from This File".
- [ ] **Step 3: Wire into EditorWorkspaceView**
  - Update `EditorWorkspaceView` to display current active sample file and support immediate switching.
- [ ] **Step 4: Verify Compilation**
  - Run: `./Scripts/check_core.sh`
  - Expected: PASS.

---

### Task 3: Smart Auto-Detection Engine (Separators, Decimals, Metadata, Matrix)

**Files:**
- Modify: `Sources/RawViewCore/Editor/EditorWorkspaceModel.swift`
- Create: `Tests/RawViewCoreTests/SmartAutoDetectTests.swift`

**Interfaces:**
- `EditorWorkspaceModel.smartAutoDetect()`
- `DetectedStructure`:
  - `columnSeparator: String`
  - `decimalDelimiter: String`
  - `metadataPairs: [(key: String, value: String)]`
  - `headerLineIndex: Int?`
  - `dataStartLineIndex: Int`
  - `suggestedChannels: [ColumnChannelMapping]`

- [ ] **Step 1: Write failing test for smartAutoDetect**
  - Test `testSmartAutoDetectTabSeparatedWithMetadata`: supplies standard Tab-separated text with 4 metadata lines (`Date: 2026-10-10`, `Instrument: Keithley 2400`), 1 header line (`Voltage (V)\tCurrent (A)`), and rows of scientific notation numbers (`1.05E-03\t2.50E-06`). Asserts columnSeparator == `\t`, metadata extracted, headerLine == 4, dataStartLine == 5, column 0 detected as X with unit "V", column 1 detected as Y with unit "A".
- [ ] **Step 2: Run test to verify failure**
  - Run: `./Scripts/check_core.sh`
  - Expected: FAIL.
- [ ] **Step 3: Implement smartAutoDetect in EditorWorkspaceModel**
  - Candidate sniffing: Tab (`\t`), Semicolon (`;`), Whitespace, Comma (`,`).
  - Decimal sniffing: Dot (`.`) vs. Comma (`,`).
  - Metadata parsing: `<key>: <value>`, `<key> = <value>`, `# ...`.
  - Data matrix detection: first row where >= 80% tokens are numeric.
  - Channel heuristics: column name keywords and unit extraction from `(...)` / `[...]`.
- [ ] **Step 4: Run test to verify pass**
  - Run: `./Scripts/check_core.sh`
  - Expected: PASS.

---

### Task 5: Impeccable Visual Profile Editor Studio with Live Sandbox Preview

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorCanvasViews.swift`
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`

**Interfaces:**
- Top Command Bar: Sample stats, "✨ Run Smart Heuristics", "💾 Save Profile".
- Metadata Summary Card: Formatted key-value pairs.
- Data Matrix Grid: Spreadsheet-style tabular grid with interactive Column Header Cards (X/Y/Aux/Units).
- Live Quick-Plot Sandbox: Embedded Chart rendering extracted X/Y curves in real-time.

- [ ] **Step 1: Implement Top Command Bar & Metadata Card**
  - Build command bar with file info and 1-click heuristic runner.
  - Render metadata card with clean pill tags.
- [ ] **Step 2: Build Interactive Data Matrix Grid with Column Header Cards**
  - Tabular layout rendering first 50 rows.
  - Clickable header cards with color badges (Blue = X Axis, Emerald = Y Axis, Slate = Aux).
  - Popover / picker for role and quick unit chips (`V`, `mV`, `A`, `mA`, `µA`, `nA`, `cm⁻¹`, `nm`, `s`, `°C`).
- [ ] **Step 3: Build Live Quick-Plot Sandbox Preview**
  - Swift Charts / Canvas mini-plot displaying current X/Y parsed coordinates live.
- [ ] **Step 4: App-level Typecheck & Verification**
  - Run: `./Scripts/check_core.sh`
  - Expected: PASS.

---

### Task 5: End-to-End Verification, Graphify & Ponytail Review

**Files:**
- Run: `Scripts/check_core.sh`
- Run: `Scripts/check_index_cli.sh`
- Run: `Scripts/package_app.sh`
- Run: `graphify extract . --code-only`
- Run: `/ponytail-review`

- [ ] **Step 1: Execute all core verification suites**
  - Verify zero compiler warnings, zero errors.
- [ ] **Step 2: Re-package Release App**
  - Execute `RAWVIEW_APP_PATH="$(pwd)/.build/RawView.app" ./Scripts/package_app.sh`.
- [ ] **Step 3: Update Graphify Knowledge Graph**
  - Re-extract AST to reflect new structures.
- [ ] **Step 4: Ponytail Review**
  - Scan diff for over-engineering and unneeded complexity.
- [ ] **Step 5: Real project testing with res_volatile-polydopamine**
  - Test deep nested folder navigation.
  - Test "Build Profile from This File" and Live Sandbox Preview.
