# Comprehensive Filename Grammar, 2-Tier Storage & Studio Ergonomics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the complete set of ergonomically unified upgrades for RawView Profile Editor:
1. **Filename Grammar Engine**: Canonical template `{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]_{batch}` (`date`: `DDMMYY-HHmmSS`, `batch`: `001`, `isOptional: true`), YAML file-backed storage, and 2-tier isolation (Project: `.rawviewer/view/grammar.yaml` vs Global: `~/.rawviewer/grammar.yaml`) with no silent overwriting.
2. **Editor Shell & Headbar Profile Management**:
   - Reorder studio tabs to `[ Raw Stream Studio | Live Sandbox Studio | Filename Grammar ]` (defaulting to `Raw Stream Studio`).
   - Move Profile Identity & Selection to top-right of the headbar: `Profile: [ 🎛️ autolab ▾ ]  [ + New ]  [ ⓘ ]`.
   - Make `+ New Profile` strictly **non-destructive**: clone and inherit current parsed columns, delimiters, and active sample state rather than wiping to a blank canvas.
   - Clean up Left Sidebar to focus purely on Active Target Sample and Cohort Examples.
3. **Raw Stream Studio Toolbar**:
   - Replace 4 fragmented rounded bordered box cards with a single, flat, unified macOS toolbar band with subtle vertical dividers (`Divider().frame(height: 22)`).
   - Fix label wrapping on "Data Start L#:" by renaming to `Data Starts:` with adequate width (84pt).
   - Eliminate redundant `Auto Detect` and `Apply & Parse` buttons: sniffing runs on sample load, and delimiter/decimal/stepper edits trigger live auto-reparsing.
   - Integrate **Linked Grammar Selector**: dropdown picking from Global / Project grammars, plus `+ Create New Grammar...` bridging directly to the `Filename Grammar` tab.
   - Promote primary **`💾 Save Profile`** action.
4. **Live Sandbox Studio Toolbar**:
   - Remove redundant `Live Sandbox Studio` title.
   - Move all controls to the **LEFT** in natural scientific sequence: `X Axis Picker` -> `Y Axis Picker` -> `Progression Controls` (`Dimension`, `Continuous / Discrete`, `Slice filter`, `Palette / Sweep`).
   - Apply centralized Design System (`AppTypography.toolbarLabel(uiFontSize:)`, `AppTypography.caption`, `StudioControls`): standardize uniform 24-26pt height, consistent baselines, and scalable typography.
   - Push data point counter (`9,999 pts`) to far right.
5. **Filename Grammar Studio**:
   - Remove redundant top header line (`Filename Grammar Studio` title and `Sample: ...` text).
   - Refactor variable table to SwiftUI `Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6)` and `GridRow` for 100% vertical column alignment.
   - Replace 14pt borderless format menu with a 20x20pt preset picker menu for Number and DateTime.
   - Provide 2-tier save menu: `Save to Project` and `Save as Global Template`.

**Architecture:**
- `RawViewCore.Discovery.FilenameGrammarEngine`: Canonical defaults, 2-tier file persistence (`loadCombined`, `save(catalog:fileURL:)`).
- `RawViewApp.Editor.Panels`:
  - `EditorCenterCanvasView.swift`: Headbar profile selector & popover, reordered tabs.
  - `EditorLeftSidebarView.swift`: Cleaned sidebar without duplicate profile identity.
  - `StreamToolbarCards.swift`: Flat unified toolbar, linked grammar selector, live re-parse.
  - `LiveSandboxPlotView.swift`: Left-aligned controls, design system typography tokens.
  - `FilenameTokensStudioView.swift`: SwiftUI Grid layout, clean header, 2-tier save menu.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit, RawViewCore (`FilenameGrammarEngine`, `ProjectContext`, `YAMLParser`), RawViewApp DesignSystem (`AppTypography`, `AppColors`, `StudioControls`), XCTest.

**Spec:** In-conversation design approved during brainstorming and impeccable review sessions on 2026-10-12.

