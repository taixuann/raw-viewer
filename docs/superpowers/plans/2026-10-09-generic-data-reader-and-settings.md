# Generic Scientific Table Sniffer, Column Mapper, and Settings Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a zero-configuration heuristic scientific table sniffer and interactive column mapper for raw measurement files lacking instrument profiles, and upgrade the macOS Settings window with live project database statistics, manual re-indexing, and reactive appearance bindings.

**Architecture:** A pure-Swift table sniffer (`GenericTableReader`) scans unprofiled measurement files, detects delimiters (comma, tab, semicolon, whitespace) and decimal notations (dot vs comma), isolates the rectangular numeric matrix, and extracts column titles/units from preceding header rows. When a source lacks a YAML profile, `InstrumentReader` seamlessly falls back to `GenericTableReader`. An interactive **Data Mapping** section in `InspectorPane` lets users pick custom X/Y columns and edit axis labels on the fly. The Settings window is linked to `RawViewModel` and `IndexDatabase` to display live disk usage and index records, offer index rebuild/vacuum actions, and faithfully apply appearance preferences across the app.

**Tech Stack:** Swift 5.9+, AppKit, SwiftUI, SQLite3 (`libsqlite3.dylib`), Foundation, CryptoKit.

**Spec:** User requirements from session 2026-10-09 (fallback-only generic reader for unprofiled files, numeric cell continuity heuristic, custom X/Y mapping, live database settings with re-index capability).

## Global Constraints
- The generic reader is strictly a **fallback path**: files matching existing declarative YAML profiles (`data/instruments/*.yaml`) MUST continue using their specialized profiles with zero behavioral regression.
- The app remains 100% self-contained in native Swift: no Python runtime or external process invocation.
- All disk and database operations must stay off `@MainActor` to ensure instantaneous UI response.
- Verification must pass `./Scripts/check_core.sh` with zero compiler warnings.

## Review Focus
1. European decimal comma notation with tab delimiters (e.g. `800,788\t4,01187` in Raman spectra) must parse as valid floats without splitting columns.
2. UTF-8 BOM prefixes (e.g. `\u{FEFF}`) on CSV files must be stripped cleanly so the first column header is not corrupted.
3. Multi-line metadata headers starting with comments (`#`, `;`, `//`) must be skipped without triggering false parsing failures.
4. If a file has fewer than 2 numeric columns or zero numeric rows, the generic reader must return an informative, human-readable error rather than crashing.
5. In Settings, altering cache limit bytes must persist to `"rawView.cacheLimitBytes.v1"` so `MeasurementCache` immediately respects the limit.

---

### Task 1: Heuristic Generic Table Sniffer & Parser (`GenericTableReader.swift`)

**Files:**
- Create: `Sources/RawViewCore/GenericTableReader.swift`
- Create: `Scripts/GenericTableReaderTests.swift`

**Interfaces:**
- Consumes: Raw file URLs, candidate string content, `NormalizedMeasurement`.
- Produces:
  ```swift
  public struct GenericTableInspection: Sendable, Equatable {
      public let delimiter: Character
      public let decimalSeparator: Character
      public let headerLineIndex: Int?
      public let dataStartLineIndex: Int
      public let columnNames: [String]
      public let columnUnits: [String?]
      public let totalRows: Int
      public let sampleRows: [[Double]]
  }

  public enum GenericTableReader {
      public static func inspect(url: URL, maxSampleLines: Int = 100) throws -> GenericTableInspection
      public static func loadMeasurement(url: URL, sourceID: String, xColumnIndex: Int = 0, yColumnIndex: Int = 1, customXLabel: String? = nil, customYLabel: String? = nil) throws -> NormalizedMeasurement
  }
  ```

- [ ] **Step 1: Write the failing self-check test in `Scripts/GenericTableReaderTests.swift`**
  Assert that tab-separated Raman data with `#` comment headers and comma-separated endurance CSV data are correctly sniffed, returning correct column names, delimiters, and numeric data blocks.

