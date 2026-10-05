# RawView reader contract v1

RawView owns its readers. Opening a project reads its raw files in-process: the
viewer never executes project-local code and, for supported formats, has no
dependency on a project reader or an ancestor Study runtime. Instrument
profiles are declarative YAML data under the project's existing plural
`data/instruments/` directory, or under its `rawview/` companion directory
when that entry exists.

## Project layout and discovery

- A project is a folder containing a readable `data/raw` directory. A missing
  raw directory is rejected with an actionable message so another folder can be
  selected.
- Only regular files under the selected project's canonical `data/raw` are
  inventoried. Symlinks are never followed for the inventory: a link is
  excluded without touching its target, and descendant project roots are never
  discovered as additional roots — a subdirectory carrying its own `data/raw`
  marker is pruned, not recursed into.
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
| `formats[].kind` | Finite layout set: `tabular` or `comment-tsv`. Any other kind is rejected. |
| `formats[].decimal` | Optional lexical decimal separator, `"."` (default) or `","`. A comma decimal rewrites `12,345` to `12.345` before parsing; it conflicts with a `","` delimiter and is rejected there. Schema v1 has no decimal field. This is a lexical property, not a transform mechanism: v2 has no transforms field either. |
| `formats[].rows.data_prefix` | May be `""` (empty string): every non-blank line after the header row is a data row (Keithley LVM rows carry an empty leading cell; the legacy Horiba semicolon table has numeric first cells). A non-empty marker keeps the v1 equality rule. Blank lines are skipped, never parsed as gap rows. |
| `formats[].columns.<key>.column_index` | Required instead of `header`/`aliases` for `comment-tsv`: the 0-based source column. Indices must be unique per format. `header`/`aliases` are rejected for this kind, and `column_index` is rejected for `tabular`. |
| `formats[].columns.<key>.required` | Tabular v2 only, `true` by default. `false` makes a declared non-axis channel optional: it resolves when its header is present and is skipped without invented values when absent, leaving required channels unchanged. Rejected in v1 and for `comment-tsv`. Plot axes (`extract.x`/`extract.y`) must reference required columns. |
| No `rows` for `comment-tsv` | A `rows` mapping under `comment-tsv` is rejected: the layout is headerless by definition. |

## Project profile ownership

Instrument profiles remain YAML data; RawView never executes project code or
loads the Study runtime. A project may keep Study-owned profiles in
`data/instruments/` and place separate versioned viewer profiles in
`data/instruments/rawview/`. When `data/instruments/rawview/` exists, those
companion profiles are the only profiles loaded: parent-directory YAML is
ignored, and an empty or unusable companion directory never falls back to it.
Companion profiles are standalone top-level RawView YAML without Study
metadata, evidence, source references, or hashes. They describe only the
formats the viewer supports. They must not duplicate Study run pins or embed
raw-file paths, hashes, measurements, or sample inventories. Tests in this
repository use synthetic fixtures; source-specific equivalence checks run
locally against the selected project and are not included in shared docs.

## Matching one source

1. The source extension must be declared by at least one valid profile. The
   extension gate runs before any header decoding, so an unclaimed extension
   reports `No instrument profile supports "x"` even when the header bytes are
   undecodable. Multiple matching profiles or modes are ambiguous and block that
   source with a diagnostic naming each candidate.
2. A mode matches when at least one `detect` signature appears,
   case-insensitively, in the first 64 KiB of the decoded file. No match reports
   the declared modes and signatures for that profile.
3. Per-source isolation: broken profiles keep their selectors and diagnostics
   per profile and never borrow another profile's. A source with exactly one
   valid mode match stays usable beside an unrelated invalid or unversioned
   profile claiming the same extension only when that profile's own declared
   detect signatures provably do not match the source (both `modes[].detect`
   and legacy `application_modes[].detect.signatures` count as evidence). A
   conflicting same-source signature, or a claim with no trustworthy selectors
   (malformed YAML supplies none), keeps the source blocked with the
   profile/field diagnostic instead of claiming a unique mapping. Sources with
   no valid match stay blocked until the invalid profile is fixed or removed.
   Sources that match no other source's declarations are unaffected.

## Tabular extraction (row-block layouts)

The row-block layout covers the Keysight B1500A I-V tabular CSV export and,
under schema v2, the Keithley LVM and legacy Horiba semicolon tables (empty
`data_prefix`, tab/`;` delimiters). The headerless Horiba comment TSV uses the
`comment-tsv` positional layout with the same gap contract.

- The file is decoded with the profile's ordered encodings, trying only
  encodings from formats that declare the source extension. A leading
  byte-order mark is accepted. The bounded 64 KiB header sample never splits a
  UTF-8 scalar: a cut mid-scalar backs off to the scalar boundary.
- The first row whose first cell equals `rows.names_prefix` is the header row.
  Every format-declared channel resolves by exact primary header first, with
  aliases only as fallback; ambiguity at either rank blocks the source, as do
  two channels resolving to the same source column. All declared channels are
  parsed into the ordered table; only the mode's x/y channels drive the plot.
- Cells are quote-aware: a delimiter inside `"..."` stays in the cell and `""`
  is an escaped quote. A malformed quote blocks the source naming file and
  line instead of shifting columns silently. Remaining cells are split on the
  profile delimiter and trimmed.
