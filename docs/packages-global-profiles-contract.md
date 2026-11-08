# Optional lab packages and global instrument profiles

**Design document (RFC).** No implementation in this revision.

**Base SHA:** `64904eecc7499d0c9751dcd92f65452e83c20e78`  
**Status:** Proposed architecture for independent verification. Package install is **not** implemented at base SHA.

## Why this document exists

RawView should ship **without** a mandatory built-in **profile** catalog. Labs (USTH first) install optional **packages** into **global storage** shared by the **CLI** and **macOS Settings**. Filename **grammar** defaults stay separate; installing a package must not activate or replace grammar. Project-local profiles continue to override the same profile ID with visible provenance.

---

## User guide and setup entry

### What is a package?

A **lab package** is a versioned directory tree installed under the platform-resolved global RawView directory (see [Layout, state, provenance](#3-layout-state-provenance)). It contains:

- A **manifest** (YAML, data-only — no scripts or hooks).
- One or more **instrument profile** YAML files (Schema v3/v4), content-hashed at install time.

Packages are optional. With zero packages installed, the app and CLI show an honest empty state: grammar may still match filenames, but no instrument profile is available unless the user adds project profiles or installs a package.

### Commands

Every command below is labeled **ACTUAL** (exists at base SHA) or **PROPOSED** (not implemented).

| Action | Command | Label |
|--------|---------|-------|
| List profiles (no project) | `raw-viewer --json profiles list` | **ACTUAL** — returns four embedded USTH profiles, `source: "builtin"` in each profile row |
| List “global” profiles | `raw-viewer --json profiles list --global` | **ACTUAL** — same four profiles; envelope `data.source` is `"global"` while per-profile `source` remains `"builtin"` |
| List project catalog | `raw-viewer --json profiles list --project <root>` | **ACTUAL** |
| Export profile | `raw-viewer --json profiles export --global <id> --out <path>` | **ACTUAL** — uses `builtin_catalog()` when no project |
| Match file to profile | `raw-viewer --json files match --project <root> --file <rel>` | **ACTUAL** |
| Inspect file | `raw-viewer --json files inspect --project <root> --file <rel>` | **ACTUAL** |
| Doctor (no project) | `raw-viewer --json doctor` | **ACTUAL** — falls back to embedded builtin profile IDs |
| Install package from local path | `raw-viewer --json packages install --from <dir-or-archive>` | **PROPOSED** |
| List installed packages | `raw-viewer --json packages list` | **PROPOSED** |
| Show package / upgrade preview | `raw-viewer --json packages show <id>` / `packages upgrade --dry-run <id>` | **PROPOSED** |
| Apply upgrade with per-profile replace consent | `raw-viewer --json packages upgrade <id> [--replace <profile-id>...]` | **PROPOSED** |
| Remove package | `raw-viewer --json packages remove <id>` | **PROPOSED** |
| Edit global user profile | `raw-viewer --json profiles edit-global <id>` (or export/import to global user tier) | **PROPOSED** |

**ACTUAL empty-catalog behavior (config filter, not package removal):** Setting `profiles.enabled: []` in project `config.yaml` yields an empty profile list while the binary still embeds four profiles. `files match` can return `grammar_matched_no_profile`. `files inspect` on the USTH Keithley fixture with empty catalog returns validation exit **4** and does **not** succeed as a generic table for that file (see [Runtime evidence](#runtime-evidence-at-base-sha)).

**PROPOSED empty-package behavior:** With no packages installed and no project override, list commands show zero package-sourced profiles; match may still return `grammar_matched_no_profile`; inspect behavior remains file-type-specific — do not promise universal generic inspection.

### Settings (macOS)

At base SHA, **Settings has no package UI** and does not spawn the `raw-viewer` CLI (`SettingsView.swift` has no `Process` bridge). **PROPOSED:** Settings panels mirror CLI package states (empty, installed, upgrade available, conflict) and invoke the bundled CLI for mutations (see [§9 Mutation authority](#9-mutation-authority-across-rust-and-swift)).

---

## Current state at base SHA (source of truth)

Design must stay consistent with these links at `64904eecc7499d0c9751dcd92f65452e83c20e78`:

| Topic | Reference |
|-------|-----------|
| Embedded catalog | [`core/src/profile/catalog.rs` L15–32 `BUILTIN_PROFILES`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/profile/catalog.rs#L15-L32), [`merge_builtin_profiles` L34–108](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/profile/catalog.rs#L34-L108), project discovery [L128–222](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/profile/catalog.rs#L128-L222) |
| Symlink skip, 1 MiB cap | [L290–298](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/profile/catalog.rs#L290-L298), [L329](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/profile/catalog.rs#L329) |
| CLI list / export / builtin catalog | [`apps/cli/src/commands/profiles.rs` L27–46](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/apps/cli/src/commands/profiles.rs#L27-L46), [`builtin_catalog()` `profile/mod.rs` L27–29](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/profile/mod.rs#L27-L29), export [L122–137](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/apps/cli/src/commands/profiles.rs#L122-L137) |
| Doctor fallback | [`doctor.rs` L61–63](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/apps/cli/src/commands/doctor.rs#L61-L63) |
| `ProfileSource` | [`explorer/mod.rs` L52–55](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/explorer/mod.rs#L52-L55), assignment [L286–293](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/explorer/mod.rs#L286-L293) |
| Global path resolver (no profiles dir today) | [`core/src/paths.rs`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/paths.rs) — `global_config_dir` only |
| macOS parallel catalog | [`Package.swift`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/apps/macos/Package.swift), [`BuiltinAssets.swift`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/apps/macos/Sources/RawViewCore/Discovery/BuiltinAssets.swift), [`InstrumentProfile.swift` L230–364](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/apps/macos/Sources/RawViewCore/Reader/InstrumentProfile.swift#L230-L364), [`InstrumentReader.swift`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/apps/macos/Sources/RawViewCore/Reader/InstrumentReader.swift), index [`ProjectIndexStore.swift`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/apps/macos/Sources/RawViewCore/Storage/ProjectIndexStore.swift) |
| UniFFI placeholder (not app-linked) | [`bindings/src/lib.rs`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/bindings/src/lib.rs) |
| Settings (no package UI) | [`SettingsView.swift`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/apps/macos/Sources/RawViewApp/SettingsView.swift) |
| Filename grammar default (separate) | [`assets/default-config.yaml`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/assets/default-config.yaml) |

Repo search at base SHA finds **no** lab-package install lifecycle (`installPackage`, `PackageManager`, etc.).

### Runtime evidence at base SHA

Verified on cloud builder `64904eecc7499d0c9751dcd92f65452e83c20e78` (binary `raw-viewer 0.3.2`). Full log: builder artifact `rv-u3-source-checks.log`.

| Case | Exit | Outcome |
|------|------|---------|
| `profiles list` | 0 | Four profiles, `source:"builtin"` |
| `profiles list --global` | 0 | Same four; envelope `source:"global"` |
| `files match` (usth-lab Keithley, builtins active) | 0 | `status:"matched"`, `profile_id:"usth/keithley-2400"` |
| `files match` (project with `profiles.enabled: []`) | 0 | `status:"grammar_matched_no_profile"` |
| `files inspect` (same empty catalog, Keithley fixture) | **4** | `validation_error`: no instrument profile mode matched **and not a valid table** |

**Clarification (preflight 8):** The Keithley inspect failure is **file-specific**; it does not establish that every grammar-matched file without a profile fails inspect the same way. Filtered-empty probes (`profiles.enabled: []`) do **not** remove embedded assets from the binary — they only hide profiles from the effective catalog. Do not imply universal generic-table capability or universal inspect failure.

---

## Design clarifications (mandatory preflight)

These eight items are acceptance constraints on the RFC below.

1. **Editable global-user copies** live **outside** immutable installed generations. The installed baseline hash is stored for diffing; provenance is **Global-user**. Local edits never mutate an immutable generation directory.
2. **Removal kinds:** (a) upstream removed a profile in a newer package version, (b) user **intentionally removed** a profile (tombstone), (c) **package uninstall**. Intentional removals persist across upgrade/reinstall until the user restores. Editable copies and their provenance survive uninstall when the user chose to keep them.
3. **Coupled generation:** The authoritative install **generation** includes package payload trees **and** state records together. Readers **pin** exactly one generation ID for the duration of a catalog read / match pass — they do not re-read a live pointer per file.
4. **Publication semantics:** Staging on the same volume is necessary but **not sufficient** for atomic visibility or crash durability. Define replace-existing behavior on Windows and Unix, behavior with open reader handles, reclamation of old generations, unsupported filesystem fallbacks, and recovery. Mark unproven FS guarantees as implementation acceptance gates.
5. **Locks:** Lock file TTL/expiry alone does not prove a dead writer. Define live-owner detection (e.g. PID + start time + heartbeat) and safe stale recovery without stealing an active lock.
6. **Precedence and collisions:** **Project** overrides **Global-user** overrides **Package** for the same canonical profile ID. Reject duplicate IDs across packages, normalized-ID collisions, case-folding ambiguities, and `safe_id` filename collisions (today import uses `id.replace('/', "-")` in [`profiles.rs` L85–86](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/apps/cli/src/commands/profiles.rs#L85-L86)). Explicit replace consent applies only to the targeted profile identity — never unrelated IDs.
7. **CLI ↔ Settings protocol:** Version the JSON envelope for package verbs (`schema_version` field in mutation responses). Specify CLI binary discovery, minimum CLI/app version pairs, and that the macOS app must **bundle and locate** the CLI (not true today). Native Swift catalog readers need shared conformance tests for provenance and generation pinning. **Recommendation (not existing):** Rust remains the **single writer**; Settings spawns bundled `raw-viewer --json`; both sides read on-disk state. **No Rust/Swift mutation bridge exists at base SHA.**
8. **Follow-up bounds:** Units below are dependency-aware — not independently shippable before prerequisites (state file, generation reader, app packaging). All `packages *` verbs are **PROPOSED**. **ACTUAL** `profiles list --global` is relabeled builtin inventory only.

---

## Technical RFC

### 1. Versioned manifest

**PROPOSED** example `package.yaml`:

```yaml
schema_version: 1
id: usth
version: "2026.11.1"
display_name: USTH Lab Instrument Profiles
profiles:
  - id: usth/keithley-2400
    path: profiles/keithley-2400.yaml
    sha256: abcd0123… # of normalized UTF-8 bytes at install time
  - id: usth/autolab-usth
    path: profiles/autolab-usth.yaml
    sha256: …
```

Rules:

- `schema_version` must be known; unknown values are **rejected** (exit 4), never guessed forward.
- Data-only: YAML profiles only; **no** scripts, hooks, or executable entries in the manifest.
- Package `id` is a short namespace token (e.g. `usth`); profile IDs remain canonical (`usth/keithley-2400`).

### 2. Identity and collisions

- **Canonical profile ID:** stable string with namespace prefix; must match profile document `profile_id`.
- **Package namespace:** `package.id` must not equal a profile ID segment in a way that confuses ownership; installed content paths are `profiles/<file>.yaml` relative to package root.
- **Cross-package duplicate profile IDs:** refuse install/upgrade with deterministic error; no last-writer-wins.
- **Filename derivation:** project import maps `/` → `-` for filenames. Global package layout uses manifest `path` (relative, no `..`). Collision rules: two distinct IDs must not resolve to the same on-disk global user filename after normalization.
- **Project override:** same ID as package or global-user replaces lower tiers in the **effective catalog**; UI and CLI show **active source** (`Project` > `Global-user` > `Package(id@version)`).

### 3. Layout, state, provenance

Extend path resolution using the same rules as [`resolve_paths`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/paths.rs) — **do not hardcode `~/.config`**.

**PROPOSED** layout under `<global_config_dir>/` (exact subdirectory names are implementation details):

| Path | Purpose |
|------|---------|
| `packages/generations/<gen>/` | Immutable staged tree: `packages/<pkg-id>/<version>/` payload + manifest copy |
| `packages/user/<safe-id>.yaml` | Editable **Global-user** profiles (outside generations) |
| `packages/state.json` (or equivalent) | Installed package versions, active generation pointer, per-profile installed hash, intentional-removal tombstones |
| `packages/lock` | Writer exclusive lock metadata |

**Provenance** (extends today's `ProfileSource::{Project, Builtin}`):

- `Project` — unchanged paths under `.raw-viewer/profiles`, legacy dirs, `data/instruments`.
- `GlobalUser` — editable tier.
- `Package { id, version }` — read-only payload from active generation.

**Interface-only:** Rust `ProfileSource` and Swift catalog summaries gain matching variants; `list_profiles` and CLI JSON use snake_case serde names consistent with existing explorer types.

### 4. Diff and replacement

On **upgrade** (and `--dry-run`), compute per-profile status vs installed generation and global-user overlay:

| Status | Meaning |
|--------|---------|
| `unchanged` | Installed hash matches upstream |
| `upstream_changed` | Package bumped content; user file untouched |
| `locally_edited` | Global-user hash differs from installed baseline |
| `conflict` | Upstream changed **and** locally edited |
| `added` / `removed` | Profile ID added/removed in manifest |

**Policy:** Keep locally edited profiles unless the user **explicitly replaces** each conflicted ID (`--replace` or Settings per-row consent). Same workflow in CLI and Settings (Settings via CLI — PROPOSED).

### 5. Upgrade and removal

- **Remove package:** delete only package-owned **unmodified** files in the active generation for that package. Global-user edits, intentional tombstones, project trees, and raw data stay.
- **Removal ≠** cache clear ≠ deleting project or measurement data.
- **Intentional removal** (user disabled a profile from a package) survives upgrade/reinstall until user restores.

### 6. Transactions

Writers:

1. Build a **complete** new generation directory on the **same volume** as the pointer.
2. Validate all manifests, hashes, profile parses (reuse 1 MiB cap), and state schema.
3. Perform **one** atomic publication step updating the active generation pointer (platform-specific: e.g. `rename` on Unix; `MoveFileEx`/`ReplaceFile` patterns on Windows — **do not assume** Unix symlink atomicity on Windows).

Readers pin generation at operation start. Old generations remain until reference count / safe reclamation (no open handles, no pinned readers). Interrupted install leaves the last **complete** generation active.

Separate directory rename and state-file rename are **not** one atomic operation unless wrapped in a single published generation object.

**Acceptance gates:** document crash/power-loss behavior per platform; filesystems without atomic rename get explicit degraded mode or refusal.

### 7. Input defenses

Reject package inputs that contain:

- Absolute paths or `..` in manifest paths
- Symlinks or hardlinks inside package payload (mirror project loader — [catalog.rs L290–298](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/profile/catalog.rs#L290-L298))
- Per-profile YAML over **1 MiB** (reuse `MAXIMUM_PROFILE_BYTES`)
- Total package size and file-count caps (PROPOSED limits: e.g. 32 MiB total, 256 files — tune at implementation)
- YAML bombs via depth/size parse limits

### 8. Integrity vs authenticity

- Content hashes prove **integrity** of installed bytes only.
- No signature or trust claim without a future signing design.
- UI copy: **“Local package from &lt;path&gt;”** — not “verified” or “trusted publisher.”

### 9. Mutation authority across Rust and Swift

Compare:

| Option | Pros | Cons |
|--------|------|------|
| **(a) Settings spawns bundled `raw-viewer --json`** | Single Rust writer; one protocol | Requires app packaging to ship CLI; latency; error propagation |
| **(b) UniFFI / FFI** | In-process calls | Bindings are placeholder only at base SHA; dual implementation risk if Swift also writes |
| **(c) Duplicated Swift writer** | No CLI dependency | Two writers; drift; concurrency hazards |

**Recommendation:** **(a)** for mutations; **(b)** not until bindings are productized; **(c)** only for read-only generation pinning in Swift if needed, backed by shared fixtures.

**Dependency:** macOS app must locate `raw-viewer` beside the bundle or via documented `RAW_VIEWER_CLI` — **not shipped today**. Versioned JSON protocol `schema_version: 1` for package commands with stable error codes in the existing CLI envelope.

**Explicit:** No Rust/Swift bridge for catalog mutation exists at base SHA. Do not claim macOS behavior from live app checks in this design pass.

### 10. Grammar

Installing or upgrading a package **never** sets or replaces the active filename grammar. Built-in grammar fallback in [`assets/default-config.yaml`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/assets/default-config.yaml) remains for projects without custom grammar.

### 11. Empty and no-package state

- Optional install; no mandatory seeding; no hidden builtin profile fallback after catalog removal migration.
- Honest copy: “No instrument packages installed.” Explain that `files match` may show `grammar_matched_no_profile` and inspect may still fail for instrument-specific files.

### 12. Migration

**Goal:** Today's four embedded USTH YAMLs become the optional **`usth`** package ([`BUILTIN_PROFILES`](https://github.com/taixuann/raw-viewer/blob/64904eecc7499d0c9751dcd92f65452e83c20e78/core/src/profile/catalog.rs#L15-L32)).

Preserve all project data and global-user data (none exists yet at base SHA).

**Consumers that must change (follow-ups):**

| Consumer | Change |
|----------|--------|
| CLI `profiles list`, `--global`, `doctor` | Real global discovery or honest rename; remove builtin fallback |
| CLI `profiles export --global` | Read from global tiers |
| `merge_builtin_profiles` / `BUILTIN_PROFILES` | Remove or gate behind migration shim |
| Explorer `ProfileSource`, match/inspect | Package + Global-user provenance |
| Swift `BuiltinAssets` / `mergeBuiltinProfiles` | Package parity or CLI-backed read |
| `ProjectIndexStore` fingerprint | Include generation ID + package versions |
| Tests: `builtin_assets.rs`, `profile_catalog_discovery.rs`, macOS builtin tests, `cli_contract.rs` | Update expectations |

First-run migration may auto-install `usth` from shipped **local** package directory inside the app bundle (PROPOSED) — subject to Tai decision (see scope-change list).

---

## Test matrix

| # | Scenario | Expected (post-implementation) |
|---|----------|-------------------------------|
| T1 | Fresh install one package | Generation published; profiles listable; hashes recorded |
| T2 | Reinstall same version | Idempotent; no duplicate state |
| T3 | Upgrade, no local edits | All `unchanged` or `upstream_changed`; pointer moves once |
| T4 | Upgrade with global-user edit | `locally_edited` kept; optional replace |
| T5 | Upgrade conflict | Both sides differ; replace required per ID |
| T6 | Remove package, local edit exists | Package bytes gone; user YAML remains |
| T7 | Interrupted install | Last complete generation still active |
| T8 | Concurrent CLI + Settings write | Lock denies or queues; no torn generation |
| T9 | Traversal / symlink / oversize in package | Rejected at validate; exit 4 |
| T10 | Duplicate ID across two packages | Second install refused |
| T11 | Project profile same ID as package | Project wins; source `Project` |
| T12 | Zero packages | Empty package list; honest UI; grammar unchanged |
| T13 | Install does not alter grammar | Grammar SHA unchanged in project/config |

Regression anchors at base SHA (ACTUAL): T12-like behavior via `profiles.enabled: []`; Keithley inspect exit 4 without profile (not generic success).

---

## Follow-up units (dependency-aware)

Units are **bounded**; order respects prerequisites. None claim PASS for packages until integrated.

| Unit | Owns (indicative) | Depends on | Notes |
|------|-------------------|------------|-------|
| **U3-R1** Rust package domain | `core/src/package/*`, manifest parser, generation layout, lock, state schema | `paths.rs` extension | Single writer core |
| **U3-R2** Global profile tier | `catalog.rs` load merge, `ProfileSource`, explorer list/match | U3-R1 state readable | Remove builtin merge later |
| **U3-R3** CLI package verbs | `apps/cli` `packages` subcommands, JSON protocol v1 | U3-R1 | All PROPOSED verbs |
| **U3-R4** Swift reader parity | `InstrumentProfile.swift`, generation pin, provenance labels | U3-R1 layout frozen | Conformance tests with Rust fixtures |
| **U3-R5** Settings UI | `SettingsView` package section, spawn CLI | U3-R3, **app packaging** | No UI at base SHA |
| **U3-R6** Embedded catalog removal + migration | Drop `BUILTIN_PROFILES`, Swift `builtinProfiles`, ship `usth` package | U3-R1–R4 stable | Coordinated release |
| **U3-R7** App packaging CLI | Xcode/spm bundle `raw-viewer`, discovery env | U3-R3 | Blocker for Settings mutations |

**Coordination:** Changes to `profiles.rs` / `main.rs` for import flags remain **U2** until verified; this design does not stack on unverified U2 heads.

---

## Needs Tai decision (scope-change list)

Not adopted in this RFC unless decided:

- Auto-install `usth` on first launch vs purely manual install
- Whether `profiles list --global` is renamed (e.g. `profiles list --installed`) when builtins are removed
- Network/registry download of packages (explicitly out of scope for v1; listed if product wants it later)
- Signing / notarization requirements for third-party packages
- Generic inspect as official empty-catalog UX for all instrument file types (current Keithley evidence is negative)

---

## Product decisions referenced

- [Issue #71 — optional packages, no built-in catalog, Settings+CLI](https://github.com/taixuann/raw-viewer/issues/71#issuecomment-6716246387)
- [Issue #71 — project overrides, explicit replacement](https://github.com/taixuann/raw-viewer/issues/71#issuecomment-6716132755)
- [Issue #73 — Settings package states](https://github.com/taixuann/raw-viewer/issues/73#issuecomment-6716246370)

Upgrades show per-profile diffs; keep local edits unless explicitly replaced; install ≠ grammar activation.

---

## Acceptance mapping (for verifier)

| Contract item | Section |
|---------------|---------|
| RFC §1 Versioned manifest | §1 |
| RFC §2 Identity | §2 |
| RFC §3 Layout | §3 + preflight 1–3 |
| RFC §4 Diff | §4 |
| RFC §5 Upgrade/removal | §5 + preflight 2 |
| RFC §6 Transactions | §6 + preflight 3–5 |
| RFC §7 Input defenses | §7 |
| RFC §8 Integrity | §8 |
| RFC §9 Mutation authority | §9 + preflight 7 |
| RFC §10 Grammar | §10 |
| RFC §11 Empty state | §11 + runtime evidence |
| RFC §12 Migration | §12 |
| Preflight 1–8 | Design clarifications + cross-refs |
| Test matrix | Test matrix |
| Follow-ups | Follow-up units |

---

*Document produced for RV-U3. PASS means design consistency and evidence alignment at base SHA — not implemented packages.*
