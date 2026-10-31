# Profile `when` matching amendment (issue #18, contract 18c-1)

This note amends the schema-v4 / profile-resolution design in issue #18.

## `when` at two levels

Instrument profiles may declare `when` at the **document root** and again on each **variant**. Resolution merges both clauses; **both must match** (logical AND). If either level fails, the variant is not a candidate.

## Filename tokens (exact)

Legacy `filename_contains_all` and v4 `when.filename_contains_all` translate in memory to **exact whole-token** equality:

- Take the source basename without extension.
- Split on `_`, `.`, `-`, and whitespace (case-sensitive tokens).
- Each required legacy entry is split the same way; every piece must appear as an exact token in the basename token set.
- Substring matches that are not whole tokens do **not** match (for example `needle` inside `needlefish`).

## Content selectors

- `content_contains_any` and `content_starts_with`: any-of within a list; all active selector groups combine with filename/grammar requirements (AND).
- Matching is **case-insensitive** over the first **64 KiB** of decoded text and over the basename string for content keys.

## Grammar routing

When a project grammar catalog is loaded:

- If the basename **fully matches** a grammar template, only profiles whose merged `when` is satisfiable with extracted grammar fields are candidates (plus normal content/filename rules).
- If grammar matches but **no** profile mode matches → error (`grammar_matched_no_profile`), not generic-table fallback.
- If the catalog is loaded but the basename matches **no** grammar → only **content-only** `when` profiles (no filename tokens, no grammar token equalities) are candidates.
- If there is **no** grammar catalog, filename and content selectors apply to all candidates (legacy fixture behavior).

## Ambiguity

Two or more profile hits → `ambiguous_profile` with **sorted** candidate profile ids (Rust and Swift share the same code string).

## Legacy → `when` mapping (in memory only; YAML unchanged)

| Legacy field | `when` field |
| --- | --- |
| `modes[].detect` / `detect.signatures` | `content_contains_any` |
| `filename_contains_all` | split → `filename_tokens` |
| `application_modes` key | `grammar_tokens.mode` |
| `header_signatures` (per-mode) | `content_contains_any` plus mode-key token where applicable |

Schema v4 variant compilation accepts a variant `when` with **no** `content_contains_any` when filename or grammar tokens provide selectors.
