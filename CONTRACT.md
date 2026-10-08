Warning: truncated output (original token count: 9446)
Total output lines: 542

# RawView reader contract v1

RawView owns its readers. Opening a project reads its raw files in-process: the
viewer never executes project-local code and, for supported formats, has no
dependency on a project reader or an ancestor Study runtime. Instrument
profiles are declarative YAML data under the project's existing plural
`data/instruments/` directory, or under its `rawview/` companion directory
when that entry exists.

## Project layout and discovery

- The exact filename .DS_Store is omitted lexically at every depth before
  per-entry metadata is requested. Other dot-prefixed files remain eligible
  for normal inventory.

- A project is a folder containing a readable `data/raw` directory. A missing
  raw directory is rejected with an actionable message so another folder can be
  selected.
- Readable regular files under the selected project's canonical `data/raw`
  enter the inventory except for the excluded names and suffixes below. Other
  symlink entries are listed lexically with no claimed target size, then
  blocked during inspection with a no-follow diagnostic; their targets are
  never followed or read. Symlinked directories are not traversed, and
  descendant project roots are never discovered as additional roots — a
  subdirectory carrying its own `data/raw` marker is pruned, not recursed into.
- Files ending in `.spe` or `.affm` (case-insensitive) are omitted from the
  inventory. RawView decides the exclusion from the file name and skips those
  entries before requesting any per-entry metadata from them; RawView never
  opens, parses, hashes, reads, copies, or transmits them. RawView cannot make
  guarantees about metadata operations the platform directory enumerator
  itself may perform while walking the tree. A directory carrying such a
  suffix is still traversed and its non-excluded children are inventoried
  normally.
- Profiles are read from the project's canonical `data/instruments/` directory,
  or from its `data/instruments/rawview/` companion directory when that entry
  exists. When the companion entry exists it is authoritative: only companion
  YAML profiles are read and the parent directory is never consulted. A missing
  companion entry keeps the top-level behavior; an empty one means no profiles;
  an unusable one (not a contained readable directory, or one that cannot be
  examined, such as a search-permission error) fails closed with a diagnostic
  and never falls back. Only a proven-absent entry falls back to the parent
  directory. The directory and every profile file must
  resolve inside the project; anything else is skipped and reported. Moving the
  project requires no code or profile edits because profiles and normalized
  results use project-relative paths.

## Instrument profile schema v1

Every profile must declare `schema_version: 1`. A missing or unsupported version
blocks only the sources that would use that profile and reports an explicit
upgrade diagnostic; RawView does not rewrite profiles and has no compatibility
mode for unversioned files. `Examples/rawview/keysight-b1500a.yaml` is a working
example.
Profiles are parsed with the in-repo fail-closed YAML subset (Foundation only,
no added dependency): tabs, duplicate keys, nested flow collections, and
unsupported escapes are rejected with line diagnostics rather than guessed.

| Field | Required | Meaning |
|---|---|---|
| `schema_version` | yes | Integer `1`. Other values are rejected. |
| `instrument.id`, `instrument.name` | yes | Instrument identity used in the gallery and provenance. |
| `instrument.vendor`, `instrument.model` | no | Descriptive identity fields. |
| `formats[].id` | yes | Format identifier, unique per profile. |
| `formats[].kind` | yes | Only `tabular` is supported in v1. |
| `formats[].extensions` | yes | Non-empty list of file extensions such as `".csv"`; matching is case-insensitive. |
| `formats[].delimiter` | yes | Single character separating cells. |
| `formats[].encoding` | no | Ordered decode attempts from `utf-8`, `windows-1252`, `iso-8859-1`, `ascii`. Defaults to `utf-8`. |
| `formats[].rows.names_prefix` | yes | First cell of the header row, e.g. `DataName`. |
| `formats[].rows.data_prefix` | yes | First cell of each data row, e.g. `DataValue`. |
| `formats[].columns.<key>.header` | yes | Column name as printed in the names row. |
| `formats[].columns.<key>.aliases` | no | Alternative header names accepted for the same column. |
| `formats[].columns.<key>.quantity` | yes | Declared physical quantity (for example `voltage`, `current`). |
| `formats[].columns.<key>.unit` | yes | Declared unit string. Overlay eligibility initially requires equal declared units; unit conversion is out of scope. |
| `formats[].columns.<key>.label` | no | Display label; defaults to the humanized column key. |
| `modes[].id` | yes | Application mode identifier, unique per profile. |
| `modes[].format` | yes | Reference to a declared `formats[].id`. |
| `modes[].detect` | yes | Non-empty list of case-insensitive header signature strings. |
| `modes[].extract.x` | yes | Column key used as the x axis. |
| `modes[].extract.y` | yes | One or more column keys used as y channels (unique; the x key is excluded). |

