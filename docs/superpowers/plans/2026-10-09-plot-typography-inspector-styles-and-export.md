# Plot Typography, Inspector Visual Harmony, Orthogonal Render Modes, and Figure/Data Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine RawView's Nature-compliant plot typography (regular-weight titles, crisp outward ticks, proportional viewport scaling), harmonize the right Inspector's contrast and font hierarchy with the left sidebar, decompose render styling into orthogonal Mark and Interpolation dimensions (including staircase step mode), add optional sweep progress gradient with colorbar, and implement high-res figure (PNG/PDF) and data (CSV) export.

**Architecture:** 
- `RawViewCore`: Update `PlotRenderStyle` to decompose into `PlotMarkType` (`line`, `dots`, `lineAndDots`) and `PlotInterpolation` (`linear`, `spline`, `step`).
- `PlotRenderingEngine`: Add staircase step path generation (`stepPath`), stroke gradient interpolation along point index/time progress, and tick length/width scaling.
- `InspectorPane`: Harmonize typography hierarchy and contrast with `ProjectSourcesSidebar`, matching macOS Human Interface Guidelines.
- `FigureExporter`: Pure native AppKit exporter creating 300 DPI Retina PNGs, vector PDFs, and clean CSV data tables via `NSSavePanel`.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (`CGContext`, `PDFContext`, `NSSavePanel`), Canvas GraphicsContext, macOS 14+.

**Spec:** User feedback from screenshot `media_1791533193156_85709ace.png` and canonical `nature-single.yaml` preset.

## Global Constraints
- Pure native Swift linking macOS system frameworks only (`AppKit`, `SwiftUI`, `UniformTypeIdentifiers`).
- Retain immutability of raw input files under `data/raw`.
- Maintain single-plot (`NativePlot`) and overlay comparison (`OverlayPlot`) rendering parity.
- Keep `@MainActor` responsive during export and rendering operations.

## Review Focus
1. Tick length and spine visibility across screen sizes: Ticks must never disappear or clip beneath axis title text.
2. Step staircase interpolation: Must correctly handle non-uniform sampling and horizontal-then-vertical transitions without gaps.
3. High-res export bounds: PDF and PNG exports must render exactly the figure card without window chrome or inspector panels.
4. Export file dialog cancellation: User dismissing `NSSavePanel` must not trigger errors or alter state.
5. Sweep gradient performance: Shading paths by progress index must not cause frame drops during pan or zoom gestures.

---

### Task 1: Nature Typography & Viewport Scaling Refinement

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift` (`NativePlot`)
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift` (`OverlayPlot`)
- Modify: `Sources/RawViewApp/PlotRenderingEngine.swift`

**Interfaces:**
- `PlotRenderingEngine.tickLength(fontScale: CGFloat) -> CGFloat`
- `PlotRenderingEngine.spineLineWidth: CGFloat = 1.0`
- `PlotRenderingEngine.tickLineWidth: CGFloat = 1.0`

- [ ] **Step 1: Write test or testable formula in PlotRenderingEngine**
  Define `spineLineWidth = 1.0`, `tickLineWidth = 1.0`, and `tickLength(fontScale:) -> CGFloat` (returning `max(6.0, 5.0 * fontScale)`).

- [ ] **Step 2: Update NativePlot axis titles and tick styling**
  - In `NativePlot.draw`:
    - Axis title font: change from `plotFont(size: 13.0 * fontScale, bold: true)` to `plotFont(size: 12.5 * fontScale, bold: false)`.
    - Spines: stroke frame with `lineWidth: 1.0`.
    - Ticks: stroke with `lineWidth: 1.0` and length `PlotRenderingEngine.tickLength(fontScale: fontScale)` (e.g. 6.5–7.5 pt).
    - Align tick labels at `plot.maxY + tickLength + 4` and left labels at `plot.minX - tickLength - 4`.

- [ ] **Step 3: Update OverlayPlot to match NativePlot exactly**
  - Apply identical regular axis title font, 1.0 pt spine, 1.0 pt tick stroke, and scaled tick length.

- [ ] **Step 4: Verify build with check_core.sh**
  Run: `./Scripts/check_core.sh`
  Expected: PASS

- [ ] **Step 5: Commit Task 1**
  ```bash
  git add Sources/RawViewApp/RawViewApp.swift Sources/RawViewApp/ProjectGalleryViews.swift Sources/RawViewApp/PlotRenderingEngine.swift
  git commit -m "feat(plot): refine axis title weight, tick length, and spine thickness for Nature single standard"
  ```

---

