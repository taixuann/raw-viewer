# Explorer Source Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show exact wrapping filenames by default and allow project-owned grammar-variable source labels shared across Explorer views.

**Architecture:** Remove heuristic label construction from ExplorerSidebarView. Persist optional per-grammar label rows in ProjectSettings and resolve them through a pure Core function. Keep parsing, grouping, filename identity, plot titles, and legend labels unchanged.

**Tech Stack:** Swift, SwiftUI, SwiftPM, existing YAML parser. No new dependencies.

**Spec:** Approved Explorer label design recorded below. `docs/superpowers/plans/2026-10-13-profile-editor-shared-controls.md` remains a separate editor workstream; this plan does not replace or execute it.

## Approved Design

- Default label is exact `source.url.lastPathComponent`, including extension. Allow wrapping and natural row height. Do not infer device/date, strip instrument names, or capitalize values.
- Offer `Customize source labels…` in Explorer sidebar controls. Customize only when a valid grammar is available.
- One configuration per grammar ID, shared across Tree, None, and variable-grouped views. Group headings remain unchanged.
- Each row contains ordered variable references joined with ` · `; users add/remove/reorder rows and elements. No arbitrary template language.
- Per-row style: size 10–18 pt inclusive, weight regular/medium/semibold, normal/monospace font, primary/secondary emphasis. Default new row: 12 pt, regular, normal, primary. No free colors or custom font-family picker.
- Preview the focused file live. Apply persists settings; Cancel leaves disk and current presentation unchanged. Reset removes that grammar's customization and restores filename display.
- Missing optional values are omitted before joining. Omit empty rows. If no configured value resolves, filename remains the fallback.
- Missing/invalid grammar, unmatched source, or stale variable references use the exact filename fallback. Do not guess from brackets, underscores, inspection metadata, or another grammar. Show one concise configuration diagnostic, not one warning per source.
- Render custom values unchanged; never edit raw filenames or measurements. Full filename stays available in tooltip and accessibility description even when customized.
- Replace the long orange grammar-unavailable message with static `Grammar unavailable · Details`. Details preserves the actual error and path. Do not hide source-reading errors or use pulsing/blinking warning animation. Investigate reported flicker live; do not assume a cause from screenshots.
- Store optional `source_labels` in `.rawviewer/setting.yaml`, not grammar.yaml or instrument profiles. Preserve data_root, default_view, default_preset, developer_mode, and explorerViews through every settings write.
- Extend settings schema 3 backward-readably: absence means no customization. Earlier binaries may reject the new key; document that forward-compatibility limit rather than promising compatibility.
- Label references count as dependents when Profile Editor rename/delete guards inspect grammar usage. Block those operations until references are removed; do not cascade-rewrite settings.

## Global Constraints

- No commits, pushes, merges, source-file deletion/splitting, or /Applications installation without Tai's approval.
- Scientific raw data is read-only. Use synthetic fixtures.
- No dependencies or unrelated refactors. No changes to profile selection, scientific parsing, caches, plot labels, or grouping semantics.
- Preserve selection, multi-selection, search-by-filename, source IDs, and error indicators.
- Dirty worktree contains uncommitted v3 work. Resolve isolation without reset or omitting that baseline.
- Implementation executor is Codex or OpenCode; controller inspects diffs and actual checks.
- Always run `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh` before completion.

## Review Focus

1. Long filenames, narrow sidebar, Unicode and punctuation remain exact and wrapping. Task 3.
2. Missing optional values never create blank rows or dangling separators. Task 2.
3. Missing grammar, unmatched files and stale refs fall back deterministically without guessed metadata. Task 2.
4. Apply failure/Cancel/Reset preserves unrelated settings and other grammars' layouts. Tasks 1 and 3.
5. Switching views preserves label configuration, selection and search; accessibility retains filename identity. Task 3.

## File Map

- Modify `Sources/RawViewCore/Storage/ProjectSettings.swift`: typed per-grammar rows and persistence/validation.
- Create `Sources/RawViewCore/Discovery/SourceLabelPresentation.swift`: pure label resolution, no filesystem writes or SwiftUI.
- Modify `Sources/RawViewApp/Explorer/ExplorerSidebarView.swift`: remove displayInfo heuristics, render rows, customize popover and concise warning.
- Modify `Sources/RawViewApp/RawViewApp.swift`: existing settings ownership/wiring only if traced call sites require it.
- Modify `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`: include label references in existing rename/delete dependency guards when those guards exist; otherwise record the dependency for the editor workstream before either ships.
- Modify `Tests/RawViewCoreTests/ProjectSettingsTests.swift`; create `Tests/RawViewCoreTests/SourceLabelPresentationTests.swift`.
- Create `docs/handoff/2026-10-13-explorer-source-labels.md`: actual checks and pending native acceptance.

### Task 1: Persist grammar-scoped label rows

**Files:** ProjectSettings.swift, ProjectSettingsTests.swift.