Unrecognized keys are rejected, not ignored: every mapping scope allowlists
its schema v1 fields (`schema_version`/`instrument`/`formats`/`modes` at the
root; `id`/`name`/`vendor`/`model` under `instrument`;
`id`/`kind`/`extensions`/`delimiter`/`encoding`/`rows`/`columns` per format;
`names_prefix`/`data_prefix` under `rows`;
`header`/`aliases`/`quantity`/`unit`/`label` per column;
`id`/`format`/`detect`/`extract` per mode; `x`/`y` under `extract`). Any other
key blocks the profile with a diagnostic naming the profile path and field.
Any `transforms` field, regardless of YAML node shape (list, map, scalar, or
empty), is rejected the same way: schema v1 has no transform mechanism, so a
declared transform (for example a current-inversion multiply) must be removed
or migrated, never ignored. Non-string list elements (in `extensions`,
`encoding`, `aliases`, `detect`, `extract.y`) are likewise rejected rather
than silently dropped. A block-list `- ` marker at its parent map's indent is
malformed YAML and fails with the profile path and line number. Every
validation problem names the profile path and the failing field (for example
`data/instruments/x.yaml: formats[0].columns.voltage.unit is required.`).

## Instrument profile schema v2 (standalone)

Viewer profiles are standalone top-level YAML documents. A Study-owned
instrument document is not read by RawView, and a document carrying a
top-level `raw_viewer:` block is rejected fail-closed with a diagnostic naming
the profile path and the migration target; RawView never extracts a nested
block and has no compatibility mode for one. Standalone top-level documents
keep working unchanged: `schema_version: 1` validates exactly the v1 rules
above, and a standalone `schema_version: 2` document validates the v2 rules
below at the top level. Provenance records the actual per-profile version in
`profile_schema_version`.

V2 additions over v1 (all fail-closed; v1 documents reject the new fields):

| Field | Meaning |
|---|---|
| `formats[].kind` | Finite layout set: `tabular`, `comment-tsv`, or `first-row-header`. Any other kind is rejected. |
| `formats[].decimal` | Optional lexical decimal separator, `"."` (default) or `","`. A comma decimal rewrites `12,345` to `12.345` before parsing; it conflicts with a `","` delimiter and is rejected there. Schema v1 has no decimal field. This is a lexical property, not a transform mechanism: v2 has no transforms field either. |
| `formats[].rows.data_prefix` | May be `""` (empty string): every non-blank line after the header row is a data row (Keithley LVM rows carry an empty leading cell; the legacy Horiba semicolon table has numeric first cells). A non-empty marker keeps the v1 equality rule. Blank lines are skipped, never parsed as gap rows. |
| `formats[].columns.<key>.column_index` | Required instead of `header`/`aliases` for `comment-tsv`: the 0-based source column. Indices must be unique per format. `header`/`aliases` are rejected for this kind, and `column_index` is rejected for `tabular`. |
| `formats[].columns.<key>.required` | Tabular and first-row-header v2 only, `true` by default. `false` makes a declared non-axis channel optional: it resolves when its header is present and is skipped without invented values when absent, leaving required channels unchanged. Rejected in v1 and for `comment-tsv`. Plot axes (`extract.x`/`extract.y`) must reference required columns. |
| `modes[].filename_contains_all` | Optional v2-only basename gate: a non-empty list of non-empty strings. Every token must occur case-insensitively in the source basename (`lastPathComponent` only; parent directories never match). Rejected in v1 as an unknown key. |
| No `rows` for `comment-tsv` | A `rows` mapping under `comment-tsv` is rejected: the layout is headerless by definition. |
| No `rows` for `first-row-header` | A `rows` mapping under `first-row-header` is rejected: the first non-blank line is the header row by definition, and every later non-blank line is a data row. |

## Project profile ownership

