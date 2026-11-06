---
name: set-grammar
description: Interview a user from sample filenames and configure a verified filename grammar in .raw-viewer/config.yaml using the raw-viewer CLI. Validates against samples including names with no extension and names with only r. or only f.
---

# Set Grammar Skill

Use this skill to inspect filename patterns across scientific datasets, interview the user about filename structure, and write a single, verified `grammar:` block into the project configuration (`.raw-viewer/config.yaml`) or global configuration (`~/.config/raw-viewer/config.yaml`).

## Rules & Constraints
1. **CLI Authority**: Always use the `raw-viewer` CLI for all tests, queries, and changes. Never shell out to `ln` or other OS-specific linking tools; use `raw-viewer skills install` or `raw-viewer skills repair`.
2. **One Grammar per Project**: A project configuration holds exactly one `grammar:` object that replaces the global/built-in grammar.
3. **No Internal Harness Mentions**: Never mention `check_core.sh` or internal test harnesses in user-facing instructions or explanations.
4. **Validation Gate**: A grammar configuration is valid only when `raw-viewer --json grammar test` exits with code 0 on all user samples, including edge cases:
   - Filenames with no file extension (e.g. `20261101_sample_iv`)
   - Filenames with only `r.[remarks]` or only `f.[flags]`
   - Filenames with both or neither remarks/flags

## Interactive Workflow

### 1. Collect Sample Filenames
Ask the user for 5 to 20 representative filenames from their data folder, or inspect existing filenames using:
```sh
raw-viewer --json files inspect <relative-or-absolute-path>
```
Ensure the sample set contains standard files as well as edge cases (e.g. omitted extensions, remarks-only, flags-only).

### 2. Interview & Token Identification
Analyze filename delimiters (`_`, `.`, `[`, `]`, `-`) and map each component to standard field roles:
- **`date`**: Timestamp or date token (type: `datetime`, role: `datetime`, specify `format` such as `DDMMYY-HHmmSS` or `YYYYMMDD`).
- **`device`** or **`instrument`**: Name or identifier of the instrument (role: `instrument`, type: `string`).
- **`application-mode`** or **`mode`**: Measurement mode (role: `mode`, type: `string`, e.g. `iv`, `cv`, `eis`, `raman`).
- **`device-id`** or **`sample`**: Device, specimen, or batch identifier (role: `device` or `sample`, type: `string`).
- **`library`** / **`study`**: Library or campaign name (role: `library` / `category`, type: `string`).
- **`remarks`**: Optional remarks block (e.g. `r.[{remarks}]`, role: `remarks`, `optional: true`).
- **`flags`**: Optional flags block (e.g. `f.[{flags}]`, role: `flags`, `optional: true`).
- **`index`**: Optional numeric sequence or run index (role: `batch` or `index`, type: `number`, `optional: true`).

### 3. Grammar Specification Format
Construct the YAML `grammar:` object:
```yaml
grammar:
  id: <unique-grammar-id>
  name: <Human-Readable Name>
  template: "{date}_{device}.{application-mode}_[{device-id}]_{library}.{study}_r.[{remarks}]_f.[{flags}]_{index}"
  fields:
    - name: date
      role: datetime
      type: datetime
      format: DDMMYY-HHmmSS
      optional: false
    - name: device
      role: instrument
      type: string
      optional: false
    - name: application-mode
      role: mode
      type: string
      optional: false
    - name: device-id
      role: device
      type: string
      optional: false
    - name: library
      role: library
      type: string
      optional: false
    - name: study
      role: category
      type: string
      optional: false
    - name: remarks
      role: remarks
      type: string
      optional: true
    - name: flags
      role: flags
      type: string
      optional: true
    - name: index
      role: batch
      type: number
      optional: true
```

### 4. Validate with CLI
Test the candidate grammar against every collected sample:
```sh
raw-viewer --json grammar test --filename "<sample-1>" --filename "<sample-2>" ...
```
Requirements:
- Must exit with code 0.
- All samples must show `"matched": true`.
- If any sample fails, revise the `template` or field optionality until all samples match.

### 5. Apply the Grammar
Apply the validated grammar to the project (or globally) using:
```sh
raw-viewer --json grammar set --file <path-to-grammar.yaml> [--project <path>]
```
Verify the live effective grammar with:
```sh
raw-viewer --json grammar show [--project <path>]
```