- Data rows are rows whose first cell equals `rows.data_prefix`. Every data row
  is kept in file order as one acquisition row, including rows with gaps.
- A missing cell (short row) or empty cell is a blank gap; case-insensitive
  `NaN`/`Inf`/`Infinity` spellings (with optional sign) are recorded gaps; a
  spelled number that parses to a non-finite value is overflow saturation.
  Each gap keeps its reason and raw token: the channel value is null for that
  row, the plot breaks the line at the gap (drawing singleton runs as visible
  dots), and the table shows the reason marker. A warning names the file,
  line, column, reason, and raw token for each gap cell. Finite values are kept
  bitwise exact; gaps are never interpolated, averaged, or replaced with
  invented finite numbers.
- Any other non-numeric cell text (for example `--`) is corrupt, not a gap: it
  blocks that source and names the file, line, column, and value. Corrupt text
  is never silently converted into valid data or a gap.
- Header lines before the names row are preserved as `Acquisition` metadata
  (for example Keysight SetupTitle, Dimension, record time) with stable unique
  keys, so repeated rows keep every distinct value. Filename-derived device,
  timestamp, and category join a separate `Identity` section; the category is
  a filename grouping aid, never scientific study membership.
- Every data row is kept in file order. Values are never sorted, interpolated,
  averaged, normalized, downsampled, or unit-converted, and repeated or reversed
  sweep points remain where the instrument wrote them.
- A missing header row or zero data rows blocks that source with a diagnostic.
- Transforms are not part of schema v1: there is no mechanism to invert, scale,
  or otherwise convert measured values.

## Normalized measurement boundary

The normalized measurement is the integration seam for plotting, tables, and
future overlay eligibility. It carries:

| Field | Meaning |
|---|---|
| `source.path`, `source.sha256` | Project-relative path and SHA-256 of exactly the bytes parsed. |
| `instrument.id`, `instrument.name` | Profile instrument identity, with optional profile `vendor`/`model` when declared. |
| `application_mode` | Matched mode id. |
| `view.kind`, `view.x`, `view.y`, `view.preserve_order` | `xy` view; `preserve_order` is always `true` for data views. |
| `channels` | Ordered channels with `name`, `label`, `unit`, `quantity`, row-aligned `values` (numbers or null gaps), and parallel `gap_reasons` (`blank`, `nan`, `infinite`, `saturated`, `unknown`); names are unique and lengths equal, so every channel has the same acquisition row count. Non-null values are always finite. |
| `metadata_sections`, `warnings`, `support_status` | Reported metadata and state; `supported` for extracted data. `metadata_sections` carries `Acquisition` (header fields such as SetupTitle, Dimension, record time), `Identity` (filename-derived device, timestamp, category, plus filename), and `Data` (channel/row/gap counts). `warnings` carries per-gap diagnostics and truncation notes. |
| `provenance` | `reader_version` and `mode` always; profile-backed sources add `profile_id`, `profile_hash`, `profile_schema_version`. |

Filename facts follow the existing project convention (read-only): a leading
`DDMMYY-HHMMSS` timestamp validated as a calendar date (years pivot to
2000–2099), a `[device]` token, and a trailing category token such as
`iv.dual-sweep`. The category is a filename grouping aid and is reported as
`category`, feeding the Date / Batch and Category groupings; it must not be
equated with scientific study membership. Study migration remains out of scope.
Unknown or calendrically impossible facts stay unknown and display as Unknown.

## Failures, progress, and limits

- Failures are isolated per source: one blocked source never suppresses another
  source's inspection or load. Invalid, unversioned, ambiguous, or unsupported
  entries stay listed with their diagnostic, except `.spe` and `.affm` files,
  which are omitted without being opened. A uniquely matched valid source
  stays usable beside an unrelated invalid profile claiming the same extension.
- Discovery, inspection, and loading run off the main thread on independent
  cancellation identities: changing focus cancels only the focused load and
  never drops in-flight inspection results. Discovery runs detached through a
  cancellable seam with incremental checkpoints (including single very wide
  directories): cancelling the open operation stops the worker instead of
  letting it finish in the background, and a generation gate drops results
  superseded by reselection. Inspection runs in batches of at most 64 sources
  with progress; a cancelled inspection keeps its partial results and offers a
  resume action for the remainder. Failed loads can be retried.
- A missing or unreadable in-root source reports its own diagnostic naming the
  project-relative path; only paths resolving outside `data/raw` report the
  outside diagnostic. A symlink source is rejected without following it: the
  link text is classified lexically, an inside-`data/raw` link reports the
  symlink diagnostic, and only a lexically outside link reports the outside
  diagnostic, so a supported-named link to a `.spe`/`.affm` target never
  reaches that target. Source and profile reads use no-follow opens pinned to
  descriptor-relative handles beneath the project root, so path checks and the
  hashed/parsed bytes cannot be separated by a swapped symlink.
- The source SHA-256 is computed incrementally from exactly the bytes parsed,
  so the recorded hash always identifies the parsed content.
- Profile files are capped at 1 MiB and mode detection reads at most the first
  64 KiB. Tabular sources stream in bounded chunks with cancellation
  checkpoints, and complete point arrays are retained without downsampling.
- No arbitrary project code is executed by RawView.
