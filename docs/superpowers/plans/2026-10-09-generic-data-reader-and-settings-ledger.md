# Execution Ledger: Generic Scientific Table Sniffer, Column Mapper, and Settings Upgrade

Plan: docs/superpowers/plans/2026-10-09-generic-data-reader-and-settings.md
Started: 2026-10-09
Completed: 2026-10-09

## Status
- [x] Task 1: Heuristic Generic Table Sniffer & Parser (`GenericTableReader.swift`)
  - Delimiter sniffer (`,`, `\t`, `;`, space), decimal dot vs comma sniffer.
  - Rectangular numeric block isolation, header/unit extraction from preceding non-numeric lines.
  - Synthesis of `NormalizedMeasurement` with channels and default XY view.
  - Unit tests verified in `Scripts/GenericTableReaderTests.swift`. (Commit `ed7c908`)
- [x] Task 2: Seamless Fallback in `InstrumentReader` for Unprofiled Files
  - Added zero-config fallback to `GenericTableReader` when `catalog.match()` finds no YAML profile.
  - Tagged with `profileID: "generic-table"` and `instrumentID: "generic-table"`.
  - In-tree core self check added to `Scripts/CoreSelfCheck.swift`. (Commit `3d273c3`)
- [x] Task 3: Interactive Column Mapping & Title Editor in Right Inspector Pane
  - Added Data Mapping section in `InspectorPane` when `profileID == "generic-table"`.
  - Dynamic dropdown pickers for X Axis Column and Y Axis Column from all numeric channels.
  - Interactive remapping method `updateGenericColumnMapping(sourceID:xCol:yCol:)` in `RawViewModel`. (Commit `e3985cb`)
- [x] Task 4: Comprehensive Settings Window Upgrade (`SettingsView.swift`)
  - Shared `@StateObject private var model = RawViewModel()` at `RawViewApp` level.
  - Connected `SettingsView` to live project SQLite database (`model.databaseStats`, file size, indexed sources count, Re-index Project button).
  - Fixed cache limit key synchronization to `"rawView.cacheLimitBytes.v1"`.
  - Restored `appTheme` on startup in `RawViewApp.init()`.
  - Wired `plotFontSerif` (`@AppStorage("plotFontSerif")`) and `defaultLineWidth` into `NativePlot`. (Commit `6d99757`)
- [x] Task 5: End-to-End Verification on `active-projects/test` Playground
  - Created playground with `sample_endurance.csv` and `sample_raman.txt` without `data/instruments`.
  - Added `activeProjectTestSelfCheck` in `Scripts/CoreSelfCheck.swift` confirming 100% discovery and load without errors. (Commit `373e3ee`)
  - Verified `./Scripts/check_core.sh` passes cleanly (both core self-check and app layer type-check).
  - Built, signed, and packaged production app into `/Applications/RawView.app`.

## Rulings
- Pure native Swift implementation linking macOS frameworks only (zero Python runtime dependency).
- 100% backward compatibility: existing instrument profiles in `data/instruments/*.yaml` remain authoritative and untouched.
