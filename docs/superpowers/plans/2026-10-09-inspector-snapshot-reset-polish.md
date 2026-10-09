# RawView UX Polish: Snapshot Menu, Right-Panel Title, Reset Plot Placement, Non-blocking Status, and Numeric Line Width Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine RawView's user experience by converting snapshots to a clean toggle menu/popover, adding a two-way synced Snapshot Title in the Inspector's SERIES section, relocating the "Reset plot" button out of the plot canvas border, eliminating the endless background inspection spinner from the plot header, and replacing the line width slider with direct numeric input and stepper controls.

**Architecture:** 
1. **Snapshots**: Replace the horizontal chip sprawl in the center top bar with a sleek `[📸 Snapshots (N) ▾]` Menu/Popover providing instant switch, toggle-off, rename, and delete actions.
2. **Right-Panel Title & Canvas Sync**: Add an inline `Snapshot / Comparison Title` TextField at the top of the Inspector's `SERIES` section when multi-selecting or viewing a snapshot, dynamically updating the plot canvas title and active snapshot name.
3. **Plot Header & Reset Button**: Move the `Reset plot` button out of the Canvas overlay into the figure card's header row alongside the figure title, preventing any collision with plot borderlines.
4. **Targeted Plot Loading Indicator**: Decouple the center panel header spinner from background folder inspection (`isInspecting`); show the spinner only when the active plot or selected overlay sources are actively loading data.
5. **Precise Numeric Line Width**: Replace the imprecise drag slider with an exact numeric TextField (`Double` formatted to 1 decimal place) plus a native macOS `Stepper` (`0.2 ... 10.0 pt`, step `0.1`).

**Tech Stack:** Swift 5.10+, SwiftUI, AppKit, RawViewCore, RawViewApp.

**Spec:** User feedback from session on 2026-10-09 with screenshot `media_1791515012498_10aa04a5.png`.

## Global Constraints

- No external dependencies; standard library and SwiftUI / AppKit only.
- RawViewCore contracts and test suites must pass 100% via `./Scripts/check_core.sh`.
- App layer must cleanly type-check and package to `/Applications/RawView.app`.
- Adhere to the `/impeccable` Operate mode: high scanability, native macOS idioms, zero visual overlap.

## Review Focus

1. **Snapshot switching & toggle-off**: Clicking an already active snapshot in the menu deselects it and reverts to free multi-source selection without errors.
2. **Title synchronization**: Typing into the Inspector's `Snapshot Title` field immediately updates the title on the plot canvas and the snapshot in memory.
3. **Canvas borderline clarity**: The `Reset plot` button must not intersect or obscure the top-right corner of the plot frame (`plot.maxX`, `plot.minY`).
4. **Header spinner quiescence**: After opening a large project (2,000+ files), the center header must not show an endless spinning indicator while inspecting; only show loading when actively fetching measurement points.
5. **Numeric line width safety**: Typing invalid or negative numbers into the line width field must clamp to safe bounds (`0.2 ... 10.0 pt`).

---

### Task 1: Fix Center Header Loading Status & Decouple from Background Inspection

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:675-690`
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift:550-620`

- [ ] **Step 1: Define `isPlotLoading` on `RawViewModel`**
In `RawViewModel`, expose a computed property `isPlotLoading: Bool` that is true only when:
- `overlayLoadTask != nil` (loading multiple selected sources for comparison), OR
- `loadTask != nil` (loading the focused source).
This strictly ignores `inspectionTask` and `discoveryTask`, ensuring the center header spinner never spins endlessly during background project indexing.

- [ ] **Step 2: Update `ProjectGallery` loading binding**
Pass `isPlotLoading` instead of generic `isLoading` to `ProjectGallery`. In `ProjectGallery`, display the header spinner only when `isLoading` is true AND show `loadingStatus` if present.

- [ ] **Step 3: Verify with `./Scripts/check_core.sh`**
Run `./Scripts/check_core.sh` to ensure type-checking passes.

- [ ] **Step 4: Commit**
`git commit -m "fix(ux): decouple center header loading indicator from background inspection"`

---

### Task 2: Relocate "Reset Plot" Button to Figure Card Header

