# Profile Editor Studio 3-Panel Impeccable Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the clean 3-Panel macOS desktop architecture in Profile Editor Studio, incorporating Explorer-grade floating card figure styling in the center panel, preventing horizontal and vertical overflow, and neatly separating concerns.

**Architecture:**
- **Panel 1 (Left Sidebar, idealWidth: 260, minWidth: 220, maxWidth: 320)**:
  - Active Target File Card (filename, path, line count, byte size, switch sample menu, pin as example).
  - Saved Profiles Library (scanned YAML profiles, 1-click loading, import YAML button).
- **Panel 2 (Center Canvas & Figure, minWidth: 500, flexible)**:
  - Top Command Bar: Canvas mode picker (`[Structural Boxes | Raw Stream]`), Auto Detect heuristics button, and live profile save status capsule.
  - Upper View: Interactive Data Matrix (`StructuralBoxesCanvasView`) with clean column header cards and data preview rows.
  - Divider: Proportional, draggable divider bounded between 15% and 85% with safe minHeight guards.
  - Lower View: `LiveSandboxPlotView` redesigned with **Explorer-style `CenteredFigureView` & `floatingCard`** (fixed scientific aspect ratio ~1.182, white background with subtle rounded corner shadow, closed Nature spines, outward ticks, auto-bound axis labels).
- **Panel 3 (Right Inspector, idealWidth: 320, minWidth: 280, maxWidth: 420)**:
  - Instrument Identity (Profile ID with token picker, Display Name, Delimiter picker).
  - Filename Semantic Tokens (Click-to-add tokens, user-defined tag names, standardized roles, universal date format hints, live sibling preview matching).
  - Footer Action Section: Test Against Cohort button & primary `Build Profile` (`Cmd+S`) button.

---

### Task 1: Redesign LiveSandboxPlotView with Explorer-Style Floating Figure Card
**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorCanvasViews.swift`

- [x] Wrap the canvas plot in `LiveSandboxPlotView` with a centered floating figure card matching Explorer (`CenteredFigureView` and `floatingCard` with white card background, subtle shadow, and calibrated aspect ratio).
- [x] Ensure the plot never stretches to extreme distorted aspect ratios; preserve clean square / 4:3 scientific dimensions.
- [x] Maintain auto-bound axis titles: `col.label (col.unit)` directly bound from `StructuralBoxesCanvasView`.
- [x] Verify build and type checking in `EditorCanvasViews.swift`.

---

### Task 2: Reconstruct 3-Panel Layout in EditorWorkspaceView
**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`

- [x] Reconfigure top-level `HSplitView` to 3 panels:
  - `leftSidebar`: Active File card + Saved Profiles library.
  - `centerCanvas`: Top command bar + Split data matrix (upper) and Explorer floating plot card (lower).
  - `rightInspector`: Instrument Identity + Filename Semantic Tokens + Cohort Testing & Build Profile.
- [x] Remove awkward tabbed specification hub that caused vertical text squishing.
- [x] Ensure all panels have explicit `minWidth`, `idealWidth`, `maxWidth` and scroll views to prevent any screen overflow.
- [x] Verify build and type checking.

---

### Task 3: Full End-to-End Verification & Packaging
**Files:**
- Run: `./Scripts/check_core.sh`
- Run: `./Scripts/check_index_cli.sh`
- Run: `./Scripts/package_app.sh`

- [x] Verify core self-check and app type-check.
- [x] Verify index CLI tests.
- [x] Package app bundle `.build/RawView.app`.
- [x] Launch application and verify responsive 3-panel layout.
