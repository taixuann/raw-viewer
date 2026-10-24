# Profile Studio, Filename Grammar, Toolbar Ergonomics & Column Cards Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clean up and polish the Profile Studio, Filename Grammar, Raw Stream Toolbar, and Column Header Cards: rename default pattern to "Standard Filename Pattern", eliminate all legacy `instrument/examples` and `-example` suffix mutation, implement progressive token extraction, overhaul Raw Stream Toolbar into a cohesive Pro macOS single-bar layout (Grammar menu, universal 24pt buttons, fixed preview=25), remove obsolete "Data Channel (Aux)" option, and polish Column Cards with Progression type hints and custom progression label editing.

**Architecture:**
1. `FilenameGrammarEngine`: rename canonical default to `"Standard Filename Pattern"` (`standard-scientific`). Add progressive token extraction so partial prefix matches extract live into chips even if full string regex has an unclosed or mismatched tail.
2. `EditorWorkspaceViewModel`: purge all references to `instrument/examples`, `pinCurrentAsExample()`, and `-example.txt`. Use direct project files.
3. Top Command Bar (`EditorCenterCanvasView`): Pro macOS neutral profile dropdown (`Profile: [ ▾ <activeName> ] [ + New ]`), no 9-dots icon, no info button, neutral segmented tabs.
4. Raw Stream Toolbar (`StreamToolbarCards`):
   - Redesign Grammar selector into a single clean button/menu (`Grammar: [ ▾ Standard Scientific (Global) ]`), with `+ Create New Grammar…` inside the menu. Delete the clunky duplicated row and extra labels.
   - Standardize Preview picker default to 25 (`[ 25 | 50 | 100 | 200 | 500 ]`), remove default 50. Ensure the expand button aligns perfectly with universal 24pt height.
   - Polish Section 3 (View & Metadata) with universal button sizing (`StudioActionButton` / 24pt height): Metadata tags pill, `Cols: 9/9` badge, `Include All`, `Auto-Skip Empty`.
5. Column Header Cards (`StreamHeaderCardView`):
   - Remove "Set as Data Channel (Aux)" from the role menu; columns default to channel unless set to X, Y, or Progression.
   - For Progression columns: display progression type and behavior on the card (`Progression: Time (Continuous)` or `Progression: Scan (Discrete)` or `Progression: <CustomName> (Discrete)`).
   - For Custom Progression: add a popover/sheet to type the custom progression name (e.g., `pH`, `Concentration`, `Cycle`) instead of auto-naming or guessing.

**Tech Stack:** Swift 5.10+, SwiftUI, AppKit (`NSColor`), Foundation (`NSRegularExpression`), XCTest.

**Spec:** User feedback on live UI and ergonomics:
1. Standard Filename Pattern naming (no "Autolab").
2. No `instrument/examples` folder or `-example` renaming.
3. Fix Col 9/9, Include All, Auto-Skip button sizing and expand button alignment using universal tokens.
4. Preview default 25 (not 50).
5. Clean grammar dropdown in Raw Stream Studio (single menu, no weird double row or duplicate "+ Create New").
6. Remove "Data Channel (Aux)" option in card header.
7. Show Progression type/behavior annotations in cards; allow typing custom progression names.

## Global Constraints

- **Scientific Data Immutability:** Raw data files in project data roots are strictly read-only.
- **Universal Design System:** Every button and control in the toolbar must use `AppTypography` and uniform 24pt height tokens.
- **Plain Register:** Short imperative sentences.

## Review Focus

- Typing into the template field must update token chips immediately even if trailing tokens don't match.
- Columns marked as Custom Progression must persist their custom dimension name to YAML.
- Preview defaults to 25 and respects the expand/collapse button.
- Deleting `instrument/examples` references must cause zero crashes or file I/O errors.
- All existing tests plus new tests must pass.

---

### Task 1: Rename Canonical Global Grammar & Update Core Tests

**Files:**
- Modify: `Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift:105-135`
- Modify: `Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift`

**Interfaces:**
- Consumes: `FilenameGrammarCatalog.standardDefaults`
- Produces: `FilenameGrammar` with `id: "standard-scientific"` and `name: "Standard Filename Pattern"`

