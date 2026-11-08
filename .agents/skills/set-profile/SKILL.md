---
name: set-profile
description: Inspect a scientific raw data file, interview the user about row and column layout, and configure a verified Schema v4 profile in .raw-viewer/profiles/<id>.yaml using the raw-viewer CLI.
---

# Set Profile Skill

Use this skill to inspect a representative raw instrument data file (e.g. Keithley, Autolab, Horiba, Keysight, Gamry, XRD, UV-Vis), interview the user, generate a Schema Version 4 profile in `.raw-viewer/profiles/<id>.yaml`, and register the profile in `profiles.enabled`.

## Rules & Constraints
1. **CLI Authority**: Always execute commands using the `raw-viewer` CLI binary. Never shell out to `ln` or other OS-specific symlink commands; use `raw-viewer skills install` or `raw-viewer skills repair`.
2. **Never Symlink Profiles**: Never place symlinks under `.raw-viewer/profiles/`. The core profile catalog strictly refuses symlinked profile files. Profiles must be saved as regular YAML files.
3. **No Internal Harness Mentions**: Never mention `check_core.sh` or internal testing infrastructure in user-facing instructions.
4. **Single-Match Verification Gate**: Before committing a profile, `raw-viewer --json files match` must return a single match outcome (`"matched"`). If two or more profiles hit, the CLI exits with code 3 (`ambiguous_profile`), which must be resolved by refining the `when:` conditions before saving.

## Interactive Workflow

### Step 1: Inspect the Raw Sample
Inspect the sample file using the CLI:
```sh
raw-viewer --json files inspect <sample_file_path>
```
Examine the returned JSON structure:
- Numbered preview rows
- Detected delimiter (`\t`, `,`, `;`, or space)
- Candidate header line and column names
- Row count and unprofiled disposition

### Step 2: Interview the User on Rows
Present the numbered preview to the user and ask:
1. **Skip rows**: Which rows should be ignored (e.g. comments, apparatus banners, blank rows)?
2. **Metadata rows**: Which rows contain key/value parameter cells (e.g. Date, Temperature, Operator, Integration Time)?
3. **Header row**: Which row contains the column names?
4. **Data start row**: Where do the numerical measurement records begin?

### Step 3: Map Columns and Physical Dimensions
For each column in the table, determine its role:
- **`channel`**: Measured or driven physical signal.
  - Define `quantity` (e.g. `voltage`, `current`, `wavenumber`, `intensity`, `capacitance`).
  - Define `unit` (e.g. `V`, `A`, `mA`, `cm-1`, `a.u.`, `F`).
  - Define `label` (human-readable title for UI).
- **`progression`**: Independent variable or stepping parameter.
  - Define `type`: `time`, `index`, or `custom`.
  - Define `behavior`: `continuous` or `discrete`.
  - Define `quantity`, `unit`, and `label`.
- **`skip`**: Extraneous or unneeded column.

### Step 4: Default Plot Configuration
Ask the user for default X and Y axes only when there is more than one plottable channel candidate. If unambiguous (e.g. 1 X and 1 Y), assign automatically:
```yaml
plot:
  x: <x-column-key>
  y: [<y-column-key>]
```

### Step 5: Draft Schema v4 Profile YAML
Assemble the candidate profile YAML:
```yaml
schema_version: 4
id: <namespace>/<instrument-id>
revision: 1
instrument:
  id: <instrument-id>
  name: <Instrument Name>
  vendor: <Vendor Name>
  model: <Model Number>
variants:
  default:
    when:
      filename_tokens:
        device: [<device-token>]
      content_contains_any:
        - "<Unique Header String 1>"
        - "<Unique Header String 2>"
    format:
      kind: tabular
      extensions: [".txt", ".csv", ".dat"]
      delimiter: "\t"
      encoding: [utf-8, windows-1252]
    rows:
      header: 1
      data_start: 2
    columns:
      x_channel:
        role: channel
        header: "<Header Name in File>"
        quantity: <quantity>
        unit: <unit>
        label: <Label>
      y_channel:
        role: channel
        header: "<Header Name in File>"
        quantity: <quantity>
        unit: <unit>
        label: <Label>
    plot:
      x: x_channel
      y: [y_channel]
```

### Step 6: Validate Candidate (Dry-Run Import)
1. Dry-run profile import **only validates the candidate YAML** (schema v3/v4). It does **not** write files, create `.raw-viewer/profiles/`, change `config.yaml`, enable the profile, or prove the installed project will match files.
   ```sh
   raw-viewer --json profiles import --project <project_path> --file <candidate_profile.yaml> --dry-run
   ```
2. Inspect JSON fields such as `validated_candidate`, `destination_exists`, and `would_require_replace`. A dry-run success does **not** mean the profile is active in the project.
3. To validate behavior against already-installed project profiles, use `files match` / `files inspect` on a sample (Step 6b below) after a real import and enable.

### Step 6b: Test Match on Sample (Installed Config)
1. Test file match on the sample:
   ```sh
   raw-viewer --json files match --project <project_path> --file <sample_file_path>
   ```
2. Verification criteria:
   - Must return `"outcome": "matched"`.
   - If exit code 3 (`ambiguous_profile`) occurs, refine `when:` tokens or `content_contains_any` until exactly one profile matches.

### Step 7: Save & Enable Profile
1. Import the verified profile into the project. If a profile with the **same id** is already installed, the CLI refuses to overwrite user edits unless you pass **`--replace`** (explicit consent). Different profile ids that map to the same destination filename (`a/b` vs `a-b`) are rejected with a collision error even with `--replace`.
   ```sh
   raw-viewer --json profiles import --project <project_path> --file <candidate_profile.yaml>
   ```
   To overwrite an existing same-id installation:
   ```sh
   raw-viewer --json profiles import --project <project_path> --file <candidate_profile.yaml> --replace
   ```
2. Enable the profile in project config:
   ```sh
   raw-viewer --json profiles enable --project <project_path> --id <namespace>/<instrument-id>
   ```

### Step 8: Final Preview
Run inspection on the sample file to provide the final summary:
```sh
raw-viewer --json files inspect --project <project_path> --file <sample_file_path>
```
Present the verified preview to the user:
- Matched profile ID and variant
- Total row count
- X and Y channel names and physical units
- First 3 rows of parsed data
