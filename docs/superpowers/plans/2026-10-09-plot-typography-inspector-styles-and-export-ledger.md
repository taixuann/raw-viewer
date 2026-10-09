# Execution Ledger: Plot Typography, Inspector Harmony, Render Modes, & Export

Plan: docs/superpowers/plans/2026-10-09-plot-typography-inspector-styles-and-export.md
Started: 2026-10-09

## Status
- [x] Task 1: Nature Typography & Viewport Scaling Refinement (commit `494045f`)
- [x] Task 2: Inspector & Sidebar Visual Harmony & High-Contrast Redesign (commit `207269e`)
- [x] Task 3: Orthogonal Plot Rendering Architecture: Marks & Interpolation (commit `a8579c9`)
- [x] Task 4: Dynamic Sweep Gradient & Color Bar (Acquisition Index / Time) (commit `a8579c9`)
- [x] Task 5: High-Res Figure Export (PNG/PDF) & Clean Data Export (CSV) (commit `a8579c9`)
- [x] Task 6: Packaging, Verification & Regression Testing (verified with check_core.sh and packaged to /Applications/RawView.app)

## Rulings
1. **Axis Title Weight**: Titles use regular font weight (`plotFont(size: 12.5 * fontScale, bold: false)`), reserving bold solely for panel letter indicators in multi-panel figures.
2. **Tick Geometry**: Outward ticks scale to `max(6.0, 5.2 * fontScale)` with `1.0 pt` stroke and `1.0 pt` spines, ensuring high-DPI Retina clarity.
3. **Orthogonal Render Dimensioning**: Decomposed render settings into `PlotMarkType` (`Line`, `Dots`, `Both`) and `PlotInterpolation` (`Linear`, `Spline`, `Step`), conditionally hiding connection style and stroke width when only dots are active.
4. **Dynamic Sweep Sequence Gradient**: Added Viridis-inspired color progression along measurement index with floating indicator `SweepColorbarView` for dual-sweep/cyclic measurements.
5. **Figure and Data Export**: Added `FigureExporter` leveraging pure native `ImageRenderer` (300 DPI Retina PNG), vector PDF, and formatted CSV export with `NSSavePanel`.

