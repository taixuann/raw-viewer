# Profile persistence audit and design discussion

Status: read-only source/configuration audit. No runtime round-trip executed. No research configuration modified. This is not scientific acceptance or an implementation plan.

## Scope and ownership

Research project: `/Users/tai/research-projects/active-projects/res_volatile-polydopamine`.
Project AGENTS.md:9–10 declares raw evidence immutable and data/instruments profiles owned by Study. RawView upgrades must target viewer profiles, not replace Study interpreter contracts.

## Observed files

Filesystem inventory found five viewer companion profiles in `data/.rawview/instrument/`: autolab-usth, keysight-b1500a, keithley-2400, iop-hanoi, horiba-labram. It found no YAML profiles in `.rawviewer/instrument/`. Project grammar exists at `.rawviewer/view/grammar.yaml`. Separate scientific profiles exist in `data/instruments/`; those are not the same schema.

## Findings

1. Existing viewer schema is already structured: instrument identity, reusable formats and modes referencing formats with detect/filename selectors and extract X/Y. Autolab has four layouts/modes; Keysight has csv and wgfmu layouts; Horiba has two layouts. Evidence: research `data/.rawview/instrument/autolab-usth.yaml:13–165`, `keysight-b1500a.yaml:15–94`, `horiba-labram.yaml:14–68`.
2. Editor compiler emits a different shape: schema_version 1, modes.table/channels and mode metadata; it does not emit formats. Evidence: RawView `Sources/RawViewCore/Editor/EditorWorkspaceModel.swift:584–687`. Strict runtime parser requires at least one format and rejects unknown root/instrument/format keys: `Sources/RawViewCore/Reader/InstrumentProfile.swift:625–640`. This is a structural incompatibility visible from source; an actual round-trip remains to be run.
3. Editor persists skip/progression/dimension/behavior and coordinate-based metadata tags. Runtime column schema shown in InstrumentProfile.swift:753–769 does not support those fields for comment-tsv. A compatible upgraded contract must cover all format branches and consumers rather than append arbitrary YAML keys.
4. Grammar writer includes identity/template/description/default/scope plus field name/role/type/format_hint/strip_brackets/is_optional/is_facet, but no schema_version. Evidence: `FilenameGrammarEngine.swift:445–478`. Loader returns nil for malformed/unreadable YAML and silently skips incomplete grammar entries or defaults unknown types to string: :488–495, :547–574. It is less strict than project settings/profile loading.
5. Actual project grammar lacks field type entries. Date format exists but loader defaults absent type to string; batch is optional with an empty format hint. Evidence: research `.rawviewer/view/grammar.yaml:9–50`; loader :570. Do not assume the live project grammar preserves the editor's intended typed fields.
6. Profile compiler has no grammar ID link; strict parser also lacks one. Evidence: compiler :584–594; parser :625–631. Linking requires schema/model/parser/compiler/consumer changes.
7. Scientific profiles contain additional metadata verification, timestamp policy, transforms and evidence fields. Example: research `data/instruments/autolab-usth.yaml:6–24`, :80–104. These are owned by Study and must not be copied into a viewer schema as execution behavior or acceptance claims.
8. Current saveProfileAndRules writes instrument YAML, category rules, then grammar; grammar save catches its own error and final save overwrites the message. Evidence: `EditorWorkspaceView.swift:317–326`, :601–623. Atomic single-file replacement is not an all-files transaction.

## Recommended design to review

Retain the existing formats/modes distinction; do not downgrade an instrument's multiple modes to the editor's single current mode when saving. Introduce a reviewed viewer schema upgrade with a profile-level saved grammar reference, dynamic metadata extraction definitions and column progression semantics. Keep identity/static literals distinct from per-source filename/header-derived metadata. Treat preview raw values as preview evidence, not constant values to reuse across files.

Move project grammar to `.rawviewer/grammar.yaml` with explicit versioning and validation. Keep active editor choice separate from the authoritative grammar link in each instrument profile. Resolve global templates into project-owned definitions before linking so relocating a project does not depend on a machine's global catalog. Reject unresolved/ambiguous IDs rather than silently changing scientific metadata.

Migration must preserve encoding, aliases, optional channels, format kinds, decimal parsing, mode selectors and all untouched modes. Read legacy profiles without rewriting them automatically. Generate upgraded viewer copies under `.rawviewer/instrument/` only after schema approval and verified round-trip. Confirm catalog precedence does not hide remaining legacy instrument profiles when the first upgraded copy appears.

## Required acceptance probes before implementation handoff

- Compile editor definitions, parse with the strict catalog, then load a representative source using that exact profile without generic-reader fallback.
- Cover Autolab decimal comma and multiple modes, B1500A row markers, Keithley empty leading cell, Horiba headerless positional columns, UV-Vis aliases.
- Verify progression, skipped columns and dynamic metadata survive save/reopen/load.
- Verify saving one mode preserves all other modes and formats.
- Verify raw files and Study-owned profiles remain unchanged.

## Brainstorming decision

Architectural change. First resolve profile identity: retain one file per instrument with multiple modes/formats, or make each saved editor profile one independent preset and introduce explicit instrument identity separately. Existing real viewer profiles support the first approach; recommend preserving it. No schema upgrade or executor dispatch until this decision and the written design are reviewed.