## Global Constraints
- Worktree: `/Users/tai/agent-development/worktrees/raw-viewer-ergonomics`
- Branch: `fix-editor-ergonomics-and-excel-coords`
- Zero regression: All 241 tests must pass; `./Scripts/check_core.sh` and `./Scripts/package_app.sh` must remain green.
- Scientific data immutability: Raw scientific data files are strictly read-only.
- Design System coherence: Use `AppTypography` and `StudioControls` rather than ad-hoc `.system(size: ...)` or `.controlSize(.mini)`.
- No silent overwrites: Project custom grammars and Global templates remain discrete and selectively switchable.

## Review Focus
1. Long format string `DDMMYY-HHmmSS` must not push downstream columns (`Rule`, `Filter`) out of alignment in the Grammar table.
2. Clicking `+ New Profile` in the headbar must duplicate/inherit existing parsed columns and delimiter settings without clearing them.
3. Switching Delimiter or stepping Header Line in Raw Stream Studio must immediately re-parse without an Apply button.
4. Clicking `+ Create New Grammar...` in Raw Stream Studio must switch active studio tab to `Filename Grammar` (`.tokens`).
5. Live Sandbox Studio controls must start from the left (`X` -> `Y` -> `Progression`), use `AppTypography` scaling, and share uniform 24-26pt heights.

---

### Task 1: Update FilenameGrammarEngine Canonical Defaults & 2-Tier Storage

**Files:**
- Modify: `Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift`
- Test: `Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift`

**Interfaces:**
- `FilenameGrammarCatalog.standardDefaults`: Template `{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]_{batch}` with `date` (`DDMMYY-HHmmSS`) and `batch` (`001`, `isOptional: true`).
- `FilenameGrammarScope`: Enum with `.project` and `.global`.
- `FilenameGrammarEngine.save(catalog:fileURL:)` and `load(fileURL:)`.
- `FilenameGrammarEngine.globalGrammarURL`: Path to `~/.rawviewer/grammar.yaml`.
- `FilenameGrammarEngine.loadCombined(project:)` returning tagged Project and Global grammars.

- [ ] **Step 1: Write failing unit tests for canonical template with batch and 2-tier storage**

```swift
func testStandardScientificTemplateWithBatchAndDateTime() throws {
    let standard = FilenameGrammarCatalog.standardDefaults.first!
    XCTAssertEqual(standard.template, "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]_{batch}")
    let (regex, fieldNames) = try FilenameGrammarEngine.compile(template: standard.template, fields: standard.fields)
    XCTAssertTrue(fieldNames.contains("batch"))
    
    let sample = "261012-143000_Autolab.CV_[D01]_Stability_r.[scan1]_001.csv"
    let facts = FilenameGrammarEngine.extract(from: sample, grammar: standard)
    XCTAssertTrue(facts.isMatched)
    XCTAssertEqual(facts.extractedFields["date"], "261012-143000")
    XCTAssertEqual(facts.extractedFields["batch"], "001")
    XCTAssertEqual(facts.extractedFields["device-id"], "D01")
}

func testGlobalAndProjectStorageIsolation() throws {
    let globalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
    let globalFile = globalDir.appendingPathComponent("grammar.yaml")
    
    let testCatalog = FilenameGrammarCatalog(grammars: [
        FilenameGrammar(id: "global-1", name: "Global Grammar", template: "{date}_{study}")
    ])
    try FilenameGrammarEngine.save(catalog: testCatalog, fileURL: globalFile)
    
    let loaded = FilenameGrammarEngine.load(fileURL: globalFile)
    XCTAssertEqual(loaded?.grammars.first?.id, "global-1")
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter FilenameGrammarEngineTests`
Expected: FAIL.

