# Project data root, Tree view, and index relocation — draft design

Status: DRAFT FOR WRITTEN REVIEW; no execution authorized by this document. Tai approved the direction and requested plan-only work in the existing raw-viewer-upgrade worktree. Written-spec and plan review remain gates before implementation. No automatic commits.

## Intent and agreed direction

Open a project folder, configure its contained data root once, then browse its exact nested folder hierarchy in a default Tree view. Prefer data/raw when it exists, but support other contained folders. Project-owned configuration lives at `.rawviewer/setting/setting.yaml`. Preserve raw evidence, native macOS functionality, existing profile compatibility, and explicit scientific interpretation. Windows remains deferred.

Tai also authorizes eventual index relocation and a headless pre-index command. The final instruction stops this turn after writing and reviewing documents: no live migration/indexing in this turn.

## Proposed decisions for written approval

- Writable index destination (Tai decision (b) after the Task 3 VFS gate failed with a confirmed ancestor-swap escape): owner-private app-local (Application Support keyed by project digest, same pattern as the measurement cache). NO project-local SQLite writes; legacy `data/.rawview/index.db` (+WAL/SHM) preserved as rollback, never auto-deleted. Settings YAML stays in-project. Cost: moving/renaming a project reindexes.
- Data root may equal the project root (`.`) or be its contained regular descendant; external roots and symlinked data-root components are rejected. Reject roots equal to or beneath project `.rawviewer`, `data/.rawview`, or `data/snapshot`; those namespaces are excluded from traversal for every root, not only `.`. `.` enables unstructured projects without creating a new hierarchy.
- Missing configuration: suggest a readable regular data/raw directory; otherwise require an explicit folder selection. GUI allows Open without saving. Headless use requires existing valid settings or an explicit --data-root argument; no hidden default during CLI writes.
- Malformed/unsupported settings or a missing configured root never silently fall back; offer corrective selection. Settings are data only, UTF-8, capped at 64 KiB, parsed with the existing fail-closed YAML subset. Reject unknown/duplicate keys.
- YAML v1 has exactly `schema_version: 1`, `data_root: "data/raw"` (or another normalized contained path), and `default_view: "tree"`. Do not store an absolute project directory: the file's owner directory determines it. Reject absolute paths and any `..` component before normalization. Saving uses contained no-follow/atomic file operations and refuses symlinked namespace entries.
- Global appearance/performance settings remain app-local. Add a clearly labeled Project settings section rather than relocating all current preferences into YAML.

## Identity, discovery, and Tree view

Keep RawSource.relativePath, normalized source.path, source IDs, and manifest identities project-relative. Tree display is relative to the configured data root; presentation does not redefine identity. Changing data root cancels discovery/inspection/focus/overlay work, starts a new generation, clears selection, and invalidates root-specific derived state. Preserve existing native UI identity and virtual grouping modes; Tree is the default.

Discovery keeps regular nested directories including empty and intermediate directories; directories are navigation nodes, never scientific study membership. Remove the source walk's implicit nested data/raw-marker pruning: a real directory inside the selected data root is part of that tree, not another automatically opened project. Retain no-follow link policy and lexical .DS_Store/.spe/.affm exclusions. Keep current eligible extensions csv/txt/lvm/dat for this slice; broad format detection, generic parser redesign, and TAI-80 editing are separate work.

When data root is `.`, exclude RawView-owned `.rawviewer`, legacy `data/.rawview`, and `data/snapshot` from source traversal to prevent settings/index/exports becoming measurements. All other directories retain physical hierarchy. Enumeration and UI installation remain cancellable and off-main; partial directory/entry access errors are returned as typed inventory issues alongside usable results, not silent omissions. Any inventory issue makes the indexing report incomplete and CLI exit 1; the GUI shows partial results with an incomplete-inventory warning. Initial tree can appear after cancellable inventory; streaming tree delivery is not promised by this slice.

Folder rows expand/collapse; file rows retain existing multi-selection/focus actions and keyboard navigation. Search matches files and retains ancestor context; existing virtual-group filters continue to work. A project/root identity change resets sidebar search, facet (to tree), filters, collapse/expansion and pagination; ordinary inspection updates preserve them. A pure core generation/selection reducer supplies executable lifecycle tests; native integration still needs UI checks. Unmatched eligible files remain selectable with diagnostics; do not add or silently broaden scientific inference.

## Readers, profiles, manifests, and measurement cache

Replace hard-coded data/raw membership checks in reader, cache, and manifests with configured-root containment. Descriptor verification must still validate the same object whose bytes are read/hashed. Diagnostics name the configured data root.

Keep profiles at project-relative data/instruments and authoritative data/instruments/rawview, independently of data-root selection. No profile-schema migration. Manifest scanning stays project-relative, prunes configured data root and both RawView metadata namespaces, and preserves explicit exact-manifest overlay membership. With data root `.`, there is no metadata subtree outside raw: return no discovered manifests with an explanatory diagnostic, rather than scanning every raw YAML file. Existing snapshot export location and format stay unchanged.

