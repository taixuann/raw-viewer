# RawView

> **High-performance, filesystem-first scientific raw measurement viewer and CLI.**

RawView provides instant, offline, publication-grade inspection and visualization of laboratory instrument raw data directly from your local filesystem. It executes in-process with zero external cloud runtime dependencies, performs zero project file mutations, and guarantees strict separation of concerns across multiple application targets powered by a unified Rust core.

---

## Architecture & Repository Layout

```
core/          raw-viewer-core: Rust engine for project layout, paths, grammars, v1–v4 profiles, and data normalization.
apps/cli/      raw-viewer: Headless CLI with JSON envelopes, grammar testing, profile management, and skills installer.
apps/macos/    Native SwiftUI 3-column scientific measurement viewer (Tree / Plot / Table) with FigRecipe publication presets.
apps/tauri/    Cross-platform desktop application shell for Windows and Linux powered by Tauri 2.
bindings/      Rust C-ABI and UniFFI bindings.
assets/        Default configurations and built-in instrument profiles (usth/...).
fixtures/      Golden data fixtures and cross-language contract verification sets.
docs/          Architectural decision records, layout specifications, and release notes.
```

The Cargo workspace at the root includes `core`, `apps/cli`, `apps/tauri/src-tauri`, and `bindings`.

---

## Configuration & Project Layout

RawView uses declarative YAML configurations. Projects remain strictly read-only; index databases and measurement caches are placed under platform cache directories outside the project root.

### Directory Structure

```
<project_root>/
  ├── data/
  │   └── raw/               # Raw scientific data files (read-only, immutable)
  └── .raw-viewer/
      ├── config.yaml        # Project configuration (schema_version: 1)
      ├── grammar.yaml       # Optional project filename grammar catalog
      ├── profiles/          # Custom project instrument profiles (<id>.yaml, regular files only)
      └── session/           # Local UI session state
```

### Configuration Locations

- **Global Config**:
  - Linux/macOS: `~/.config/raw-viewer/config.yaml` (or `$XDG_CONFIG_HOME/raw-viewer/config.yaml`)
  - Windows: `%APPDATA%\raw-viewer\config.yaml`
- **Project Config**: `<project>/.raw-viewer/config.yaml`
- **Cache & Index**:
  - `<platform-cache>/raw-viewer/projects/<sha256(canonical-project-root)>/index.db`

### Migration from Legacy `.rawviewer`

RawView automatically resolves legacy `.rawviewer` project structures:
- If `<project>/.raw-viewer/config.yaml` is absent, RawView falls back to `.rawviewer/setting.yaml`.
- Grammar search order:
  1. `<project>/.raw-viewer/grammar.yaml`
  2. `<project>/.rawviewer/grammar.yaml`
  3. `<project>/.rawviewer/view/grammar.yaml`
  4. `config.yaml` inline `grammar:` block
  5. Built-in `standard-scientific` grammar

---

## Filename Grammar & Instrument Profiles

### One Grammar per Project
A project defines filename parsing rules via a single `grammar:` block in `.raw-viewer/config.yaml` (or `.raw-viewer/grammar.yaml`). The project grammar replaces global and built-in rules, extracting semantic tokens (`date`, `device`, `mode`, `sample`, `remarks`, `flags`, `index`).

Validate grammar matching across sample filenames using the CLI:
```bash
raw-viewer --json grammar test --filename "20261101_keithley.iv_[sample1]_study_001.txt"
```

### Instrument Profiles (Schema Version 4)
Instrument profiles configure column extraction, numerical units, physical quantities, row skips, and plotting axes.

- **Storage**: Placed in `.raw-viewer/profiles/<id>.yaml` as regular YAML files (symlinked profile files are rejected by the core).
- **Built-in Profiles**: Shipped in the binary under namespace `usth/...`:
  - `usth/keithley-2400`: Keithley 2400 SourceMeter (dual-sweep IV)
  - `usth/autolab-usth`: Metrohm Autolab potentiostat (CV, CA, EIS Nyquist/Bode)
  - `usth/horiba-labram`: Horiba LabRAM Raman spectrometers
  - `usth/iop-hanoi`: Institute of Physics Hanoi UV-Vis spectrophotometer
  - `usth/keysight-b1500a`: Keysight B1500A semiconductor analyzer