**Files:**
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift:960-1040`
- Modify: `Sources/RawViewApp/RawViewApp.swift:870-930`

- [ ] **Step 1: Remove `.overlay(alignment: .topTrailing)` from `NativePlot` and `OverlayPlot` ZStacks**
Remove the floating `Reset plot` button overlay that was positioned on top of the Canvas.

- [ ] **Step 2: Add `Reset plot` button into figure card title row**
In both `NativePlot.body` and `OverlayPlot.body`, place the `Reset plot` button in an `HStack` alongside the figure title:
```swift
HStack(alignment: .center) {
    Text(titleText)
        .font(.custom(..., size: 13.5).bold())
        .lineLimit(1).truncationMode(.middle)
    Spacer()
    Button {
        zoom = 1; gestureZoomStart = 1; pan = .zero; dragStart = .zero
    } label: {
        Label("Reset plot", systemImage: "arrow.counterclockwise")
            .font(.caption2)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help("Reset plot zoom and pan")
}
```
This guarantees the button never touches or obscures the plot's border rectangle.

- [ ] **Step 3: Verify with `./Scripts/check_core.sh`**
Run `./Scripts/check_core.sh` to ensure clean compilation.

- [ ] **Step 4: Commit**
`git commit -m "fix(ux): relocate reset plot button to figure card header row"`

---

### Task 3: Replace Line Width Slider with Numeric Input and Stepper

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:1340-1370`

- [ ] **Step 1: Redesign `styleSection` in `InspectorPane`**
Replace the `Slider` with a formatted numeric `TextField` and macOS `Stepper`:
```swift
HStack(spacing: 8) {
    Text("Line width").font(.caption)
    Spacer()
    TextField("1.4", value: $lineWidth, format: .number.precision(.fractionLength(1)))
        .textFieldStyle(.roundedBorder)
        .font(.caption)
        .frame(width: 50)
        .multilineTextAlignment(.trailing)
    Stepper("", value: $lineWidth, in: 0.2...10.0, step: 0.1)
        .labelsHidden()
        .controlSize(.small)
    Text("pt").font(.caption2).foregroundStyle(.secondary)
}
```

- [ ] **Step 2: Clamp bounds in `RawViewModel.lineWidth`**
Ensure `lineWidth` in `RawViewModel` is clamped between `0.2` and `10.0`.

- [ ] **Step 3: Verify with `./Scripts/check_core.sh`**
Run `./Scripts/check_core.sh` to verify compilation.

- [ ] **Step 4: Commit**
`git commit -m "feat(ux): replace line width slider with direct numeric input and stepper"`

---

### Task 4: Snapshot Menu/Popover in Center Header and Title in Right Panel

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift` (`RawViewModel`, `RawViewShell`, `InspectorPane`)
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift` (`ProjectGallery`, `OverlayPlot`)

- [ ] **Step 1: Add `activeSnapshotTitle` & two-way sync in `RawViewModel`**
In `RawViewModel`:
- Add `@Published var comparisonTitle: String = ""`
- When a snapshot is active, `comparisonTitle` reflects and mutates the active snapshot's name.
- When saving a snapshot, use `comparisonTitle` if non-empty.

- [ ] **Step 2: Add `Snapshot Title` input field in `InspectorPane.seriesSection`**
When `selectedIDs.count >= 2` or `activeSnapshotID != nil`:
Add an editable title box at the top of `SERIES` with:
- `TextField("Comparison / Snapshot Title…", text: $comparisonTitle)`
- Quick `[📸 Save Snapshot]` button alongside.
This provides the requested right-panel rename and title editing capability.

- [ ] **Step 3: Replace header chip sprawl with a compact Snapshot Menu / Popover**
In `ProjectGalleryViews.swift` header:
Replace the horizontal scroll of chips with a native Menu / Popover button:
`Menu { ... } label: { Label("Snapshots (\(snapshots.count))", systemImage: "camera") }`
Inside the menu:
- Section with "Save Current View" action.
- Section listing each saved snapshot with checkmark `✓` if active (clicking active toggles it off!).
- Rename and Delete actions for each snapshot.

- [ ] **Step 4: Connect figure canvas title to `comparisonTitle`**
In `OverlayPlot`, if `!comparisonTitle.isEmpty`, use it as the prominent figure title instead of `3 sources · overlay in acquisition order`.

- [ ] **Step 5: Verify with `./Scripts/check_core.sh`**
Run `./Scripts/check_core.sh` to verify compilation and tests.

- [ ] **Step 6: Commit**
`git commit -m "feat(ux): snapshot popover menu, right-panel title editor, and reactive canvas sync"`

---

### Task 5: Packaging and End-to-End Live Verification

**Files:**
- Execute: `./Scripts/package_app.sh`

- [ ] **Step 1: Clean build and package**
Run `RAWVIEW_APP_PATH=/Applications/RawView.app ./Scripts/package_app.sh`.

- [ ] **Step 2: Kill existing and relaunch**
Run `pkill -9 -f RawView || true && open /Applications/RawView.app`.

- [ ] **Step 3: Live process verification**
Verify with `pgrep -lf RawView`. Confirm visually that all 4 improvements are active and working smoothly.