- [ ] **Step 2: Run test to verify it fails**
  Run: `swiftc Sources/RawViewCore/*.swift Scripts/GenericTableReaderTests.swift -o /tmp/test-table && /tmp/test-table`
  Expected: FAIL with "GenericTableReader not found"

- [ ] **Step 3: Implement `GenericTableReader` in `Sources/RawViewCore/GenericTableReader.swift`**
  - Read first 100 lines.
  - Test candidate delimiters: `\t`, `,`, `;`, and whitespace sequences.
  - Determine decimal point (`.` vs `,`) by analyzing token parsing frequency.
  - Scan for continuous numeric matrix: at least 3 consecutive rows having equal column count $K \ge 2$ with $>80\%$ numeric cells.
  - Extract header line $L-1$ into column names and regex-parse units enclosed in `(...)` or `[...]`.
  - Parse full dataset into `NormalizedMeasurement` using specified or default column indices (col 0 for X, col 1 for Y).

- [ ] **Step 4: Run test to verify it passes**
  Run: `swiftc -I Sources/RawViewCore Sources/RawViewCore/*.swift Scripts/GenericTableReaderTests.swift -o /tmp/test-table && /tmp/test-table`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/RawViewCore/GenericTableReader.swift Scripts/GenericTableReaderTests.swift
  git commit -m "feat(core): add heuristic generic scientific table sniffer and parser"
  ```

---

### Task 2: Seamless Fallback in `InstrumentReader` for Unprofiled Files

**Files:**
- Modify: `Sources/RawViewCore/InstrumentReader.swift:420-460`
- Modify: `Sources/RawViewCore/InstrumentReader.swift:50-100`

**Interfaces:**
- Consumes: `InstrumentCatalog.resolve`, `GenericTableReader.inspect`, `GenericTableReader.loadMeasurement`.
- Produces: If catalog resolution fails to match any YAML profile, `InstrumentReader.inspectSource` invokes `GenericTableReader.inspect` and records a synthetic `SourceInspection` with `profileID: "generic-table"`, allowing the file to be opened and plotted.

- [ ] **Step 1: Write test case in `Scripts/CoreSelfCheck.swift`**
  Add verification that inspecting `active-projects/test/data/raw/sample_endurance.csv` (which has no instrument profile) resolves successfully to `"generic-table"` format.

- [ ] **Step 2: Verify failure before implementation**
  Run: `./Scripts/check_core.sh`
  Expected: FAIL (source fails profile resolution).

- [ ] **Step 3: Implement fallback logic in `InstrumentReader.swift`**
  - In `InstrumentReader.inspectSource`: when `catalog.resolve` returns `.failed` or foreign match, call `GenericTableReader.inspect(url: source.url)`. If successful, return `SourceInspection(format: "Generic Table (\(delimiterName))", profileID: "generic-table", sampleStats: ...)`.
  - In `InstrumentReader.loadMeasurement`: when profile ID is `"generic-table"`, route to `GenericTableReader.loadMeasurement`.

- [ ] **Step 4: Verify test passes**
  Run: `./Scripts/check_core.sh`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/RawViewCore/InstrumentReader.swift Scripts/CoreSelfCheck.swift
  git commit -m "feat(reader): fallback to generic table sniffer when instrument profile is missing"
  ```

---

### Task 3: Interactive Column Mapping & Title Editor in Right Inspector Pane

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift` (`RawViewModel`, custom column selections)
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift` (`InspectorPane` UI)

**Interfaces:**
- Consumes: `model.sourceStates[focusedID]?.measurement`, `measurement.profileID == "generic-table"`.
- Produces:
  - `RawViewModel.genericColumnMapping: [String: (xCol: Int, yCol: Int)]`
  - Re-triggers single-source load with selected column indices when user changes X or Y column pickers.
  - Section in `InspectorPane` labeled **Data Mapping**:
    - X Axis Column dropdown (lists available file columns with detected headers).
    - Y Axis Column dropdown.
    - Editable X & Y axis label text fields.
    - Button **"Save as Instrument Profile"** (writes a standard `.yaml` template into `data/instruments/`).

