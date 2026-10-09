# Plot Styling & Nature Typography Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement interactive plot render modes (Line, Scatter, Line + Scatter, Smooth Spline) with customizable dot/line sizes, and upgrade NativePlot to strict Nature Single publication specifications (`nature-single.yaml`) with adaptive font scaling, clean outward ticks, and responsive layout.

**Architecture:** Add `PlotRenderStyle` enum and controls to `RawViewModel` and `InspectorPane`, extend `NativePlot` canvas drawing to support points and cubic splines, implement adaptive viewport typography scaling tied to `@AppStorage("uiFontSize")`, and align ticks and spines with canonical Nature single-column parameters ($59.1 \times 50.0\text{ mm}$ ratio, $0.8\text{ pt}$ spines, $4.25\text{ pt}$ outward ticks).

**Tech Stack:** Pure native Swift, SwiftUI (`Canvas`, `GraphicsContext`, `Path`), AppKit (`NSFont`, `NSColor`), CoreGraphics.

**Spec:** Canonical Nature single-column preset specification at `/Users/tai/research-projects/tools/figrecipe/presets/nature-single.yaml`.

## Global Constraints
- Pure native Swift linking macOS system frameworks only (zero Python or external binaries).
- 100% backward compatible with existing YAML instrument profiles and cached index databases.
- All core and app verification gates must pass cleanly via `./Scripts/check_core.sh`.
- Non-destructive updates: existing feature sets (snapshots, series visibility, draggable legend, pinch/drag zoom) must continue functioning seamlessly.

## Review Focus
1. **Large vs Small Display Scaling**: Verify typography remains legible and proportioned when resizing from minimum window width ($880\text{ pt}$) to full-screen 4K Retina.
2. **Scatter Performance**: Ensure scatter point drawing over large datasets (thousands of rows) uses efficient batch drawing without UI stalls.
3. **Spline Edge Cases**: Handle datasets with duplicate X values, vertical drops, and gaps (`nil` values) without bezier overshoot or crashing.
4. **Settings Live Reactivity**: Changing `uiFontSize` or `defaultLineWidth` in Settings (`Cmd + ,`) must immediately reflect on open plots.
5. **Tick Overlap Avoidance**: Outward ticks and tick labels must never collide with axis titles, even with multi-digit or logarithmic notations.

---

## Ponytail & Impeccable Audit Summary

### Impeccable Review Findings
- **Defect 1 (Static Typography in Scaled Canvas)**: Hardcoding `10.5 pt` tick labels inside a $1000\text{ pt}$ canvas creates a miniature text defect where figures look empty. Fix: Apply adaptive scaling formula $\text{fontScale} = \max(1.0, \min(1.6, \text{plotW} / 480.0)) \times (\text{uiFontSize} / 12.0)$.
- **Defect 2 (Missing Render Modes)**: Empirical scientific data (especially resistance switching, retention, endurance, and discrete spectroscopy) requires scatter points and scatter-over-line modes to be scientifically interpretable.
- **Defect 3 (Tick Geometry Discrepancy)**: Current inward/outward tick length ($5.0\text{ pt}$ / $0.9\text{ pt}$ width) drifts from Nature's $1.5\text{ mm}$ ($4.25\text{ pt}$) length, $0.28\text{ mm}$ ($0.8\text{ pt}$) thickness, and strict outward direction.

### Ponytail Complexity Audit
- `delete:` Do not create a separate plugin or complex spline calculation library. A 20-line Catmull-Rom to cubic Bezier conversion directly using CoreGraphics `Path.addCurve` is sufficient.
- `shrink:` Consolidate plot styling properties into `RawViewModel` and pass them cleanly into `NativePlot` without wrapping in extra intermediate controller classes.
- `yagni:` Avoid per-point individual styling configurations. Series-level and plot-level styling covers 100% of single and multi-cohort comparison use cases.
- `net:` Clean, direct addition of ~120 lines, zero new dependencies.

---

## Tasks

