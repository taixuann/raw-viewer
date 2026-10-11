# Unified 2-Column Profile Editor Studio Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign Profile Editor Studio into a unified 2-column layout: Left Workspace consolidates structural data tables above and instrument identity/token rules below; Right Panel hosts a full-height, publication-grade Live Plot with auto-bound axis titles/units and primary build actions.

**Architecture:** 
- Left/Primary Column: Vertical layout combining `StructuralBoxesCanvasView` (or `EditorCanvasView`) on top with a collapsible/tabbed Specification Hub on the bottom (Instrument Identity, Filename Semantic Tokens, Saved Profiles Library).
- Right Column: Dedicated full-height Live Scientific Plot Studio featuring Explorer-grade plot styling, X/Y column selectors, auto-bound labels (`label (unit)`), compile status capsule, and `Build Profile` (Cmd+S) action button.

**Tech Stack:** Swift 5.10 / macOS 14+, SwiftUI, AppKit, RawViewCore.

**Spec:** In-chat consensus following `/brainstorming` and `/impeccable` design principles.

## Global Constraints
- Pure SwiftUI macOS native styling (`.windowToolbarStyle(.unified)`, macOS controls, zero cross-platform hackery).
- Raw data files in `data/raw/` must remain completely immutable.
- Main actor must remain unblocked at all times (60fps guaranteed).
- No arbitrary fixed percentage presets (`Plot 70%`, `Table 70%`); use natural proportional or flexible split layout.
- Two-way binding for axis titles: editing column label/unit in the data matrix immediately updates the Live Plot axes without double entry.

## Review Focus
1. Switching between sample files updates both structural boxes and live plot without UI lag or stale data.
2. Editing column label or unit in the matrix immediately propagates to the live plot axis title.
3. Full height of right plot studio preserves proper scientific aspect ratio (4:3 or square) without distortion.
4. "Build Profile" (Cmd+S) properly compiles and writes YAML to `.rawviewer/instrument/<id>.yaml` and updates the active profile list.
5. All automated checks (`check_core.sh`, `check_index_cli.sh`, `package_app.sh`) pass cleanly.

---

### Task 1: Refactor LiveSandboxPlotView for Dedicated Right-Column Studio

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorCanvasViews.swift`

- [x] Remove redundant manual custom axis title inputs inside `LiveSandboxPlotView` and bind `activeXLabel` and `activeYLabel` directly to the active `ColumnDefinition`'s `label` and `unit`.
- [x] Refactor `LiveSandboxPlotView` header to cleanly show X Column and Y Column pickers with colored accents (Blue for X, Green for Y) and points count badge.
- [x] Add publication plot container styling suitable for a dedicated vertical column (Nature ticks, 4-box closed spine, clear axis typography).
- [x] Verify build and type checking in `Sources/RawViewApp/Editor/EditorCanvasViews.swift`.

---

### Task 2: Build Unified 2-Column Layout in EditorWorkspaceView

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`

- [x] Replace 3-panel `HSplitView` (`leftSidebar`, `centerCanvas`, `rightInspector`) with a 2-panel `HSplitView`:
  - Panel 1 (Left / Primary Workspace):
    - Top Command Bar: Canvas mode switcher (`Structural Boxes` / `Raw Stream`), Auto Detect button, active sample file capsule.
    - Upper Section: Data inspection table (`StructuralBoxesCanvasView` or `EditorCanvasView`).
    - Lower Section (Specification Hub): Unified cards for:
      - Active File & Saved Profiles (quick switch and import YAML).
      - Instrument Identity (ID, Display Name, Delimiters).
      - Filename Semantic Elements (Tags, Roles, universal date-time format, sibling matches).
  - Panel 2 (Right / Live Plot Studio):
    - Full-height `LiveSandboxPlotView`.
    - Bottom Action Bar: Compile Status capsule, `Build Profile` (Cmd+S), and `Test Against Cohort`.
- [x] Remove obsolete hardcoded percentage buttons (`Plot 70%`, `Table 70%`, etc.).
- [x] Verify responsive layout across different window sizes.

---

### Task 3: Full End-to-End Verification & Application Packaging

**Files:**
- Run: `./Scripts/check_core.sh`
- Run: `./Scripts/check_index_cli.sh`
- Run: `./Scripts/package_app.sh`

- [x] Run `./Scripts/check_core.sh` to verify CoreSelfCheck and app layer type checking.
- [x] Run `./Scripts/check_index_cli.sh` to verify CLI test suite.
- [x] Run `./Scripts/package_app.sh` to package `.build/RawView.app`.
- [x] Launch `.build/RawView.app` and verify zero lag with 41,000-line sample files.
