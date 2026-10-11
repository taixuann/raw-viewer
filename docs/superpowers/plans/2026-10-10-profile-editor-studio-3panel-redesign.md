# Profile Editor Studio 3-Panel Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the Profile Editor Studio into a scientific workstation with a clean 3-panel architecture: (1) Active File Card & Saved Profiles Library on the left, (2) Dual View Data Matrix & Interactive Live Sandbox Plot with dynamic X/Y channel selectors in the center, and (3) Structured Specification with dedicated Filename Token Rules and clear scientific column roles (X / Y / Aux) on the right.

**Architecture:** Refine `Sources/RawViewApp/Editor/EditorWorkspaceView.swift` and `Sources/RawViewApp/Editor/EditorCanvasViews.swift`. Scan `.rawviewer/instrument/` for saved profiles; provide interactive dropdown selectors for $(X, Y)$ curve plotting in `LiveSandboxPlotView`; reorganize the right inspector into 3 distinct sections (Identity, Filename Patterns, Column Mapping).

**Tech Stack:** Swift, SwiftUI, RawViewCore, AppKit.

**Spec:** In-chat consensus from user review of running app screenshot `media_1791615115561_c64319ff.png`.

## Global Constraints
- Preserve raw data immutability: files in `data/raw/` are strictly read-only.
- All writes remain sandboxed under `<project>/.rawviewer/instrument/`.
- No external dependencies; native SwiftUI components and system controls only.
- Verification gates: `Scripts/check_core.sh` and `Scripts/check_index_cli.sh` must pass cleanly without warnings.

## Review Focus
- Switching active sample file or loading a saved profile must not corrupt editor state.
- Interactive X/Y channel pickers in Live Sandbox must handle non-numeric or empty columns gracefully.
- Token selection changes must immediately refresh sibling live previews.
- Column mapping role buttons must be mutually exclusive (setting X clears Y and vice versa).

---

### Task 1: Left Panel Redesign - Active Target File Card & Saved Profiles Library

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`

**Steps:**
- [ ] In `EditorWorkspaceViewModel`, add `savedProfiles: [URL]` and `func refreshSavedProfiles()`.
- [ ] Add `func loadSavedProfile(url: URL)` to parse and load an existing YAML profile into the editor.
- [ ] Replace the 20-sample-file list in `leftSidebar` with:
  - `Active Target File Card`: Shows filename, path, size, line count, and a menu button to switch sample to another file in the project.
  - `Saved Profiles Library`: Lists all `.yaml` files in `.rawviewer/instrument/`, with a badge and click-to-load action.
- [ ] Remove the filename token segmenter from the left panel (it moves to the right panel in Task 3).
- [ ] Verify that selecting a saved profile loads its metadata and column definitions into the editor.

---

### Task 2: Center Panel Redesign - Interactive Live Sandbox Studio with X & Y Channel Pickers

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorCanvasViews.swift`
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`

**Steps:**
- [ ] Update `LiveSandboxPlotView` in `EditorCanvasViews.swift` to accept `@Binding var selectedXCol: String?` and `@Binding var selectedYCol: String?`.
- [ ] Add a channel picker header in `LiveSandboxPlotView`:
  - `Picker("X Axis", selection: $selectedXCol)` listing all available columns.
  - `Picker("Y Axis", selection: $selectedYCol)` listing all available columns.
  - Dynamic curve rendering that graphs the selected $(X, Y)$ pair in real-time.
- [ ] If no specific $X$ or $Y$ is selected, default to the column marked `isXAxis` and the first column marked `isYAxis`.
- [ ] In `EditorWorkspaceView.swift`, wire up state bindings for `sandboxXCol` and `sandboxYCol` to `LiveSandboxPlotView`.
- [ ] Verify that switching X or Y dropdowns immediately re-plots the curve on the canvas.

---

### Task 3: Right Panel Redesign - Dedicated Filename Token Section & Clear Column Roles

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`
- Modify: `Sources/RawViewApp/Editor/EditorCanvasViews.swift`

**Steps:**
- [ ] In `EditorWorkspaceView.swift`, reorganize `rightInspector` into 3 explicit sections:
  1. `Section 1: Instrument Identity`: ID, Name, Delimiter, Decimal separator.
  2. `Section 2: Filename Token Rules`: Interactive token pills (`Mã mẫu / Device ID`, `Phân loại / Category`) with Live Sibling Preview.
  3. `Section 3: Column Mapping & Roles`: Column table.
- [ ] In `Section 3: Column Mapping`, remove confusing terms ("sweep / signal") and replace with clear scientific role toggles:
  - `[X]` Trục X (Hoành độ)
  - `[Y]` Trục Y (Đo lường)
  - `[Aux]` Phụ trợ (Bỏ qua)
- [ ] Ensure role selection is mutually exclusive per column and updates both the right panel and the center spreadsheet header cards.
- [ ] In `StructuralBoxesCanvasView`, update `columnHeaderCard` menu labels from "Sweep" / "Signal" to "X Axis" / "Y Axis" / "Auxiliary".

---

### Task 4: Verification, AST Knowledge Graph, and Quality Review

**Files:**
- Verify: `Scripts/check_core.sh`
- Verify: `Scripts/check_index_cli.sh`
- Build: `Scripts/package_app.sh`

**Steps:**
- [ ] Run `./Scripts/check_core.sh` to confirm core self-check and app layer type-check pass.
- [ ] Run `./Scripts/check_index_cli.sh` to confirm CLI end-to-end indexer tests pass.
- [ ] Run `graphify update .` to update the AST knowledge graph.
- [ ] Perform Ponytail Review to eliminate dead code or redundant abstraction.
- [ ] Dispatch code reviewer subagent for whole-branch review.
- [ ] Build and verify packaged application bundle with `./Scripts/package_app.sh`.
