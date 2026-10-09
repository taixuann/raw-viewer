# RawView Polish & Feature Enhancements Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix sidebar background artifact, add quick search bar to sidebar, calibrate Nature preset typography and tick labels with trailing anchor to prevent Y-title overlap during zoom/pan, add toggleable Inspector with shortcut ⌘I, and add Data tab search with ⌘F.

**Architecture:** 
- In `ProjectSourcesSidebar`: Add `.scrollContentBackground(.hidden)`, uniform window background, and an integrated `SearchField` wired to `@State private var search = ""` and `matches()`.
- In `NativePlot` & `OverlayPlot`: Update typography to match `nature-single.yaml` (axis labels: 8.0 pt, tick labels: 7.5 pt, title: 8.5 pt). Anchor Y-axis tick labels to `.trailing` at `plot.minX - 6`. Calculate `leftGutter` dynamically based on maximum tick label text width plus title margin to guarantee no overlap even under extreme zoom.
- In `RawViewModel` & `RawViewShell`: Add `@Published var showInspector: Bool = true`. Add a toggle button with icon `sidebar.right` and keyboard shortcut `⌘I`. When hidden, omit inspector from `HSplitView` so Center Gallery takes full available width.
- In `MeasurementTable`: Add an integrated search bar with `@FocusState` triggered by `⌘F`, filtering rows across all channels and showing match count.
- In packaging & runtime: Kill old processes before launch, package with `./Scripts/package_app.sh`, verify live.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (`GraphicsContext`, `Canvas`, `HSplitView`, `NSVisualEffectView`).

---

### Task 1: Sidebar Background Fix & Quick Search Field

**Files:**
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift:75-115`
- Modify: `Sources/RawViewApp/RawViewApp.swift:575-625`

**Steps:**
- [x] Add `.scrollContentBackground(.hidden)` to `List(selection: $selectedSourceIDs)` in `ProjectSourcesSidebar`.
- [x] Ensure sidebar background is consistently `Color(nsColor: .windowBackgroundColor)` throughout `sidebarPane` and `ProjectSourcesSidebar`.
- [x] Add quick search field UI below the "Group by" picker with magnifying glass icon, `TextField("Filter sources…", text: $search)`, and clear button when non-empty.
- [x] Verify `matches(_:label:)` filters sources immediately as the user types.

---

### Task 2: Nature Preset Typography, Outward Ticks, Trailing Anchor & Dynamic Left Gutter

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:735-790` (`NativePlot.draw`)
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift:680-730` (`OverlayPlot.draw`)
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift:480-515` (`CenteredFigureView`)

**Steps:**
- [x] Update typography to exact Nature single preset specs:
  - Axis titles: 8.0 pt Arial
  - Tick labels: 7.5 pt Arial
  - Card title: 8.5 pt Arial bold / headline
- [x] Calculate Y-axis tick labels text bounds or string lengths dynamically.
- [x] Draw Y-axis tick labels with `anchor: .trailing` at `CGPoint(x: plot.minX - 6, y: py)`.
- [x] Compute `leftGutter` dynamically: `let leftGutter = max(68, maxTickWidth + 28)`.
- [x] Position Y-axis title at `plot.minX - maxTickWidth - 16` so it never collides with tick numbers during zoom or pan.
- [x] Update `CenteredFigureView` card size calculation to account for adjusted typography and gutter sizes.

---

### Task 3: Inspector Visibility Toggle (⌘I) & Loading Indicator

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:20-50` (`RawViewModel`)
- Modify: `Sources/RawViewApp/RawViewApp.swift:550-575` (`RawViewShell`)
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift:320-350` (`ProjectGallery` header)

**Steps:**
- [x] Add `@Published var showInspector: Bool = true` to `RawViewModel`.
- [x] In `ProjectGallery` top control bar (next to Plot / Data picker), add an Inspector toggle button:
  `Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }`
  with `.help("Toggle Inspector (⌘I)")` and `.keyboardShortcut("i", modifiers: .command)`.
- [x] In `RawViewShell.body`: Only include `inspector` in `HSplitView` when `model.showInspector` is true.
- [x] When sources are being discovered or inspected, display a clean inline loading indicator in the gallery header.

---

### Task 4: Data Tab Search with ⌘F Shortcut

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:830-875` (`MeasurementTable`)

**Steps:**
- [x] Add `@State private var searchText = ""` and `@FocusState private var isSearchFocused: Bool` to `MeasurementTable`.
- [x] Add a search bar at the top of the Data table with search field and match counter ("Showing X of Y rows").
- [x] Bind keyboard shortcut `⌘F` (`.keyboardShortcut("f", modifiers: .command)`) to focus the search field.
- [x] Filter `rows` to only include row indices where at least one channel's formatted value contains `searchText` (case-insensitive).

---

### Task 5: Build, Package, Verification, and Live Process Test

**Files:**
- Run: `./Scripts/check_core.sh`
- Run: `RAWVIEW_APP_PATH=/Applications/RawView.app ./Scripts/package_app.sh`
- Verify: Terminate running instance, launch fresh app, test all features.
