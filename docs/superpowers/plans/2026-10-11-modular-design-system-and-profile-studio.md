# Whole-Codebase Modularization & Deep Design System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose monolithic files across RawViewApp and RawViewCore into focused, cohesive, deep modules following `codebase-design` principles, providing a centralized dynamic Design System (typography, colors, button and input primitives), modular stream parsing & metadata grids, and decomposed explorer inspectors, while guaranteeing 100% zero-regression and character-by-character semantic parity.

**Architecture:** Decompose code along deep functional seams rather than superficial technical layers. Provide a single centralized Design System (`Sources/RawViewApp/DesignSystem/`) scaling with `@AppStorage("uiFontSize")`. Break the remaining oversized views (`ParserSettingsCanvasView.swift`, `RawViewApp.swift`, `ProjectGalleryViews.swift`, `InstrumentReader.swift`) into bounded components where each file has a single responsibility. Enforce continuous build, test, and release verification after each extraction task.

**Tech Stack:** Swift 5.10+, SwiftUI, AppKit, SQLite3 (WAL mode), XCTest / Swift Testing.

**Spec:** Brainstorming session recorded in initiative `kp-4806b1ed17534409ac6be1f7fbb02bd8` and `docs/superpowers/plans/2026-10-11-modular-design-system-and-profile-studio.md`.

## Global Constraints

- Never mutate or delete underlying raw measurement files (`.csv`, `.txt`, `.lvm`) under project data roots.
- Maintain 100% test passing parity (all 236 tests in 10 test suites must pass at every task boundary).
- Zero SQLite writes outside `<project>/.rawviewer/` (invariant contract).
- Every typography and UI element must dynamically scale with user preference `@AppStorage("uiFontSize")` (baseline 12.0 pt).
- In each extraction task, extract exact original code verbatim to ensure zero accidental behavior drift, verify cleanly, then adopt shared Design System primitives.

## Review Focus

1. **Font Scale Non-Regression:** Ensure all extracted views receive or observe `uiFontSize` correctly so text does not freeze at default sizes.
2. **Matrix Grid Column Alignment:** Ensure `uniformColumnWidth` and column count calculations in `StreamRowView` remain strictly identical to guarantee 100% vertical grid alignment between header, metadata, and numeric matrix cells.
3. **Metadata Cell Popover Anchoring:** Ensure `MetadataCellPopoverView` stays correctly anchored to the clicked cell token and adjacent tokens are preserved for auto-suggestions.
4. **AppKit / Window Integration:** When decomposing `RawViewApp.swift`, ensure `WindowGroup`, menu commands, hotkeys, and app lifecycle state machines remain uncompromised.
5. **Thread Safety & Concurrency:** Keep all background inspection and index database access off `@MainActor`.

---

### Task 1: Centralized Design System Module (`AppTypography`, `AppColors`, `StudioControls`)

**Files:**
- Create: `Sources/RawViewApp/DesignSystem/AppTypography.swift`
- Create: `Sources/RawViewApp/DesignSystem/AppColors.swift`
- Create: `Sources/RawViewApp/DesignSystem/StudioControls.swift`
- Modify: `Sources/RawViewApp/Editor/StudioTokens.swift`
- Test: `Tests/RawViewCoreTests/ScientificTypographyTests.swift`

**Interfaces:**
- Consumes: `@AppStorage("uiFontSize") private var uiFontSize: Double = 12.0`
- Produces: `AppTypography.font(size:weight:design:uiFontSize:)`, `AppColors.Role`, `StudioButton`, `StudioRolePill`, `StudioSegmentPicker`

- [ ] **Step 1: Create `AppTypography.swift`**

Extract and extend dynamic typography scaling rules from `StudioTokens.swift` into `Sources/RawViewApp/DesignSystem/AppTypography.swift` with standard roles:
`title`, `sectionHeadline`, `body`, `bodySemibold`, `toolbarLabel`, `description`, `caption`, `captionBold`, `monoCell`, `monoBadge`.

- [ ] **Step 2: Create `AppColors.swift`**

Define unified semantic color tokens for column roles (`.x`, `.y`, `.progression`, `.skip`, `.channel`), status badges, and 12-color stream palette (`AppColors.palette`).

- [ ] **Step 3: Create `StudioControls.swift`**

Implement reusable atom buttons:
- `StudioActionButton`: standard 24pt height button with dynamic illumination (`isIlluminated`, `isActive`).
- `StudioRolePill`: compact capsule badge displaying role with 2-tier context submenu.
- `StudioSegmentPicker`: styled segmented control for mode switching.

- [ ] **Step 4: Verify Compilation & Core Self-Check**

