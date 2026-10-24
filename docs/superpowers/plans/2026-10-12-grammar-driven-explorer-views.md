# Grammar-Driven Explorer Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hard-coded semantic Explorer grouping choices with project-configured views of filename grammar variables.

**Architecture:** Keep extraction definitions in the grammar catalog. Store project-only Explorer view references in `.rawviewer/setting.yaml`. Extract grouping values from source basenames without opening raw files. Keep Tree and None as structural modes, not grammar variables.

**Tech Stack:** Swift, SwiftUI, Foundation, existing YAMLParser and FilenameGrammarEngine. No new dependencies.

**Spec:** User-approved direction in this conversation: each variable added from Explorer creates an independent Explorer view; grouping is separate from filtering; project settings own view selection. This document is a review draft, not implementation authorization. Full Save Profile persistence and reader compatibility are a separate design discussion.

## Global Constraints

- Read owning repo AGENTS.md before execution.
- Raw scientific files remain immutable.
- Do not delete or split existing source files.
- Preserve data_root, default_view, default_preset and existing settings security checks.
- Keep default_view `tree` in this increment.
- Do not change grammar parsing, scientific interpretation, instrument profile schema, or measurement cache formats.
- Do not add a new configuration file.
- Keep filtering independent of grouping. Do not repurpose GrammarField.isFacet.
- Do not commit, push, package into Applications, or publish without human authorization.
- Execute via Tai-selected Codex or OpenCode in an isolated worktree. Leave the current dirty worktree untouched. Include approved prerequisite changes explicitly rather than silently using an older base.

## Review Focus

1. Legacy settings load with no configured semantic views; Tree remains available.
2. Renamed/deleted grammar references appear unavailable with a diagnostic; do not silently choose another grammar.
3. Unmatched or partial-match filenames remain visible in an Unmatched group; never group partial facts as confirmed matches.
4. Identical token names in different grammars remain distinct by grammar ID and variable name.
5. Saving view choices preserves project settings, propagates errors, and refreshes Explorer without reopening raw files.

## Proposed storage contract for review

Use schema version 3 for new settings containing explorer_views. Continue reading versions 1 and 2. Each explorer_views item has grammar_id and variable. The list order controls the view menu order. Labels use the variable name; do not add custom labels or nested grouping yet. An empty list means no semantic grouping views.

Example fragment (not an existing schema):

```yaml
schema_version: 3
data_root: "data/raw"
default_view: "tree"
default_preset: "nature-single"
explorer_views:
  - grammar_id: "standard-scientific"
    variable: "study"
  - grammar_id: "standard-scientific"
    variable: "device-id"
```

Do not store global UI preferences in a reusable global grammar template. Explorer owns Add View from Filename… and Remove View actions. They persist only this project's view references with explicit error reporting. The Grammar editor has no grouping checkbox. Save Grammar and Save as Global Template persist extraction definitions only. Changing Save Profile's broader write contract remains out of scope until the follow-up design is approved.

---

### Task 1: Extend project settings safely

**Files:**
- Modify: `Sources/RawViewCore/Storage/ProjectSettings.swift`
- Test: `Tests/RawViewCoreTests/ProjectSettingsTests.swift`

**Interfaces:**
- Add `ExplorerViewDefinition: Sendable, Equatable` with `grammarID: String`, `variable: String` and initializer for both.
- Extend `ProjectSettings` with `explorerViews: [ExplorerViewDefinition]`, default `[]`.
- Keep `ProjectSettingsStore.load(projectRoot:)` and `save(_:projectRoot:)` signatures.

- [ ] Write failing tests for v1/v2 loading to an empty list, v3 round-trip of study/device-id references, duplicate-reference rejection, empty identifiers, unknown nested keys and malformed explorer_views types.
- [ ] Run the targeted ProjectSettingsTests using the repo-supported Swift test environment; verify new assertions fail for the intended missing behavior, not a toolchain problem.
- [ ] Implement strict schema-v3 parsing and safe YAML scalar escaping. Accept explorer_views only in v3. Preserve old fields on read-modify-save. Preserve no-follow, size-limit and atomic-write behavior.
- [ ] Run targeted tests, including existing symlink and corrupt-settings regressions. Verify all pass.
- [ ] Review the task diff. Commit only if Tai authorizes it.

