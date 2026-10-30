#!/usr/bin/env python3
"""Generate golden manifest entries and fixture files for step 3."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FIX = ROOT / "fixtures"
PROFILES = FIX / "profiles"
SOURCES = FIX / "sources"
GRAMMAR = FIX / "grammar"
PROFILES.mkdir(parents=True, exist_ok=True)
SOURCES.mkdir(parents=True, exist_ok=True)
GRAMMAR.mkdir(parents=True, exist_ok=True)

KEYSIGHT_V1 = PROFILES / "keysight-b1500a.yaml"
KEYSIGHT_V2 = PROFILES / "keysight-b1500a-v2.yaml"

GRAMMAR_YAML = """schema_version: 1
grammars:
  - id: electrochem
    name: Electrochem Filenames
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
"""
(GRAMMAR / "electrochem.yaml").write_text(GRAMMAR_YAML, encoding="utf-8")

# acme v3 profile (cv + ca + rich variants) — matches v3_acme_cv.rs
ACME_V3 = (ROOT / "v3_acme_cv.rs").read_text(encoding="utf-8")
# Extract const blocks programmatically is fragile; embed minimal rich variant inline.
ACME_PROFILE = """schema_version: 3
identity:
  id: acme
  name: Acme Lab
  instrument:
    id: acme-inst
    name: Acme Instrument
filename:
  grammar_id: electrochem
  variant_keys:
    - instrument
    - mode
variants:
  - id: cv
    name: CV
    key_values:
      instrument: acme
      mode: cv
    raw_stream:
      extensions: [".txt"]
      encoding: [utf-8]
      delimiter: ","
      decimal_separator: "."
      rows:
        header:
          row: 2
        data_start:
          after_header: true
      columns:
        - id: potential
          source:
            header: Volts
          label: Voltage
          quantity: voltage
          unit: V
          required: true
          role: channel
          axes: [x]
        - id: current
          source:
            header: Amps
          label: Current
          quantity: current
          unit: A
          required: true
          role: channel
          axes: [y]
    metadata_capture:
      - kind: pre_header_fields
    default_plot:
      x: potential
      y: [current]
  - id: ca
    name: CA
    key_values:
      instrument: acme
      mode: ca
    raw_stream:
      extensions: [".txt"]
      encoding: [utf-8]
      delimiter: ","
      decimal_separator: "."
      rows:
        header:
          row: 2
        data_start:
          after_header: true
      columns:
        - id: elapsed
          source:
            header: Secs
          label: Time
          quantity: time
          unit: s
          required: true
          role: channel
          axes: [x]
        - id: current
          source:
            header: mAmps
          label: Current
          quantity: current
          unit: mA
          required: true
          role: channel
          axes: [y]
    metadata_capture:
      - kind: pre_header_fields
    default_plot:
      x: elapsed
      y: [current]
  - id: rich
    name: Rich
    key_values:
      instrument: acme
      mode: rich
    raw_stream:
      extensions: [".txt"]
      encoding: [utf-8]
      delimiter: ","
      decimal_separator: "."
      rows:
        header:
          row: 2
        data_start:
          after_header: true
      columns:
        - id: potential
          source:
            header: Volts
          label: Voltage
          quantity: voltage
          unit: V
          required: true
          role: channel
          axes: [x]
        - id: current
          source:
            header: Amps
          label: Current
          quantity: current
          unit: A
          required: true
          role: channel
          axes: [y]
    metadata_capture:
      - kind: pre_header_fields
    default_plot:
      x: potential
      y: [current]
"""
(PROFILES / "acme-v3.yaml").write_text(ACME_PROFILE, encoding="utf-8")

FILENAME_V2 = """schema_version: 2
instrument:
  id: synth
  name: Synth
formats:
  - id: csv
    kind: tabular
    extensions: [".csv"]
    delimiter: ","
    rows:
      names_prefix: "DataName"
      data_prefix: "DataValue"
    columns:
      voltage:
        header: "V1"
        quantity: voltage
        unit: "V"
      current:
        header: "I1"
        quantity: current
        unit: "A"