Private content-verified measurement cache remains app-local. Include configured data-root identity and a bumped reader/cache namespace in derived keys so results cannot leak across root changes. Generic INSPECTION must be repaired in this slice: inspect only the secured bounded 64 KiB prefix, never reopen the pathname or count total rows by reading the whole file. Unprofiled results are unresolved structural candidates, not supported scientific measurements. The broader generic full-measurement loader (unpinned reads/dropped rows) remains outside this slice; do not claim scientific trust or propagate its result as validated indexing evidence.

## SQLite authority, relocation, and lifecycle

The project-local SQLite index is an advisory catalog, not evidence or a measurement cache. Treat migrated/project-controlled records as unverified hints. UI restoration must recompute the inspection outcome from the secured prefix/current catalog or obtain the independently verified private inspection-cache result. Never promote fields from the project DB merely because their digest/catalog metadata matches: a contributor can forge the fields and copy correct validity metadata. Same size/mtime is not content proof; a digest establishes freshness, not authorship of an inspection result.

Use one shared core coordinator for GUI and CLI. Index namespace is `(project identity, normalized data root, reader version, catalog fingerprint, index schema)`; record validity additionally uses secured bounded-prefix digest and descriptor size. Filter out stale/deleted paths and persist deterministic blocked outcomes without caching transient access failures.

Never `mv`/copy just a live WAL database file. Close this process's handles; acquire an exclusive project maintenance lease before relocation. Use SQLite backup into a sibling staging database from a read-only legacy connection, so committed WAL content is included. Verify integrity and scope, close staging, atomically publish when destination is absent, then reopen destination. Do not overwrite an existing destination or unlink an externally held database. Preserve legacy db/WAL/SHM for rollback; removing them is a separate maintenance action after explicit confirmation. This is logical relocation of active use, not immediate destructive cleanup.

Invalid/unreadable legacy DB: report the problem, retain it, and create/rebuild the destination only when that namespace is safe. A symlinked destination/metadata namespace is a security refusal, not a reason to follow it. Ordinary read-only permission failure uses an owner-private app-local index fallback or no-index operation with visible status. Stats must not create/open a database during SwiftUI body evaluation. Database operations check SQLite return values including WAL setup and transaction commit; cancellations retain completed bounded batches. Concurrency uses one per-project lease for bounded writer/migration jobs; the long-lived GUI does not hold it while idle or reading. Store resolution/open performs no creation: first writer acquires the lease, checks migration, and only then creates/opens a writable destination. Focused GUI writes acquire a short lease; if busy, preserve the fresh in-memory inspection and show deferred index persistence rather than disrupting viewing. Bulk GUI/CLI jobs report busy rather than racing rebuild. Lease release survives crash through OS locking, not stale marker existence alone.

Runtime path cutover and removal of EVERY direct GUI IndexDatabase.open call must ship together, including stats/reindex; do not expose an intermediate build that creates the destination before migration. SQLite namespace protection is a proof gate: check-then-open is insufficient against swapped ancestors or DB/WAL/SHM symlinks. Require tested descriptor-relative/no-follow SQLite VFS access and no-clobber publication, or stop project-local writable-index rollout and propose private storage to Tai. No assumed race resistance from static checks; do not silently change the approved destination.

## Headless pre-indexing

Planned product: `rawview-index` sharing RawViewCore; no UI launch or project code execution. Planned interface:

`rawview-index --project <absolute-project-path> [--data-root <project-relative-path>] [--save-settings] [--rebuild] [--json]`

--save-settings requires --data-root. --rebuild re-inspects via the secure path; it does not delete measurement caches or raw files. Indexing populates bounded inspection summaries, not complete measurement arrays; focused loads still verify/read content. JSON emits counts/storage mode only by default, not raw names, values, identifiers, or hashes. Source failures and inventory issues are counted and isolated through typed dispositions (profileMatched, structuralCandidate, deterministicBlocked, transientFailure, cancelled), not localized-message matching; fatal config/storage errors fail; interrupt preserves committed batches and reports incomplete work. Cancelled/unvisited entries never inflate inspected/completed counts. Read-only fallback is explicit. No realistic promise of zero wait: discovery and content validation remain necessary.

Exit contract: 0 completed inventory/inspection (deterministic unsupported results allowed), 1 fatal setup/storage failure, 2 invalid arguments/settings, 3 writer busy, 130 interrupted. Tests must distinguish deterministic unsupported results from transient access failures: transient failures produce an incomplete report and exit 1.

## Verification and completion boundary

Synthetic fixtures only by default. Cover portable settings, symlink/escape failures, root switches, legacy default compatibility, exact tree/filter behavior, manifest/overlay parity, WAL migration rollback/conflict/crash recovery, same-size/same-time source edits, catalog invalidation, read-only fallback, CLI-to-GUI reuse, cancellation and source zero-open exclusions. Record cold/warm timing against a fixed synthetic cohort; do not invent latency guarantees.

Current baseline: core self-check and app typecheck passed during preceding audit; SwiftPM tests could not compile because Testing was unavailable. Implementation needs an environment able to run the suite; never relabel unexecuted assertions as passes. No real-project pre-index/migration acceptance until Tai selects its exact path. No commits, install, publication, or scientific acceptance implied.
