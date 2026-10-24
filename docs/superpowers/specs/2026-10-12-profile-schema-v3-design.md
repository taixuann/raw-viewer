# Profile schema v3 design

Status: updated conversational design for final review. Not implemented. Still version 3; supersedes the earlier one-file-per-mode proposal.

## Intent and ownership

One `.rawviewer/instrument/<profileID>.yaml` contains one named profile and multiple variants. A profile can represent Autolab USTH with CV/CA/EIS and layout alternatives without separate files. Preserve profile identity separately from instrument identity. Each variant owns parsing, metadata and plot defaults.

`.rawviewer/grammar.yaml` owns a schema-version-1 grammar catalog. `.rawviewer/setting.yaml` schema v3 owns project data root, defaults, Explorer views and developer_mode (default false). Grammar roles annotate metadata only. Profile variant_keys select fields used for routing; Explorer independently selects fields used as views. No category.yaml writes in the new path. Legacy sources and Study contracts remain unchanged.

## Grammar contract

Root: schema_version: 1 and grammars list. Each grammar: id, name, template, fields; optional description. Each field: name, role, type (existing string/number/datetime), optional format, optional boolean (default false). Role is a stable metadata key; allow custom nonempty roles rather than restrict to instrument names. No variant-key flag, is_facet, grouping/filtering or active_grammar_id in new grammar serialization.

Require unique grammar/field IDs, exact template-field correspondence and compatible type/format. Preserve raw text separately from typed interpretation, including leading zeros. Optional-field delimiter behavior must be ported explicitly from tested extraction semantics; reject invalid patterns, never silently treat partial matches as full matches. Project-owned grammar references make profiles portable. Read legacy path only when canonical grammar file is absent; malformed canonical data is an error. Missing legacy types require reviewed migration, not guessed scientific semantics.

```yaml
schema_version: 1
grammars:
  - id: standard-scientific
    name: Standard Filename Pattern
    template: "{instrument}.{mode}_{sample}"
    fields:
      - name: instrument
        role: instrument
        type: string
        optional: false
      - name: mode
        role: mode
        type: string
        optional: false
      - name: sample
        role: sample
        type: string
        optional: false
```

This illustrative grammar is not a replacement for the project's real filename template. Library/Study extensions are deferred.

## Instrument contract

Root keys: schema_version (3), identity, filename, variants. Identity: id/name and instrument.id/name, optional vendor/model. Filename: grammar_id and variant_keys (ordered unique field names in that grammar). Keys are chosen in the Filename Grammar variable table for the active profile, persisted in profile YAML only. Key fields must be required; values compare exact extracted raw strings, case-sensitive. No implicit type coercion or role-to-selector conversion.

Each variant: unique id/name, key_values mapping containing exactly all selected keys, optional match, raw_stream, metadata list, default_plot. Repeated key tuples are allowed only with distinguishable stream/header selectors; runtime still requires exactly one candidate, never first-match wins. Stable variant ID is not the same as the mode token: cv and cv-2col may share mode=cv.

Match may retain legacy `filename_contains_all` and `content_contains_any` string lists, with their legacy case-insensitive semantics. These are explicit compatibility selectors applied in addition to variant key equality and stream checks. Unknown selectors fail validation. Empty optional selector lists are rejected. Partial filename matches never route.

Raw stream: extensions list, encoding list, delimiter, decimal_separator, rows, columns. Coordinates are one-based physical rows/tokens. Preserve empty cells. Encoding names reuse existing reader names; decoding alternatives are explicit, not invented from samples.

