# Handoff: profile schema v3 and round-trip (Tasks 1–8)

Date: 2026-10-12. Worktree has uncommitted implementation changes for
Tasks 1–7 plus Task 8 docs (`CONTRACT.md`, `README.md`). No commits,
pushes, migrations, or installs were performed. Per-task evidence lives
in `.superpowers/sdd/2026-10-12-profile-schema-v3-and-round-trip/`.

## (a) Status-filter dimension removal disclosure

Explorer `Status` grouping and status filter chips were removed with
hardcoded facets per owner direction (Task 7: `ExplorerSidebarView.swift`
now offers Tree/None plus settings-driven views; `SourceFilter.swift`
gained `removeFacets(notIn:)` so removed-view chips purge cleanly).
Status badges, rows, and diagnostics are kept (`supportStatus` banners
and per-source status in `ExplorerCenterPlotView`, `SourceGrouping`
support rows). The now-unused `SourceGrouping.status` core field was left
in place (deletion would churn Discovery for no behavior gain).

## (b) Deferred-fix-wave list (final review; unfixed, queued)

Carried from final review, not re-verified line-by-line here:

- Task 5: 1 MiB-cap-after-read (sample-match preview reads before
  enforcing the cap — fail-closed but reads first), first-failure-note
  on noMatch (no-match status should name the first failing check),
  unwritable-dir test (no simulated write-failure coverage for the
  preview/sample path).
- Task 4: cache-key overload cut (a proposed `MeasurementCache` key
  simplification was cut from the task; revisit if key construction
  churns again).
- Task 6: CoreSelfCheck 13-line dup cut (a proposed dedup of the
  settings-mirror block in `Scripts/CoreSelfCheck.swift` was cut;
  the block stays as-is while the gate is green).

## (c) Manual UI verification — all PENDING HUMAN, none claimed

Type-checked only (headless environment); each needs a human run:

Task 6 (source editors / lifecycle):

1. Dirty profile → red-dot close → Save writes byte-exact, Discard
   closes, Cancel keeps (do this first-thing before other UI passes).
2. Same matrix for app quit with two dirty windows.
3. ⌘S in each tab saves only that tab's document; sidebar-focused ⌘S
   still saves the workspace document.
4. Invalid YAML Apply/Save leaves disk untouched with diagnostic.
5. External edit/delete → conflict diagnostic → Reload reconciles;
   explicitly also external rename and settings write-failure rollback
   (toggle rolls back with error).
6. Legacy profile shows read-only banner; Import enables editing.
7. Quit with an unsaved v2→v3 upgrade draft (upgrade-draft quit note):
   guard must offer Save/Discard/Cancel without losing the draft.

Tasks 3/5/8 (editor round-trip):

8. Dirty drafts survive variant/sample/source-tab switches; failed Save
   aborts transitions, Cancel keeps state.
9. Schema badge reads Profile schema v2 Legacy / v3; upgrade summary is
   inline with actionable blockers.
10. Dirty Developer-Mode disabling keeps guards armed; two-window
    behavior; long profile names.

Tasks 7/8 (Explorer):

11. Axis channel menus (2+ choices), Default multi-Y series,
    one-channel override, Reset to Variant Defaults.
12. Overlay clicks across channel/quantity/unit contracts; missing-ID
    diagnostic requires explicit reset.
13. Snapshot capture/restore plotting; no profile writes from Explorer.

Cross-cutting:

14. Keyboard and VoiceOver flow (schema/checklist/search/focus,
    inspector menus, dialogs).
15. Narrow-window and enlarged-font layout: native menu-picker
    fallback, stacked axis rows, discoverable horizontal variable-grid
    scrolling (no mobile redesign).

## (d) Scientific acceptance

Green suites (`check_core.sh`, `check_index_cli.sh`, full `swift test`)
establish software-contract compliance only — parsing, routing,
provenance, round-trips, and fail-closed behavior on synthetic
fixtures. Scientific acceptance (correctness of physical
interpretation against real instruments) is explicitly NOT established
by these gates and requires domain review plus the manual UI pass above.

## (e) Task 5 native acceptance — profile editor shared controls (2026-10-13)

Worktree `fix-editor-ergonomics-and-excel-coords`, Tasks 1–4 baseline
kept dirty, no commit/push, no real-configuration deletion (every
destructive path left unexercised by design; nothing was deleted).

Software acceptance (executed, PASS):
- `Scripts/package_app.sh` with session scratch paths
  (`RAWVIEW_APP_PATH=$TMPDIR/pe-task5-RawView.app`,
  `RAWVIEW_BUILD_DIR=$TMPDIR/pe-task5-build`,
  `CLANG_MODULE_CACHE_PATH=$TMPDIR/pe-task5-mcache`): build + `codesign
  --verify --deep --strict` PASS. Bundle launched; empty-state renders.
- Full `swift test`: 368 tests / 14 suites PASS.
  `./Scripts/check_core.sh` PASS. `./Scripts/check_index_cli.sh` PASS.
  `git diff --check` exit 0.
- EXECUTED save-scope byte-diff through the real save paths (transient
  test, removed after the run, never committed): profile-only save via
  `EditorWorkspaceModel.saveDocument` leaves `.rawviewer/grammar.yaml`
  bytes identical; grammar-only save via `FilenameGrammarEngine.save`
  leaves `.rawviewer/instrument/*.yaml` bytes identical. PASS.
- Static audit (code, no defects found, no UI edits made): exactly one
  Save Profile + one Save Grammar in the shared bar with scope-naming
  help; no combined-save wiring; Cmd+S routes via focused-document
  `saveFocusedDocument`; delete confirmations name the exact target
  with Cancel preserved and fail-closed error paths; Developer Mode
  gates the Profile YAML tab; no Upgrade UI reachable from the editor
  (only model-level `upgradeDraft` guards); Save/Delete buttons carry
  text labels + help for VoiceOver (explicit `accessibilityLabel` only
  on diagnostics/status, not a defect).
- Observed live: Profile Editor segment selects; with no project open
  the body keeps the Explorer empty state by design
  (`RawViewApp.swift`: editor renders only when a project is open) —
  not a defect.

PENDING HUMAN (blocked, not claimed):
- Interactive pass never ran: the first driving click past the tab
  switch was refused on user-approval timeout, and the block forbids
  retrying via another path. No project was opened in the UI (synthetic
  fixture ready at `$TMPDIR/pe-task5-proj`, never loaded), so live
  Developer Mode on/off, long/custom names, empty catalogs,
  variant-key eligibility, Cmd+S distinction in-app, keyboard/VoiceOver
  flow, matching errors + Retry, deletion confirmations, failed-save
  feedback, and narrow-window layout are all still pending human
  acceptance with the packaged bundle above.

Scientific acceptance: NOT established by any gate here (synthetic
fixtures only); requires domain review plus the pending human pass.