- [ ] **Step 1: Add column mapping state in `RawViewModel`**
  Add `@Published var columnSelections: [String: (x: Int, y: Int)] = [:]` and support custom column loading in `loadFocused()`.

- [ ] **Step 2: Add Data Mapping section to `InspectorPane`**
  In `InspectorPane`, when focused measurement has profile ID `"generic-table"`, display interactive pickers for X column and Y column with column titles.

- [ ] **Step 3: Verify compilation with `./Scripts/check_core.sh`**
  Run: `./Scripts/check_core.sh`
  Expected: PASS

- [ ] **Step 4: Commit**
  ```bash
  git add Sources/RawViewApp/RawViewApp.swift Sources/RawViewApp/ProjectGalleryViews.swift
  git commit -m "feat(inspector): add interactive X/Y column mapper and title editor for generic data"
  ```

---

### Task 4: Comprehensive Settings Window Upgrade (`SettingsView.swift`)

**Files:**
- Modify: `Sources/RawViewApp/SettingsView.swift`
- Modify: `Sources/RawViewApp/RawViewApp.swift`

**Interfaces:**
- Consumes: `model.project`, `model.indexDatabaseURL`, `IndexDatabase`, `UserDefaults`.
- Produces:
  - **Appearance**: Apply theme on app launch and onChange; bind `plotFontSerif` and `defaultLineWidth` to `NativePlotCanvas`.
  - **Storage & Database**:
    - Display live SQLite index stats: file size on disk in MB, total records in `sources` table vs project source count.
    - Button **"Re-index Project"**: Triggers `model.resumeInspection()`.
    - Button **"Clear & VACUUM Index"**: Resets `.rawview/index.db`.
    - Fix cache limit key to `"rawView.cacheLimitBytes.v1"`.

- [ ] **Step 1: Connect `RawViewModel` into `SettingsView`**
  Pass `model` or access environment/UserDefaults so Settings reflects current open project database information.

- [ ] **Step 2: Implement Live Database Section in `storageTab`**
  - Compute size of `project.indexDatabaseURL` in bytes.
  - Show count of indexed entries vs total sources.
  - Add Re-index and Clear Index buttons.

- [ ] **Step 3: Fix Cache Key & Appearance Synchronization**
  - Use `"rawView.cacheLimitBytes.v1"` in cache limit picker.
  - Connect `plotFontSerif` and `defaultLineWidth` to plot rendering.

- [ ] **Step 4: Verify compilation with `./Scripts/check_core.sh`**
  Run: `./Scripts/check_core.sh`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/RawViewApp/SettingsView.swift Sources/RawViewApp/RawViewApp.swift
  git commit -m "feat(settings): connect live SQLite stats, re-index action, and reactive appearance bindings"
  ```

---

### Task 5: End-to-End Verification on `active-projects/test` Playground

**Files:**
- Test playground: `/Users/tai/research-projects/active-projects/test/data/raw/` (`sample_raman.txt`, `sample_endurance.csv`).

- [ ] **Step 1: Build release app bundle**
  Run: `RAWVIEW_APP_PATH=/Applications/RawView.app ./Scripts/package_app.sh`
  Expected: Packaged and verified `/Applications/RawView.app`.

- [ ] **Step 2: Launch and verify live behavior**
  - Open `/Users/tai/research-projects/active-projects/test`.
  - Verify that both `sample_raman.txt` and `sample_endurance.csv` appear without errors, their headers and delimiters are auto-detected, and plots render cleanly.
  - In `sample_endurance.csv`, change Y column from `v_lrs_V` to `r_hrs_ohm` via Inspector Data Mapping and verify graph updates immediately.
  - Press `Cmd + ,` to open Settings, verify Live Database Stats display accurately, and test Appearance toggles.

- [ ] **Step 3: Final commit and summary**
  ```bash
  git commit -am "test(e2e): verify generic table sniffer and settings on test playground"
  ```
