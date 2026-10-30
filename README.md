# RawView

> **High-performance, filesystem-first scientific raw measurement viewer for macOS.**

RawView provides instant, offline, publication-grade visualization and inspection of laboratory instrument measurements directly from your local filesystem. It executes in-process with zero external runtime dependencies and never executes untrusted project code.

---

## Repository layout

```
core/          Rust library crate raw-viewer-core. Step 1 is a placeholder API.
bindings/      Rust library reserved for a future UniFFI Swift bridge.
apps/macos/    SwiftUI app: Package.swift, Sources, Tests, Scripts, and Examples.
apps/tauri/    Minimal Tauri 2 shell. src-tauri calls raw-viewer-core.
docs/          Design notes and handoff records.
```

The Cargo workspace at the repository root includes `core`, `bindings`, and `apps/tauri/src-tauri`.

Rust checks run from the repository root:

```bash
cargo fmt --check
cargo clippy --workspace -- -D warnings
cargo test --workspace
```

Swift commands run from `apps/macos/` (`swift build`, `swift test`). The package scripts resolve their own location, so from the repository root:

```bash
./apps/macos/Scripts/check_core.sh
./apps/macos/Scripts/check_index_cli.sh
./apps/macos/Scripts/package_app.sh
```

---

## Key Capabilities

- **Filesystem-First & Zero Mutation**: Opens research projects containing `data/raw/` in read-only mode. Never alters raw data files, timestamps, or original values.
- **Publication-Grade Scientific Presets**: Canonical presets calibrated to FigRecipe specifications:
  - **Nature**: Single ($59.1\text{ mm} \times 50.0\text{ mm}$, closed box) & Open ($59.1\text{ mm} \times 50.0\text{ mm}$, 2-axis L-frame)
  - **Science**: Single ($42.0\text{ mm} \times 38.0\text{ mm}$, closed box) & Open ($42.0\text{ mm} \times 38.0\text{ mm}$, 2-axis L-frame)
  - **ACS**: Single ($54.7\text{ mm} \times 47.0\text{ mm}$, closed box)
  - **IEEE**: Single ($59.0\text{ mm} \times 49.0\text{ mm}$, closed box, Serif typography)
- **High-Performance SQLite WAL Indexing**: Effortlessly browses projects with 8,000+ files. Background worker pools (`TaskGroup`) scan headers progressively without blocking the main UI thread.
- **Orthogonal Plot Styling**:
  - **Mark Types**: Line, Dots (scatter), or Both (line + dots).
  - **Interpolation**: Linear, Monotone Catmull-Rom Spline (strictly passes through sample points without runaway oscillations), or Staircase Step.
  - **Acquisition Sweep Indicator**: Optional continuous color gradient visualizing acquisition sequence and time progression ($t = 0 \to t = N$).
- **Reproducible Snapshot Packages**:
  - Single-click figure export to **300+ DPI Retina PNG** and **Vector PDF**.
  - Structured Snapshot Packages saved directly to `data/snapshot/<name>/` containing `list.yaml`, `figure.png`, and `figure.pdf`.
- **Streamlined Inspector & Fast Data Search**:
  - Resizable 3-column macOS interface with collapsible inspector (`⌘I`).
  - Searchable Data Table (`⌘F`) preserving exact tabular columns, gap reasons, and raw numbers.
  - Interactive X/Y channel mapping and inline custom series labeling.
- **Native macOS Settings**:
  - Appearance: System, Light, and Dark themes with typography scaling.
  - Performance: Lazy (on-demand) vs. Eager background discovery modes.
  - Storage: Project database index statistics and cache pruning.

---

## Supported Instruments & Reader Families

RawView reads declarative instrument profiles (`schema_version: 1`, `2`, or variant-based `3` with key-routed variants in one file) from `data/instruments/` (or `data/instruments/rawview/`):

| Instrument / Family | Supported Layouts | Plotted Channels |
| :--- | :--- | :--- |
| **Keysight B1500A** | `DataName`/`DataValue` tabular CSV, dual sweep, list sweep, WGFMU pulse first-row & endurance blocks | Voltage, Current, Time, Pulse indices |
| **Keithley 2400** | LabVIEW Measurement (`.lvm`, `.txt`, `.csv`), tab-separated | Voltage and Current |
| **Horiba LabRAM** | Raman spectroscopy comment-header TSV (comma decimal) and semicolon tables | Raman shift ($\text{cm}^{-1}$) and Intensity |
| **IoP Hanoi** | UV-Vis optical spectroscopy first-row CSV/TXT | Wavelength (nm) and Transmittance (%) |
| **Generic Table Sniffer** | Delimited scientific files (`.csv`, `.tsv`, `.txt`) with auto-detected headers | Interactive channel mapper |

---

## Local Development & Verification

### Prerequisites
- macOS 13.0+ (Ventura, Sonoma, Sequoia), Xcode 15+ or Swift 6.0+ Command Line Tools, for the Swift package
- Rust stable (1.90 or newer) for the Cargo workspace. The Tauri shell links WebKit on Linux.

### Verification & Core Checks
RawView includes an offline test runner and type checker. Run it from the repository root:

```bash
# Run self-check and verify core contracts
./apps/macos/Scripts/check_core.sh
```

### Packaging & Installation
Build a production-optimized, code-signed macOS `.app` bundle:

```bash
# Build and package into /Applications/RawView.app
./apps/macos/Scripts/package_app.sh /Applications/RawView.app
```

---

### Headless Indexing (CLI)
RawView includes a standalone CLI tool `rawview-index` for automated, non-interactive project indexing:

```bash
# Build and run the pre-indexing CLI tool from the Swift package:
cd apps/macos
swift run rawview-index --project /path/to/project --data-root data/raw --save-settings --json
```

Flags:
- `--project <path>` (required): Path to project root.
- `--data-root <path>`: Project-relative data directory (e.g. `data/raw` or `.`).
- `--save-settings`: Persist the configured data root into `.rawviewer/setting/setting.yaml`.
- `--rebuild`: Reindex all sources without using cached advisory hints.
- `--json`: Output machine-readable JSON summary to stdout.

Exit codes: `0` complete, `1` incomplete/fatal, `2` configuration error, `3` writer busy, `130` interrupted.

---

## Architecture & Security Contract

1. **In-Process Reading**: All parsing occurs within `RawViewCore` using standard Swift Foundation. No subprocesses or shell scripts are executed.
2. **Configurable Data Root**: Configured via `.rawviewer/setting/setting.yaml` (`schema_version: 3`, with `data_root`, `developer_mode`, and `explorer_views`). Supports `.` (project root) or any contained regular directory. Symlinked components and escaping paths are rejected fail-closed.
3. **Tree Navigator**: Native folder disclosure tree preserving directory ancestors and project-relative source identities. Filename grammars (`.rawviewer/grammar.yaml`, schema 1) drive Explorer views; variant-based profiles (schema 3) route each source to exactly one variant.
4. **App-Local Writable Index**: Writable SQLite indexes are stored in owner-private Application Support (`~/Library/Application Support/RawView/<project-digest>/index.db`). Zero project-local SQLite writes ensure immutable projects and eliminate VFS race risks. Legacy `data/.rawview/index.db` is preserved read-only as advisory hints and rollback.
5. **Fail-Closed Parsing**: Corrupt rows, malformed YAML, or unsupported versions produce actionable diagnostic banners rather than silent misinterpretations.

---

## License

Licensed under the MIT License. See [LICENSE](LICENSE) for details.
