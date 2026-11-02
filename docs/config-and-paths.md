# Config and paths

RawView's Rust core chooses global config, project metadata, and cache directories. It does not create them when it reads them.

## Global config

The global config directory still holds legacy `config.toml` (global scope only; out of scope for #24a layout work).

1. If `$XDG_CONFIG_HOME/raw-viewer` exists, use it.
2. Otherwise, if `~/.config/raw-viewer` exists, use it.
3. Otherwise, use the platform default:
   - Linux: `~/.config/raw-viewer`
   - macOS: `~/Library/Application Support/raw-viewer`
   - Windows: `%APPDATA%\raw-viewer`

## Project layout (Rust core, #24a)

Project settings live in `<project>/.raw-viewer/config.yaml` with **`schema_version: 1`** (required when the file exists; any other value is a typed error). Keys: `data_root`, `default_view`, `default_preset`, `explorer_views`, `source_labels`. A missing file loads defaults (`data/raw`, `tree`, `nature-single`). `developer_mode` in a project file is ignored.

Other read-only project metadata paths (constants in `core/src/paths.rs`):

| Path | Role |
| --- | --- |
| `.raw-viewer/profiles/` | Preferred instrument profiles |
| `.raw-viewer/session/` | Session transcripts (Swift-owned writes; Rust read-only) |
| `.raw-viewer/preset/` | Plot presets |
| `.raw-viewer/grammar.yaml` | Primary filename grammar catalog |

Grammar read order (first existing file wins): `.raw-viewer/grammar.yaml`, then `.rawviewer/grammar.yaml`, then `.rawviewer/view/grammar.yaml`.

Legacy `.rawviewer/setting.yaml` (v1–v3) remains Swift-side migration input; the Rust core does not gate on it.

## Cache and index

Writable `index.db` files never live inside the project tree. The Rust cache directory is:

`<platform-cache>/raw-viewer/projects/<sha256(canonical-project-root-utf8)>/index.db`

Platform cache bases match [`directories::BaseDirs::cache_dir`] plus `raw-viewer` (Linux honors absolute `$XDG_CACHE_HOME`).

The Rust core performs **no writes** under the project root (enforced by `core/tests/project_layout_write_ban.rs`).

[`directories::BaseDirs::cache_dir`]: https://docs.rs/directories/latest/directories/struct.BaseDirs.html#method.cache_dir