### Task 2: Group inventory by declared grammar variables

**Files:**
- Modify: `Sources/RawViewCore/Discovery/SourceGrouping.swift`
- Test: `Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift`

**Interfaces:**
- Add `SourceGrouping.groups(sources: [RawSource], grammar: FilenameGrammar, variable: String) -> [SourceGroup]`.
- Consume `FilenameGrammarEngine.extract(from:grammar:)` and its `isMatched`/`extractedFields` result.
- Return existing SourceGroup values with stable source IDs; no measurement inspection prerequisite.

- [ ] Write failing tests asserting same study values group together, all source IDs occur exactly once, partial/nonmatches enter Unmatched, absent optional variables enter Missing value, and extraction uses basename rather than full path.
- [ ] Run FilenameGrammarEngineTests and verify intended failures.
- [ ] Implement grouping from inventory basenames. Use lexical ordering for populated groups, followed by Missing value and Unmatched. A matched literal value equal to either bucket label must not collide with the bucket identity; qualify its displayed label deterministically.
- [ ] Run targeted tests and verify deterministic results with reordered input. Assert no raw file read is needed by using nonexistent synthetic source URLs.
- [ ] Review the diff. Do not remove existing SourceGrouping APIs used by other callers.

### Task 3: Add and remove views in Explorer

**Files:**
- Modify: `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`
- Modify: `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`
- Modify: `Sources/RawViewApp/Explorer/ExplorerSidebarView.swift`
- Modify: `Sources/RawViewApp/RawViewApp.swift`
- Test: `Tests/RawViewCoreTests/ProjectSettingsTests.swift`

**Interfaces:**
- Add `Add View from Filename…` to the Explorer menu. Open a native popover selecting grammar and variable, showing group counts and unmatched count, with an Add View action.
- Reference identity is `(grammarID, variableName)` in project settings, not in GrammarField.
- Remove the Filter in Explorer toggle from Grammar UI. Continue accepting legacy isFacet on load; do not introduce filter configuration into this grouping increment.
- Pass saved explorerViews and the project grammar catalog to ProjectSourcesSidebar through its initializer and the existing app-owned project state.
- Use a discriminated selection identity for Tree, None and a grammar-variable reference; do not use a bare variable name as identity.

- [ ] Trace all ProjectSettings constructors and all ProjectSourcesSidebar callers before editing. Ensure data-root changes cannot reset explorerViews.
- [ ] Add regression tests proving a settings update preserves dataRoot/defaultView/defaultPreset and references with identical variables in different grammars.
- [ ] Run the targeted tests and verify intended failures where behavior is missing.
- [ ] Implement Add View and Remove View persistence in Explorer. Disable duplicate additions. Save settings before updating the visible menu; keep the current menu intact on failure and show the error. On successful add, select the new view. Removing the active view selects Tree. Grammar saves never save Explorer choices.
- [ ] Replace the hard-coded semantic facet menu and switch with settings-driven choices and Task 2 grouping. Keep Tree/None. Remove Status as a grouping choice, but retain status badges and diagnostics. Keep existing filter behavior outside this grouping scope.
- [ ] Reload settings/catalog into the app-owned Explorer state after successful save. Show unavailable references with diagnostics; if the current reference disappears, return to Tree with a visible explanation.
- [ ] Run targeted tests and the core/app typecheck. Verify all pass.
- [ ] Manually verify independent study/device-id views, grouping/filtering independence, persistence after reopen, unavailable references, Unmatched visibility, and no raw-file mutation.

### Task 4: Verify and hand off

