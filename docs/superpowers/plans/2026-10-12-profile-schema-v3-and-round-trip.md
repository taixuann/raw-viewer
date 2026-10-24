# Profile Schema v3, Variants and Editor Round-Trip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Save one named profile containing key-routed parsing variants and use exactly those definitions in editor and Explorer.

**Architecture:** Grammar catalog defines metadata extraction; profile owns variant_keys and variants; settings own Explorer views and Developer Mode. A typed profile document is the shared serializer/editor/runtime contract. This revision supersedes all earlier one-mode-per-file instructions; still schema v3 because it is not shipped.

**Tech Stack:** Swift, SwiftUI, Foundation, existing YAMLParser, reader/cache. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-12-profile-schema-v3-design.md`. Explorer-view requirements: `docs/superpowers/plans/2026-10-12-grammar-driven-explorer-views.md`. Historical observed audit: `docs/superpowers/plans/2026-10-12-profile-persistence-audit.md`; its independent-profile recommendation is superseded by the spec.

## Global Constraints

- Read AGENTS.md. Do not delete/split existing source files.
- Preserve raw evidence and Study-owned profiles. No real-project migration in this implementation brief.
- One profile file contains variants; variant edits/save never drop other variants.
- Grammar types remain string/number/datetime. Roles annotate metadata only. Variant Key controls live in Grammar UI but persist in the active profile.
- No Aux type; ordinary channel, progression and skip retain explicit definitions.
- Physical row/column coordinates on disk are one-based. Empty cells preserve positions. Marker/header locators remain explicit; never freeze legacy layouts from one sample.
- Preserve v1/v2 reader/security/gap/encoding semantics. No silent fallback, first-match choice, invented columns or sample constants.
- No commits, pushes, installs or publication without authorization.
- Executor is Tai-selected Codex or OpenCode. Isolate implementation; preserve current dirty worktree and explicitly resolve baseline prerequisites.

## Review Focus

1. Same key tuple, different layouts must resolve uniquely or produce ambiguity.
2. Switching variants/samples/source tabs must preserve all drafts and unaffected variant definitions.
3. Legacy conversion preserves markers, aliases, optional columns, encoding and multi-Y defaults without rewriting originals.
4. Invalid references, external changes and partial saves must never replace valid files or falsely report success.
5. Defaults, preview axes and Explorer overrides stay separate; cache identity includes exact profile/variant/grammar provenance.

## File responsibilities

- Discovery/FilenameGrammarEngine.swift: strict versioned grammar catalog and legacy import.
- Reader/InstrumentProfile.swift: v3 document, variants, validation and catalog compatibility.
- Editor/EditorWorkspaceModel.swift: document/selected-variant editing and mappings.
- Reader/InstrumentReader.swift and NormalizedMeasurement.swift: resolution, extraction and provenance.
- Storage/ProjectSettings.swift and MeasurementCache.swift: settings preservation and complete fingerprints.
- Existing Editor/Explorer views and RawViewApp: document lifecycle, routing-key controls, source editors, settings and axes. Avoid unrelated redesign.

---

### Task 1: Grammar persistence contract

**Files:** Modify `Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift`, `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`; test `Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift`.
**Interfaces:** Versioned grammar catalog at `.rawviewer/grammar.yaml`; fields/keys exactly as spec. Retain existing public extraction types; provide throwing validated load/save rather than malformed/missing conflation.

- [ ] Write tests for full catalog round-trip, custom metadata roles, arbitrary variable names, raw leading zeros, type/format errors, duplicate IDs and exact template-field correspondence.
- [ ] Write tests for optional delimiter/bracket semantics using complete and incomplete filenames; partial extraction must not route. Cover legacy absent types/path, malformed canonical file and no silent fallback.
- [ ] Run FilenameGrammarEngineTests in the repo-supported Swift environment; require intended RED.
- [ ] Implement strict schema-v1 catalog parsing/serialization, stable role keys mapped to UI labels and explicit legacy diagnostics. No variant key or Explorer settings in grammar output.
- [ ] Run tests; require actual GREEN. Save errors preserve existing documents. Review diff without committing.

### Task 2: Typed variant profile contract

**Files:** Modify `Sources/RawViewCore/Reader/InstrumentProfile.swift`, `Sources/RawViewCore/Editor/EditorWorkspaceModel.swift`; create `Tests/RawViewCoreTests/ProfileDocumentV3Tests.swift`.
**Interfaces:** Add `ProfileDocumentV3: Sendable, Equatable`, nested variants and locator types exactly matching spec; `parse(text: String) throws -> ProfileDocumentV3`, `serializedYAML() throws -> String`. Editor owns full document plus selectedVariantID. `makeProfileDocument()` and `applyProfileDocument(_:selectedVariantID:)` preserve all variants and distinguish profile/instrument identity.

- [ ] Write testV3RoundTripsMultipleVariants: full equality for composite keys, cv/ca/eis-like synthetic variants, two layouts sharing keys, all locators, skip/progression/axes/defaults, optional columns and metadata.
- [ ] Write rejection tests for unsafe profile ID, duplicate variant/column IDs, optional/unknown routing keys, incomplete key_values, unknown selectors/enums, invalid coordinates and skipped/missing/optional default axes.
- [ ] Run ProfileDocumentV3Tests; require intended RED.
- [ ] Implement document validation and scalar escaping. Duplicate key tuples are not immediately rejected; runtime selectors must still establish exactly one match. Validate references against Task 1 catalog. Never add a fallback X/Y when none exist.
- [ ] Run new/existing editor tests; require GREEN. Verify serialization retains unaffected variants.

### Task 3: Variant-aware editor and save lifecycle

**Files:** Modify `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`, `Panels/EditorCenterCanvasView.swift`, `Panels/EditorLeftSidebarView.swift`, `Panels/FilenameTokensStudioView.swift`, `ParserSettingsCanvasView.swift`, `LiveSandboxPlotView.swift`, `Sources/RawViewCore/Editor/EditorWorkspaceModel.swift`; test ProfileDocumentV3Tests.
**Interfaces:** Profile document selection in sidebar; Variant menu and Add/Duplicate Variant in workspace. Variable table exposes Variant Key checkbox scoped to active profile. New Profile copies whole document; Duplicate Variant copies only current variant. Profile Save writes complete document to `.rawviewer/instrument/<profileID>.yaml`.

- [ ] Write tests for editing A, switching to B and saving without losing A; duplicating profile vs variant; key-set change requiring all variant values; preview sample preserving every definition and dirty state.
- [ ] Run tests RED; implement explicit document-to-variant edit mapping and whole-document save. Variant switch retains incomplete visual drafts in memory, not disk; required-field failures block whole-document Save, not navigation between variants. Dirty unapplied YAML requires Apply/Discard/Cancel before visual navigation. Test completing two unresolved upgrade variants without navigation traps.
- [ ] Add Routing keys for <profile name> scope note, required-only key eligibility and per-variant key-value editor. Keys do not auto-select values or reinterpret metadata roles. No selected profile disables key controls with explanation.
- [ ] Add visible visual controls for fixed/marker/first-nonblank row boundaries, header/position/aliases/required column properties, encoding/extensions and compatibility selectors in a collapsed Matching & Layout section. Do not bury unresolved migration fields in Developer Mode alone.
- [ ] Implement Save failure, external-conflict and combined grammar/profile partial-save status. Stop category.yaml writes only after consumers migrate; preserve legacy files. Save from a variant always writes the full profile document.
- [ ] Preserve draft state above conditional workspace mounting. Guard profile/project/workspace/New/Import/close/quit transitions; failed Save aborts transition, Cancel keeps state.
- [ ] Run tests and app checks; manually verify Profiles first, Sample/Cohort as preview inputs, stable IDs and Sandbox Use as Profile Defaults applies only to selected variant.

### Task 4: Exact variant resolution and extraction

**Files:** Modify `Sources/RawViewCore/Reader/InstrumentProfile.swift`, `InstrumentReader.swift`, `NormalizedMeasurement.swift`, `Sources/RawViewCore/Storage/MeasurementCache.swift`; test InstrumentReaderTests and ProfileDocumentV3Tests.
**Interfaces:** Full grammar match → exact raw key tuple → compatibility selectors/stream checks → exactly one variant. Normalized results and inspections retain profileID/variantID and grammar/document fingerprints plus axis eligibility/progression. Legacy case-insensitive selectors remain explicit, not global key normalization.

- [ ] Write tests for different modes with shared grammar, repeated tuple/different headers, ambiguous candidates, missing key, partial match, encoding alternatives, reordered header-only columns and position/header disagreement.
- [ ] Write save-parse-load round-trip asserting exact profile AND variant provenance, values/gaps, units, defaults, metadata changing per file, skip exclusion and optional absent channels. Generic fallback must fail these assertions.
- [ ] Run tests RED; implement bounded secure streaming resolution/extraction with existing acquisition/gap behavior. Runtime failures cannot silently route v3 into generic success. Preserve source-qualified metadata conflicts.
- [ ] Include complete document, variant and grammar in cache identity. Test grammar-only/key/variant edits invalidate cache; payload version if result schema changes.
- [ ] Merge canonical/legacy catalog peers without hiding unrelated profiles; ambiguity remains explicit. Ignore archive directories if present. Run legacy/cache/security regressions GREEN.

### Task 5: Thin v1/v2 conversion adapter and sample matching

**Files:** Modify InstrumentProfile.swift, EditorWorkspaceModel.swift, EditorWorkspaceView.swift, EditorCenterCanvasView.swift, EditorLeftSidebarView.swift; test ProfileDocumentV3Tests/InstrumentReaderTests.
**Interfaces:** Upgrade… creates one unsaved v3 profile document with variants from selected legacy modes; originals unchanged. Unresolved grammar/key values/unsupported semantics are actionable Needs definition, not guessed. Read-only schema badge and inline upgrade summary; no new panel or archive manager.

- [ ] Write generic fixture tests for marker/first-row/headerless layouts, varying row counts, aliases, optional channels, encoding, selected modes and multi-Y; preserve all transferable declarations.
- [ ] Run RED; implement strict typed adapter bypassing lenient first-mode loader. Never branch on real instrument names. Unsupported fields cannot disappear through acknowledgment. Cancel/zero selection/repeated upgrade/colliding path/write failure preserve originals and drafts.
- [ ] Provide mode selection only when needed; each selected mode becomes a variant in one draft. Schema shows Profile schema v2 Legacy / v3; migration draft status v2 → v3 Draft. Readiness and testing are separate.
- [ ] Compare old/new reader outcomes on generic fixtures, not only successful parse. Real PDA data is optional read-only integration evidence, not the fixture authority.
- [ ] Match preview by exact profile/variant and fresh source/catalog/grammar fingerprints, excluding generic candidates. Off-main bounded I/O and generation checks prevent late A-to-B results. Show Searching, Match confirmed, No matching sample, Ambiguous or I/O error with Retry.
- [ ] Searchable Choose sample reaches every source. Manual selection is marked unconfirmed until checked. No match clears stale confirmation (status → unconfirmed; loaded sample kept, never silently unloaded); all sample switches preserve drafts/definitions.
- [ ] Run tests GREEN; manual keyboard/VoiceOver schema/checklist/search/focus cases. No real migration or archive deletion.

### Task 6: Developer source editors and project settings

**Files:** Modify ProjectSettings.swift, RawViewApp.swift, SettingsView.swift, HotkeyManager.swift and existing Editor views; create `Tests/RawViewCoreTests/YAMLDocumentEditingTests.swift`; test ProjectSettingsTests.
**Interfaces:** developerMode false default in project settings v3. Profile YAML edits entire variants document. Grammar Edit YAML switches Visual/YAML inline for complete project catalog. One focused-window context Save command; no duplicate command-S bindings.

- [ ] Write settings round-trip/preservation tests for project configure/data-root changes and Explorer view updates, including developer_mode/explorer_views.
- [ ] Write draft tests for exact source-byte/comment preservation, invalid YAML, two dirty documents, external rename/delete/change, failed saves and canceled transitions.
- [ ] Run RED; add native project-scoped toggle in existing settings with no-project disabled state and rollback on write failure.
- [ ] Implement native monospaced source editing, undo/redo, no smart substitutions, visible exact path/scope, text status and actionable diagnostics. Save validates all variants, not only selected variant. Do not mutate shared grammar on profile save without explicit combined action.
- [ ] Apply valid source draft to visual state explicitly; apply is not save. Invalid draft stays intact. Restrict direct writes to canonical viewer-owned paths; legacy/Study imports read-only. Focus in sidebar never changes active document Save target.
- [ ] Run tests GREEN; manually verify two windows, source/visual transitions, dirty Developer Mode disabling, conflict recovery, accessibility, long names and adaptive native menu picker when tabs do not fit.

### Task 7: Explorer views and variant-defined axis controls

**Files:** Modify ProjectSettings.swift, SourceGrouping.swift, ExplorerSidebarView.swift, ExplorerInspectorView.swift, ExplorerCenterPlotView.swift, RawViewApp.swift; test ProjectSettingsTests, FilenameGrammarEngineTests, ProfileDocumentV3Tests.
**Interfaces:** Consume approved Explorer-view plan without grammar-side grouping checkbox. Effective axis choices are selected variant's declared available columns; overrides are per-source/session, keyed by profile/variant/stable column IDs, never automatic profile writes.

- [ ] Write tests for dynamic grammar-variable views/settings preservation and absent/unmatched references, plus multiple X/Y options, skip exclusion, optional-present eligibility and stable duplicate-label selection.
- [ ] Run RED; implement Add View from Filename… with preview/save/remove, keeping Tree/None. Persist only view references in settings; key fields remain unrelated to view eligibility.
- [ ] Add channel menus to existing Axes rows only when multiple choices exist. Keep Absolute and Linear/Log. Preserve multiple default Y series as Default series; one-channel selection overrides display, Reset restores selected variant defaults.
- [ ] Validate overlays across all source channel/quantity/unit contracts. Recompute labels/units/domains/snapshots from effective selection; missing IDs require explicit reset, no first-column substitution. New sources use their own variant defaults.
- [ ] Run tests GREEN; manually verify axis/default/reset/overlay behavior and no profile writes from Explorer.

### Task 8: Final acceptance and executor handoff

**Files:** Modify CONTRACT.md and README.md; all brief-owned files reviewed.
- [ ] Document exact grammar/instrument/settings keys, variant routing, metadata origin, source editor, adapter and legacy boundaries.
- [ ] Run `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh`; require exit 0.
- [ ] Run full repo-supported test suite and record actual executed tests; zero tests is failure.
- [ ] Verify Editor and Explorer agree on active variant parsing/defaults/metadata with disposable fixtures. UI cases include dirty drafts, failed save, schema badge, narrow/enlarged-font layout and keyboard/VoiceOver flow.
- [ ] Inspect full diff, `git diff --check` and status. Confirm no raw/Study/global writes, unrelated changes or implicit commits.
- [ ] Report changed files, real verification results, UI observations and remaining scientific acceptance separately. No real profile migration/commit/push/install unless authorized.

## Final-review implementation corrections

Fold these requirements into owning tasks:
- Task 2: structural parse separate from validate(catalog:); explicit ProfileUpgradeDraft/diagnostics and finalize interface. Add legacy_origin path/SHA256 and metadata_capture rules defined in spec. Test existing YAMLParser against every literal YAML example; use block mappings, no parser expansion for shorthand.
- Task 1: explicit legacy field/role mapping, bracket and optional delimiter regression tests; no name-substring inference.
- Task 3: stable column IDs/source fields independent from names; preserve complete Y lists. Variant keys disabled for nonreferenced grammars; explicit rebind reviews all values. Current-variant key fields below selector. Visible Save Profile / Save Grammar labels and document-level dirty/error status.
- Task 4: retain physical marker tokens; case-insensitive primary-header-first alias fallback; ordered pre-header/comment acquisition metadata with repeated keys. Test metadata old/new parity. Canonical legacy-origin shadowing suppresses only exact unchanged original; test one import plus unrelated legacy peer and changed-origin conflict.
- Task 5: incomplete conversion drafts are editable/navigable; full validation only at Save. No premature validated document requirement. Source originals stay immutable.
- Tasks 3/4: Sandbox uses shared normalized reader output from draft; test parity for marker boundaries, decimal comma, gaps and multi-Y. No-default state must not guess axes. Apply defaults previews complete replacement Y list.
- Task 6: source-to-visual regeneration of comments warns first, preserves cancel path, no silent draft merge.
- Tasks 3/7: discoverable horizontal scrolling for variable grid; stack axis channel/absolute/scale rows when needed at minimum native window width/enlarged font. No mobile redesign.

## Self-review and approval

Task boundaries cover every spec section and five Review Focus classes. Earlier append-only amendments were consolidated to remove contradictory per-mode-file instructions. Exact locator/selectors are now defined in the spec; review their semantics against existing extractors before implementing. Final independent schema/source and Impeccable UI reviews completed and corrections recorded above. Both literal YAML examples were executed through the actual repository YAMLParser via Swift stdin and passed (example 1 OK, example 2 OK; exit 0). This verifies syntax only, not unimplemented v3 semantics. Implementation has not started. Baseline and executor selection remain explicit handoff prerequisites.