modes:
  - id: dual-sweep
    format: csv
    filename_contains_all: ["synth-token", "dual-sweep"]
    detect: ["SYNTH-SPECIFIC-HEADER"]
    extract:
      x: voltage
      y: [current]
"""
(PROFILES / "filename-v2.yaml").write_text(FILENAME_V2, encoding="utf-8")

# Sources
(SOURCES / "dual-sweep.csv").write_text(
    "\ufeffSetupTitle, 2-terminal dual Vsweep\n"
    "ApplicationTest, 2-terminal dual Vsweep, Public\n"
    "Dimension1, 5, 5\n"
    "DataName, V1, I1\n"
    "DataValue, 0, 1E-12\n"
    "DataValue, 0.1, 2E-12\n"
    "DataValue, 0.2, 3E-12\n"
    "DataValue, 0.1, 4E-12\n"
    "DataValue, 0, 5E-12\n",
    encoding="utf-8",
)

(SOURCES / "gaps.csv").write_text(
    "SetupTitle, 2-terminal dual Vsweep\n"
    "DataName, V1, I1\n"
    "DataValue, 0, 1E-12\n"
    "DataValue, , 2E-12\n"
    "DataValue, 0.2, \n"
    "DataValue, 0.1, 4E-12\n"
    "DataValue, 0, 5E-12\n",
    encoding="utf-8",
)

(SOURCES / "gap-reasons.csv").write_text(
    "SetupTitle, 2-terminal dual Vsweep\n"
    "DataName, V1, I1\n"
    "DataValue, 0, 1E-12\n"
    "DataValue, 0.1,\n"
    "DataValue, 0.2, NaN\n"
    "DataValue, 0.3, inf\n"
    "DataValue, 0.4, 1e999\n"
    "DataValue, 0.5, 5E-12\n",
    encoding="utf-8",
)

(SOURCES / "raman-semicolon.txt").write_text(
    "raman_shift;intensity\n201.25;3.5\n202.5;4.75\n203.75;-2.25\n\n",
    encoding="utf-8",
)

(SOURCES / "b1500-dual-sweep.csv").write_text(
    "SetupTitle, 2-terminal dual Vsweep\n"
    "DataName, V1, I2\n"
    "DataValue, 0.0, 1E-12\n"
    "DataValue, 0.1, 2E-12\n"
    "DataValue, 0.2, 3E-12\n"
    "DataValue, 0.1, 4E-12\n"
    "DataValue, 0.0, 5E-12\n",
    encoding="utf-8",
)

(SOURCES / "b1500-list-sweep.csv").write_text(
    "SetupTitle, I/V List Sweep 1V\n"
    "DataName, V1, I2\n"
    "DataValue, 0.2, 3E-9\n"
    "DataValue, 0.0, 1E-9\n"
    "DataValue, 0.1, 2E-9\n",
    encoding="utf-8",
)

(SOURCES / "b1500-wgfmu-std.csv").write_text(
    "SetupTitle, STP decay\n"
    "DataName, Time, MeasResult1_value, MeasResult2_value\n"
    "DataValue, 0, 0, 1E-12\n"
    "DataValue, 1E-9, 0.5, 2E-12\n"
    "DataValue, 2E-9, 1.0, 3E-12\n",
    encoding="utf-8",
)

(SOURCES / "b1500-wgfmu-ppf-time.csv").write_text(
    "time_s,current_a\n0,1e-12\n2e-9,3e-12\n1e-9,2e-12\n",
    encoding="utf-8",
)

(SOURCES / "b1500-wgfmu-ppf-index.csv").write_text(
    "index-pulse,current_a\n0,1e-12\n1,2e-12\n",
    encoding="utf-8",
)

wgfmu_large = ["SetupTitle, STP decay", "DataName, Time, MeasResult1_value, MeasResult2_value"]
for i in range(8000):
    t = i * 1e-9
    v1 = (i % 100) * 0.01
    v2 = (i + 1) * 1e-12
    wgfmu_large.append(f"DataValue, {t}, {v1}, {v2}")
(SOURCES / "b1500-wgfmu-large.csv").write_text("\n".join(wgfmu_large) + "\n", encoding="utf-8")

(SOURCES / "acme.cv_run1.txt").write_text(
    "Run, acme-cv-1\nVolts, Amps\n1.0, 10.0\n2.0, 20.0\n\n",
    encoding="utf-8",
)
(SOURCES / "acme.ca_run2.txt").write_text(
    "Run, acme-ca-2\nSecs, mAmps\n0.0, 5.0\n1.0, 6.0\n\n",
    encoding="utf-8",
)
(SOURCES / "acme.rich_run7.txt").write_text(
    "Run, acme-rich-7\nVolts, Amps\n1.0, 10.0\n, \n2.0, NaN\n\n",
    encoding="utf-8",
)

(SOURCES / "generic-fallback.csv").write_text(
    "Meta, generic table\nX, Y\n0, 1\n0.5, 2\n1, 3\n",
    encoding="utf-8",
)

(SOURCES / "filename-v2.csv").write_text(
    "SetupTitle, SYNTH-SPECIFIC-HEADER\n"
    "DataName, V1, I1\n"
    "DataValue, 0, 1E-12\n",
    encoding="utf-8",
)

cases = [
    {
        "id": "keysight-dual-sweep-v1",
        "profile_files": {"keysight-b1500a.yaml": "profiles/keysight-b1500a.yaml"},
        "source_files": {"data/raw/fixture-run/dual-sweep.csv": "sources/dual-sweep.csv"},
        "source_to_load": "data/raw/fixture-run/dual-sweep.csv",
    },
    {
        "id": "keysight-gaps-v1",
        "profile_files": {"keysight-b1500a.yaml": "profiles/keysight-b1500a.yaml"},
        "source_files": {"data/raw/gaps.csv": "sources/gaps.csv"},
        "source_to_load": "data/raw/gaps.csv",
    },
    {
        "id": "keysight-gap-reasons-v1",
        "profile_files": {"keysight-b1500a.yaml": "profiles/keysight-b1500a.yaml"},
        "source_files": {"data/raw/gap-reasons.csv": "sources/gap-reasons.csv"},
        "source_to_load": "data/raw/gap-reasons.csv",
    },
    {
        "id": "keithley-lvm-v2",
        "profile_files": {"keithley-2400.yaml": "profiles/keithley-2400.yaml"},
        "source_files": {"data/raw/sweep.txt": "sources/sweep.txt"},
        "source_to_load": "data/raw/sweep.txt",
    },
    {
        "id": "horiba-raman-tsv-v2",
        "profile_files": {"horiba-labram.yaml": "profiles/horiba-labram.yaml"},
        "source_files": {"data/raw/sers.txt": "sources/sers.txt"},
        "source_to_load": "data/raw/sers.txt",
    },
    {
        "id": "horiba-raman-semicolon-v2",
        "profile_files": {"horiba-labram.yaml": "profiles/horiba-labram.yaml"},
        "source_files": {"data/raw/characterization.txt": "sources/raman-semicolon.txt"},
        "source_to_load": "data/raw/characterization.txt",
    },
    {
        "id": "b1500-dual-sweep-v2",
        "profile_files": {"keysight-b1500a.yaml": "profiles/keysight-b1500a-v2.yaml"},
        "source_files": {
            "data/raw/keysight-b1500a.dual-sweep_one.csv": "sources/b1500-dual-sweep.csv"
        },
        "source_to_load": "data/raw/keysight-b1500a.dual-sweep_one.csv",
    },
    {
        "id": "b1500-list-sweep-v2",
        "profile_files": {"keysight-b1500a.yaml": "profiles/keysight-b1500a-v2.yaml"},
        "source_files": {
            "data/raw/keysight-b1500a.list-sweep_one.csv": "sources/b1500-list-sweep.csv"
        },
        "source_to_load": "data/raw/keysight-b1500a.list-sweep_one.csv",
    },
    {
        "id": "b1500-wgfmu-std-v2",
        "profile_files": {"keysight-b1500a.yaml": "profiles/keysight-b1500a-v2.yaml"},
        "source_files": {
            "data/raw/keysight-b1500a.wgfmu_std.csv": "sources/b1500-wgfmu-std.csv"
        },
        "source_to_load": "data/raw/keysight-b1500a.wgfmu_std.csv",
    },
    {
        "id": "b1500-wgfmu-ppf-time-v2",
        "profile_files": {"keysight-b1500a.yaml": "profiles/keysight-b1500a-v2.yaml"},
        "source_files": {
            "data/raw/keysight-b1500a.wgfmu_ppf-time.csv": "sources/b1500-wgfmu-ppf-time.csv"
        },
        "source_to_load": "data/raw/keysight-b1500a.wgfmu_ppf-time.csv",
    },
    {
        "id": "b1500-wgfmu-ppf-index-v2",
        "profile_files": {"keysight-b1500a.yaml": "profiles/keysight-b1500a-v2.yaml"},
        "source_files": {
            "data/raw/keysight-b1500a.wgfmu_ppf-index.csv": "sources/b1500-wgfmu-ppf-index.csv"
        },
        "source_to_load": "data/raw/keysight-b1500a.wgfmu_ppf-index.csv",
    },
    {
        "id": "b1500-wgfmu-large-v2",
        "profile_files": {"keysight-b1500a.yaml": "profiles/keysight-b1500a-v2.yaml"},
        "source_files": {
            "data/raw/keysight-b1500a.wgfmu_large.csv": "sources/b1500-wgfmu-large.csv"
        },
        "source_to_load": "data/raw/keysight-b1500a.wgfmu_large.csv",
    },
    {
        "id": "v3-acme-cv",
        "grammar_file": "grammar/electrochem.yaml",
        "profile_files": {"acme-v3.yaml": "profiles/acme-v3.yaml"},
        "source_files": {"data/raw/acme.cv_run1.txt": "sources/acme.cv_run1.txt"},
        "source_to_load": "data/raw/acme.cv_run1.txt",
    },
    {
        "id": "v3-acme-ca",
        "grammar_file": "grammar/electrochem.yaml",
        "profile_files": {"acme-v3.yaml": "profiles/acme-v3.yaml"},
        "source_files": {"data/raw/acme.ca_run2.txt": "sources/acme.ca_run2.txt"},
        "source_to_load": "data/raw/acme.ca_run2.txt",
    },
    {
        "id": "v3-acme-rich-gaps-v3",
        "grammar_file": "grammar/electrochem.yaml",
        "profile_files": {"acme-v3.yaml": "profiles/acme-v3.yaml"},
        "source_files": {"data/raw/acme.rich_run7.txt": "sources/acme.rich_run7.txt"},
        "source_to_load": "data/raw/acme.rich_run7.txt",
    },
    {
        "id": "generic-table-fallback",
        "profile_files": {},
        "source_files": {"data/raw/generic.csv": "sources/generic-fallback.csv"},
        "source_to_load": "data/raw/generic.csv",
    },
    {
        "id": "filename-selector-v2",
        "profile_files": {"synth.yaml": "profiles/filename-v2.yaml"},
        "source_files": {
            "data/raw/run_synth-token_dual-sweep.csv": "sources/filename-v2.csv"
        },
        "source_to_load": "data/raw/run_synth-token_dual-sweep.csv",
    },
]

(FIX / "manifest.json").write_text(json.dumps({"cases": cases}, indent=2) + "\n", encoding="utf-8")
print(f"Wrote {len(cases)} manifest cases under {FIX}")