- [ ] **Step 1: Write failing unit test for canonical naming**

```swift
func testStandardDefaultsCanonicalNaming() {
    let defaults = FilenameGrammarCatalog.standardDefaults
    XCTAssertFalse(defaults.isEmpty)
    let first = defaults[0]
    XCTAssertEqual(first.id, "standard-scientific")
    XCTAssertEqual(first.name, "Standard Filename Pattern")
    XCTAssertFalse(first.name.contains("Autolab"))
    XCTAssertTrue(first.isDefault)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FilenameGrammarEngineTests/testStandardDefaultsCanonicalNaming`
Expected: FAIL.

- [ ] **Step 3: Update `FilenameGrammarEngine.swift` standardDefaults**

Change `id: "autolab-scientific"` to `"standard-scientific"` and `name: "Autolab USTH Scientific Pattern"` to `"Standard Filename Pattern"`.
Update any existing tests in `FilenameGrammarEngineTests.swift` that checked for `"autolab-scientific"` to use `"standard-scientific"`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FilenameGrammarEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift
git commit -m "feat(grammar): rename default pattern to Standard Filename Pattern"
```

---

### Task 2: Remove `-example` Suffix Mutation & Purge Example Directory

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift:203-263, 658-670`
- Modify: `Sources/RawViewApp/Editor/Panels/EditorLeftSidebarView.swift`

**Interfaces:**
- Consumes: `EditorWorkspaceViewModel.selectedSource`, `EditorWorkspaceViewModel.sources`
- Produces: Clean sample binding without touching `.rawviewer/instrument/examples/` or writing `-example.txt` files.

- [ ] **Step 1: Remove `pinCurrentAsExample()` and example directory creation**

In `EditorWorkspaceView.swift`:
1. Remove `pinCurrentAsExample()`.
2. In `saveProfileAndRules()` (lines 658-670), delete the block that creates `.rawviewer/instrument/examples` and writes `-example` files.
3. In `loadRepresentativeSampleForProfile(profileURL:)`, look directly in project sources matching profile name or instrument ID; remove `.rawviewer/instrument/examples` directory scan.

- [ ] **Step 2: Remove any UI references to pinning examples**

In `EditorLeftSidebarView.swift`, verify that no button or menu item calls `pinCurrentAsExample`.

- [ ] **Step 3: Verify build and test suite**

Run: `swift test --parallel` and `./Scripts/check_core.sh`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/RawViewApp/Editor/EditorWorkspaceView.swift Sources/RawViewApp/Editor/Panels/EditorLeftSidebarView.swift
git commit -m "refactor(editor): remove legacy example suffix mutation and directory creation"
```

---

### Task 3: Progressive / Resilient Token Extraction

**Files:**
- Modify: `Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift:306-360`
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift:550-565`
- Test: `Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift`

**Interfaces:**
- Consumes: `FilenameGrammarEngine.extract(from:grammar:)`
- Produces: `ExtractedGrammarFacts` containing partial extracted fields even on trailing mismatch.

- [ ] **Step 1: Write failing unit test for progressive partial extraction**

```swift
func testProgressiveTokenExtractionOnPartialMismatch() {
    let grammar = FilenameGrammar(
        id: "test",
        name: "Test",
        template: "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]_{batch}",
        fields: [
            GrammarField(name: "date", role: "Date & Time", type: .datetime, formatHint: "DDMMYY-HHmmSS"),
            GrammarField(name: "instrument", role: "Instrument", type: .string),
            GrammarField(name: "mode", role: "Mode", type: .string),
            GrammarField(name: "device-id", role: "Device ID", type: .string, stripBrackets: true),
            GrammarField(name: "study", role: "Study", type: .string),
            GrammarField(name: "remarks", role: "Remarks", type: .string, stripBrackets: true, isOptional: true),
            GrammarField(name: "batch", role: "Batch", type: .number, formatHint: "001", isOptional: true)
        ]
    )
    let filename = "271125-000000_autolab.cv_[d01]_kinetics_r.[100mv]-extra.txt"
    let facts = FilenameGrammarEngine.extract(from: filename, grammar: grammar)
    
    XCTAssertEqual(facts.extractedFields["date"], "271125-000000")
    XCTAssertEqual(facts.extractedFields["instrument"], "autolab")
    XCTAssertEqual(facts.extractedFields["mode"], "cv")
    XCTAssertEqual(facts.extractedFields["device-id"], "d01")
    XCTAssertEqual(facts.extractedFields["study"], "kinetics")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FilenameGrammarEngineTests/testProgressiveTokenExtractionOnPartialMismatch`
