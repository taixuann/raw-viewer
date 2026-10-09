# Multi-Publisher Presets, Typography Calibration, and Top Toolbar Preset Selector

## Context & Objectives
- Incorporate FigRecipe publication standards (`nature-single`, `nature-open`, `science-single`, `science-open`, `acs-single`, `ieee-single`) into RawView as selectable scientific presets.
- Calibrate typography: Regular-weight legend, scaled legend sizing (~10 pt * fontScale), outward tick lengths, aspect ratios, and open (L-frame) vs closed (4-spine) frames.
- Place a top toolbar preset switcher between `[Plot | Data]` and `[Snapshot]`.
- Remove redundant "Plot Defaults" section from `SettingsView.swift`.

---

## Tasks

### Task 1: ScientificPreset Model (`Sources/RawViewCore/ScientificPreset.swift`)
- Define `struct ScientificPreset: Identifiable, Sendable, Hashable`:
  - Presets: `natureSingle`, `natureOpen`, `scienceSingle`, `scienceOpen`, `acsSingle`, `ieeeSingle`.
  - Properties: `id`, `displayName`, `publisher`, `aspectRatio`, `isOpenFrame`, `serif`, `spineThickness`, `tickLengthPt`, `legendPt`, `axisLabelPt`, `tickLabelPt`, `titlePt`.
- Add test coverage in `Tests/RawViewCoreTests/ScientificPresetTests.swift`.

### Task 2: Typography & Spine Calibration in `PlotRenderingEngine` & `DraggableLegendView`
- In `DraggableLegendView.swift`:
  - Use `.regular` font weight (remove `.semibold`).
  - Accept `fontSize: CGFloat` (calibrated to preset legend sizing).
- In `NativePlot` and `OverlayPlot`:
  - Dynamically render frame: 4-spine closed box or 2-spine L-frame according to `preset.isOpenFrame`.
  - Apply `preset.aspectRatio` (`width_mm / height_mm`), `preset.spineThickness`, `preset.tickLengthPt * fontScale`.
  - Calibrate axis titles and tick positions with proper padding.

### Task 3: Top Toolbar Preset Switcher & ViewModel State
- Add `selectedPreset: ScientificPreset` in `RawViewModel`.
- In `ProjectGallery`:
  - Place Preset menu between `[Plot | Data]` picker and `[Snapshot]` menu.
  - Group presets into "Standard Journals (Closed 4-Box)" and "Open L-Frames (2-Axis)".
  - Bind selection to `model.selectedPreset`.

### Task 4: Clean up `SettingsView`
- Remove `Section("Plot Defaults")` from `SettingsView.swift`.
- Keep clean interface theme and sizing controls.

### Task 5: Verification & Packaging
- Run `./Scripts/check_core.sh`.
- Package into `/Applications/RawView.app`.
- Conduct code standards and spec reviews.
