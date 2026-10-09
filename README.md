# RawView

> **High-performance, filesystem-first scientific raw measurement viewer for macOS.**

RawView provides instant, offline, publication-grade visualization and inspection of laboratory instrument measurements directly from your local filesystem. It executes in-process with zero external runtime dependencies and never executes untrusted project code.

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

RawView reads declarative instrument profiles (`schema_version: 1` or `2`) from `data/instruments/` (or `data/instruments/rawview/`):

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
- macOS 13.0+ (Ventura, Sonoma, Sequoia)
- Xcode 15+ or Swift 6.0+ Command Line Tools

### Verification & Core Checks
RawView includes an offline test runner and type checker:

```bash
# Run self-check and verify core contracts
./Scripts/check_core.sh
```

### Packaging & Installation
Build a production-optimized, code-signed macOS `.app` bundle:

```bash
# Build and package into /Applications/RawView.app
./Scripts/package_app.sh /Applications/RawView.app
```

---

## Architecture & Security Contract

1. **In-Process Reading**: All parsing occurs within `RawViewCore` using standard Swift Foundation. No subprocesses or shell scripts are executed.
2. **Deterministic Caching**: Inspection summaries are cached in project-local SQLite WAL databases (`data/.rawview/index.db`) or user Application Support.
3. **Fail-Closed Parsing**: Corrupt rows, malformed YAML, or unsupported versions produce actionable diagnostic banners rather than silent misinterpretations.

---

## License

Licensed under the MIT License. See [LICENSE](LICENSE) for details.