Rows: `header` is null, `{row: positiveInt}`, `{first_nonblank: true}`, or `{prefix: nonemptyString}`. `data_start` is `{row: positiveInt}` or `{after_header: true}`. Optional `data_prefix` (including empty string) preserves marker filtering; empty means no prefix filter. `comment_prefix` is optional nonempty string for headerless comment layouts. `excluded_metadata` is a unique list of positive physical rows. Variants must preserve legacy marker-row semantics, not freeze positions from one sample. Header prefix and nonempty data_prefix mean equality with the first trimmed/unquoted delimiter token, not arbitrary string-prefix matching. Keep that token in physical column coordinates; never remove it. Use the first matching header, skip blank data lines, and filter declared comment lines before decoding. excluded_metadata affects metadata only, not data rows.

Columns: stable id, source mapping with optional column (positiveInt), header, aliases. Require column or header. If both are supplied, require agreement; do not silently relocate. Aliases require header. Additional keys: label, quantity, optional unit, required boolean (default true), role (channel/progression/skip), axes subset x/y and optional progression (type index/time/custom, name, behavior continuous/discrete). No Aux. Skip retains definition, disables decoding and axes/default eligibility. Optional missing columns remain absent, not fabricated. Default axes must be required nonskipped declared axis-capable columns; Explorer offers optional axis-capable columns only when present.

Metadata list: key, role, source.row/column, optional format and optional parameter.name/source.row/column for a linked key cell. Ignored tags use role ignore. All values are read per source; sample rawValue never becomes a constant. Reject extraction tags on excluded metadata rows. Preserve conflicting filename/header metadata with source qualification and diagnostics, not silent precedence.

Default plot: null or x (column ID), y (nonempty ID list), optional progression ID. Multiple axis-capable columns are independent of defaults. Sandbox and Explorer choices are display-only until explicit Use as Profile Defaults in editor. No numeric transforms or acquisition-order changes.

```yaml
schema_version: 3
identity:
  id: autolab-usth
  name: Autolab USTH
  instrument:
    id: autolab-usth
    name: Autolab USTH
filename:
  grammar_id: standard-scientific
  variant_keys: [instrument, mode]
variants:
  - id: cv
    name: CV
    key_values:
      instrument: autolab-usth
      mode: cv
    raw_stream:
      extensions: [".txt"]
      encoding: [utf-8]
      delimiter: ";"
      decimal_separator: ","
      rows:
        header:
          first_nonblank: true
        data_start:
          after_header: true
        excluded_metadata: []
      columns:
        - id: potential
          source:
            header: "Potential applied (V)"
          label: Voltage
          quantity: voltage
          unit: V
          required: true
          role: channel
          axes: [x]
        - id: current
          source:
            header: "WE(1).Current (A)"
          label: Current
          quantity: current
          unit: A
          required: true
          role: channel
          axes: [y]
    metadata: []
    default_plot:
      x: potential
      y: [current]
```

Example contains only one variant for brevity; CA/EIS use different key_values and complete stream definitions within the same variants list. Real imports preserve full encoding alternatives and selector behavior.

## Resolution and UI

Full grammar parse → key tuple candidates → compatibility selectors and declared stream/header checks → exactly one variant. Ambiguity is actionable; no generic fallback can claim v3 success. Provenance records profile ID, variant ID and document/grammar fingerprints. Catalog merges legacy peers without hiding unrelated profiles. Archive directories are excluded if any exist; archive-management UI is deferred.

Left sidebar selects Profiles; workspace has a labeled Variant selector with Add/Duplicate Variant actions. New Profile duplicates the whole document with a new profile ID; Duplicate Variant duplicates only selected variant and requires resolving key/selector collisions. Changing keys presents an explicit edit of all variant values; incomplete drafts cannot save. Label the variable-table checkbox Variant Key and show scope `Routing keys for <profile name>`, not grammar properties. No profile selected means the control is disabled with explanatory text. Switching variants preserves document-level dirty state and other variant edits; only document replacement prompts Save/Discard/Cancel.

Schema badge is read-only: Profile schema v2 Legacy / v3; Upgrade produces one unsaved v3 profile with selected variants, not separate files. Missing definitions are inline actionable blockers, not an acknowledgment checkbox. Strict adapter does not use the lenient first-mode loader. Legacy read-only; explicit canonical import leaves originals unchanged.