### Task 1: Plot Styling Model & Inspector Controls
Define `PlotRenderStyle` enum (`line`, `scatter`, `lineAndScatter`, `spline`), add `renderStyle`, `markerSize`, and `lineWidth` controls to `RawViewModel`, and build interactive style selectors into `InspectorPane`.

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:65-150` (Add properties to `RawViewModel`)
- Modify: `Sources/RawViewApp/RawViewApp.swift:1350-1450` (Add Plot Style section to `InspectorPane`)
- Modify: `Sources/RawViewApp/SettingsView.swift` (Add default marker size setting)

- [ ] Step 1: Define `PlotRenderStyle` enum in `RawViewApp.swift` (`line`, `scatter`, `lineAndScatter`, `spline`).
- [ ] Step 2: Add `@Published var renderStyle: PlotRenderStyle = .line` and `@Published var markerSize: Double = 4.5` to `RawViewModel`.
- [ ] Step 3: Add `Plot Style` section to `InspectorPane` with segmented picker for render style and stepper/sliders for Line Width ($0.2 - 5.0\text{ pt}$) and Dot Size ($2.0 - 10.0\text{ pt}$).
- [ ] Step 4: Add `defaultMarkerSize` into `SettingsView.swift` Appearance tab.
- [ ] Step 5: Verify build with `./Scripts/check_core.sh`.

### Task 2: Adaptive Nature Typography & Dynamic Viewport Scaling
Implement dynamic viewport-aware typography scaling in `NativePlot` respecting `@AppStorage("uiFontSize")`, scale factor, and canonical Nature single-column proportions.

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:1085-1250` (`NativePlot`)

- [ ] Step 1: In `NativePlot`, read `@AppStorage("uiFontSize") private var uiFontSize: Double = 12.0`.
- [ ] Step 2: Calculate dynamic `fontScale = max(1.0, min(1.6, plot.width / 480.0)) * (uiFontSize / 12.0)`.
- [ ] Step 3: Update `plotFont(size:bold:)` to scale with `fontScale`, raising base axis title to $13.0\text{ pt}$ and tick label to $11.5\text{ pt}$ (scaled $\approx 14\text{ pt}$ and $12.5\text{ pt}$ at standard width).
- [ ] Step 4: Adjust left and bottom gutters adaptively based on measured tick label widths and dynamic font heights so labels never clip or overlap.
- [ ] Step 5: Verify build with `./Scripts/check_core.sh`.

### Task 3: Outward Ticks & Closed Box Spines Matching Nature Specification
Align tick lines, tick spacing, tick lengths, and bounding frame thickness strictly to `nature-single.yaml`.

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:1190-1240` (`NativePlot.draw`)

- [ ] Step 1: Set box spine border thickness to $0.8\text{ pt}$ (matching `thickness_mm: 0.28`).
- [ ] Step 2: Update tick marks to strictly outward direction with length $4.25\text{ pt}$ (matching `length_mm: 1.5`) and thickness $0.8\text{ pt}$.
- [ ] Step 3: Ensure outward ticks on bottom axis point downwards ($+4.25\text{ pt}$) and on left axis point leftwards ($-4.25\text{ pt}$).
- [ ] Step 4: Add adaptive nice-tick division (3 to 5 ticks) to avoid collision while covering dynamic zoom/pan viewports.
- [ ] Step 5: Verify build with `./Scripts/check_core.sh`.

### Task 4: Native Rendering Engine (Scatter Dots & Catmull-Rom Splines)
Extend `NativePlot` canvas drawing loop to render scatter points, combined line+points, and smooth Catmull-Rom cubic splines.

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:1220-1280` (`NativePlot.draw`)

- [ ] Step 1: Implement Catmull-Rom to cubic Bezier curve converter for smooth spline mode.
- [ ] Step 2: Implement scatter dot rendering with circular markers of radius `markerSize / 2`.
- [ ] Step 3: Implement branch logic in `draw`:
  - When `.line`: stroke polyline segments.
  - When `.scatter`: fill circular dots at every finite sample point.
  - When `.lineAndScatter`: stroke polyline and fill dots.
  - When `.spline`: stroke smooth cubic Bezier path.
- [ ] Step 4: Verify rendering across all modes with multi-series overlay and gap segmentation.
- [ ] Step 5: Verify build with `./Scripts/check_core.sh`.

### Task 5: End-to-End Verification, Packaging, & Regression Check
Run full test suite, verify against test playground `/Users/tai/research-projects/active-projects/test`, and package production app.

**Files:**
- Verify: `Scripts/check_core.sh`
- Package: `/Applications/RawView.app`

- [ ] Step 1: Run `./Scripts/check_core.sh` and ensure 0 errors.
- [ ] Step 2: Run `RAWVIEW_APP_PATH=/Applications/RawView.app ./Scripts/package_app.sh`.
- [ ] Step 3: Launch `/Applications/RawView.app` and test switching between Line, Scatter, Line+Dots, and Spline, adjusting line width and dot size.
- [ ] Step 4: Commit changes and provide summary to user.