Instrument profiles remain YAML data; RawView never executes project code or
loads the Study runtime. A project may keep Study-owned profiles in
`data/instruments/` and place separate versioned viewer profiles in
`data/instruments/rawview/`. When `data/instruments/rawview/` exists, those
companion profiles are the only profiles loaded: parent-directory YAML is
ignored, and an empty or unusable companion directory never falls back to it.
The `rawview` companion directory and each selected YAML entry must be regular
paths in that directory; RawView rejects a symlinked companion directory,
profile entry, or opened profile whose descriptor path resolves elsewhere.
Companion profiles are standalone top-level RawView YAML without Study
metadata, evidence, source references, or hashes. They describe only the
formats the viewer supports. They must not duplicate Study run pins or embed
raw-file paths, hashes, measurements, or sample inventories. Tests in this
repository use synthetic fixtures; source-specific equivalence checks run
locally against the selected project and are not included in shared docs.

### Profile upgrade procedure

1. Keep the Study-owned instrument profile unchanged. Create or update a
   standalone viewer profile in `data/instruments/rawview/` with an explicit
   supported `schema_version`.
2. Declare only observed tabular layouts: extension, delimiter, encoding,
   headers and aliases, quantities, units, and the channels used for plotting.
   Use `filename_contains_all` only with observed basename tokens when broad
   signatures need scoping or signatures overlap another instrument or layout.
   A missing token leaves the file inventoried but unmatched with a
   source-level diagnostic. Do not add transforms or inferred channels.
3. Validate the profile with RawView's inspection and load path against
   representative files. Confirm mode selection, row order and count, arrays,
   units, and diagnostics for unmatched or malformed sources.
4. Keep source-specific measurements and hashes in local validation evidence;
   do not copy raw data, inventories, or hashes into the profile or shared
   documentation.

## Matching one source

1. The source extension must be declared by at least one valid profile. The
   extension gate runs before any header decoding, so an unclaimed extension
   reports `No instrument profile supports "x"` even when the header bytes are
   undecodable. Multiple matching profiles or modes are ambiguous and block that
   source with a diagnostic naming each candidate.
2. A mode matches when its filename selector matches (every
   `filename_contains_all` token occurs case-insensitively in the source
   basename; a mode without the field keeps the legacy behavior) AND …3446 tokens truncated…root, and entry names are digests; no raw path or project identifier
appears in directory or entry names. The cached measurement payload does
include the project-relative source path. Application Support is preferred,
with a private temporary-directory location as fallback. If neither location
can be secured, caching becomes a no-op and source reads still work. The current
schema uses a fresh `RawView-v3` directory (or `RawViewCache-v3` in the
temporary fallback) so it does not depend on permissions of cache directories
created by earlier releases. Owner-only storage protects against project
contributors running under a different OS user; it is not a sandbox against a
hostile process running as the same user, which can race path-based cache
operations.

- **Inspection entries** are keyed by the project-relative source identity,
  lowercase extension, descriptor size taken from the already secured
  descriptor, the SHA-256 of the exact bounded 64 KiB prefix read from the
  no-follow handle, the complete profile-catalog fingerprint (including
  invalid profile bytes/claims that could affect resolution), the reader
  version, and the cache schema. Every hit still no-follow opens the source
  under `data/raw`, reads and hashes that exact prefix, and checks the pinned
  descriptor size. A same-size, same-timestamp header edit therefore misses;
  a row-only edit with an unchanged header prefix and size may reuse the
  inspection. Only deterministic successful and deterministic
  profile-resolution outcomes are stored: cancellation and transient
  filesystem/security/open/read errors are never cached.
- **Measurement entries** store the complete normalized measurement, including
  path/provenance, instrument/mode/view, every channel name/label/unit/
  quantity, every finite Double bit pattern, every gap reason and row,
  acquisition order, metadata fields, warnings, support status, and
  provenance. A candidate hit is found by hashed project-relative source
  identity plus the selected profile/catalog fingerprint, reader version, and
  schema; a hit is then served only after a fresh full-content SHA-256 from
  the secured source handle equals the digest recorded in the entry. Size and
  timestamps are never content proof. On a miss the reader keeps its
  single-pass reader/hash path and stores the result.
