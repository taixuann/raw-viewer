---
name: verify-raw-viewer
description: Linux Rust-core verification for RawView. Runs scripted checks against raw-viewer-core (not Tauri) and writes a proof log under target/verify/. Use before claiming reader or generic-table behavior works on Linux CI.
---

# Verify RawView (Linux Rust core)

Prove `raw-viewer-core` behavior with commands an agent can run headlessly on Linux. macOS Swift checks (`check_core.sh`, `check_index_cli.sh`) are documented in AGENTS.md but are not run here.

## Doctor

From the repository root:

```sh
git rev-parse --is-inside-work-tree
rustc --version
cargo test -p raw-viewer-core --test generic_table --no-run
```

All commands must succeed before driving features.

## Drive (feature map)

See [features.md](./features.md). Exactly one feature is wired today: **generic-table-csv**.

### generic-table-csv

Run:

```sh
bash .agents/skills/verify-raw-viewer/scripts/verify_generic_table.sh
```

This executes:

1. `cargo test -p raw-viewer-core --test generic_table -- --nocapture`
2. The skill-local probe (`probe-generic-table`) to print measurement fields.

Do not substitute workspace-wide `cargo test` on Linux when verifying this feature; it builds the Tauri app and requires WebKit dev packages.

## Evidence

The script writes a proof log to:

`target/verify/<git-sha>.log`

Each log records:

- Git SHA and UTC timestamp
- Integration test command, exit code, and full test output
- Probe command, exit code, and printed fields
- Pass/fail lines for `instrument=generic-table`, `application_mode=table-view`, `view_x=col_0`, `view_y=[col_1]`

Paste the log into PR evidence when asked. Logs live under `target/` and are not committed.

## Cleanup

The probe removes its temp directory. No servers or tmux sessions are started. Re-running the script overwrites the log for the current HEAD SHA.

## Adding features

Follow the maintenance steps in [features.md](./features.md). Prefer one integration test or probe per feature, keep packages scoped to `-p raw-viewer-core`, and extend the shell script (or add a parallel script) so proof logs stay reproducible on fresh clones.