Expected: FAIL.

- [ ] **Step 3: Implement progressive token extraction in `FilenameGrammarEngine.swift`**

Update `FilenameGrammarEngine.extract`:
1. First, try full regex `^...$`. If matched, return `ExtractedGrammarFacts` with `isMatched = true`.
2. If full match fails, compile progressive prefixes (from N-1 tokens down to 1 token) without trailing anchor to extract all valid preceding variables.
3. Return `ExtractedGrammarFacts(isMatched: false, extractedFields: partialExtracted, ... unmatchedReason: "Partial match: trailing tokens or suffix differs")`.

- [ ] **Step 4: Update `EditorWorkspaceViewModel.updateSampleGrammarFacts()`**

Ensure `sampleExtractedFacts` always provides extracted fields for chips and table even when `isMatched == false`.

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter FilenameGrammarEngineTests`
Expected: PASS.

```bash
git add Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift Sources/RawViewApp/Editor/EditorWorkspaceView.swift
git commit -m "feat(grammar): add progressive token extraction for live typing feedback"
```

---

### Task 4: Impeccable Redesign of Top Command Bar & Profile Selector

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/EditorCenterCanvasView.swift:88-195`

**Interfaces:**
- Consumes: `EditorWorkspaceViewModel.savedProfiles`, `EditorWorkspaceViewModel.editor`
- Produces: Pro macOS native profile dropdown and neutral studio tabs.

- [ ] **Step 1: Redesign Profile Selector and remove clutter in `EditorCenterCanvasView.swift`**

1. Remove 9-dots icon `🎛️` from `profileManagementBar`.
2. Remove `[ ⓘ ]` info button and `showingProfileInfoPopover`.
3. Profile dropdown:
   - Label: `Profile:` (`.secondary`, 11pt semibold).
   - Menu:
     - Active profile name (`.monospaced`, 11pt) with subtle chevron.
     - Items: Saved profiles list with checkmark for current profile.
   - Button `[ + New ]` (`.buttonStyle(.bordered)`, `.controlSize(.small)`): Opens clean duplicate profile popover.
4. Segmented tab switcher: Neutral Pro macOS styling (no electric blue fills).

- [ ] **Step 2: Verify build and test suite**

Run: `./Scripts/check_core.sh`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/RawViewApp/Editor/Panels/EditorCenterCanvasView.swift
git commit -m "feat(editor): impeccable redesign of profile selector and neutral studio tabs"
```

---

### Task 5: Raw Stream Toolbar Ergonomics & Universal Sizing Overhaul

**Files:**
- Modify: `Sources/RawViewApp/Editor/Grid/StreamToolbarCards.swift:214-435`
- Modify: `Sources/RawViewApp/Editor/ParserSettingsCanvasView.swift`

**Interfaces:**
- Consumes: `StreamToolbarCards` Section 2 & 3
- Produces: Clean Grammar menu, universal 24pt buttons for Metadata/Cols/Include/Auto-Skip, and preview defaulted to 25 with aligned expand button.

- [ ] **Step 1: Redesign Grammar selector in `StreamToolbarCards.swift` (Section 2)**

1. Turn Grammar selector into a single clean dropdown menu:
   `Grammar: [ ▾ 🌐 Standard Scientific (Global) ]` (height 24pt).
2. Inside the Menu:
   - Project Grammars section
   - Global Grammars section
   - Divider
   - `+ Create New Grammar…` button (calls `onCreateNewGrammar()`)
3. Delete the redundant second row (`+ Create New Grammar…` button and template text) below the menu.

- [ ] **Step 2: Universal sizing for Section 3 (View & Metadata Controls)**

1. Preview rows:
   - Set default selection to 25 rows (not 50).
   - Standardize Picker height to 24pt.
   - Align the Expand button (`arrow.down.right.and.arrow.up.left`) to strict 24pt height with square 24x24 frame and centered icon.
2. Metadata & Columns bar (Row 2):
   - Metadata Tags button: height 24pt, `.buttonStyle(.bordered)`.
   - `Cols: 9/9` badge: standard font `AppTypography.captionBold` (10.5pt), height 22pt, properly padded with `.padding(.horizontal, 6)`.
   - `Include All`: `.buttonStyle(.bordered)`, height 24pt, `AppTypography.toolbarLabel`.
   - `⊘ Auto-Skip Empty`: `.buttonStyle(.bordered)`, height 24pt, `AppTypography.toolbarLabel`.

- [ ] **Step 3: Verify build and test suite**

Run: `./Scripts/check_core.sh` and `swift test --parallel`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/RawViewApp/Editor/Grid/StreamToolbarCards.swift Sources/RawViewApp/Editor/ParserSettingsCanvasView.swift
git commit -m "feat(stream): clean up grammar menu, default preview to 25, and unify toolbar button sizing"
```

