---
name: setup-rawviewer
description: Complete setup, configuration, and troubleshooting guide for RawView projects, filename grammars, instrument profiles (Schema v3/v4), lab packages, and CLI diagnostics. Use when setting up a RawView workspace, writing `.raw-viewer/grammar.yaml` or `~/.config/raw-viewer/grammar.yaml`, creating or debugging instrument profile YAMLs, or diagnosing why files fail to match or plot.
---

# Setup RawView

Authoritative reference for configuring RawView (macOS app and `raw-viewer` CLI) from project initialization through grammar, instrument profiles, and diagnostics.

## 1. Project Layout & Config

A RawView project root contains:

- `data/raw/` (or custom `data_root` configured in `.raw-viewer/config.yaml`)
- `.raw-viewer/config.yaml` — project settings (`schema_version: 1`, `data_root`, `default_view`, `default_preset`, `tree_grouping`, `profiles`)
- `.raw-viewer/grammar.yaml` — optional project-level filename grammar (overrides global)
- `.raw-viewer/instrument/*.yaml` — optional project-local instrument profiles (override global/package profiles)

Global user-level defaults live in `~/.config/raw-viewer/` (or `$XDG_CONFIG_HOME/raw-viewer/`):

- `~/.config/raw-viewer/grammar.yaml` — global default filename grammar
- `~/.config/raw-viewer/packages/` — installed optional lab packages (e.g. `usth-lab`)

Quick check from any project root:

```bash
raw-viewer doctor
```

## 2. Filename Grammar Setup

### Precedence
1. Project: `<project>/.raw-viewer/grammar.yaml`
2. Global: `~/.config/raw-viewer/grammar.yaml`
3. Built-in scientific fallback

### Template Syntax & Token Types
Define placeholders in curly braces `{token}` and optional segments in brackets `[{token}]`:

```yaml
schema_version: 1
grammars:
  - id: standard-lab
    name: Standard Lab Grammar
    template: "{date}_{device}.{application-mode}_[{device-id}]_{library}.{study}_r.[{remarks}]_f.[{flags}]_{index}"
    is_default: true
    fields:
      - name: date
        type: datetime
        format: "DDMMYY-HHmmSS"
      - name: device
        type: string
      - name: application-mode
        type: string
      - name: device-id
        type: string
        optional: true
      - name: library
        type: string
      - name: study
        type: string
      - name: remarks
        type: string
        optional: true
      - name: flags
        type: string
        optional: true
      - name: index
        type: number
        format: "001"
        optional: true
```

### Key Flags in Settings > Grammar Builder
- **Type** (`string`, `datetime`, `number`): `datetime` enables normalized Year (`YYYY`), Month (`YYYY-MM`), or Day (`YYYY-MM-DD`) folder grouping.
- **Variant Key**: Marks tokens (`application-mode`, `mode`, `variant`) that distinguish separate measurement modes so files are not collapsed together.
- **Optional**: Matches `[{token}]` segments that may be omitted from filenames.
- **Facet**: Exposes token values as multi-select filters in the Explorer sidebar.
- **Tree**: Includes the token in `tree_grouping` hierarchy (synced on save).

Test any filename against the active grammar:

```bash
raw-viewer grammar test "110526-000000_autolab-usth.ca_[cu-ta-pda.q1-ito.1]_electrochem.protonation_r.[clean]_f.[none]_001.txt"
raw-viewer grammar show
```

## 3. Instrument Profile Setup (Schema v3/v4)

Instrument profiles tell RawView how to match a raw data file and parse its header, columns, units, and default plot axes.

### Profile Anatomy (Schema v3/v4)
```yaml
schema_version: 3
id: custom-instrument
name: Custom Instrument
when:
  all:
    - filename_tokens:
        device: custom-instrument
    - content_contains_any:
        - "Potential"
        - "WE(1).Potential"
reader:
  delimiter: "\t"
  header_lines: 1
  decimal: "."
  columns:
    - name: potential
      label: Potential
      unit: V
      quantity: voltage
    - name: current
      label: Current
      unit: A
      quantity: current
view:
  kind: xy
  x: potential
  y:
    - current
```

### Common Tips
- Keep raw files strictly read-only; RawView never writes to `data/raw/`.
- Use `when.filename_tokens` together with `when.content_contains_any` to avoid ambiguous multi-profile hits.
- For multi-cycle or sweep data (CV, CA, EIS), mark a `progression` channel (`quantity: index` or `time`) to enable cycle/sweep segmentation in the Inspector.
- Inspect how a single file resolves and parses:

```bash
raw-viewer inspect path/to/rawfile.txt
raw-viewer files match
```

## 4. Updating & Keeping Skills Synced

Update the `raw-viewer` CLI and refresh installed skills:

```bash
raw-viewer update
raw-viewer skills install
```

In the macOS app, open **Settings > Lab Packages** to install/remove optional lab profile packages, **Settings > Profiles** to toggle or export individual profiles, and **Settings > Grammar** to customize project or global filename rules.
