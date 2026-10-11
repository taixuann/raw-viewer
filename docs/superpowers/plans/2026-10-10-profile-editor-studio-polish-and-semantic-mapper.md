# Profile Editor Studio Polish, Dynamic Semantic Token Mapper & 5:5 Full Plot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Polish Profile Editor Studio by splitting the Center Panel 50:50 between Spreadsheet & Full-Dataset Live Plot, adding YAML profile import in the Left Panel, and replacing static category assumptions with a dynamic, user-defined semantic element token mapper with highlight boxes.

**Architecture:** 
- Left Panel: Add `importProfile()` utilizing `NSOpenPanel` to import external YAML profiles into `.rawviewer/instrument/`, save a representative example if desired, and auto-load into the workspace.
- Center Panel: Split into a balanced 50:50 vertical layout (`GeometryReader` / flexible frames). The top 50% renders the streamlined macOS data grid with units integrated into headers (`Quantity [Unit]`) and compact `[X]` / `[Y]` badges. The bottom 50% renders `LiveSandboxPlotView` parsing 100% of all data lines (full dataset resolution) while filtering out header/metadata rows.
- Right Inspector: Replace static token rules with `Dynamic Semantic Token Mapper`: interactive token chips mapped to custom user-defined element cards (Tag Name, Tag Role, Format, Delimiter pattern) with synchronized color highlighting.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (`NSOpenPanel`), RawViewCore (YAMLParser, CategoryRuleEngine, ProjectContext).

**Spec:** User feedback in chat session `2026-10-10`.

## Global Constraints
- Read-only data safety: Never mutate or write to `data/raw`. All profiles are stored in `.rawviewer/instrument/` and semantic rules in `.rawviewer/view/category.yaml`.
- Fast responsiveness: The table matrix displays the first 40 rows for lag-free scrolling, while the plot engine parses full rows asynchronously/efficiently.
- Apple Human Interface Guidelines: Professional, restrained scientific workstation styling.

---

### Task 1: Left Panel Profile Import & Example Seeding
- [ ] Add `importProfile()` in `EditorWorkspaceViewModel` invoking `NSOpenPanel` filtered to `.yaml` files.
- [ ] On file selection, parse/validate YAML via `YAMLParser.parse`, copy to `.rawviewer/instrument/<filename>`, and trigger `loadSavedProfile(url:)`.
- [ ] Add an `Import YAML…` button with icon `square.and.arrow.down.on.square` in `leftSidebar` under Saved Profiles header.
- [ ] Verify core self-checks pass.

### Task 2: Center Panel 50:50 Layout & Full-Dataset Plot Engine
- [ ] Update `centerCanvas` in `EditorWorkspaceView.swift` to use a 50:50 balanced split (`GeometryReader` or equal weighted frames).
- [ ] In `LiveSandboxPlotView` (`EditorCanvasViews.swift`):
  - Ensure `plotData` reads and parses **all** lines of `lines` (the complete file dataset, not limited to preview rows).
  - Cleanly skip all metadata lines and column header lines using `lineTags` and `dataStartIndex`.
  - Add downsampling/stride safeguard if dataset exceeds 50,000 points to keep UI rendering 60fps.
- [ ] Verify plot curve renders complete cyclic loops / spectra across the entire dataset.

### Task 3: Streamlined Data Matrix with Merged Quantity & Unit Headers
- [ ] In `StructuralBoxesCanvasView` (`EditorCanvasViews.swift`):
  - Merge column label and physical unit into a single clean line: e.g. `Potential applied [V]` or `WE(1).Current [A]`.
  - Replace bulky toggles with compact, elegant `[X]` (blue capsule) and `[Y]` (green capsule) indicator buttons.
  - Streamline cell paddings and font hierarchy according to macOS data grid standards.

### Task 4: Dynamic Semantic Token Mapper in Right Inspector
- [ ] Define `SemanticTokenElement` struct in `EditorWorkspaceModel.swift` or `CategoryRuleEngine.swift` containing:
  - `token: String`
  - `userTagName: String` (e.g. "Date", "Sample ID", "Condition", "Operator", or any custom tag)
  - `role: SemanticElementRole` (`.category`, `.legendLabel`, `.metadata`, `.ignored`)
  - `formatHint: String` (e.g. "DDMMYY-HHMMSS")
  - `colorIndex: Int`
- [ ] In `EditorWorkspaceView.swift`:
  - Render the selected filename broken into interactive tokens with distinct color highlights.
  - For each active element, render a dedicated card/box allowing the user to type their custom Tag Name, choose Role, and specify format.
  - Update `updateSiblingPreviews()` and `saveProfileAndRules()` to serialize these dynamic definitions into `.rawviewer/view/category.yaml`.

### Task 5: Verification, Code Review & App Packaging
- [ ] Run `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh`.
- [ ] Run `graphify update .`.
- [ ] Run Ponytail Review pass to eliminate redundant abstractions.
- [ ] Dispatch Senior Code Review subagent for independent verification.
- [ ] Rebuild and package `.build/RawView.app` using `./Scripts/package_app.sh`, launch the app, and finalize goal.