- [ ] **Step 3: Implement standard template and 2-tier file methods in `FilenameGrammarEngine.swift`**
  - Update `FilenameGrammarCatalog.standardDefaults`.
  - Add `save(catalog:fileURL:)` and `load(fileURL:)`.
  - Add `globalGrammarURL` and `loadCombined(project:)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FilenameGrammarEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit changes**

```bash
git add Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift
git commit -m "feat(grammar): add canonical standard pattern with batch and 2-tier storage"
```

---

### Task 2: Headbar Profile Management, Non-Destructive Duplication & Tab Reordering

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`
- Modify: `Sources/RawViewApp/Editor/Panels/EditorCenterCanvasView.swift`
- Modify: `Sources/RawViewApp/Editor/Panels/EditorLeftSidebarView.swift`

**Interfaces:**
- `EditorWorkspaceView.StudioTab`: Reorder cases to:
  1. `rawStream = "Raw Stream Studio"` (default)
  2. `liveSandbox = "Live Sandbox Studio"`
  3. `tokens = "Filename Grammar"`
- `EditorWorkspaceViewModel`:
  - `duplicateProfileFromCurrent(newID: String, newName: String)`: non-destructive clone.
  - `saveGrammarToProject()`
  - `saveGrammarToGlobal()`
  - `saveProfileAndRules()`
- `EditorCenterCanvasView`:
  - Top command bar right side: `Profile: [ 🎛️ autolab ▾ ]  [ + New ]  [ ⓘ ]` (popover for Profile ID & Display Name).
- `EditorLeftSidebarView`:
  - Remove redundant `profileIdentityCard`; streamline to Active Target Sample and Saved Profiles library.

- [ ] **Step 1: Reorder `StudioTab` enum and add non-destructive profile duplication**
  - Order: `.rawStream`, `.liveSandbox`, `.tokens`.
  - Add `duplicateProfileFromCurrent(newID:newName:)` in `EditorWorkspaceViewModel` retaining existing column definitions and delimiters.

- [ ] **Step 2: Implement Headbar Profile Selector & Info Popover in `EditorCenterCanvasView.swift`**
  - Right-aligned profile picker menu with all saved profiles.
  - `+ New` button presenting non-destructive duplicate popover.
  - Info `ⓘ` button showing popover with Profile ID and Display Name TextFields.

- [ ] **Step 3: Remove `profileIdentityCard` from `EditorLeftSidebarView.swift`**

- [ ] **Step 4: Verify build with `./Scripts/check_core.sh`**

Run: `./Scripts/check_core.sh`
Expected: PASS.

- [ ] **Step 5: Commit changes**

```bash
git add Sources/RawViewApp/Editor/EditorWorkspaceView.swift Sources/RawViewApp/Editor/Panels/EditorCenterCanvasView.swift Sources/RawViewApp/Editor/Panels/EditorLeftSidebarView.swift
git commit -m "feat(editor): reorder tabs and move profile identity to headbar with non-destructive new"
```

---

### Task 3: Redesign Raw Stream Toolbar (Flat Band, Linked Grammar, Live Re-parse & Save Profile)

**Files:**
- Modify: `Sources/RawViewApp/Editor/Grid/StreamToolbarCards.swift`
- Modify: `Sources/RawViewApp/Editor/Panels/ParserSettingsCanvasView.swift`

**Interfaces:**
- `StreamToolbarCards`:
  - Single unified flat bar separated by vertical dividers (`Divider().frame(height: 22)`).
  - Rename label to `Data Starts:` with 84pt width to prevent line wrapping.
  - Remove `Auto Detect` and `Apply & Parse` buttons.
  - Connect delimiter, decimal, and row steppers to live re-parsing on change.
  - Add Linked Grammar selector (`Grammar: [ 🌐 Standard Scientific (Global) ▾ ]`) with `+ Create New Grammar...` action setting `selectedStudioTab = .tokens`.
  - Add primary `Save Profile` button.

- [ ] **Step 1: Refactor `StreamToolbarCards.swift` into unified flat layout**
- [ ] **Step 2: Wire live auto-reparsing in `ParserSettingsCanvasView.swift` on control change**
- [ ] **Step 3: Add Linked Grammar dropdown with `+ Create New Grammar...` callback**
- [ ] **Step 4: Connect `Save Profile` action**
- [ ] **Step 5: Verify build with `./Scripts/check_core.sh`**
- [ ] **Step 6: Commit changes**