- **Enable List**: Profiles are active when included in `profiles.enabled` in `config.yaml` (or managed via `raw-viewer profiles enable <id>`).
- **Matching Rules**:
  - Profile candidate matching tests `when:` conditions against grammar tokens and `content_contains_any` header strings.
  - **Single Match**: Profile is applied.
  - **Zero Hits**: Falls back to the Generic Table sniffer for delimited data.
  - **Ambiguous Match**: If 2 or more profile variants match, the engine surfaces an explicit `ambiguous_profile` error (exit code 3) and strictly refuses to fall back to a generic table.

---

## Headless CLI (`raw-viewer`)

### Installation Path
- **macOS / Linux**: `~/.local/bin/raw-viewer`
- **Windows**: `%LOCALAPPDATA%\raw-viewer\bin\raw-viewer.exe`

Install locally from source:
```bash
make install-local
```

### JSON Envelope & Exit Codes
All commands accept `--json` to output structured JSON:
- **Success**: `{"ok": true, "command": "<cmd>", "data": { ... }}`
- **Error**: `{"ok": false, "command": "<cmd>", "error": {"code": "...", "message": "...", "details": { ... }}}`

**Exit Codes**:
| Code | Identifier | Description |
| :---: | :--- | :--- |
| `0` | Success | Command completed successfully |
| `1` | Usage Error | Invalid flags or syntax |
| `2` | Not Found | Specified file, profile, or project does not exist |
| `3` | Ambiguous Profile | Multiple profiles matched a single source file |
| `4` | Validation Error | Malformed YAML, invalid schema, or failed test |
| `5` | I/O Error | Filesystem permission or read/write error |

### Common CLI Commands

```bash
# System diagnostics and environment paths
raw-viewer --json doctor

# Resolve project data root, grammar source, and profile count
raw-viewer --json projects resolve --project /path/to/project

# View or test project grammar
raw-viewer --json grammar show --project /path/to/project
raw-viewer --json grammar test --project /path/to/project --filename "sample.txt"

# Inspect and match measurement files
raw-viewer --json files inspect --project /path/to/project --file data/raw/sample.txt
raw-viewer --json files match --project /path/to/project --file data/raw/sample.txt
raw-viewer --json files export --project /path/to/project --file data/raw/sample.txt --format csv

# List, enable, and import profiles
raw-viewer --json profiles list --project /path/to/project
raw-viewer --json profiles enable --project /path/to/project --id usth/keithley-2400
raw-viewer --json profiles import --project /path/to/project --file candidate-profile.yaml --dry-run
```

---

## Agent Skills (`set-grammar` & `set-profile`)

RawView ships two built-in agent skills in `.agents/skills/`:
- **`set-grammar`**: Conversational workflow to interview users, deduce filename patterns, validate edge-case samples (no extension, remarks-only, flags-only), and write a verified `grammar:` block into `config.yaml`.
- **`set-profile`**: Interactive workflow that inspects sample files, interviews users on header/data rows and column quantities/units, validates single-match conditions, and writes Schema v4 profile YAML.

### Skill Symlink Installation
Skills are symlinked on launch into agent skill directories:
- **Unix**: `~/.agents/skills/` and `~/.claude/skills/`
- **Windows**: `%USERPROFILE%\.agents\skills\` and `%USERPROFILE%\.claude\skills\`

Install or repair links at any time using the CLI:
```bash
raw-viewer --json skills install
raw-viewer --json skills repair
```
*Note: Real directories at target paths are protected and never overwritten.*

---

## Local Development & CI Verification

Run the full local verification suite before pushing:
```bash
# Run local pre-push checks (fmt, clippy, workspace tests, swift checks, PR contract checks)
./Scripts/pre_push.sh

# Or run individual checks
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```