- **Storage** is binary property list per entry with a checksummed metadata
  sidecar; writes are atomic (temp + rename), so corruption or interruption is
  an ordinary miss the next store rebuilds. Oversized entries stay usable for
  the current request but are not stored; each entry is capped at 128 MiB.
  Storage is bounded by a per-project limit (default 512 MiB) with LRU
  eviction, configurable in the inspector, with a clear action and usage/limit
  status. Clearing removes only cache entry directories — never project files.
  Cache operations check the owner-only app-local namespace and fail closed on
  observed symlinks or permission changes. This prevents project-controlled
  cache injection but does not provide same-UID process isolation;
  inspection/focused/overlay tasks serialize through one cache.
- The SwiftPM fixture suite contains assertions for the bitwise full-payload
  round-trip (gaps, metadata), invalidation matrix, corruption recovery,
  symlink/containment, ignored project-controlled cache entries, limit/LRU/clear,
  cancellation/transient non-caching, and `.spe`/`.affm` zero-open; fixtures are
  synthetic and never touch real project data. That suite is **NOT_ASSESSED** on
  this host: the Command Line Tools SwiftPM environment could not build the
  test target (compiler/SDK mismatch and unavailable Swift `Testing` module).
  The dependency-free `Scripts/check_core.sh` self-check passed and
  directly verifies app-local cache placement, ignored project cache content,
  inspection reuse, measurement hits and same-size/same-time invalidation,
  bitwise sample/gap round-trip, and LRU/clear. Do not treat unrun SwiftPM
  assertions as executed results.

## Cache decision checkpoint (Issues 6 and 7)

The local benchmark on 2026-10-05 used the selected project without copying or
printing source names, identifiers, or values. The supported inventory
contained 6,723 files (496,087,152 bytes). Three discovery runs took
0.550–0.611 s. Three uncached inspection runs took 12.453, 11.450, and
11.458 s (median 11.458 s): 3,854 inspections matched profiles and 2,869
returned non-success states. A separate pass securely opened and hashed the
bounded 64 KiB inspection prefixes for all 6,723 files (81,616,891 bytes) in
0.228 s. This is about 2% of the uncached inspection median.

A separate earlier cache run recorded 36.990 s for cold population and a
2.539 s warm inspection median across 6,723 entries (5,117,196 bytes). That
timing path includes cache population and is not directly comparable with the
uncached 11.458 s median above. Final-candidate measurements are recorded
below.

Three largest matched local sources across the three observed modes totalled
154,124 bytes. Nine full reader loads (three repetitions per source) retained
23,562 rows; the median load was 24.3 ms. Full-content SHA-256 verification for
those sources took a 0.1 ms median. A binary property-list prototype packed
sample bit patterns and gap codes, occupied 407,301 bytes across the nine
trials, and round-tripped every value and gap bitwise exactly; it did not yet
include all metadata fields, so that size is a lower bound. Binary property
lists are the selected local format because they are native, dependency-free,
and preserve the exact packed arrays without text-number conversion.

The implementation decision is a 512 MiB default per-project LRU cache,
configurable in the viewer and clearable by the user. All projects use a
private app-local cache directory keyed by a digest of the canonical project
root; RawView never reads a project-writable cache. Inspection entries
are keyed by project-relative path, extension, descriptor size, SHA-256 of the
exact bounded header prefix, full profile-catalog fingerprint, reader version,
and cache schema. Every inspection hit still opens the source without following
links, reads and hashes that exact prefix, and checks the descriptor size.
Measurement entries are keyed by source identity and the resolved profile and
reader/schema versions; a possible hit requires a fresh full-content SHA-256
from the secured source handle to equal the digest recorded in the entry.
Neither size nor timestamps establish content identity. Atomic, checksummed
entries turn corruption or interruption into misses and rebuilds. Cancellation
and transient filesystem/security failures are not cached. LRU eviction and
clear operations are contained to the cache root and never modify raw sources
or instrument profiles.

Issue #7 pins a three-run uncached inspection median of 7.247 s. Its targets
are a three-run warm inspection median at or below 3.624 s (half the pinned
baseline), including prefix verification and cache lookup/decode, and prefix
verification at or below 1.449 s. The earlier 24.3 ms full-measurement median
has no recorded exact source cohort, so it is historical context rather than
a verifiable cross-mode target. Full-load acceptance is now measured per mode:
for each fixed representative source, the three-run warm median must be no
more than half its uncached median. Separately, the historical Issue #6 fixed
caps are 4.7 ms for dual-sweep, 5.15 ms for list-sweep, and 406.65 ms for
WGFMU; they are not this candidate's half-median values.

