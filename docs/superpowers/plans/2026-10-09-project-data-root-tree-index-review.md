# Project data root / Tree / index — planning review record

Status: independent initial review completed; parent verified findings against source and corrected draft documents. No second independent review of corrected drafts is claimed. No product code or implementation tests changed/run in this review.

Documents:
- ../specs/2026-10-09-project-data-root-tree-index-design.md
- 2026-10-09-project-data-root-tree-index.md

## Accepted findings and document corrections

1. A digest/catalog match does not authenticate a project-controlled inspection payload. Restoration now requires recomputation from pinned prefix/current catalog or private verified cache. Forgery tests retain correct validity metadata while changing semantic fields.
2. SourceInspectionResult currently erases error class into text. Plan now introduces typed dispositions carried through inspectMany/cache, with cancellation not counted as inspected work.
3. Generic inspection currently reopens and scans entire files. Bounded pinned-prefix inspection is now in scope; full generic measurement-load redesign remains separate and cannot be called scientifically verified.
4. Early indexDatabaseURL change could create destination before migration. Cutover and all direct GUI DB-open removals are now one Task 4 integration boundary; store resolution cannot create files before migration lease.
5. Lease lifetime specified as writer-job-scoped; idle GUI/read operations do not reserve it. Focused GUI writes encountering a busy lease retain fresh in-memory state and report deferred persistence.
6. Partial enumeration/metadata errors produce typed inventory issues, visible GUI partial state, incomplete reports and CLI exit 1, rather than silent success.
7. Sidebar search/facet/filter/collapse/pagination reset on project/root change, not inspection refresh. Core ProjectSessionState supplies an explicit executable generation/selection test seam; native integration still needs UI verification.
8. Viewer metadata and snapshot namespaces cannot be selected as data roots and are excluded for all configured roots, not only dot-root.

## Remaining gates — not resolved by writing documents

- Written approval of spec and plan, including proposed .rawviewer/index.db destination, allowing dot-root with no discovered manifests, and non-destructive legacy retention.
- Safe writable project-local SQLite race protection must be proven. Existing pathname-based IndexDatabase.open has no demonstrated descriptor-relative/no-follow VFS guarantee for ancestor/db/WAL/SHM swaps. Plan requires a tested VFS/no-clobber proof before rollout; if unsuitable, stop and ask Tai about private writable index storage. Do not silently weaken security or move the destination.
- A compatible toolchain is required to execute Swift Testing suites. Earlier core self-check/app typecheck passed; earlier swift test was blocked by missing Testing. No proposed-feature tests have executed.
- Actual live project path and execution authorization are needed before database relocation/pre-indexing; this planning turn deliberately did neither.
- Pre-indexing can avoid repeated cold inspection work, but secure freshness validation and directory discovery remain necessary; zero-wait behavior is not promised.

## Scope status

Existing raw-viewer-upgrade worktree reused. Windows remains deferred. Documents uncommitted. No database relocation, deletion, source mutation, UI implementation, CLI execution, installed-app replacement, Linear update or publication occurred.