Run: `./Scripts/check_core.sh`
Expected: App layer type-check passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/RawViewApp/DesignSystem/
git commit -m "feat(design-system): introduce centralized AppTypography, AppColors, and StudioControls"
```

---

### Task 2: Decompose `ParserSettingsCanvasView` into Toolbar Cards, Header Cells, and Stream Rows

**Files:**
- Create: `Sources/RawViewApp/Editor/Grid/StreamToolbarCards.swift`
- Create: `Sources/RawViewApp/Editor/Grid/StreamHeaderCardView.swift`
- Create: `Sources/RawViewApp/Editor/Grid/StreamRowView.swift`
- Modify: `Sources/RawViewApp/Editor/ParserSettingsCanvasView.swift`

**Interfaces:**
- Consumes: `ColumnDefinition`, `MetadataCellTag`, `LineRegionType`, `AppTypography`, `AppColors`
- Produces: Decomposed grid components reducing `ParserSettingsCanvasView.swift` from ~2,150 lines to < 500 lines.

- [ ] **Step 1: Extract `StreamToolbarCards.swift`**

Extract the 4 top control cards (Delimiter & Decimal card, Row bounds card, Metadata & Preview rows card, Auto-detect & Apply card) into `StreamToolbarCards.swift`.

- [ ] **Step 2: Extract `StreamHeaderCardView.swift`**

Extract column header card (Raw mode vs Configured Card mode, `#colIdx`, Title textfield, slash delimiter, `UnitAutocompleteField`, Role pill) into `StreamHeaderCardView.swift`.

- [ ] **Step 3: Extract `StreamRowView.swift`**

Extract individual row rendering (Line number badge, token cell loop, selection highlight, `streamRowContextMenu`) into `StreamRowView.swift`.

- [ ] **Step 4: Update `ParserSettingsCanvasView.swift` to assemble modular components**

Replace inline bodies in `ParserSettingsCanvasView.swift` with the extracted child views.

- [ ] **Step 5: Verify character & layout parity**

Run: `./Scripts/check_core.sh` and `swift test --parallel`
Expected: All 236 tests pass, 0 type-check errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/RawViewApp/Editor/Grid/ Sources/RawViewApp/Editor/ParserSettingsCanvasView.swift
git commit -m "refactor(editor): decompose ParserSettingsCanvasView into modular StreamToolbar, HeaderCard, and StreamRow"
```

---

### Task 3: Decompose Metadata Interactive Tagger & Popovers

**Files:**
- Create: `Sources/RawViewApp/Editor/Metadata/MetadataCellPillView.swift`
- Create: `Sources/RawViewApp/Editor/Metadata/MetadataCellPopoverView.swift`
- Create: `Sources/RawViewApp/Editor/Metadata/MetadataSummaryPopover.swift`
- Modify: `Sources/RawViewApp/Editor/StructuralBoxesCanvasView.swift`
- Modify: `Sources/RawViewApp/Editor/Grid/StreamRowView.swift`

**Interfaces:**
- Consumes: `MetadataCellTag`, `CellTarget`, `onTagMetadataCell`, `onRemoveMetadataTag`
- Produces: Isolated metadata components with zero cross-file duplication.

- [ ] **Step 1: Extract `MetadataCellPopoverView.swift`**

Move `MetadataCellPopoverView` struct (Value display, Entity Type picker, Parameter Key suggestions, Format field) into its own file under `Sources/RawViewApp/Editor/Metadata/`.

- [ ] **Step 2: Extract `MetadataCellPillView.swift`**

Unify the metadata cell pill rendering used across both `StructuralBoxesCanvasView` and `StreamRowView` into `MetadataCellPillView.swift`.

- [ ] **Step 3: Extract `MetadataSummaryPopover.swift`**

Move the overall metadata tags list popover content (`metadataPopoverContent`) into `MetadataSummaryPopover.swift`.

- [ ] **Step 4: Verify integration**

Run: `./Scripts/check_core.sh` and `swift test --parallel`
Expected: All 236 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RawViewApp/Editor/Metadata/ Sources/RawViewApp/Editor/StructuralBoxesCanvasView.swift Sources/RawViewApp/Editor/Grid/StreamRowView.swift
git commit -m "refactor(editor): unify and extract MetadataCellPopover, MetadataCellPill, and MetadataSummary"
```

---

### Task 4: Decompose `EditorWorkspaceView` (Profile Studio 3-Panel Shell)