**Interfaces:** Add `SourceLabelLayout(grammarID: String, rows: [SourceLabelRow])`, `SourceLabelRow(variables: [String], fontSize: Int, weight: String, font: String, emphasis: String)`, and `ProjectSettings.sourceLabels: [SourceLabelLayout]` with initializer default `[]`. Use exact enums/allowed strings from Approved Design; no generic style dictionary.

- [ ] Write failing tests `sourceLabelsRoundTripAndPreserveOtherSettings`, `oldSettingsDefaultToFilename`, `invalidLabelStyleAndDuplicateGrammarRejected`. Assert defaults, bounds 10/18 accepted and 9/19 rejected, invalid weight/font/emphasis rejected, empty variable lists/blank names rejected, and every unrelated settings field preserved.
- [ ] Run `swift test --filter ProjectSettingsTests`; record actual RED.
- [ ] Implement `source_labels` as indented YAML sequences using the existing parser. Trace every ProjectSettings construction/update and preserve sourceLabels; reject invalid payloads before writes. Allow `[]` layouts as the reset/default state, not empty rows inside a layout.
- [ ] Run the targeted suite; require PASS. Review serialization and diff. Do not commit.

### Task 2: Resolve labels without heuristic naming

**Files:** SourceLabelPresentation.swift, SourceLabelPresentationTests.swift.

**Interfaces:** Produce `ResolvedSourceLabelRow(text: String, style: SourceLabelRow)` and `SourceLabelPresentation.resolve(filename: String, layout: SourceLabelLayout?, matchedGrammarID: String?, values: [String: String], availableVariables: Set<String>) -> [ResolvedSourceLabelRow]`. Filename fallback uses 12 pt regular normal primary. A mismatched/nil grammar or any stale configured reference falls back for the whole source.

- [ ] Write failing tests `exactFilenameFallback`, `optionalValuesJoinWithoutDanglingSeparator`, `emptyRowsDisappear`, `staleOrUnmatchedGrammarFallsBack`, and `customValuesRemainExact`. Include Unicode filenames/extensions, missing/all-missing values, whitespace values, and two different grammar IDs. Treat absent or whitespace-only values as missing; preserve nonempty original strings.
- [ ] Run `swift test --filter SourceLabelPresentationTests`; record RED.
- [ ] Implement the pure resolver and no other extraction logic. Use current grammar-extracted variable dictionary, not inspection deviceID/timestamp shortcuts.
- [ ] Run targeted tests; require PASS. Review fallback determinism and no mutation. Do not commit.

### Task 3: Render, customize and verify Explorer

**Files:** ExplorerSidebarView.swift, RawViewApp.swift only as required, EditorWorkspaceView.swift for dependency integration, handoff document.

**Interfaces:** Consume Task 1 settings and Task 2 resolver. Trace actual settings callbacks and grammar extraction before adding UI bindings; do not duplicate canonical settings ownership. Stage customization locally; Apply uses existing validated settings save and changes visible configuration only on success.

- [ ] Capture current visual RED: repeated device/date labels and truncated source rows. Inspect actual warning updates for reported flicker.
- [ ] Replace `displayInfo(for:)` heuristics and `.lineLimit(1)` with wrapping resolved rows. Preserve IDs, selection, filename search, source status and accessibility. Remove automatic mode badge from name construction; do not remove genuine status/error feedback.
- [ ] Add customization popover with row/variable order, bounded style controls, focused-file preview, Apply/Cancel/Reset and useful empty states. Preserve layouts for other grammars on Apply/Reset; report save errors without false success.
- [ ] Make grammar warning concise/static with Details. Add sourceLabels to grammar rename/delete reference checks; verify both workstreams agree on the settings field before acceptance.
- [ ] Verify synthetic cases: missing grammar, unmatched file, optional values, changed variables, two grammar layouts, Apply failure, Cancel, Reset, Tree/grouped-view switches, search and multi-selection. Check narrow/wide sidebar, long names, keyboard and VoiceOver. Record PASS/FAIL or pending; Core tests do not prove UI callbacks.
- [ ] Run `swift test`, `./Scripts/check_core.sh`, `./Scripts/check_index_cli.sh`, `git diff --check`; require each exit 0 without pipe-masked status.
- [ ] Package current code with `Scripts/package_app.sh` using session scratch paths; inspect one native screenshot batch, fix observed defects once, confirm at most once. Read Impeccable craft-floor before UI edits.
- [ ] Write handoff with exact executed checks, schema compatibility caveat and pending acceptance. Do not commit. Do not claim scientific acceptance from green tests.

## Self-Review

Default filename, customization, fallback, persistence and warning each have an owning task. Types and resolver signatures are shared explicitly. Five Review Focus conditions have tests/native checks. The plan is separate from editor cleanup but names the grammar-deletion dependency. No implementation starts from this artifact automatically.

## Execution Handoff

Plan complete. Tai reviews this file before implementation. Preserve task-by-task review; resolve executor and dirty-worktree isolation at execution time.
