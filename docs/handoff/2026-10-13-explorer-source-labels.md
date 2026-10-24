# Handoff: Explorer source labels Task 3 (render + customize + verify)

Date: 2026-10-13. No commits, pushes, resets, or installs. Temp probe test
created for diagnosis and removed. Fixtures live only in session scratch
(`label-fx`, `label-nogram`), never in the repo. User defaults recents
restored to the pre-existing real project.

## What changed

- `Sources/RawViewApp/Explorer/ExplorerSidebarView.swift`
  - Removed `displayInfo(for:)` heuristics (bracket/device inference,
    date guessing, instrument-name stripping, mode badge) and
    `.lineLimit(1)` truncation on source rows.
  - Rows render wrapping resolved rows via `SourceLabelPresentation.resolve`
    (Task 2, reused as-is). First matching grammar in catalog order wins;
    missing grammar / unmatched file / stale refs fall back to the exact
    filename. IDs, selection, filename search, status dot, Focused pill,
    tooltip, and filename-based accessibility label preserved.
  - `Customize source labels…` tag button in sidebar controls, disabled
    without a grammar catalog. Popover stages edits locally: grammar
    picker, row/variable add-remove-reorder, style controls (size 10–18
    stepper, weight/font/emphasis segmented), focused-file preview, stale
    variable note, Apply (validated save, other grammars preserved, closes
    only on success) / Cancel (discards) / Reset (removes that grammar's
    layout).
  - Grammar warning is now static `Grammar unavailable · Details`; Details
    reveals the full error + path. No animation.
- `Sources/RawViewApp/RawViewApp.swift` (existing wiring pattern only)
  - `@Published sourceLabelLayouts`, loaded/cleared in
    `refreshExplorerViews`, `saveSourceLabels` mirroring
    add/removeExplorerView (write-first, visible change only on success,
    error string returned, all other settings preserved). Sidebar call
    site passes layouts + save callback.
- `EditorWorkspaceView.swift`: NO change. There are no rename/delete
  dependency guards for grammars or explorer views in this workstream
  (`renameActiveGrammar` renames with no guard; no delete function).
  Per plan, the sourceLabels-as-dependents rule is recorded here for the
  editor workstream instead of invented: block grammar rename/delete
  while `source_labels` references that grammar ID / variable, same as
  explorer views, before either ships.

## Native verification (packaged app, synthetic fixtures, real pixels)

- PASS default: exact filenames, wrapping (3-line 70+ char name intact).
- PASS custom: `keithley · 001`/`2026-10-01`, optional-missing `keithley`/
  `2026-10-03` (no dangling separator), unmatched
  `notes-unmatched-file.csv` fallback, two grammar layouts persisted.
- PASS narrow + wide: long labels wrap, no truncation, no breakage.
- PASS popover: opens, loads both saved rows with styles, live preview.
- PASS Apply: font_size 13 on disk, other grammar + settings preserved.
- PASS Cancel: disk byte-identical, popover closed.
- PASS Reset: iv-sweep layout removed, raman-map + all else preserved,
  rows back to exact filenames.
- PASS Apply failure: unwritable dir → disk unchanged, popover stays open
  with `settings could not be saved: You don't have permission…`.
- PASS missing grammar: `Grammar unavailable · Details`, full error+path
  on Details, customize disabled, exact filename row.
- Precedence note: `wafer-A_map-03.csv` prefix-matches iv-sweep, so the
  first-match rule labels it via iv-sweep, not raman-map. Deterministic
  and consistent with engine matching; not a defect. Reorder grammars if
  a project needs another winner.
- Packaging: first attempt failed on quoted `$TMPDIR` in exports
  (literal-quote output-file-map error, exit masked by pipe); rerun with
  unquoted exports, output to file, exit 0 unmasked.
- Pending human: keyboard-only flow, VoiceOver pass, Tree/None/grouped
  view switching with labels, multi-select comparison with custom rows,
  in-popover variable add/remove/reorder clicks (same proven Apply path),
  flicker re-check under load (no animation in new warning by
  construction).

## Gates (all exit 0, unmasked)

- `swift test`: 359 tests, 14 suites, pass.
- `./Scripts/check_core.sh`: pass (incl. app-layer type-check).
- `./Scripts/check_index_cli.sh`: pass.
- `git diff --check`: clean.

## Compatibility caveat (from plan)

Absence of `source_labels` means no customization. Earlier binaries
reject the new key on load; forward compatibility is not promised.
