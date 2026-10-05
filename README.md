# RawView

RawView is a native macOS viewer for raw research measurements. Opening a project
inventories supported regular files under the selected project's `data/raw`
directory: `.spe` and `.affm` files are skipped without being opened, nested
project folders are never discovered as additional roots, and a missing raw
directory offers a clear diagnostic so another folder can be selected.

Instrument profiles are declarative YAML under the existing plural
`data/instruments/` directory, or under its `rawview/` companion directory
when it exists: companion profiles then override the parent directory, and an
empty or unusable companion directory never falls back to it. RawView owns the
readers: supported layouts are the Keysight B1500A I-V, dual-sweep,
list-sweep, and WGFMU tabular CSV profiles (`DataName`/`DataValue` rows), the
Keithley 2400 dual-sweep LVM tab file, and both Horiba LabRAM Raman tables
(comment-header TSV with European decimal comma, legacy semicolon table).
List-sweep values are shown exactly as stored, with no legacy sign transform;
WGFMU plots channel 1 and keeps its profile-declared unit status. Viewer
profiles are standalone, versioned top-level YAML (`schema_version: 1` or `2`);
nested `raw_viewer` blocks are rejected.
Existing unversioned profiles stay visible
with an explicit upgrade diagnostic, block only the sources they claim, and
are never rewritten. RawView never executes project code. GTIIT XPS,
Autolab/IOP, and Oxford MFP layouts remain out of scope (see CONTRACT.md).

The center switches between project-wide Plot and Data tabs. Each supported
source keeps a matching figure and an ordered, untransformed table: every
original point is preserved in acquisition order, including sweep reversals.
Blank cells, recorded NaN/infinity tokens, and overflow saturation stay
distinguishable gaps (plot lines break with visible dots on singleton runs,
tables show per-reason markers) with per-gap warnings naming file, line,
column, reason, and raw token; other corrupt text blocks the affected source.
The table keeps every format-declared channel while only the mode's axes drive
the plot. The sidebar groups by Category (a filename grouping aid, never
scientific study membership) and supports Shift/Command multi-selection, and a
cancelled inspection keeps partial results
with a resume action. Selecting multiple sources compares their original curves
only when every source lists in one exact shared study manifest (`study_id` +
`sources: [{path}]`) with matching X/Y quantities and exact units; otherwise the
comparison stays blocked and the focused source remains shown. The floating
central plot card keeps generous whitespace with distinct per-source
labels/colors, and the
right inspector exposes Data, Style, Series, and Axes controls (series
visibility toggles, line width, existing X/Y absolute/linear/log behavior),
with invalid log domains reported on the affected source only. Header metadata
(SetupTitle, Dimension, record time) and filename-derived device, timestamp,
and category are preserved in the inspector; the filename category is a
grouping aid, not scientific study membership. Invalid, unsupported,
or ambiguous sources keep their own actionable status and can be retried.

Build and package locally:

```sh
tools/raw-viewer/Scripts/package_app.sh
open /tmp/RawView.app   # developer build output (local)
```

The reader contract and instrument profile schema are documented in
[CONTRACT.md](CONTRACT.md); working standalone profiles are in
[Examples/rawview/](Examples/rawview/). Discovery,
inspection, and loading run off the main thread on independent cancellation
identities in bounded batches with per-source failures, progress,
cancellation, resume, and retry. Sources stream with cancellation checkpoints
and no file-size cap.

Deterministic results are cached per project in a private app-local directory
(512 MiB default per project, configurable in the inspector). RawView never
reads or writes a cache under the selected project, so project-writable files
cannot inject plotted measurements. The directory and entry names contain only
digests; payloads include normalized measurements and their project-relative
source paths. Inspection entries key on the source identity, the SHA-256 of
the exact bounded header prefix, and the complete profile-catalog fingerprint,
so same-size edits or profile changes invalidate them while row-only edits may
reuse an inspection. Every cached full measurement still re-opens the source
without following links and re-verifies a fresh full-content SHA-256 before
decoding. Corrupt or partial entries are ordinary misses and rebuild. Entries
store complete normalized measurements (every value bit pattern, gap reason,
metadata field, warning, and provenance entry) as checksummed binary property
lists, atomically replaced, and are never transformed. Each entry is capped at
128 MiB. `.spe` and `.affm` files are skipped without being opened, including
by the cache; raw files and instrument profiles are never modified.

The current package script is a developer build. It is not distribution-ready:
notarization and distribution packaging remain unimplemented.

The native Canvas style resource is generated from
`figrecipe/presets/nature-single.yaml`; check for drift with:

```sh
python3 tools/raw-viewer/Scripts/generate_native_style.py --check
```

Donor disposition:

| Donor | Disposition | Why |
|---|---|---|
| tqbf/swiftui-app | `REFERENCE_ONLY` | Native window/bootstrap patterns only; this app uses SwiftUI directly. |
| Dirscope | `REFERENCE_ONLY` | Project-folder selection only; no directory browser code was copied. |
| MiMiNavigator | `REFERENCE_ONLY` | Navigation concepts only. |
| CodeEdit | `REFERENCE_ONLY` | Sidebar and inspector layout concepts only. |
| Bonsplit | `REJECT` | No multi-pane split package needed; SwiftUI split views suffice. |
| Swift Pieces, HIGDesign | `REFERENCE_ONLY` | Native control and platform guidance only. |
| SwiftUIX, SwiftUI-Introspect | `REJECT` | No dependency needed for the selected-source flow. |
| swift-trading-view | `REJECT` | Web-based chart implementation conflicts with native Canvas ownership. |

No donor source code or package was copied into this app.

Fixture-based checks verify the app path; they do not establish scientific
validation for any real source. Supported layout semantics were derived from
project-local instrument profiles; migrating a project's profiles is a
separate, owner-approved change.
