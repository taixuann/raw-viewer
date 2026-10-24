---
name: rawview-setup-profile
description: Inspect scientific raw instrument data files (Keithley, Keysight, Horiba, Autolab, XRD, UV-Vis, etc.) and generate a verified Schema v3 Instrument Profile YAML in `.rawviewer/instrument/<id>.yaml`. Use when setting up new instrument readers, configuring columns, delimiters, headers, units, or metadata extraction for RawView.
---

# RawView Setup Instrument Profile Skill

Use this skill to inspect raw scientific data files from laboratory instruments and automatically generate a verified **Schema Version 3** profile in `.rawviewer/instrument/<profile_id>.yaml`.

## Workflow

### 1. Sniff the Raw Data File
Inspect the first 50–100 lines of a representative sample file:
```sh
head -n 60 "<sample_file_path>"
```
Check:
1. **Encoding**: utf-8 (default), ascii, or utf-16.
2. **Delimiter**: Comma `,`, Tab `\t`, Semicolon `;`, or Space.
3. **Decimal Separator**: Dot `.` (standard) or Comma `,` (European style).
4. **Header Lines**: Which physical row contains the column names?
5. **Data Start**: Does data start immediately `after_header: true`, or at a specific `{ row: N }`?
6. **Comments / Metadata**: Are there metadata lines before or within the header (e.g. starting with `#`, `//`, or key-value pairs)?

### 2. Map Columns and Physical Dimensions
Identify the measurement channels:
- **Independent variable (X-axis)**:
  - Voltage ($V$), Wavenumber ($cm^{-1}$), Wavelength ($nm$), Time ($s$), 2-Theta ($^\circ$).
- **Dependent variable(s) (Y-axis)**:
  - Current ($A, mA, \mu A$), Intensity ($a.u.$), Absorbance, Resistance ($\Omega$).
- Role: `channel` (active plotting), `progression` (for stepped parameters), or `skip` (ignored columns).

### 3. Profile Contract (Schema Version 3)
Target file: `<project_root>/.rawviewer/instrument/<instrument-id>.yaml`

```yaml
schema_version: 3
identity:
  id: <instrument-id>
  name: <Instrument Name>
  instrument:
    id: <instrument-id>
    name: <Instrument Name>
filename:
  grammar_id: <grammar-id> # Matches id in .rawviewer/grammar.yaml
  variant_keys: [<field_name>] # e.g. [mode] or [instrument]
variants:
  - id: <variant-id> # e.g. default, iv-sweep, raman-single
    name: <Variant Name>
    key_values:
      <field_name>: <expected_value>
    raw_stream:
      extensions: [".csv", ".txt", ".dat"]
      encoding: [utf-8]
      delimiter: "," # or "\t", ";", " "
      decimal_separator: "."
      rows:
        header:
          first_nonblank: true # OR { row: 1 } OR { prefix: "#" }
        data_start:
          after_header: true # OR { row: 15 }
        excluded_metadata: []
      columns:
        - id: x_col
          source:
            header: "Voltage (V)" # Exact string in header row
          label: Voltage
          quantity: voltage
          unit: V
          required: true
          role: channel
          axes: [x]
        - id: y_col
          source:
            header: "Current (A)"
          label: Current
          quantity: current
          unit: A
          required: true
          role: channel
          axes: [y]
    metadata: [] # Optional: extracted metadata cells from header
    default_plot:
      x: x_col
      y: [y_col]
```

### 4. Advanced Header Metadata Cells (Optional)
If the instrument outputs parameters in header rows (e.g. Row 3, Column 2 contains temperature):
```yaml
    metadata:
      - key: temperature
        role: temperature
        source:
          row: 3
          column: 2
        parameter:
          name: Temperature
          source:
            row: 3
            column: 1
```

### 5. Verification
- Verify YAML syntax:
  ```sh
  python3 -c "import yaml; yaml.safe_load(open('.rawviewer/instrument/<instrument-id>.yaml'))"
  ```
- If inside the RawView repository, run test gates:
  ```sh
  ./Scripts/check_core.sh
  ```