---

### Task 6: Column Header Cards Polish (Progression Hints, Custom Name Popover, Remove Data Channel Option)

**Files:**
- Modify: `Sources/RawViewApp/Editor/Grid/StreamHeaderCardView.swift:245-420, 564-610`
- Modify: `Sources/RawViewApp/Editor/ParserSettingsCanvasView.swift:496-515`

**Interfaces:**
- Consumes: `ColumnDefinition.progressionType`, `ColumnDefinition.progressionBehavior`, `ColumnDefinition.customProgressionName`
- Produces: Detailed Progression cards with type annotations, custom name input, and clean role menu.

- [ ] **Step 1: Remove "Set as Data Channel (Aux)" from the role menu**

In `StreamHeaderCardView.swift` (lines 316-324 and 590-592):
Remove the "Set as Data Channel (Aux)" button. A column that is not X, Y, Progression, or Skip is naturally an auxiliary data channel. If user wants to reset from X/Y/Progression, they can choose from the clean contextual actions or Include Column.

- [ ] **Step 2: Enhance Progression display on Column Header Card**

When `col.role == .progression`:
1. In `rolePillText(col)`: display the specific progression type and behavior:
   - Time: `Time (Cont)` or `Time (Disc)`
   - Scan / Index: `Scan (Disc)` or `Scan (Cont)`
   - Custom: `<CustomName> (Disc)` or `<CustomName> (Cont)`
2. Add a subtle secondary caption badge under the Title/Unit row or in the card header displaying:
   `⏱️ <Type> • <Behavior.capitalized>` (e.g. `⏱️ Scan • Discrete` or `⏱️ pH • Continuous`).

- [ ] **Step 3: Custom Progression Name Popover**

When the user selects "Custom Progression…" in the menu:
Present a compact popover or sheet asking for:
- Progression Name (e.g. `pH`, `Concentration`, `Temperature`, `Gate Voltage`).
- Behavior: Segmented picker `[ Discrete | Continuous ]`.
- Save button: updates `col.customProgressionName`, `col.progressionType = .custom`, `col.progressionBehavior`, and triggers `onUpdateColumn`.

- [ ] **Step 4: Verify build and test suite**

Run: `./Scripts/check_core.sh` and `swift test --parallel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RawViewApp/Editor/Grid/StreamHeaderCardView.swift Sources/RawViewApp/Editor/ParserSettingsCanvasView.swift
git commit -m "feat(cards): polish progression cards with behavior annotations and custom name popover"
```

---

### Task 7: End-to-End Verification & App Packaging

**Files:**
- None (verification & build scripts)

- [ ] **Step 1: Run core checks**

Run: `./Scripts/check_core.sh`
Expected: PASSED.

- [ ] **Step 2: Run index CLI check**

Run: `./Scripts/check_index_cli.sh`
Expected: PASSED.

- [ ] **Step 3: Run full parallel test suite**

Run: `swift test --parallel`
Expected: All tests pass.

- [ ] **Step 4: Re-package application binary**

Run: `./Scripts/package_app.sh`
Expected: Build succeeds and updates `/tmp/RawView.app`.

- [ ] **Step 5: Update graphify knowledge graph**

Run: `graphify update .`
Expected: Graph updated cleanly.
