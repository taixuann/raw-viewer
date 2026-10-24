# Profile Editor Shared Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the Profile Editor with shared controls, valid-v3-only profiles, variable-defined names, unambiguous saves, and safe profile/grammar deletion.

**Architecture:** Keep EditorWorkspaceViewModel as the state owner. Use one shared document bar across all tabs. Tighten editor discovery separately from runtime compatibility; change grammar field semantics deliberately rather than merely relabeling a role picker.

**Tech Stack:** Swift, SwiftUI, SwiftPM, existing YAML parser. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-12-profile-schema-v3-design.md` supplies unchanged contracts. The approved decisions below supersede its editor legacy-upgrade flow, role UI, and sidebar placement. Earlier plans remain historical, not competing authorities.

## Approved Decisions

- Show Profile and Grammar beside each other across every tab, including Profile YAML. Keep Sample compactly in the shared header.
- Remove the mounted left sidebar. Preserve Import, Refresh, cohort validation, sample matching/status, and contextual Retry in shared menus/popovers.
- Show only profiles that strictly parse and validate as schema v3 against the current catalog. Exclude v1/v2, unsupported versions, malformed YAML, and invalid references from editor selection. Show a small excluded-count diagnostic with reasons, not selectable broken profiles.
- Remove Upgrade buttons, forms, and editor upgrade transitions. Keep excluded originals untouched. Reject incompatible imports with a clear error. Do not silently convert or fall through to the lenient loader.
- Do not change Explorer/runtime legacy compatibility in this task. Any removal of runtime support needs a separate decision.
- Remove Scientific Role. A template variable defines the metadata identity: `{batch}` becomes `batch`, not Remarks. Show an editable `Name` equal to the variable identifier; edit updates the matching template placeholder and field together. No second display-name abstraction.
- Require unique nonempty names compatible with the existing template parser. Reject braces/delimiter-breaking syntax and duplicate names. Do not alter custom names through title-casing.
- New grammar saves omit `role`. Load old schema-1 role-bearing catalogs, but preserve their mapping until explicitly edited; do not silently reinterpret every legacy field on load. Pin old-versus-new extraction behavior in tests. Retain arbitrary extracted variable values for Explorer views and routing.
- Renaming a variable referenced by profile variant keys or settings views is blocked with the affected references listed. Do not cascade-rewrite multiple documents or leave dangling references. User removes references before renaming.
- Keep exactly one Save Profile and one Save Grammar in the shared bar. Remove both Raw Stream Save Profile and Filename Grammar's duplicate Save Grammar. Save Profile writes only the profile; Save Grammar writes only the catalog. Cmd+S retains focused-document routing. No combined legacy/profile-and-rules save remains reachable from editor UI.
- Put a labeled Delete Profile/Delete Grammar action beside the corresponding New action. Use secondary native destructive styling; require a confirmation naming the target. Disable when no deletable target exists.
- Delete Profile removes only a verified project-owned canonical `.rawviewer/instrument/` YAML file. Never delete fallback/global/Study files, symlink targets, or raw data. Recheck external changes before deletion. Select another valid profile or show an empty state only after success.
- Delete Grammar removes one entry, not the grammar.yaml file. Block deletion if any project profile or settings view references it, including references discoverable in excluded profile files. Fail closed if reference inspection fails. Report dependents; do not cascade-delete them.
- Delete unsaved grammar drafts is an explicit discard; deleting the final grammar leaves an empty editor state with New available. Do not auto-recreate the deleted grammar. If current catalog validation rejects empty catalogs, support an empty persisted catalog as part of this task and pin it with a test.
- Dirty drafts require Save/Discard/Cancel before destructive transitions. Failure/cancel leaves selection, drafts, and disk unchanged. Pending YAML drafts must not recreate deleted documents on a later save.

## Global Constraints

- No commit, push, merge, or /Applications installation without Tai's approval.
- Never delete or split existing source files without explicit authorization. Deletion permission here covers user-selected configuration documents only.
- Raw scientific data is immutable. Test with synthetic fixtures.
- Preserve profile schema 3 and settings schema 3. Grammar remains schema 1 with backward-readable role fields and optional role for new variable-native fields; document the compatible extension.
- No new dependencies, unrelated refactors, or automatic upgrades.
- Preserve exact YAML drafts/comments, dirty/conflict guards, variant routing, and cache identity.
- Record the dirty worktree baseline. Resolve isolation without resetting or omitting uncommitted v3 work.
- Route implementation to Codex or OpenCode under the owning repo instructions; controller verifies returned diff and checks. Executor choice follows Tai's existing preference where compatible with current constraints.
- Run `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh` before completion.

## Review Focus

1. Selected v2/invalid profile is excluded without data loss or lenient fallback; import reports the actual reason. Task 1.
2. Custom variable names round-trip; role-bearing catalogs do not silently lose metadata behavior; referenced rename is blocked. Task 2.
3. Save Profile never writes grammar, and Save Grammar never writes profile; failed saves are not reported as success. Task 3.
4. Cancelled/failed/external-change deletion preserves disk and drafts; dependent grammar deletion and non-owned paths are blocked. Task 4.
5. Empty catalogs, last-item deletion, narrow windows, Developer Mode, and Cmd+S remain usable. Tasks 4–5.

## File Map

- `Sources/RawViewApp/Editor/EditorWorkspaceView.swift`: discovery/import, strict editor loading, shared state, save/deletion coordination.
- `Sources/RawViewApp/Editor/Panels/EditorCenterCanvasView.swift`: shared document/sample bar; remove upgrade UI; deletion confirmations.
- `Sources/RawViewApp/Editor/Panels/EditorLeftSidebarView.swift`: source for relocated actions; leave source intact and unmounted.
- `Sources/RawViewApp/Editor/Panels/FilenameTokensStudioView.swift`: Name editing, remove role picker and duplicate grammar save/selection.
- `Sources/RawViewApp/Editor/ParserSettingsCanvasView.swift` and `Grid/StreamToolbarCards.swift`: remove duplicate document controls and unused plumbing.
- `Sources/RawViewCore/Discovery/FilenameGrammarEngine.swift`: role-optional variable-native fields, rename validation, empty catalog persistence.
- `Sources/RawViewCore/Reader/InstrumentProfile.swift`: reuse strict profile parsing and catalog validation; modify only if a small reusable discovery/reference helper is needed.
- `Tests/RawViewCoreTests/FilenameGrammarEngineTests.swift` and `ProfileDocumentV3Tests.swift`: regression checks at existing Core seams.
- `docs/handoff/2026-10-12-profile-schema-v3.md`: superseded upgrade behavior and actual acceptance results.

### Task 1: Strict editor profile discovery and removal of Upgrade

**Files:** EditorWorkspaceView.swift, EditorCenterCanvasView.swift, ProfileDocumentV3Tests.swift; InstrumentProfile.swift only if needed for a testable filter helper.

**Interfaces:** Reuse strict v3 parser/validator and `requestProfileSwitch(to:)`, `importProfile()`, `refreshSavedProfiles()`. Trace their actual definitions before edits. Produce a valid-only savedProfiles list plus excluded diagnostics, not a new runtime catalog API.

- [ ] Write a failing fixture check `editorDiscoveryExcludesLegacyMalformedAndInvalidReferences`: valid v3 included; v2, malformed v3, unsupported version, missing grammar excluded; original bytes unchanged.
- [ ] Run the targeted Swift test; record actual RED. If discovery exists only in the App target, extract the smallest filtering seam into the existing Core owner rather than claiming a Core test exercises UI.
- [ ] Filter discovery/import/load consistently; remove Upgrade presentation and reachable editor transitions. Keep runtime legacy support intact.
- [ ] Run targeted tests and app type-check through `./Scripts/check_core.sh`; require PASS. Manually check incompatible import error and no misleading “No profile selected” for a valid selected v3.
- [ ] Review task diff. Do not commit.

### Task 2: Variable-defined Name instead of Scientific Role

**Files:** FilenameGrammarEngine.swift, FilenameTokensStudioView.swift, FilenameGrammarEngineTests.swift; reference checks coordinated in EditorWorkspaceView.swift.

**Interfaces:** Reuse template variables, extractedFields, and existing profile/settings reference IDs. Produce optional-role loading and role-free serialization for new fields. Name edits stage one coherent grammar change; no new display-label property.

- [ ] Write failing tests `variableNativeNamesRoundTripWithoutRole`, `legacyRoleMappingSurvivesLoad`, `customVariableMetadataIsPreserved`, and `renameRejectsDuplicateInvalidAndReferencedNames`. Assert `{batch}` retains metadata key batch, old datetime/device mapping remains, and rejected rename leaves template/fields unchanged.
- [ ] Run targeted tests and record RED.
- [ ] Implement the compatible schema extension, atomic in-memory Name edits, and dependency checks. Remove Scientific Role UI. Audit metadata consumers before changing extraction; do not silently drop timestamp/device facts.
- [ ] Run grammar/profile regression suites; require PASS. Check arbitrary custom names through visual editor → YAML → reload and Explorer view extraction.
- [ ] Review task diff and schema documentation. Do not commit.

### Task 3: Shared controls and document-specific saves

**Files:** EditorWorkspaceView.swift, EditorCenterCanvasView.swift, FilenameTokensStudioView.swift, ParserSettingsCanvasView.swift, StreamToolbarCards.swift. Sidebar file remains intact.

**Interfaces:** Reuse `chooseSamplePreview(_:)`, `retryPreviewMatch()`, `testAgainstCohort()`, `saveProfileDocument()`, `saveGrammarCatalog()`, and grammar selection. Add `sources: [RawSource]` to EditorCenterCanvasView initializer and update its caller. Preserve focused save routing.

- [ ] Capture visual RED evidence: duplicate save/profile controls, inconsistent grammar placement, mounted sidebar. Trace all toolbar call sites.
- [ ] Move shared controls/actions and sample status to the header; remove mounted sidebar, duplicate selectors, and tab-local saves. Remove reachable combined-save wiring.
- [ ] Check synthetic profile-only save leaves grammar bytes unchanged; grammar-only save leaves profile bytes unchanged; failed validation preserves old bytes and shows an error. Check sample-switch drafts and profile-switch guards manually.
- [ ] Run `swift test`, core and CLI scripts, and `git diff --check`; require exit 0 without pipe-masked status. Review bounded diff. Do not commit.

### Task 4: Safe Delete Profile and Delete Grammar

**Files:** EditorWorkspaceView.swift, EditorCenterCanvasView.swift, FilenameGrammarEngine.swift, existing grammar/profile tests. Place a reusable filesystem check in an existing Core owner only if needed to exercise it.

**Interfaces:** Add view-model actions `requestDeleteProfile()` and `requestDeleteGrammar()`; stage confirmation before mutation. Use existing dirty-transition coordination, validated canonical URLs, and catalog persistence. No cascade deletion.

- [ ] Write failing checks `deleteRejectsNonOwnedSymlinkAndChangedTargets`, `grammarDeleteBlocksProfileAndViewReferences`, `failedDeletePreservesState`, and `lastGrammarDeletionPersistsEmptyCatalog`. Use disposable fixtures; verify cancellation, write failure, unreadable dependent files, and byte preservation.
- [ ] Run targeted checks and record RED.
- [ ] Implement project-only profile deletion and dependency-checked grammar entry removal. Confirm exact target, preserve state until successful persistence, clear obsolete YAML baselines after success, and keep New available in empty states.
- [ ] Run targeted checks and full automated gates; require PASS. Manually check Save/Discard/Cancel, secondary destructive button labels, deleting selected versus other documents, and no resurrection through Cmd+S.
- [ ] Review safety diff. Do not commit or delete any real project configuration during verification.

### Task 5: Build and native acceptance

**Files:** Only the preceding UI files for observed defects; handoff document.

**Interfaces:** Consume completed editor controls and record real acceptance evidence.

- [ ] Package with `Scripts/package_app.sh` using session scratch app/build/module-cache paths; require build and codesign success.
- [ ] Run one batched wide/narrow native UI pass: Developer Mode, long/custom names, empty catalogs, key eligibility, Save/grammar Cmd+S distinction, keyboard/VoiceOver, matching errors, and deletion guards. Capture actual evidence; mark unavailable checks pending.
- [ ] Fix observed defects in one bounded batch; read Impeccable craft-floor before UI edits. Confirm with at most one further screenshot pass.
- [ ] Re-run full tests, core and CLI scripts, and diff check after fixes. Update handoff; distinguish software/UI acceptance from scientific acceptance. Stop adding editor features.

## Self-Review

All approved decisions have an owning task and failure checks. Legacy visibility removal is editor-only; role removal is a semantic migration with compatibility tests, not a cosmetic rename. Empty final grammar, excluded dependents, dirty deletion, and different save scopes are explicit. Source files are not deleted. No implementation or real configuration deletion is authorized by this planning update.

## Execution Handoff

Updated plan only. Wait for Tai to review this scope before implementation. Preserve task-by-task review and resolve executor/isolation details at execution time.

### Task 6 (follow-up, approved 2026-10-14): New blank v3 from current sample

**Files:** EditorWorkspaceView.swift, EditorWorkspaceModel.swift (only if a reusable constructor seam is needed), ProfileDocumentV3Tests.swift.

**Interfaces:** Reuse ProfileDocumentV3 initializer + validate(catalog:), current editor delimiter/columns/sample, activeGrammarID. Produce a loaded unsaved v3 document, never a disk write.

- [ ] Write a failing check `newFromSampleCreatesLoadedUnsavedV3`: no document → New → hasProfileDocument true, one variant, grammar = active grammar, profileDirty true, zero disk writes (assert directory listing unchanged).
- [ ] Run targeted test; record RED.
- [ ] Implement New-from-sample in the +New no-document path (replace the ID/Name-only stub): build one variant from the live parse (delimiter, decimal, header/data-start, columns incl. skip/X/Y, extensions, match evidence where available), keyless key set, dirty unsaved. Keep duplicate-current-document behavior when a document is loaded.
- [ ] Run targeted + full suite, core and CLI scripts, diff check; require exit 0 unmasked. Manually verify the reported zero-to-save flow in a packaged build.
- [ ] Review bounded diff. Do not commit.

### Task 7 (follow-up, approved 2026-10-14): per-tab saves, tick-only keys, remove variant/duplicate/validate UI

Supersedes Task 3's shared-save-bar placement (live UI verdict, not a behavior change).

**Files:** EditorWorkspaceView.swift, EditorCenterCanvasView.swift, FilenameTokensStudioView.swift, ParserSettingsCanvasView.swift, StreamToolbarCards.swift (only as traced), EditorWorkspaceModel.swift (only for autofill seam), ProfileDocumentV3Tests.swift and/or FilenameGrammarEngineTests.swift.

**Interfaces:** Reuse saveProfileDocument(), saveGrammarCatalog(), selectGrammar(), sampleExtractedFacts.extractedFields, rename/variant-key engine APIs. Produce no new documents or schemas.

- [ ] Move Save Grammar into the Filename Grammar tab only; move Save Profile into Raw Stream Studio only. Remove both from the shared header. Keep Cmd+S tab routing (saveFocusedDocument).
- [ ] Remove the Keys value-entry row. Variant Key stays a tick in the grammar table and nothing else. Key values autofill read-only from the current sample's extracted fields on sample select/match (stage + dirty); missing extraction leaves the value empty and save reports the exact key. The editor operates on the sample-matched variant (existing match flow); instrument → mode level filtering lives in Explorer views, no new hierarchy UI here.
- [ ] Remove Variant picker + Duplicate variant button, Duplicate Profile UI (+New blank-from-sample stays), and Validate button/menu UI. Delete model methods only when zero references remain including tests; otherwise leave them unreferenced-but-tested out of the UI.
- [ ] Reproduce then fix the reported save-after-grammar failure: exact validation error first (suspect: empty staged key values), autofill as the fix, exact error text surfaced in the status pill on any remaining failure. End-to-end check: tick keys on a matched sample → Save Profile writes bytes.
- [ ] Run targeted + full suite, core and CLI scripts, diff check; require exit 0 unmasked. Verify in a packaged build.
- [ ] Review bounded diff. Do not commit.