### Task 2: Inspector & Sidebar Visual Harmony & High-Contrast Redesign

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift` (`InspectorPane`)

**Interfaces:**
- Section Header Style: `.font(.system(size: 11, weight: .bold)).foregroundStyle(.primary.opacity(0.85))`
- Label Style: `.font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)`
- Sub-caption / Units: `.font(.system(size: 10)).foregroundStyle(.secondary)`

- [ ] **Step 1: Unify section headers across InspectorPane**
  Replace `.font(.caption2.bold()).foregroundStyle(.secondary)` with a unified header style across `SERIES`, `PLOT STYLING`, `AXES`, `SOURCE METADATA`, and `CACHE & STORAGE`.

- [ ] **Step 2: Increase label contrast and eliminate washed-out gray text**
  In `styleSection`:
  - Change "Render Mode", "Line width", "Dot size", "Show Legend" labels to `.font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)`.
  - Enclose slider and stepper pairs in clean, subtle card rows (`.padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))`).

- [ ] **Step 3: Harmonize alignment and spacing with left sidebar**
  Ensure consistent horizontal padding (`14 pt`) and vertical rhythm matching `ProjectSourcesSidebar`.

- [ ] **Step 4: Verify build with check_core.sh**
  Run: `./Scripts/check_core.sh`
  Expected: PASS

- [ ] **Step 5: Commit Task 2**
  ```bash
  git add Sources/RawViewApp/RawViewApp.swift
  git commit -m "feat(inspector): harmonize typography hierarchy, contrast, and spacing with project sidebar"
  ```

---

### Task 3: Orthogonal Plot Rendering Architecture: Marks & Interpolation

**Files:**
- Modify: `Sources/RawViewCore/PlotRenderStyle.swift`
- Modify: `Sources/RawViewApp/PlotRenderingEngine.swift`
- Modify: `Sources/RawViewApp/RawViewApp.swift` (`RawViewModel`, `InspectorPane`, `NativePlot`)
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift` (`OverlayPlot`, `ProjectGallery`)
- Modify: `Sources/RawViewApp/SettingsView.swift`

**Interfaces:**
- `PlotMarkType: String, CaseIterable, Identifiable`: `.line ("Line")`, `.dots ("Dots")`, `.lineAndDots ("Both")`
- `PlotInterpolation: String, CaseIterable, Identifiable`: `.linear ("Linear")`, `.spline ("Spline")`, `.step ("Step")`
- `PlotRenderingEngine.stepPath(points: [CGPoint]) -> Path`
- `PlotRenderingEngine.renderRun(points: [CGPoint], mark: PlotMarkType, interpolation: PlotInterpolation, ...)`

- [ ] **Step 1: Define `PlotMarkType` and `PlotInterpolation` in RawViewCore**
  Update `Sources/RawViewCore/PlotRenderStyle.swift` to declare `PlotMarkType` and `PlotInterpolation`. Keep `PlotRenderStyle` for backwards compatibility if needed, or replace with the two orthogonal enums.

- [ ] **Step 2: Implement staircase step interpolation in PlotRenderingEngine**
  Add `static func stepPath(points: [CGPoint]) -> Path`:
  - For each segment between $(x_i, y_i)$ and $(x_{i+1}, y_{i+1})$, add horizontal line to $(x_{i+1}, y_i)$ then vertical line to $(x_{i+1}, y_{i+1})$.

- [ ] **Step 3: Update PlotRenderingEngine.renderRun**
  Accept `mark: PlotMarkType` and `interpolation: PlotInterpolation`.
  - When `mark == .dots`: draw markers only.
  - When `mark == .line`: stroke path (`linear`, `spline`, or `step`).
  - When `mark == .lineAndDots`: stroke path (`linear`, `spline`, or `step`) AND draw markers.

- [ ] **Step 4: Update Inspector controls and ViewModel bindings**
  - In `InspectorPane`:
    - First row: segmented picker for Mark Type (`Line`, `Dots`, `Both`).
    - Second row (visible when Mark is not `Dots`): segmented picker for Interpolation (`Linear`, `Spline`, `Step`).
  - In `RawViewModel` & `SettingsView`: bind `@Published var markType: PlotMarkType` and `@Published var interpolation: PlotInterpolation`.

- [ ] **Step 5: Verify build with check_core.sh**
  Run: `./Scripts/check_core.sh`
  Expected: PASS

- [ ] **Step 6: Commit Task 3**
  ```bash
  git add Sources/RawViewCore/PlotRenderStyle.swift Sources/RawViewApp/PlotRenderingEngine.swift Sources/RawViewApp/RawViewApp.swift Sources/RawViewApp/ProjectGalleryViews.swift Sources/RawViewApp/SettingsView.swift
  git commit -m "feat(plot): decompose render styles into orthogonal mark types and linear/spline/step interpolations"
  ```

---

### Task 4: Dynamic Sweep Gradient & Color Bar (Acquisition Index / Time)