Sample selection must confirm the active profile AND variant; current matching sample first, otherwise deterministic source-ID order. No match clears stale confirmation (loaded sample kept as unconfirmed preview) and offers searchable Choose sample. Matching/preview I/O is bounded off-main with generation checks. Changing a preview never autodetects or rewrites definitions.

Developer Mode adds Profile YAML for the complete profile and Edit YAML inside Filename Grammar for the complete project catalog. Paths/scope visible. Validate before source save and preserve exact edited bytes/comments. Visual/source draft switching must not lose edits. One Save command per focused workspace document; variant saves persist whole profile. Dirty replacement/workspace/window/quit transitions guarded; errors cancel transitions. External changes require reconciliation. Narrow headers use native menus/wrapping, not smaller text; keyboard and VoiceOver behavior required.

## Final review corrections

Use existing YAMLParser subset: indented mappings, supported scalar/list syntax, no flow mappings. Structural parse is separate from validation against a grammar catalog. Define ProfileUpgradeDraft containing editable optional fields and blocking diagnostics, not a prematurely valid ProfileDocumentV3. Finalize only after required fields and references validate.

Canonical imports carry optional legacy_origin mapping with project-relative path and exact source SHA256. Catalog shadowing applies only to the unchanged exact companion profile identified by this origin; preserve unrelated legacy profiles and report changed-origin conflicts. Never use an instrument ID alone to suppress a legacy peer. Retain the authoritative companion-directory boundary rather than accidentally importing Study profiles.

For lossless legacy acquisition metadata, each variant may declare metadata_capture list of explicit compatibility rules: kind pre_header_fields for ordered pre-header records, or kind comment_key_value with prefix for ordered comment key=value records throughout the stream. Preserve repeated keys and record order. These are additive to fixed-cell metadata; provenance remains separate. Do not synthesize fixed coordinates from sample files. Adapter comparison must include acquisition metadata.

Header lookup is case-insensitive, primary header first then alias fallback, matching existing reader semantics; reject ambiguous headers and two semantic columns resolving to one source column. Stable column IDs are independent from source header names and labels.

Legacy grammar mapping: format_hint to format, is_optional to optional; bracket captures preserve existing tested extraction values. Read is_facet/default/scope/active selection only as legacy compatibility state, not new metadata-routing flags. Map recognized role labels explicitly to machine keys; custom roles remain explicit. Do not infer role/type from variable name substrings.

Variant Key is enabled only for the active profile referenced grammar. Other catalog selections show a disabled explanation plus Use this grammar for profile… with explicit rebind/key review. Key edits dirty the profile only. Current-variant raw key values appear beneath Variant selector; all-variant matrix appears only during key-set changes. Suggestions from sample require acceptance.

Sandbox consumes normalized extraction from the same v3 reader path using the in-memory draft; no separate numeric parsing/axis guessing. Null defaults show No default axes. Use as Profile Defaults previews and explicitly replaces the complete X/Y list, never silently truncates multi-Y. Source Save preserves edited bytes; later visual regeneration warns before replacing comment-bearing source text. Incomplete visual variants remain navigable; Save validates all variants.

## Migration and verification

Adapter maps selected legacy modes into variants within one draft, preserves encoding, row selectors, aliases, optional columns, matching selectors and axis sets. Key values/grammar missing from source are Needs definition, never guessed. Unsupported fields block save until real resolution. Generic synthetic fixtures are primary; real PDA profiles only integration examples. Compare legacy/upgraded matching, channels, values/gaps, units and defaults. No real-project migration without authorization.

Require document round-trip for multiple variants, key edits, duplicate tuples/ambiguity, source/raw metadata, skip/progression, caches, source editor and all legacy/security regressions. Run check_core.sh and check_index_cli.sh plus actual full tests. Software completion is not scientific acceptance.