**Files:**
- Create: `Sources/RawViewApp/Editor/Panels/EditorLeftSidebarView.swift`
- Create: `Sources/RawViewApp/Editor/Panels/EditorCenterCanvasView.swift`
- Create: `Sources/RawViewApp/Editor/Panels/EditorRightInspectorView.swift`
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`

**Interfaces:**
- Consumes: `EditorWorkspaceModel`, `RawViewModel`, `ProjectContext`
- Produces: `EditorLeftSidebarView` (target file & library), `EditorCenterCanvasView` (50:50 table & live plot), `EditorRightInspectorView` (identity, tokens, column roles).

- [ ] **Step 1: Extract `EditorLeftSidebarView.swift`**

Extract `leftSidebar` (Active Target File card, Profile Library scan, Import YAML button) into `EditorLeftSidebarView.swift`.

- [ ] **Step 2: Extract `EditorCenterCanvasView.swift`**

Extract `centerCanvas` (Dual-mode Switcher, Split layout, Table container, Live Sandbox Studio plot) into `EditorCenterCanvasView.swift`.

- [ ] **Step 3: Extract `EditorRightInspectorView.swift`**

Extract `rightInspector` (Instrument Identity card, Filename Token Rules mapper, Column Definitions & Roles list, YAML compile/save actions) into `EditorRightInspectorView.swift`.

- [ ] **Step 4: Update `EditorWorkspaceView.swift` to assemble panels**

Reduce `EditorWorkspaceView.swift` to clean container shell linking ViewModel with the 3 panels.

- [ ] **Step 5: Verify build & tests**

Run: `./Scripts/check_core.sh` and `swift test --parallel`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RawViewApp/Editor/Panels/ Sources/RawViewApp/Editor/EditorWorkspaceView.swift
git commit -m "refactor(editor): decompose EditorWorkspaceView into LeftSidebar, CenterCanvas, and RightInspector panels"
```

---

### Task 5: Decompose Explorer Shell (`RawViewApp.swift` & `ProjectGalleryViews.swift`)

**Files:**
- Create: `Sources/RawViewApp/Explorer/ExplorerSidebarView.swift`
- Create: `Sources/RawViewApp/Explorer/ExplorerCenterPlotView.swift`
- Create: `Sources/RawViewApp/Explorer/ExplorerInspectorView.swift`
- Create: `Sources/RawViewApp/Explorer/ExplorerToolbarCommands.swift`
- Modify: `Sources/RawViewApp/RawViewApp.swift`
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift`

**Interfaces:**
- Consumes: `RawViewModel`, `ProjectIndexStore`, `MeasurementCache`
- Produces: Clean, modular App shell where `RawViewApp.swift` serves as high-level application orchestrator (~300 lines instead of 2,476 lines).

- [ ] **Step 1: Extract `ExplorerSidebarView.swift`**

Extract `ProjectSourcesSidebar`, search bar, study manifest filter, category grouping tree list into `ExplorerSidebarView.swift`.

- [ ] **Step 2: Extract `ExplorerCenterPlotView.swift`**

Extract the main scientific plot viewer, toolbar mode buttons (Plot vs Data table, Preset picker, Snapshot, Export, Build Profile button) into `ExplorerCenterPlotView.swift`.

- [ ] **Step 3: Extract `ExplorerInspectorView.swift`**

Extract `InspectorPane`, series details, metadata summary, quality inspection banners into `ExplorerInspectorView.swift`.

- [ ] **Step 4: Extract `ExplorerToolbarCommands.swift`**

Extract macOS App menu commands, keyboard shortcuts, and file open panels into `ExplorerToolbarCommands.swift`.

- [ ] **Step 5: Verify full-app build and run release verification**

Run: `./Scripts/check_core.sh`
Run: `swift test --parallel`
Run: `./Scripts/package_app.sh`
Expected: 100% build complete, all 236 tests pass, packaged app signed and verified.

- [ ] **Step 6: Commit**

```bash
git add Sources/RawViewApp/Explorer/ Sources/RawViewApp/RawViewApp.swift Sources/RawViewApp/ProjectGalleryViews.swift
git commit -m "refactor(explorer): decompose monolithic RawViewApp and ProjectGalleryViews into dedicated Explorer modules"
```

---

### Task 6: Whole-Branch Parity Audit & Final Integration

**Files:**
- Verify: Full codebase diff against `master`
- Check: All line counts across `Sources/`

- [ ] **Step 1: Run line count audit**

Confirm no single view file exceeds ~600 lines.

- [ ] **Step 2: Run all verification scripts**

```bash
./Scripts/check_core.sh
./Scripts/check_index_cli.sh
swift test --parallel
./Scripts/package_app.sh
```

- [ ] **Step 3: Launch app and smoke test**

Launch the release binary and verify Explorer, Profile Studio, Live Sandbox, and Settings render at 60 FPS with full parity.

- [ ] **Step 4: Final commit & ready for merge**

```bash
git status
```
