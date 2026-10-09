# Lazy Inspection, Fast Filtering, and Native Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform RawView into a lightweight, responsive viewer by replacing eager background file inspection with lazy on-demand inspection, optimizing sidebar facet filtering to eliminate main-thread freezes ("quay mòng mòng"), and introducing a native macOS `Settings` window (`Cmd + ,`) with Appearance, Performance, and Cache tabs.

**Architecture:** 
1. **Lazy on-demand inspection**: Project open runs only the sub-100ms filesystem walk (`discoverSourcesAsync`) and fast SQLite cache lookup. Files render immediately by filename/size, and individual header inspection occurs only when selected/focused or explicitly triggered.
2. **Debounced & hoisted sidebar filtering**: Hoist `Set` allocations and grouping computations out of the SwiftUI `body` loop, caching facet lookups and capping multi-source auto-loading to prevent memory spikes on large cohorts.
3. **Native macOS `Settings` Scene**: Attach standard SwiftUI `Settings` scene to `RawViewApp` providing `Cmd + ,` hotkey access to Appearance (font size, theme), Performance (lazy/eager toggle, comparison cap), and Storage (cache limit, index stats).

**Tech Stack:** macOS 14+, SwiftUI, AppKit, SQLite3 (WAL mode), RawViewCore.

**Spec:** User feedback on 2026-10-09 regarding continuous startup inspection, sidebar freeze when filtering large datasets, and need for a native `Cmd + ,` settings window.

## Global Constraints
- No external dependencies added.
- Existing plot scaling, nature fonts, snapshots, overlay eligibility, and reset button features must remain 100% functional.
- Zero data loss: Raw files and instrument profiles are read-only.
- All core checks (`./Scripts/check_core.sh`) must pass before packaging.

## Review Focus
1. Opening a folder with 5,000+ files must never spin the background inspector endlessly; filenames appear instantly.
2. Clicking a filter chip on thousands of sources must not block the main thread or cause a spinning beachball.
3. Multi-selecting a large cohort (>15 files) must not choke memory with unconstrained concurrent reads.
4. Pressing `Cmd + ,` must reliably open the Settings modal on macOS.
5. SQLite `.rawview/index.db` records must seamlessly hydrate sidebar titles without full file re-reading.

---

### Task 1: Lazy Inspection & On-Demand Loading

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:510-585` (`RawViewModel.install`, `RawViewModel.startInspection`, `RawViewModel.loadFocused`)
- Test: `./Scripts/check_core.sh`

**Interfaces:**
- Consumes: `ProjectContext.discoverSourcesAsync()`, `IndexDatabase.lookupAll()`
- Produces: `isLazyLoadingEnabled: Bool`, on-demand `inspectSourceIfNeeded(id)`

- [ ] **Step 1: Disable automatic eager bulk inspection in `RawViewModel.install`**
In `RawViewModel.install(_ context: ProjectContext)`:
- Discover files via `context.discoverSourcesAsync()`.
- Restore already-cached metadata from SQLite (`lookupAll()`) off the main thread.
- If lazy mode is enabled (default), **do not** call `startInspection(context)` for all uninspected sources. Leave uninspected items in `initialStates` with `inspection == nil`.
- Set `isLoading = false` and `loadingPhase = "Idle"` immediately upon discovery completion.

- [ ] **Step 2: Add on-demand inspection in `loadFocused`**
In `RawViewModel.loadFocused()`:
- When a source is focused, if `sourceStates[id]?.inspection == nil`:
  Perform quick header inspection for this single focused file before loading measurement data.
- Update `sourceStates[id]?.inspection` and save record to SQLite `IndexDatabase`.

- [ ] **Step 3: Provide explicit "Index All" action in sidebar**
In sidebar when uninspected files exist:
- Display a subtle icon/button `Index all (N remaining)` so users can still opt-in to full offline indexing if desired, but never forced upon startup.

- [ ] **Step 4: Verify with `./Scripts/check_core.sh`**
Run `./Scripts/check_core.sh` to ensure type-checking passes.

- [ ] **Step 5: Commit**
```bash
git add Sources/RawViewApp/RawViewApp.swift
git commit -m "perf: enable lazy on-demand source inspection and eliminate startup loading thrash"
```

---

### Task 2: Fast Search & Filtering Optimization

**Files:**
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift:90-120, 345-395` (`ProjectSourcesSidebar.groups`, `labelsByFacet`, `filteredSources`)
- Modify: `Sources/RawViewApp/RawViewApp.swift:330-365` (`ensureSelectedLoaded`)

**Interfaces:**
- Consumes: `ProjectSourcesSidebar.filter`, `RawViewModel.selectedSourceIDs`
- Produces: Debounced filtering, hoisted `allowed` Set, multi-source auto-load threshold (`maxAutoLoad = 15`)

