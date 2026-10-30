---
name: rawview-setup-grammar
description: Setup or update `.rawviewer/grammar.yaml` and explorer source labels for a RawView project by analyzing filename patterns in scientific data roots. Use when setting up filename tokens, variables, parsing sample metadata from filenames, or configuring sidebar source labels in RawView.
---

# RawView Setup Grammar Skill

Use this skill to automatically inspect scientific data filenames in a project, extract structured variables, and generate a verified `.rawviewer/grammar.yaml` (schema v1) alongside `.rawviewer/setting.yaml` source label layouts.

## Workflow

### 1. Identify the Project and Sample Filenames
- Locate the project root (where `.rawviewer/` lives, or the folder containing raw data files).
- List 10–20 representative filenames from the data directory:
  ```sh
  find <data_root> -type f -not -name ".*" | head -n 25
  ```
- Omit hidden files like `.DS_Store` and non-data extensions (e.g. `.png`, `.pdf`).

### 2. Decompose Filename Grammar
Analyze delimiters (`_`, `-`, `.`) and identify semantic tokens:
- **Sample / Specimen**: e.g., `sampleA`, `pda-thinfilm`, `sample-01`
- **Measurement Mode / Instrument**: e.g., `cv`, `eis`, `iv`, `raman`, `b1500a`
- **Physical Parameter / Condition**: e.g., `10V`, `300K`, `pH7`, `scan1`
- **Timestamp / Date**: e.g., `20261016`, `2026-10-16`, `143000`

### 3. Grammar YAML Contract (Schema Version 1)
Target file: `<project_root>/.rawviewer/grammar.yaml`

```yaml
schema_version: 1
grammars:
  - id: <unique-grammar-id>
    name: <Human Readable Name>
    template: "{sample}_{condition}_{date}"
    fields:
      - name: sample
        role: sample
        type: string
        optional: false
      - name: condition
        role: condition
        type: string
        optional: false
      - name: date
        role: date
        type: datetime
        format: "yyyyMMdd"
        optional: false
```

#### Rules:
1. Every `{variable}` in `template` must match exactly one entry in `fields` by `name`.
2. `name` must be a valid identifier (alphanumeric and hyphens/underscores).
3. `type` must be one of: `string`, `number`, `datetime`.
4. If `type: datetime`, provide `format` (e.g., `yyyyMMdd` or `yyyy-MM-dd`).
5. `optional: true` is allowed for trailing or delimited tokens that may be absent in some files.

### 4. Configure Explorer Source Labels (Optional but Recommended)
To prevent the Explorer sidebar from showing raw filenames, add a `source_labels` entry to `.rawviewer/setting.yaml`:

```yaml
source_labels:
  <unique-grammar-id>:
    rows:
      - variables: ["sample"]
        style:
          font_size: 13
          font_weight: bold
      - variables: ["condition", "date"]
        separator: " · "
        style:
          font_size: 11
          foreground: secondary
```

### 5. Verification
- Verify that the YAML is valid syntax:
  ```sh
  python3 -c "import yaml; yaml.safe_load(open('.rawviewer/grammar.yaml'))"
  ```
- If working inside the RawView repository or tests, run:
  ```sh
  ./apps/macos/Scripts/check_core.sh
  ```