Local acceptance evidence for the exact candidate (distinct from the older
2026-10-06 unverified observations, which it supersedes). A full-data parser
run used a disposable APFS copy-on-write fixture under a private temporary
directory with the three versioned v2 viewer profiles; nothing was written to
the selected project, and `.spe`/`.affm` entries were filtered by filename
suffix before any metadata/content operation. The fixture and its temporary
identity report were removed after the run. No source filenames, raw values,
or source/profile hashes appear below.

On arm64 / macOS 26.3.1, 7,540 supported-extension files (2,701 CSV;
4,839 TXT; 373,840,602 logical bytes) were inventoried. Of these, 5,200 had
a valid profile/mode inspection and 5,191 loaded; 9 failures were isolated
per-source `invalidSource` diagnostics; 2,340 were blocked or unmatched with
explicit diagnostics; 0 profile-catalog issues; 0 `.spe`/`.affm` opens.
Pooled diagnostic loaded counts across the inventory (not separate per-profile
or per-mode counts): dual-sweep 4,702; list-sweep 300; Raman semicolon 1;
Raman TSV 15; WGFMU 173. Source size/mtime metadata was unchanged after the
validation.

A separate one-real-source-per-mode end-to-end check compared every complete
channel array, acquisition order, gaps, and cache payload against independent
local extraction for all 10 declared modes; source and profile hashes were
verified locally and no identifiers or values were retained or sent
externally. Each warm full cache payload was byte-for-byte equal to its
uncached normalized payload.

Open plus discovery took 0.749 s. Three uncached inspections took 13.993,
13.938, and 13.963 s (median 13.963 s; 5,200 supported, 0 profile issues).
Secure prefix verification covered 86,602,005 bytes per run in 0.756, 0.699,
and 0.696 s (median 0.699 s), passing the 1.449 s target. Private app-local
inspection-cache population took 36.631 s; three warm scans took 3.801,
3.317, and 3.309 s (median 3.317 s), passing the 3.624 s target. The cache
held 7,545 entries / 9,291,674 bytes of the 536,870,912-byte limit.

Largest fixed selected source per measured mode, with three-run medians
(uncached / warm); warm medians include a fresh full-source digest check and
decoding the complete cached arrays. This candidate's half-median caps are
4.65 ms for dual-sweep, 4.75 ms for list-sweep, and 467.6 ms for WGFMU (half
of its own 9.3 / 9.5 / 935.2 ms uncached medians). The warm medians also pass
the historical Issue #6 fixed caps (4.7 / 5.15 / 406.65 ms):
dual-sweep 601 points / 2 channels / 34,544-byte encoded payload at 9.3 /
3.8 ms (candidate cap 4.65 ms; historical cap 4.7 ms); list-sweep 402 / 2 /
39,227 bytes at 9.5 / 4.6 ms (candidate cap 4.75 ms; historical cap 5.15 ms);
WGFMU 70,000 / 5 / 1,775,671 bytes at 935.2 / 18.7 ms (candidate cap 467.6 ms;
historical cap 406.65 ms). Cold cache population for those three representatives took
1.268 s. A six-load cached switching sequence had a 53.6 ms median. Peak RSS
was 292.2 MiB.

The exact-manifest evaluator benchmark returned an eligible two-source cohort
and measured a 13.5 μs median across 1,000 evaluations. This measures
eligibility evaluation only, not reader, rendering, or file-switch latency.
The final packaged app was opened against a disposable copy of the project:
the native UI confirmed two exact-manifest sources, 201 points each, 402 total,
and zero gaps. Long series labels stayed inside the center plot card, and the
Inspector showed one visible “Line width” label with the slider accessibility
name “Series line width”. The blocked state for sources lacking one exact
shared manifest was also verified earlier. Real WGFMU overlay, SwiftUI render
latency, and isolated user-visible file-switch latency remain
**NOT_ASSESSED**. The SwiftPM `Testing` suite remains **NOT_ASSESSED** on
this host because its command-line toolchain lacks the Swift `Testing`
module. `Scripts/check_core.sh` (including the app-layer typecheck),
`Scripts/package_app.sh`, signature verification, diff checks, profile YAML
parsing, and the AQG construction check pass on the current candidate.

The synthetic inventory check confirms root and nested .DS_Store entries are
omitted while a dot-prefixed CSV and an ordinary CSV remain discoverable.

Code validation establishes reader behavior only; it does not establish
scientific acceptance of any measurement.
