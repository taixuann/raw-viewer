# RawView

RawView is a native macOS project viewer. Opening a project inventories regular
files under `data/raw` and shows searchable Sample / Device, Instrument, Study,
Mode, Date / Batch, and Status trees. After one explicit approval, the project's
`data/instruments/reader.py` inspects and loads every discovered source. Approval
is saved for that project and exact reader SHA-256; changing the reader requires
approval again. The reader and configured parsers run with the user's
permissions and can access or change files available to that account.

The center switches between project-wide Plot and Data tabs. Each source keeps a
matching figure and ordered, untransformed table panel. Failed or unsupported
sources retain their own status panel. X and Y absolute, linear, and logarithmic
controls live in the right inspector and apply to every figure; invalid log
domains are reported on the affected source's plot only.

Build and package locally:

```sh
tools/raw-viewer/Scripts/package_app.sh
open /tmp/RawView.app   # developer build output (local)
```

The reader JSON contract is documented in [CONTRACT.md](CONTRACT.md). Inspection
uses `inspect-many --paths-json` in batches of at most 256 project-relative
paths. Parsing is bounded to two concurrent source loads, with per-source
failures, progress, cancellation, and retry.

The current package script is a developer build. It uses the host's Python 3 and
user-site dependencies when available. It is not distribution-ready: a minimal,
deterministic app-bundled Python runtime and its dependencies remain unimplemented.

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

Raw reader behavior depends on the project-owned reader and its configured
parsers. A fixture fake reader can verify RawView's app path without running a
research reader or inspecting research raw files; fixture results do not
establish scientific validation for any real source.
