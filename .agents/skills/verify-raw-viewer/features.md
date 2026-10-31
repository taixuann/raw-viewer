# verify-raw-viewer feature map (Linux / Rust core)

Scope: `raw-viewer-core` on Linux only. macOS Swift checks and Tauri UI are out of scope here (Tauri pulls WebKit on Linux).

## Features

| ID | User-visible behavior | Proof command | Expected signals |
| --- | --- | --- | --- |
| `generic-table-csv` | Opening an unprofiled delimited CSV yields a generic table measurement with default axes. | `cargo test -p raw-viewer-core --test generic_table -- --nocapture` (via skill script) | Probe lines: `instrument=generic-table`, `application_mode=table-view`, `view_x=col_0`, `view_y=[col_1]` |

## generic-table-csv

### Sub-features

- Delimiter sniff on a small header window (comma-separated sample in `core/tests/generic_table.rs`).

### How to get to it (user POV)

- Place `simple.csv` under `<project>/data/raw/` with no instrument profile matching the file.
- Load the file through the core reader (`load_measurement`).

### Driving it with `scripts/verify_generic_table.sh`

From repository root on Linux:

```sh
bash .agents/skills/verify-raw-viewer/scripts/verify_generic_table.sh
```

The script runs the integration test, runs the in-skill probe binary, checks the four key lines, and writes `target/verify/<git-sha>.log`.

### Gotchas

- Stay on `-p raw-viewer-core`; full-workspace `cargo test` also builds Tauri on Linux.
- The integration test does not print field values; the probe step exists only to capture them in the proof log.

## Adding later features

1. Add a row to the table above with a dedicated `cargo test -p raw-viewer-core …` command (or a focused probe crate under this skill).
2. Document expected observable lines in **Expected signals**.
3. Extend `scripts/verify_generic_table.sh` or add a sibling script; append results to the same `target/verify/<sha>.log` or a feature-specific log named in the skill.
4. Re-run the script on a fresh clone before updating the PR proof log.