```bash
git add Sources/RawViewApp/Editor/Grid/StreamToolbarCards.swift Sources/RawViewApp/Editor/Panels/ParserSettingsCanvasView.swift
git commit -m "feat(stream): redesign toolbar to flat unified band with linked grammar and live re-parse"
```

---

### Task 4: Ergonomic Overhaul of Live Sandbox Studio Toolbar

**Files:**
- Modify: `Sources/RawViewApp/Editor/LiveSandboxPlotView.swift`

**Interfaces:**
- Remove redundant `Live Sandbox Studio` title label and left-side `Spacer()`.
- Sequence all controls on the LEFT in natural scientific order:
  1. `X:` Picker (blue accent)
  2. `Y:` Picker (green accent)
  3. `Progression:` Dimension (`#5 Scan`), Mode (`Continuous | Discrete`), Slice Filter (`All (13)`), Color Style (`Palette | Sweep`).
- Standardize controls using centralized `AppTypography`:
  - Uniform 24-26pt control height (`.controlSize(.small)`).
  - Use `AppTypography.toolbarLabel(uiFontSize: uiFontSize)` for labels and pickers.
- Push data point counter (`9,999 pts`) to far right.

- [ ] **Step 1: Reorganize toolbar layout in `LiveSandboxPlotView.swift`**
  - Move X and Y pickers to the start of the toolbar.
  - Sequence Progression controls immediately after Y picker.
  - Place `Spacer()` after Progression controls to push point counter to the right.

- [ ] **Step 2: Apply centralized `AppTypography` and uniform control sizing**
  - Standardize all pickers, segmented controls, and menu pills to `.controlSize(.small)` and height 24-26pt.

- [ ] **Step 3: Verify build with `./Scripts/check_core.sh`**

Run: `./Scripts/check_core.sh`
Expected: PASS.

- [ ] **Step 4: Commit changes**

```bash
git add Sources/RawViewApp/Editor/LiveSandboxPlotView.swift
git commit -m "feat(sandbox): left-align toolbar controls in X-Y-Progression sequence with universal typography"
```

---

### Task 5: Clean Up Filename Grammar Studio & Align Table with SwiftUI `Grid`

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`

**Interfaces:**
- Remove redundant top header line (`Filename Grammar Studio` title and `Sample: ...` text).
- Refactor variable table to `Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6)` and `GridRow`.
- Replace 14pt borderless format menu with a 20x20pt preset picker menu for Number and DateTime using `AppTypography`.
- Add 2-tier save menu (`Save to Project` and `Save as Global Template`).

- [ ] **Step 1: Remove redundant title and sample line in `FilenameTokensStudioView.swift`**
- [ ] **Step 2: Convert variable table rows and header to `Grid` and `GridRow`**
  - Exact column widths: `Token` 115pt, `Sample` 135pt, `Role` 120pt, `Data Type` 100pt, `Format` 140pt, `Rule` 90pt, `Filter` 110pt.
- [ ] **Step 3: Replace format menu button with 20x20pt preset button**
- [ ] **Step 4: Add 2-Option Save Grammar menu (Project vs Global)**
- [ ] **Step 5: Verify build with `./Scripts/check_core.sh`**
- [ ] **Step 6: Commit changes**

```bash
git add Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift
git commit -m "feat(tokens): align grammar table with Grid, fix format picker, and add 2-tier save"
```

---

### Task 6: End-to-End Verification & Knowledge Page Sync

**Files:**
- Full test suite, check scripts, and package script.
- Update `graphify update .`
- Sync Hindsight initiative `kp-33b3f557ad3f4cc99c409a309c69b5f0`.

- [ ] **Step 1: Run complete test suite and verification scripts (`swift test --parallel`, `./Scripts/check_core.sh`, `./Scripts/check_index_cli.sh`, `./Scripts/package_app.sh`)**
- [ ] **Step 2: Update graphify knowledge graph**
- [ ] **Step 3: Record initiative in Hindsight memory**
