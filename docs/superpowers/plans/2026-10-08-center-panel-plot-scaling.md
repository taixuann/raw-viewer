# Center Panel Full-Width Plot Scaling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow the center plot canvas and box spines to expand horizontally across the full width of the center panel without letterboxing or squishing into a small centered rectangle, while maintaining proportional scaling of the plot and typography.

**Architecture:** Update `NativePlot` and `OverlayPlot` canvas layout and frame geometry so the plot box expands to fill the available horizontal width of the card. Dynamically derive the canvas height from the available card width according to the scientific aspect ratio (or allow responsive height expansion in the ScrollView container), ensuring the plot uses the entire panel area without large empty margins on the sides.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (`GraphicsContext`, `Canvas`, `GeometryReader`)

**Spec:** User feedback on `raw-viewer` center panel behavior (Issue: plot box was clamped to a small centered rectangle inside a large card; user requirement: "ratio nó scale cả cái box ấy cơ chứ cái đấy bạn cố định nó lại à??? nghĩa là center panel nó dài ra hiểu ko??").

## Global Constraints

- Preserve clean box spines (0.8 pt clean border, zero background gridlines).
- Preserve outward ticks (1.5 mm / ~4.25 pt, 5 ticks per axis).
- Preserve Nature single Arial typography (11 pt axis titles, 9.5 pt tick labels).
- Preserve high-contrast Nature color palette.
- Do not re-introduce study manifest warnings or overlay restrictions.

## Review Focus

- Ultra-wide displays: plot box should expand smoothly across the width of the card without overflowing the viewport.
- Resizable inspector interactions: as the user drags the inspector wider or narrower, the center plot should immediately resize its width and proportional height.
- Small/narrow windows: plot minimum dimensions must prevent negative or zero `CGRect` bounds.
- Multi-series overlay mode: `OverlayPlot` must match the full-width scaling behavior of `NativePlot`.
- Pan & zoom gestures: zoom/pan coordinates must remain anchored accurately to the expanded plot box rect.

---

### Task 1: Responsive Canvas Height & Full-Width Aspect Scaling

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:650-715`
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift:395-425`

**Interfaces:**
- Consumes: `NormalizedMeasurement`, `AxisScale`
- Produces: `NativePlot` with dynamic full-width frame and proportional height

- [ ] **Step 1: Check existing plot rect calculation**

Verify how `NativePlot` calculates `plot`: currently it clamps `plotW` to `availHeight * targetRatio`, preventing the plot from expanding horizontally across `availWidth`.

- [ ] **Step 2: Update `NativePlot` layout geometry to expand horizontally**

In `NativePlot`:
1. Use `GeometryReader` or compute canvas height dynamically from available width so the card and plot scale together:
   `let plotWidth = max(200, size.width - leftGutter - 20)`
   `let plotHeight = min(size.height - 16 - 54, max(260, plotWidth / (59.1 / 50.0)))`
2. Remove horizontal centering that pushed the plot into the center with massive side margins.
3. Anchor the plot box from `leftGutter` to `size.width - 20`.

- [ ] **Step 3: Update `Canvas` frame in `NativePlot`**

Set the `Canvas` frame to expand with width:
`.frame(maxWidth: .infinity)` with appropriate minimum height so the plot scales naturally with window width.

- [ ] **Step 4: Verify with `swift build`**

Run: `swift build`
Expected: Build complete!

- [ ] **Step 5: Commit changes**

```bash
git commit -am "feat: allow NativePlot to scale full width across center panel"
```

---

### Task 2: Update `OverlayPlot` Full-Width Scaling

**Files:**
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift:580-640`

**Interfaces:**
- Consumes: `NormalizedMeasurement`, `Series`
- Produces: `OverlayPlot` with full-width responsive scaling matching `NativePlot`

- [ ] **Step 1: Check existing `OverlayPlot` draw implementation**

Verify `OverlayPlot.draw` uses the same clamped logic that needs full-width expansion.

- [ ] **Step 2: Apply full-width plot box calculation to `OverlayPlot`**

Ensure `OverlayPlot.draw` expands horizontally across `size.width - leftGutter - 20` and aligns with `NativePlot`.

- [ ] **Step 3: Verify with `swift build`**

Run: `swift build`
Expected: Build complete!

- [ ] **Step 4: Commit changes**

```bash
git commit -am "feat: allow OverlayPlot to scale full width across center panel"
```

---

### Task 3: Package, Run, and Validate Layout

**Files:**
- Run: `./Scripts/package_app.sh`
- Test: Open packaged application and verify visually

- [ ] **Step 1: Terminate running instance**

Run: `pkill -f RawView || true`

- [ ] **Step 2: Run `package_app.sh`**

Run: `./Scripts/package_app.sh`
Expected: Packaged and verified release app bundle

- [ ] **Step 3: Launch updated RawView.app**

Run: `open /path/to/RawView.app`
Verify: Center plot fills the card horizontally ("dài ra") without awkward empty side margins.