- [ ] **Step 1: Hoist `allowed` Set out of per-group loop in `groups(for:)`**
In `ProjectGalleryViews.swift`:
```swift
let allowed = Set(filteredSources.map(\.id))
return base.compactMap { group -> SourceGroup? in
    let ids = group.sourceIDs.filter { allowed.contains($0) && matches($0, label: group.label) }
    return ids.isEmpty ? nil : SourceGroup(label: group.label, sourceIDs: ids)
}
```
Currently `Set(filteredSources.map(\.id))` is instantiated inside the `compactMap` block for every single group! Hoist it outside the block so it is constructed once per filter pass.

- [ ] **Step 2: Optimize `labelsByFacet` to avoid allocating 6 `Set` objects per file**
Instead of dynamically creating 6 sets for every single file in the array on every render frame, pre-cache or match directly against clean strings.

- [ ] **Step 3: Add multi-source comparison auto-load threshold guard**
In `RawViewModel.ensureSelectedLoaded()`:
- If `pending.count > 15`:
  Cap the automatic parallel load to the first 15 sources in the cohort.
  Add an informative state/banner: *"Overlaying first 15 of \(pending.count) sources to prevent system freeze."*
  This directly prevents the beachball when clicking large filter categories.

- [ ] **Step 4: Verify with `./Scripts/check_core.sh`**
Run `./Scripts/check_core.sh`.

- [ ] **Step 5: Commit**
```bash
git add Sources/RawViewApp/ProjectGalleryViews.swift Sources/RawViewApp/RawViewApp.swift
git commit -m "perf: optimize sidebar facet grouping and add comparison cohort auto-load guard"
```

---

### Task 3: Native macOS Settings Scene (`Cmd + ,`)

**Files:**
- Create: `Sources/RawViewApp/SettingsView.swift`
- Modify: `Sources/RawViewApp/RawViewApp.swift:6-14` (`RawViewApp: App`)
- Modify: `Sources/RawViewApp/RawViewApp.swift` (`RawViewModel` preferences integration)

**Interfaces:**
- Consumes: `@AppStorage` settings, `RawViewModel.cacheStatus`, `RawViewModel.clearCacheFiles`
- Produces: `Settings { SettingsView(...) }` scene in `RawViewApp`

- [ ] **Step 1: Create `SettingsView.swift` with standard 3 tabs**
Implement `struct SettingsView: View` with `TabView`:
1. **Appearance Tab** (`paintbrush`):
   - Theme mode (`System`, `Light`, `Dark`).
   - Font size preset (`Small: 11pt`, `Default: 13pt`, `Large: 15pt`).
   - Plot typography choice (Nature Serif vs Sans).
   - Default plot line width (`0.5 ... 5.0 pt`).
2. **Performance Tab** (`bolt.fill`):
   - Loading mode toggle: `Lazy (on-demand inspection)` vs `Eager (bulk background index)`.
   - Max comparison auto-load cap (`5`, `10`, `15`, `25`, `50`).
3. **Storage Tab** (`internaldrive`):
   - RAM & Disk cache size status.
   - Max cache limit stepper / slider.
   - Action buttons: *"Clear Cache"*, *"Rebuild Project Index"*.

- [ ] **Step 2: Add `Settings` scene to `RawViewApp: App`**
In `Sources/RawViewApp/RawViewApp.swift`:
```swift
@main
struct RawViewApp: App {
    var body: some Scene {
        WindowGroup("RawView") { RawViewShell() }
            .defaultSize(width: 1320, height: 820)
            .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }
    }
}
```
This automatically provides native macOS `Cmd + ,` hotkey support and the "Settings…" menu item.

- [ ] **Step 3: Connect settings to `RawViewModel` and UI styling**
Wire font scale and lazy loading options into `RawViewModel` and views.

- [ ] **Step 4: Verify with `./Scripts/check_core.sh`**
Run `./Scripts/check_core.sh`.

- [ ] **Step 5: Commit**
```bash
git add Sources/RawViewApp/SettingsView.swift Sources/RawViewApp/RawViewApp.swift
git commit -m "feat(settings): add native macOS Settings window with Appearance, Performance, and Storage tabs"
```

---

### Task 4: Ponytail Review & Code Modernization

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift`
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift`

- [ ] **Step 1: Clean up redundant structures identified during audit**
- Remove unneeded computed property churn.
- Ensure all legacy code comments and active features remain strictly preserved without accidental deletions.

- [ ] **Step 2: Verify with `./Scripts/check_core.sh`**
Run `./Scripts/check_core.sh`.

- [ ] **Step 3: Commit**
```bash
git add Sources/RawViewApp/RawViewApp.swift Sources/RawViewApp/ProjectGalleryViews.swift
git commit -m "refactor(cleanup): apply ponytail simplifications and modernize state flow"
```

---

### Task 5: End-to-End Build, Package, and Verify Application

**Files:**
- Execute: `./Scripts/package_app.sh`

- [ ] **Step 1: Production release packaging**
Run `RAWVIEW_APP_PATH=/Applications/RawView.app ./Scripts/package_app.sh`.

- [ ] **Step 2: Relaunch and live process verification**
Kill previous process and launch `/Applications/RawView.app`.
Verify with `pgrep -lf RawView`. Test `Cmd + ,` to open the Settings window and verify instant folder loading.
