# Profile Editor Comprehensive Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Overhaul Profile Editor by: (1) scanning all profile locations for the library; (2) upgrading Live Sandbox Plot to a publication-grade scientific chart with axes labels, ticks, nice intervals, grid, and custom axis titles; (3) replacing rigid token heuristics with user-defined element tokens having standardized domain types (`Instrument`, `Mode`, `Study`, `Library`, `Device ID`, `Date & Time`, `Remarks`) and universal date-time format specifications (`DDMMYYYY-HHmmSS` / `DDMMYY-HHmmSS`); (4) removing redundant Column Definitions from the Right Inspector and centralizing complete column editing and axis assignment into the Center Panel table headers while fixing unit formatting.

**Architecture:**
- **Profile Discovery**: In `EditorWorkspaceViewModel.refreshSavedProfiles()`, scan `.rawviewer/instrument/`, `data/.rawview/instrument/`, `data/instruments/`, and system sample profiles (`Examples/rawview/`), gathering all unique YAML profiles.
- **Scientific Live Sandbox Plot**: In `LiveSandboxPlotView` (`EditorCanvasViews.swift`), draw axes with ticks, numerical tick labels calculated via nice number intervals, subtle grid lines, closed box border, and user-editable X and Y axis titles.
- **Dynamic Semantic Token Element System**: Standardize `SemanticTokenElement.role` with allowed types: `Instrument`, `Mode`, `Study`, `Library`, `Device ID`, `Date & Time`, `Remarks`. Add `dateTimeFormat` property supporting universal format specs (`DDMMYYYY-HHmmSS`, `DDMMYY-HHmmSS`).
- **Center-Focused Column Architecture**: Delete redundant Section 3 in Right Inspector. In Center Panel `StructuralBoxesCanvasView`, preserve and display full column labels and physical units without truncation, and provide popover/inline editors for renaming and axis role mapping.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit, RawViewCore.

## Global Constraints
- Read-only data safety: Never modify `data/raw`.
- Profiles saved to `.rawviewer/instrument/<id>.yaml` and view rules to `.rawviewer/view/category.yaml`.
- Clean compilation passing `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh`.

---

### Task 1: Comprehensive Multi-Directory Profile Discovery
- [ ] Update `refreshSavedProfiles()` in `EditorWorkspaceView.swift` to scan:
  - `<project>/.rawviewer/instrument/`
  - `<project>/data/.rawview/instrument/`
  - `<project>/data/instruments/`
  - App Examples directory (`Examples/rawview/` or bundle resources)
- [ ] Deduplicate profiles by filename / instrument ID.
- [ ] Verify that existing project profiles appear immediately in the Left Panel library list.

### Task 2: Standardized Universal Semantic Token Elements & Date Format
- [ ] Update `SemanticTokenElement` in `CategoryRuleEngine.swift`:
  - `role`: Standardized to `[Instrument, Mode, Study, Library, Device ID, Date & Time, Remarks]`
  - `formatHint`: Support universal date-time formats (`DDMMYYYY-HHmmSS`, `DDMMYY-HHmmSS`, etc.)
- [ ] In `EditorWorkspaceView.swift`:
  - Update Section 2 UI to show token chips with a picker offering the exact standardized roles.
  - When role is `Date & Time`, provide a format input / preset picker for `DDMMYYYY-HHmmSS` and `DDMMYY-HHmmSS`.
  - Let users freely name and assign each token without system auto-guess overriding user intent.
- [ ] Update serialization in `CategoryRuleEngine.save` and `parse`.

### Task 3: Publication-Grade Live Sandbox Plot
- [ ] In `LiveSandboxPlotView` (`EditorCanvasViews.swift`):
  - Add state/binding for `xAxisTitle: String` and `yAxisTitle: String` (defaulting to the selected column label + unit).
  - Compute nice ticks for min/max on both X and Y axes (e.g. 4-5 ticks per axis with scientific/decimal formatting).
  - Render axis lines, outward/inward tick marks, numerical tick labels, subtle grid lines, and axis title labels.
  - Maintain 100% full dataset resolution with robust numerical parsing.

### Task 4: Center Panel Column Unification & Right Inspector Slimming
- [ ] In `EditorWorkspaceView.swift`:
  - Remove Section 3 ("Column Definitions & Roles") completely from `rightInspector`.
  - Right Inspector now focuses strictly on: (1) Instrument Identity, (2) Filename Semantic Elements, (3) Cohort Test & Save Profile.
- [ ] In `StructuralBoxesCanvasView` (`EditorCanvasViews.swift`):
  - Fix unit display in `columnHeaderCard` so units are never lost or truncated.
  - Show full `name [unit]` with clear badge indicators `[X]`, `[Y]`, `[Aux]`.
  - Add quick action / menu to edit axis title and update plot bindings.

### Task 5: Verification, Packaging & Delivery
- [ ] Run `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh`.
- [ ] Run `graphify update .`.
- [ ] Run Ponytail Review pass to check simplicity and eliminate unnecessary code.
- [ ] Build release package via `./Scripts/package_app.sh`, launch the app, and confirm.
