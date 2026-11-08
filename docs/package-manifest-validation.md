# Package manifest validation (in-memory only)

This document describes **manifest text validation only**. It does not install packages, read the filesystem, verify payload hashes, manage catalogs, or resolve the diagnostic source label as a path.

## API

`parse_package_manifest(text, source_label)` in `core/src/package/manifest.rs` returns either a typed `PackageManifest` or an ordered list of `ManifestDiagnostic` values. The `source_label` is copied into each diagnostic for human context; it is **never opened** or interpreted as a filesystem path.

**Manifest-valid is not ownership-valid.** Passing validation means the YAML text matches the rules below. It does not decide package ownership, cross-package conflicts, or install safety.

## Accepted YAML subset

Parsing uses the existing depth-limited YAML parser (`crate::yaml::parse(text, false)`): block mappings and block sequences. Every leaf value is read as a **string** and validated in Rust; this unit does not claim YAML scalar type fidelity.

Plain, double-quoted, and single-quoted scalars are accepted where the parser yields them. The parser does not record whether a scalar was quoted.

### Pre-parse unsupported-syntax guard (mandatory)

Because the parser may accept bare `|`, flow `[ ... ]`, and other constructs as ordinary scalars or flow lists, validation runs a **quote-aware** line scan **before** calling the parser. The guard inspects syntax positions only:

- `key: value` mapping value positions (including empty values that begin nested blocks only when the scan applies).
- Block-sequence item positions: `- value`, `- key: value`, and flow or multiline forms the line structure exposes.

For each scalar position, if the token is **not** double- or single-quoted, reject when the raw text:

- begins with `!`, `&`, or `*` (tags, anchors, aliases);
- is exactly `|` or `>`, or begins a block-scalar opener treated as unsupported here;
- begins with `{` (flow mapping) or `[` (flow sequence).

Quoted scalars may contain `*`, `&`, `!!`, `|`, `<`, `>`, etc. as literal punctuation; there is **no** global substring denylist.

Alias-like **unquoted map keys** (for example `*bad: 1`) are rejected as unknown or unsupported syntax per binding B4.

## Input limits

- Maximum **1 MiB** UTF-8 byte length (checked before parse).
- **NUL** bytes rejected.

## Top-level schema (schema_version 1)

Required keys, in diagnostic order: `schema_version`, `id`, `version`, `display_name`, `profiles`. Unknown keys (including `hooks` and `scripts`) are rejected in every manifest-owned mapping.

| Field | Rules |
|-------|--------|
| `schema_version` | Scalar text must be exactly `1`. Plain `1`, `"1"`, and `'1'` accepted. Reject `true`, `1.0`, `2`, `null`/`~`/empty, missing. |
| `id` | One segment: lowercase ASCII `[a-z0-9][a-z0-9_-]*`, length ≤ 64. |
| `version` | Nonempty visible ASCII, ≤ 128 chars (opaque, not semver). Text `true` / `123` accepted. Reject empty, `null`, `~`. |
| `display_name` | Nonempty, ≤ 256 Unicode scalar values, no control characters. |
| `profiles` | Nonempty sequence, ≤ 256 entries. |

Each profile entry is a mapping with keys `id`, `path`, `sha256` only (same unknown-key rule).

| Profile field | Rules |
|---------------|--------|
| `id` | Exactly `namespace/name` (one slash); each segment matches the package id grammar. Duplicate profile IDs in one manifest rejected (later entry). |
| `path` | Exactly `profiles/<file>.yaml`: two components; first `profiles`; second is a single filename with nonempty stem and `.yaml` extension. Portable guards (Windows reserved names, `< > " \| ? *`, backslash, colon, control chars, `..`, leading slash, drive/UNC forms, trailing dot/space per component, component length ≤ 255, total ≤ 1024 bytes). Exact and ASCII-casefolded path collisions rejected (later entry). |
| `sha256` | Exactly 64 ASCII hex digits; normalized to lowercase in the typed output. Syntax only—no byte verification. |

No rule ties `package.id` to profile namespace segments beyond separate grammar checks (RFC C1).

## Diagnostic precedence

1. Too large, then NUL (stop at first).
2. Parser syntax and unsupported-syntax (stop).
3. Top-level schema and shape, fields in order: `schema_version`, `id`, `version`, `display_name`, `profiles`.
4. Profile list order; per entry fields `id`, `path`, `sha256`.
5. Cross-entry collisions: duplicate profile id, then path (reported at the later entry).

Within one mapping, unknown keys are reported in **source order** (parser preserves map entry order). Duplicate map keys are a parser syntax error (step 2).

`line` is set only when the parser or pre-parse scan provides it; schema errors otherwise use `line: None`.

## Non-goals

Filesystem access, environment, payload reading, hash verification, install/discovery/catalog, CLI exit codes, edits to `core/src/yaml/*`, and profile document ID cross-checks are out of scope for this module.