- [ ] Run `./Scripts/check_core.sh`; require exit 0.
- [ ] Run `./Scripts/check_index_cli.sh`; require exit 0.
- [ ] Run the repository-supported full test suite; verify actual test execution and record test count. Do not treat a zero-test run as success.
- [ ] Inspect `git diff --check`, the complete diff and status. Verify no unrelated source edits, scientific-data writes, hooks or global configuration changes.
- [ ] Record UI acceptance observations separately from automated checks. Passing tests does not establish scientific acceptance.
- [ ] Return changed paths, actual checks, known limitations and the verified diff to Tai. No commit/push/publication unless authorized.

## Approved storage direction; separate follow-up implementation

Project grammar moves to `.rawviewer/grammar.yaml`. Read legacy `.rawviewer/view/grammar.yaml` only when the new path is absent; surface malformed new files instead of falling back. Never silently delete the legacy file. Stop writing category.yaml after its consumers have been migrated to grammar extraction. Instrument profiles will reference a saved grammar ID; the exact profile schema and mode linkage require the audit below. Keep index.db, setting.yaml, instrument/ and existing preset/ ownership unchanged. Add migration tests in the separately approved persistence plan before executing these storage changes.

## Approved grammar contract

Tai approved a versioned catalog at `.rawviewer/grammar.yaml` containing `grammars`, each with stable `id`, `name`, `template` and `fields`. Each field contains `name`, metadata `role`, `type`, optional `format`, and `optional`. Reuse the app's existing GrammarFieldType values `string`, `number`, `datetime`; do not introduce a new type system. Every `{variable}` is an extracted metadata field. Role annotates metadata meaning only; it never enables grouping/filtering or changes raw data. Explorer owns all decisions to use fields as views or filters.

Do not write `is_facet`, Explorer view settings, raw-stream definitions or a runtime-authoritative `active_grammar_id` in the new grammar contract. Use stable machine role keys mapped to existing UI labels. Validate unique grammar IDs and field names, exact template/field correspondence, known types, and valid formats. Preserve raw extracted text separately from any typed interpretation, including leading zeros. Treat partial matches as editor feedback only. Explicitly define optional-field delimiter behavior and bracket capture before implementation; test actual default filenames rather than assume it from the YAML shape.

Persistence implementation tasks, in order:
- [ ] Add a versioned validated grammar document parser/serializer in `Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift`, reusing existing types. Add round-trip and invalid-document tests in `Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift` before implementation.
- [ ] Add legacy-path import tests, including absent type, legacy display roles, is_facet and active_grammar_id. Preserve legacy files. Do not silently guess missing semantic types during migration; surface unresolved fields for review. Reject malformed new-path documents without legacy fallback.
- [ ] Adapt Grammar editor save/load to the agreed keys and metadata-only roles. Test optional remarks/batch, bracket handling, raw `001` preservation, custom variable names and duplicate IDs. Surface save errors.
- [ ] Connect Explorer to this validated catalog after the persistence change is approved and implemented. Instrument grammar linkage remains a separate profile-schema task.
- [ ] Run both required repo check scripts and the real targeted tests. Verify round-trip before claiming persistence complete.

This section records the approved grammar scope; it does not authorize implementation or finalize the instrument profile schema.

## Deferred follow-up: Save contract audit

Trace Grammar selection, Raw Stream column/metadata definitions, profile YAML compiler, strict ProfileCatalog parser, Explorer reader, settings persistence and refresh. Compare each UI-defined field with its serialized location and runtime consumer. Decide ownership and linkage before consolidating or removing category.yaml or grammar.yaml. Require an editor-save-reader round-trip test; generic-reader fallback is not proof that a saved profile works.

## Self-review

All five Review Focus cases map to Tasks 1–3. No nested grouping, custom view builder, new dependencies or grammar duplication is proposed. Proposed schema version, save trigger and menu removal require Tai's review before implementation. Current dirty changes are prerequisites to resolve at execution handoff, not permission to overwrite them.
