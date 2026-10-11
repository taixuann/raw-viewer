# Streamlined 2-Panel Profile Studio Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate the Profile Editor Studio into an asymmetrical 2-panel architecture (Left: Unified Profile Specification & File Source Sidebar; Right: Full-width Interactive Visual Studio with Data Matrix and Explorer-grade Floating Figure Card). Apply ponytail simplicity and graphify updates.

**Architecture:**
- **Panel 1 (Left Sidebar: `minWidth: 300, idealWidth: 340, maxWidth: 420`)**:
  - Compact File & Profile Source Bar (Active file card with switch/pin buttons + Saved Profiles dropdown menu with load/import actions).
  - Instrument Identity (Profile ID with token picker, Display Name, Delimiter menu).
  - Filename Semantic Tokens (Click-to-add token chips, user-defined tag names, standardized roles, format hint, sibling preview matching).
  - Sticky Footer Actions: Test Against Cohort + prominent `Build Profile` (Cmd+S).
- **Panel 2 (Right Canvas: `minWidth: 500, flexible`)**:
  - Top Command Bar: Canvas mode picker (`[Structural Boxes | Raw Stream]`), Auto Detect heuristics button, and real-time save status capsule.
  - Upper View: Interactive Data Matrix (`StructuralBoxesCanvasView`) with column headers (role pills `[X]`, `[Y]`, Title, Unit) and data rows.
  - Draggable Resizing Divider (smooth vertical height allocation between 15% and 85%).
  - Lower View: Explorer-grade `CenteredFigureView` with floating white card, subtle shadow, Nature ticks, calibrated aspect ratio, and auto-bound axis titles.

---

### Task 1: Reorganize Left Sidebar into Unified Profile & Rules Inspector
**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`

- [x] Combine Active Target File card and Saved Profiles library into a compact top block (Menu dropdown for saved profiles with item count and import action).
- [x] Move Instrument Identity (ID, Display Name, Delimiter) directly into the left sidebar scroll view.
- [x] Move Filename Semantic Elements (token pills, tag inputs, role pickers, format hints, sibling matches) into the left sidebar scroll view.
- [x] Place Test Against Cohort and `Build Profile` (Cmd+S) in a sticky footer at the bottom of the left sidebar.
- [x] Verify build and type checking.

---

### Task 2: Expand Right Canvas to Own the Full Interactive Visual Workspace
**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`

- [x] Remove the obsolete 3rd panel from `HSplitView` so only 2 panels exist: `leftConfigSidebar` and `rightVisualCanvas`.
- [x] Configure `rightVisualCanvas` to house the Command Bar (Mode switch, Auto Detect, Status) and the vertical split (Upper: Data Matrix / Raw Stream; Lower: Explorer-grade Floating Plot Card).
- [x] Ensure non-distorted layout: scrolling and resizing never cause text truncation or container overflow.
- [x] Verify build and type checking.

---

### Task 3: Ponytail Complexity Review & Code Minimization
**Files:**
- Review: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`
- Review: `Sources/RawViewApp/Editor/EditorCanvasViews.swift`

- [x] Run `/ponytail-review` pass: detect dead code, redundant views, unused layout math, speculative abstractions.
- [x] Remove unused methods/enums and simplify View hierarchy.
- [x] Re-run type-check and verification suite.

---

### Task 4: End-to-End Verification, App Packaging, and Graphify Synchronization
**Files:**
- Run: `./Scripts/check_core.sh`
- Run: `./Scripts/check_index_cli.sh`
- Run: `./Scripts/package_app.sh`
- Run: `graphify update .`

- [x] Verify core self-checks and application type-checking pass.
- [x] Verify index CLI tests pass.
- [x] Package release app bundle `.build/RawView.app`.
- [x] Launch application and verify responsive 2-panel layout.
- [x] Update graphify knowledge graph.