**Files:**
- Modify: `Sources/RawViewApp/PlotRenderingEngine.swift`
- Modify: `Sources/RawViewApp/RawViewApp.swift` (`RawViewModel`, `InspectorPane`, `NativePlot`)
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift` (`OverlayPlot`)

**Interfaces:**
- `@Published var colorBySweepProgress: Bool` in `RawViewModel`
- `PlotRenderingEngine.renderProgressGradientRun(points: [CGPoint], interpolation: PlotInterpolation, ...)`
- `SweepColorbarView: View`: compact gradient bar showing Start ($t=0$) to End ($t=N$).

- [ ] **Step 1: Implement progress gradient stroke helper in PlotRenderingEngine**
  Given $N$ points in run, interpolate colors from Blue ($\text{start}$) $\to$ Purple $\to$ Amber/Orange ($\text{end}$) or Viridis gradient using segment-by-segment coloring or `GraphicsContext.Shading.linearGradient`.

- [ ] **Step 2: Add Inspector toggle "Color by Sequence / Sweep"**
  In `InspectorPane.styleSection`: Add `Toggle("Color by Sweep Progress", isOn: $colorBySweepProgress)`.

- [ ] **Step 3: Add Sweep Color Bar indicator on plot overlay**
  When `colorBySweepProgress` is active, display a subtle horizontal gradient pill at top/bottom indicating Sweep Progress ($0\% \to 100\%$).

- [ ] **Step 4: Verify build with check_core.sh**
  Run: `./Scripts/check_core.sh`
  Expected: PASS

- [ ] **Step 5: Commit Task 4**
  ```bash
  git add Sources/RawViewApp/PlotRenderingEngine.swift Sources/RawViewApp/RawViewApp.swift Sources/RawViewApp/ProjectGalleryViews.swift
  git commit -m "feat(plot): add sweep progress color gradient and indicator for cyclic and dual-sweep measurements"
  ```

---

### Task 5: High-Res Figure Export (PNG/PDF) & Clean Data Export (CSV)

**Files:**
- Create: `Sources/RawViewApp/FigureExporter.swift`
- Modify: `Sources/RawViewApp/RawViewApp.swift` (`RawViewModel`, `ProjectGallery`)
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift`

**Interfaces:**
- `FigureExporter.exportImage(view: AnyView, size: CGSize, scale: CGFloat, url: URL)`
- `FigureExporter.exportPDF(view: AnyView, size: CGSize, url: URL)`
- `FigureExporter.exportCSV(measurement: NormalizedMeasurement, url: URL) throws`
- `RawViewModel.exportCurrentFigure(format: ExportFormat)`
- `RawViewModel.exportCurrentData()`

- [ ] **Step 1: Implement FigureExporter**
  - Implement raster bitmap renderer using `ImageRenderer` (macOS 13+) or `NSBitmapImageRep` at 3.0x scale (300+ DPI Retina).
  - Implement vector PDF export using `ImageRenderer.render(raster: false)` or AppKit PDF context.
  - Implement CSV export streaming channel labels, units, and aligned row values.

- [ ] **Step 2: Add NSSavePanel export dialogs in RawViewModel**
  Add `promptExportFigure()` and `promptExportData()` presenting system `NSSavePanel` with `.png`, `.pdf`, and `.csv` content types.

- [ ] **Step 3: Wire Export actions to UI**
  - Add "Export Figure…" and "Export Data…" in the top Header Menu (next to View segmented picker and Snapshot menu).
  - Add an Export section / buttons in `InspectorPane`.

- [ ] **Step 4: Verify build with check_core.sh**
  Run: `./Scripts/check_core.sh`
  Expected: PASS

- [ ] **Step 5: Commit Task 5**
  ```bash
  git add Sources/RawViewApp/FigureExporter.swift Sources/RawViewApp/RawViewApp.swift Sources/RawViewApp/ProjectGalleryViews.swift
  git commit -m "feat(export): add high-res PNG, vector PDF, and CSV data export"
  ```

---

### Task 6: Packaging, Verification & Regression Testing

**Files:**
- Verify: `./Scripts/check_core.sh`
- Package: `/Applications/RawView.app` via `./Scripts/package_app.sh`

- [ ] **Step 1: Run check_core.sh to verify zero compiler warnings and errors**
- [ ] **Step 2: Package /Applications/RawView.app**
  Run: `RAWVIEW_APP_PATH=/Applications/RawView.app ./Scripts/package_app.sh`
- [ ] **Step 3: Test launch and verify live UI**
  Test opening Keithley 2400 dual-sweep, toggling Step / Spline / Line / Dots, verifying regular axis titles, crisp outward ticks, and testing Figure & Data Export dialogs.
- [ ] **Step 4: Update execution ledger and finalize**
