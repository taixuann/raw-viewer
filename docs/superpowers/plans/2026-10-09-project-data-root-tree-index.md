# Project Data Root, Tree View, and Index Relocation — Draft Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax. Execute only after Tai approves the written spec, this plan, and Codex/OpenCode executor choice.

**Goal:** Configure one contained data root per project, browse its physical Tree view, relocate the advisory SQLite index safely, and support headless pre-indexing reused by the GUI.

**Architecture:** Project configuration defines a project-relative data root without changing source identity. One core indexing coordinator owns migration, index validity, and GUI/CLI writer coordination; descriptor-verified readers and the private measurement cache remain the scientific data path. Existing virtual navigation and exports remain available.

**Tech Stack:** Swift 6 tools / Swift v5 language mode, macOS 14+, Foundation, existing YAMLParser, CryptoKit, SQLite3, SwiftUI/AppKit; no new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-09-project-data-root-tree-index-design.md` — DRAFT pending written approval. This requested draft plan is not permission to bypass the written-spec gate.

## Global Constraints

- Work in `/Users/tai/agent-development/worktrees/raw-viewer-upgrade`; reuse it, do not create another worktree. Baseline `75f9add1af120f94ca3e1a64477b930c9139168e` plus planning documents only at authoring time. Recheck before execution.
- Canonical product owner: `/Users/tai/research-projects/tools/raw-viewer`; no product source in the workshop root.
- Configuration exactly `.rawviewer/setting/setting.yaml`; active writable index is owner-private app-local (Application Support keyed by project, Tai decision (b) after the VFS gate failed) — NO project-local SQLite writes; legacy `data/.rawview/index.db` preserved as rollback; private measurement cache stays app-local.
- Settings schema exactly schema_version 1, normalized project-relative data_root, default_view tree; 64 KiB UTF-8 cap; reject duplicate/unknown keys, absolute/parent paths, and symlinked namespace/root components.
- Data root is `.` or a contained regular directory. Suggest data/raw if present; missing configuration prompts, corrupt configuration never silently defaults. Global preferences and data/instruments profile precedence remain unchanged.
- Keep source/provenance/manifest IDs project-relative. Preserve raw bytes, timestamps, acquisition order, values, gaps, units, diagnostics and explicit scientific membership.
- Eligible extensions remain csv/txt/lvm/dat. .DS_Store and .spe/.affm retain existing lexical exclusion policies. Do not turn ignored filenames into a new scanning/opening path.
- Index is advisory and untrusted; size/mtime alone may not confer scientific supported/profile-valid state. Recompute outcomes from secured prefix/current catalog or independently verified owner-private cache; never authenticate project-controlled outcome fields by matching digests alone.
- No destructive legacy SQLite cleanup in automatic migration; preserve rollback artifacts. Never move one live WAL file by itself.
- No real data copying/printing in shared evidence; synthetic fixtures by default. No install, commit, push, merge, release, or Linear changes without separate authority.
- Stop this turn after plan/review. No DB relocation or pre-index run now. Actual target research project must be selected before later live execution.

## Review Focus

1. Same-size/same-time source edits, removed profiles, and forged project index records must not restore trusted reader state — Tasks 3 and 4.
2. Open settings/root symlink swaps, dot/parent paths, and a root equal to project must not expose outside files or recursively inventory viewer metadata — Tasks 1 and 2.
3. WAL-only committed records, busy concurrent processes, corrupt DBs, and interrupted migration must preserve original files and never publish partial destination state — Task 3.
4. Source selection/expansion/filter state and late async results after data-root change must not show the previous root's data — Tasks 5 and 6.
5. Read-only roots, unusable private fallback, partial scan failures, and CLI interruptions must stay diagnosable without writes to raw files or false completion — Tasks 3, 4, 6 and 7.

## Impact audit before task execution

Observed hard-coded assumptions:
- ProjectContext.swift:10-22 location/open contract; :208-217 nested marker pruning; :337 missing-file text.
- InstrumentReader.swift:132 and :300 literal data/raw membership checks; :186-190 and :351-370 generic URL reread fallback.
- MeasurementCache.swift:527-528 literal membership; keys/namespace must distinguish configured root and reader changes.
- StudyManifest.swift:65 raw scanner pruning, :260 membership, :270-279 diagnostics.
- RawViewApp.swift:525-564 stats/rebuild opens, :824 index write, :847-1053 install/restoration/batch writes, other lookup sites located by search. Existing lazy and eager restoration both trust size/mtime; lazy restoration uses an untracked detached task and can overwrite newer source state.
- ProjectGalleryViews.swift: grouping/list UI and fixed-root empty text; SettingsView.swift: storage UI and no project-location section.
- FigureExporter.swift uses project-root data/snapshot; keep format/location, exclude snapshots when root is `.`.
- Tests and CoreSelfCheck encode nested-marker pruning and data/raw diagnostics: update only intentionally changed behavior, retain no-follow/overlay/profile tests.

## Proposed file structure and interfaces

All new symbols below are proposed by this plan, not claims that they already exist.

- `ProjectSettings.swift`: `public struct ProjectSettings: Sendable, Equatable { public let dataRoot: String; public let defaultView: String }`; `public enum ProjectSettingsStore` with `load(projectRoot: URL) throws -> ProjectSettings?` (nil only proven absent), `save(_ settings: ProjectSettings, projectRoot: URL) throws`. Internal parser/serializer reuse YAMLParser without loosening profile rules.
- ProjectContext additions: `public static func open(_ root: URL, dataRootRelativePath: String) throws -> Self`; preserve `open(_ root: URL)` for existing data/raw callers, but make it consult saved settings first and never silently recover invalid settings. `public let dataRootRelativePath: String`; `public func sourceRelativePath(of source: URL) -> String?` validates lexical claimed containment, returns project-relative identity, while secure open independently validates descriptor containment.
- `SourceTree.swift`: `public struct SourceTreeNode: Identifiable, Sendable, Equatable { public let id: String; public let name: String; public let sourceID: String?; public let children: [SourceTreeNode] }`; directory id uses distinct `directory:` prefix, file id uses `source:` prefix. `public struct SourceInventory: Sendable { public let sources: [RawSource]; public let directoryPaths: [String]; public let issues: [InventoryIssue] }`; `ProjectContext.discoverInventoryAsync() async throws -> SourceInventory`; compatibility discoverSources methods return inventory.sources.
- `ProjectIndexStore.swift`: core actor resolves storage and owns a lazily opened connection, migration and advisory records; OS maintenance lease is job-scoped, never held by an idle GUI. `public static func open(project: ProjectContext) async throws -> ProjectIndexStore`; `public func migrateLegacy() async throws -> IndexMigrationReport`; `public func usage() async throws -> IndexUsage`. Reports expose storage mode, warnings and counts, not raw values. Proposed value types must be defined in this file and reused, never duplicated in UI.
- `ProjectIndexer.swift`: `public struct ProjectIndexRunReport: Sendable { public let discovered: Int; public let inspected: Int; public let deterministicBlocked: Int; public let transientFailures: Int; public let inventoryFailures: Int; public let structuralCandidates: Int; public let cancelled: Int; public let complete: Bool; public let storageMode: String }`; `public enum ProjectIndexer { public static func run(project: ProjectContext, rebuild: Bool, onProgress: @escaping @Sendable (Int, Int) async -> Void) async throws -> ProjectIndexRunReport }`. inspectMany remains the reader seam ONLY after typed dispositions and pinned generic inspection are implemented in Task 4; coordinator centralizes writes/validation.
- `ProjectSetupView.swift`: native project setup/change-location surface; GUI state owned by RawViewModel. Do not move generic global settings into it.
- `Sources/RawViewIndexCLI/main.swift`: new rawview-index product, argument parsing, exit/summary contract; use no project-local scripts.

Exact persisted DB metadata schema and validation methods are defined in Task 3; do not wire consumers to old lookupAll/asInspection restoration while implementing earlier tasks.

Additional proposed test seams: `InventoryIssue: Sendable, Equatable` carries project-relative path and typed enumeration/metadata failure; `InspectionDisposition: String, Sendable, Codable` has profileMatched, structuralCandidate, deterministicBlocked, transientFailure, cancelled. Add disposition to SourceInspectionResult and preserve it through inspectMany/cache (bump cache schema). Add `ProjectSessionState` in core: `generation: Int`, `selectedSourceIDs: Set<String>`, `expandedDirectoryIDs: Set<String>`; `beginRootChange() -> Int` increments generation and clears selections/expansion, `accepts(generation: Int) -> Bool` rejects stale results. Test this reducer in core; native model integration requires UI verification.

SQLite filesystem protection is an execution prerequisite, not an assumed capability: demonstrate descriptor-relative/no-follow SQLite VFS handling for database/WAL/SHM and safe no-clobber publication using synthetic swap races. If unavailable or disproportionate, stop Task 3 and ask Tai to approve a private writable-index alternative. Do not silently implement project-local check-then-open or invent a passing security guarantee.

### Task 1: Portable project settings and contained data-root contract

**Files:** Create Sources/RawViewCore/ProjectSettings.swift and Tests/RawViewCoreTests/ProjectSettingsTests.swift; modify ProjectContext.swift and Scripts/CoreSelfCheck.swift.
**Interfaces:** Produces ProjectSettingsStore, configured ProjectContext.open, dataRootRelativePath and sourceRelativePath as above. Existing root/rawRoot properties remain.

- [ ] Add failing tests named settingsRoundTripIsProjectRelative, missingSettingsIsNotMalformedSettings, settingsRejectUnknownVersionKeysAndParentPaths, settingsRejectSymlinkNamespaceAndRoot, projectMovePreservesDataRoot. Assert exact YAML fields/version and 64 KiB cap; move synthetic whole project and verify same relative identities.
- [ ] Run `swift test --filter ProjectSettingsTests`; require assertion failures for new behavior rather than an environment/import failure. If Testing unavailable, use approved matching toolchain/CI or stop; mirror critical cases in CoreSelfCheck, not pretend suite ran.
- [ ] Implement parser/atomic safe save and configured open; keep default open compatibility; reject any symlinked configured-root component. `.` accepted with later metadata exclusion policy. Config save failures visible; no silent fallback from corruption.
- [ ] Run the named tests and `Scripts/check_core.sh`; update stale root diagnostics only when behavior changed. Confirm synthetic fixture raw bytes/mtime unchanged.
- [ ] Review diff; request a bounded commit only if Tai has authorized commits.

### Task 2: Inventory/tree and complete containment propagation

**Files:** Create SourceTree.swift and Tests/RawViewCoreTests/SourceTreeTests.swift; modify ProjectContext.swift, InstrumentReader.swift, MeasurementCache.swift, StudyManifest.swift, ProjectCatalogTests.swift, MeasurementCacheTests.swift, InstrumentReaderTests.swift, OverlayEligibilityTests.swift, CoreSelfCheck.swift.
**Interfaces:** Produces SourceInventory/discoverInventoryAsync and tree nodes; consumes Task 1 sourceRelativePath/configured rawRoot.

- [ ] Add failing tests configuredRootWorksAcrossLoadInspectCacheAndManifest, treePreservesIntermediateAndEmptyFolders, treeIDsSeparateDirectoryAndSource, dotRootExcludesViewerMetadataAndSnapshots, nestedDataRawMarkerNoLongerPrunesSelectedData, rootSwitchDoesNotReuseDerivedNamespace. Assert project-relative source.path remains `measurements/batch/a.csv` for data root measurements; tree root display name measurements; existing legacy IDs unchanged.
- [ ] Add regression assertions for .spe/.affm zero-open, outside/swapped links, wide-directory cancellation, exact-manifest membership and equal-ID/different-manifest rejection. For dot root assert no discovered manifests and explicit diagnostic.
- [ ] Run targeted suites first to show intended failures; implement a single claimed-path containment helper and replace every literal prefix check at audited sites. Keep descriptor verification and no-follow guards independent, not replacing them with string checks.
- [ ] Inventory directories directly (not infer solely from file paths), return typed InventoryIssue values for enumeration and per-entry metadata failures rather than silently skipping them; retain accessible siblings, mark partial inventory incomplete, and keep cancellation distinct from partial I/O errors. Add partialDirectoryFailureKeepsSiblingsAndFailsCLICompleteness and metadataReadFailureIsReported tests. Reject configured roots inside viewer metadata/snapshot namespaces and exclude those paths for every data root; add customDataRootDataDoesNotInventorySnapshotOrLegacyIndex. source walker stops pruning nested project markers. Manifest walker still avoids independent descendant project metadata per existing policy outside data root; prune configured data root/RawView metadata and retain profile precedence. Update cache/reader namespace and tests for root changes.
- [ ] Run all affected suites and self-check. Search remaining `data/raw` literals, classify legitimate defaults/profile examples versus incorrect runtime assumptions. Do not bulk replace profile paths or snapshot locations.
- [ ] Review diff; commit only with authorization.

### Task 3: Safe SQLite namespace, relocation, advisory trust, and writer lease

**Files:** Create ProjectIndexStore.swift and Tests/RawViewCoreTests/ProjectIndexStoreTests.swift; modify IndexDatabase.swift, ProjectContext.swift, .gitignore and CoreSelfCheck.swift.
**Interfaces:** Produces ProjectIndexStore/open/migrateLegacy/usage, IndexMigrationReport and IndexUsage. Remove GUI use of raw connection lifecycle in Task 4/6. Preferred destination is `.rawviewer/index.db` inside store only at this stage; DO NOT change runtime indexDatabaseURL or GUI consumers until Task 4 cuts over every call together. resolved fallback URL belongs to store, not callers. Store open only resolves state; first writer under lease migrates before any destination creation.

- [ ] Add failing tests legacyWALBackupIncludesCommittedRows, destinationConflictPreservesBoth, migrationFailureLeavesLegacyIntact, busyWriterIsReportedAndCrashReleasesLease, indexNamespaceChangesWithRootCatalogReader, unsafeMetadataNamespaceFailsClosed, readOnlyProjectUsesPrivateFallback. Assert legacy db/WAL/SHM never deleted automatically; integrity_check returns ok on published destination; staging failures cannot replace valid destination.
- [ ] Add forgedIndexCannotPromoteTrustedInspection (forge mode/support/profile fields while keeping the CORRECT source digest/catalog metadata) and sameSizeSameTimeHeaderEditInvalidatesIndex; import old rows as hints only, never successful SourceInspection authority. Cache values are neither loaded from SQLite nor moved from private measurement storage.
- [ ] Run tests to RED; implement OS-managed advisory lock for each bounded migration/index writer job lifetime, safely keyed to canonical project in private app-local state (including read-only roots). Do not use stale lockfile existence as mutex. GUI and CLI share lock semantics.
- [ ] Add DB `index_metadata` table containing schema version, project identity, data_root, reader_version and catalog_fingerprint; add record prefix_sha256/descriptor_size validity fields and explicit advisory-state representation. Implement SQLite read-only backup/close/checkpoint APIs and checked PRAGMA/BEGIN/COMMIT results. Backup to unique destination sibling then atomic publication under lease. Prove descriptor-relative/no-follow VFS handling and no-clobber publication against ancestor/database/WAL/SHM swap races BEFORE project-local SQLite writes; static prechecks are insufficient. Return security error on symlink, ordinary permission fallback on read-only root. If proof fails, stop and obtain a storage-design decision.
- [ ] On incompatible metadata, rebuild active namespace rather than restoring its rows; when absent destination and valid legacy exists migrate as hints. Existing destination wins; corrupt legacy retained with diagnostic. `.gitignore` excludes derived `.rawviewer/index.db*` and migration staging only, not setting YAML.
- [ ] Run migration/security suites and self-check with synthetic WAL fixtures and separate-process lock tests. Verify no writes outside viewer-owned destinations and lease/staging cleanup after interruption.
- [ ] Review diff; commit only with authorization.

### Task 4: Shared indexing coordinator and validated startup restoration

**Files:** Create ProjectIndexer.swift and Tests/RawViewCoreTests/ProjectIndexerTests.swift; modify IndexDatabase.swift/ProjectIndexStore.swift, InstrumentReader.swift, GenericTableReader.swift, SourceInspection.swift, MeasurementCache.swift, ProjectContext.swift, RawViewApp.swift indexing/stats methods, CoreSelfCheck.swift.
**Interfaces:** Produces ProjectIndexer.run and ProjectIndexRunReport. Add to ProjectIndexStore `validatedInspection(for source: RawSource, project: ProjectContext) async throws -> SourceInspectionResult?` and `record(_ result: SourceInspectionResult, source: RawSource, project: ProjectContext) async throws`; store owns catalog/prefix checks and lifecycle. Do not duplicate validity logic in GUI.

- [ ] Add failing tests CLIAndGUIShareIndexValidity, catalogChangeInvalidatesAllAffectedHints, deletedFilesDisappear, blockedSourcesRemainVisible, transientErrorsAreNotCached, cancelledIndexKeepsCompletedBatches, sourceFailureDoesNotDropOtherResults. Reports distinguish profile matches, structural candidates, deterministic blocked, transient and cancelled outcomes via typed InspectionDisposition (never message strings); complete false when transient OR inventory failures remain. Cancellation must not count unvisited entries as inspected.
- [ ] Test a forged record, same-size/time modified prefix, interrupted batch and rebuild; validate using pinned bounded bytes/current catalog, not advisory metadata. A deterministic unprofiled result is not scientific acceptance.
- [ ] First replace generic inspection URL rereads with `GenericTableReader.inspect(prefix: Data) throws -> GenericTablePreview` bounded to 64 KiB. Define preview with delimiter/decimal/header candidates and sampled rows ONLY (no total file row count); add prefixOnlyInspectionNeverReopensSource, truncatedSampleRemainsUnresolved, genericReadFailureRemainsTransient tests. Carry structuralCandidate disposition with unresolved semantic status through UI/CLI; do not claim supported scientific data. Preserve profile ambiguity/fail-closed diagnostics alongside candidate preview. Full generic measurement-load redesign remains deferred. Then implement coordinator via corrected discover/inspectMany seams and private cache; hold per-project writer lease for bounded writes/migration job, with clear busy reporting. Persist only deterministic verified outcomes; completed batches remain durable, refresh removes stale entries, rebuild bypasses SQLite hints without deleting raw/cache data.
- [ ] ATOMically cut over ProjectContext.indexDatabaseURL and replace EVERY old GUI `lookupAll().asInspection` restoration/direct upsert/open site (stats, rebuild, focused, resumed, lazy, eager) with store/coordinator in this task; migrate only off-main before any destination creation. Project DB payloads never become trusted outcomes: recompute from pinned prefix/catalog or private verified cache. Add firstGUIOpenMigratesBeforeDestinationCreation integration assertion. Long-lived stores/readers never hold writer lease; focused index write busy preserves in-memory outcome and reports deferred persistence. Merge validated results into source states, do not replace a newer focused result with late restoration.
- [ ] Run core suites/self-check; instrument synthetic cold/warm runs including revalidation cost and assert exact outcome/count parity, not a made-up speed threshold.
- [ ] Review diff; commit only with authorization.

### Task 5: Tree navigator preserving current interaction

**Files:** Modify ProjectGalleryViews.swift and RawViewApp.swift; create Tests/RawViewCoreTests/TreeNavigationTests.swift for pure filtering/state helpers in SourceTree.swift.
**Interfaces:** Consumes SourceInventory/SourceTreeNode; add core `SourceTree.filtered(sourceIDs: Set<String>) -> [SourceTreeNode]` on a proposed SourceTree value initialized from inventory/project, preserving directory ancestors. RawViewModel stores inventory issues, active navigation mode, and expanded directory IDs scoped to current project/data root. Create core ProjectSessionState reducer/tests as defined above. Reset sidebar search/facet/filter/collapse/pagination via project+root View identity; keep them unchanged during ordinary inspection updates.

- [ ] Add failing tests treeFilterKeepsAncestorsAndDoesNotFlatten, duplicateBasenamesKeepDistinctIDs, rootChangeClearsSelectionAndExpansion, virtualGroupingStillUsesProjectRelativeIDs. Directory-only branches retained in unfiltered Tree, only ancestors of matches retained during search.
- [ ] Implement Tree as default navigator mode; use native disclosure/file rows, keyboard expand/collapse and existing file multi-selection/focus. Existing sample/instrument/category/mode/date/status views remain alternatives; no instrument inference from directories.
- [ ] Keep folders non-source-selectable; inspection badges never shift identity or invent study membership. Loading/error/empty states show selected data root and inventory issues.
- [ ] Run helper tests/self-check and native manual verification on synthetic deep, empty, duplicate-name and wide inventories; verify focused plot/table, overlays, keyboard selection and search clear/restore behavior. Record evidence, do not claim UI tests from core typecheck alone.
- [ ] Review diff; commit only with authorization.

### Task 6: Project setup/settings and coherent root-switch lifecycle

**Files:** Create ProjectSetupView.swift; modify RawViewApp.swift, SettingsView.swift, ProjectGalleryViews.swift and core ProjectSessionState tests (not tests importing the executable model).
**Interfaces:** Consumes ProjectSettingsStore/context and shared store/coordinator. RawViewModel adds `configureProject(root: URL, dataRoot: String, persist: Bool) async` and `changeDataRoot(to relativePath: String, persist: Bool) async`; internal request generations protect every old discovery/inspection/load/overlay/index result. Stats stored published snapshots, not side-effecting computed DB opens.

- [ ] Add failing lifecycle tests lateOldRootResultsCannotInstall, setupCancelPreservesCurrentProject, failedSettingsSaveDoesNotClaimSaved, readOnlyUseWithoutSavingWorks, malformedSavedRootNeedsCorrection. Settings folder picker limited to root/contained directories; show data/raw suggestion only if regular/readable.
- [ ] Build native compact setup sheet: Project folder, Data folder, Change…, Open Project, Cancel, explicit Open without saving when requested. Existing valid settings bypass setup; invalid settings show corrective diagnostic, never hidden fallback.
- [ ] Add Project settings section with project path, relative data location, Change…, persistence status and effective index path/storage mode. Global Appearance/Performance settings stay unchanged. Root switch cancels tracked lazy restoration as well as full inspection, obtains fresh generation, clears scoped selection/state, rebuilds namespace and tree.
- [ ] Verify Task 4 already removed ALL main-thread computed databaseStats opens and synchronous reindex deleteAll; wire the new settings UI to async published usage/coordinator without reintroducing them. Show busy/cancellation/storage errors and resume without silently swallowing SQLite failures.
- [ ] Run state tests/self-check and native manual flow: legacy project, new custom-root project, read-only, moved whole project, missing root, canceled setup, switching during load, filters and snapshots/export non-regression. No real project installation needed.
- [ ] Review diff; commit only with authorization.

### Task 7: Headless pre-index command

**Files:** Create Sources/RawViewIndexCLI/main.swift and Scripts/check_index_cli.sh; modify Package.swift, CoreSelfCheck.swift; create Tests/RawViewCoreTests/IndexCommandTests.swift and core IndexCommand.swift for pure parsing/exit classification.
**Interfaces:** Product rawview-index depends only on RawViewCore. Proposed `IndexCommand.parse(_ arguments: [String]) throws -> IndexCommandOptions`; options define project URL, optional dataRoot, saveSettings/rebuild/json flags. CLI consumes ProjectSettingsStore, ProjectIndexer.run and report; no separate reader implementation.

- [ ] Add failing parser tests exact flags/missing arguments/unknown flags, --save-settings without --data-root, outside relative roots, and invalid settings. Explicit --data-root may correct invalid saved configuration for this invocation; it overwrites settings only with --save-settings. No saved config and no explicit root is exit 2 even when data/raw exists, making write scope explicit.
- [ ] Define exit mapping 0 complete (deterministic blocked permitted), 1 fatal/transient incomplete, 2 arguments/configuration, 3 writer busy, 130 interrupt. --json prints one count/storage report to stdout; progress goes stderr, summary contains no raw filenames/values/hashes. Keep error details sanitized by default.
- [ ] Implement async CLI and signal cancellation with completed batch retention. Add end-to-end synthetic shell fixtures testing config-only/explicit override/saved settings/rebuild/interrupt/busy/read-only and proof CLI writes are restored by GUI through the same validation seam.
- [ ] Run `swift build --product rawview-index`, `Scripts/check_index_cli.sh`, targeted tests/self-check. CLI build/test artifacts go under managed scratch. Verify raw fixture bytes and mtime unchanged, deterministic blocked counts and exit semantics exact.
- [ ] Planned later command (DO NOT RUN during planning): `swift run --package-path /Users/tai/agent-development/worktrees/raw-viewer-upgrade rawview-index --project <Tai-selected-project> --data-root data/raw --save-settings --json`. Subsequent runs omit root/save flags; --rebuild requests full reinspection. Select an actual authorized project path before substituting placeholder.
- [ ] Review diff; commit only with authorization.

### Task 8: Cross-cutting review, docs, and release acceptance

**Files:** Modify CONTRACT.md, README.md, RELEASE_GATE.md, affected tests and Scripts/CoreSelfCheck.swift; preserve Windows deferred plan.
**Interfaces:** No new runtime interface; publishes exact setup/index authority/migration/CLI behavior and real evidence.

- [ ] Audit all data/raw/indexDatabaseURL/IndexDatabase.open usages and confirm no runtime path bypass remains. Review generic fallback separately: generic inspection must now be bounded/pinned with typed structural-candidate status; remaining full-load URL rereads/row dropping cannot be labeled scientifically validated and this slice does not widen that measurement fallback.
- [ ] Update contract for configuration/tree/root containment/manifest policy and advisory index versus private content-verified measurement cache; document legacy preservation, read-only fallback and actual command. Preserve profile schema and export format/location.
- [ ] Run full `swift test` in a compatible toolchain plus `Scripts/check_core.sh`, CLI checks, `git diff --check`. If any cannot execute, state NOT_ASSESSED and do not declare completion. Inspect scripts before building/package; current package_app.sh uses RAWVIEW_APP_PATH, not its positional argument, so never accidentally install via misleading README command.
- [ ] Package only into authorized scratch via existing environment variables, verify native flows including tree/setup/index stats/cancel/filter/plot/table/overlay/export. No /Applications replacement unless separately requested.
- [ ] Obtain fresh whole-diff review; fix findings with their own tests. Compare source bytes/timestamps and index integrity on synthetic fixtures. Code tests do not establish scientific acceptance.
- [ ] After Tai selects exact live project and confirms execution, run one pre-index/migration job there, read back effective settings/index integrity and report counts/storage/remaining failures without raw data disclosure. This conditional step is not authorized for this planning turn.
- [ ] Ask Tai for integration/commit/publication instructions; leave worktree and legacy rollback artifacts intact. Windows remains deferred.

## Authoring self-review

Independent review identified index-authenticity, typed-error, generic-inspection and path-cutover blockers; document corrections address them, while SQLite VFS race protection remains a mandatory feasibility gate before execution. This is a reviewed draft, NOT a claim of implementation readiness or a second reviewer approval. Spec coverage is represented in Tasks 1-8; each Review Focus has owning tests. Proposed interfaces are explicitly new and consumed by later tasks. Existing source identity/profile/export contracts are retained except deliberate configured-root/tree changes. Written spec, destination assumption, legacy retention strategy, and plan need Tai's review before execution. No tests of proposed implementation have been run because no product code is written.
