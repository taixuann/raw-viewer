#!/usr/bin/env python3
"""Write fixture copies and placeholder golden JSON for the Swift harness.

Golden bytes should match `NormalizedMeasurementGoldenEncoder` on macOS. When
Swift output drifts, run:

  RAWVIEW_WRITE_GOLDENS=1 swift test --filter GoldenMeasurementHarnessTests
"""
from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "core/tests/fixtures"
GOLDEN = ROOT / "core/tests/golden"


def swift_capitalized(text: str) -> str:
    words = text.split(" ")
    out: list[str] = []
    for word in words:
        if not word:
            out.append(word)
            continue
        out.append(word[0].upper() + word[1:].lower())
    return " ".join(out)


def meta_label(key: str) -> str:
    return swift_capitalized(key.replace("_", " "))


def f64bits(value: float) -> str:
    return struct.pack("<d", float(value)).hex()


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def meta_field(key: str, value, kind: str, unit: str | None = None) -> dict:
    field = {
        "key": key,
        "kind": kind,
        "label": meta_label(key),
        "value": value,
    }
    if unit is not None:
        field["unit"] = unit
    return field


def channel(
    name: str,
    label: str,
    unit: str,
    quantity: str | None,
    values: list[float | None],
    gap_reasons: list[str | None] | None = None,
) -> dict:
    if gap_reasons is None:
        gap_reasons = [None if v is not None else "unknown" for v in values]
    ch = {
        "gap_reasons": gap_reasons,
        "label": label,
        "name": name,
        "unit": unit,
        "values": [None if v is None else {"bits": f64bits(v)} for v in values],
    }
    if quantity is not None:
        ch["quantity"] = quantity
    return ch


def dump(obj: dict) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode(
        "utf-8"
    )


KEYSIGHT_PROFILE = """schema_version: 1
instrument:
  id: keysight-b1500a
  name: Keysight B1500A Semiconductor Device Parameter Analyzer
  vendor: Keysight Technologies
  model: B1500A
formats:
  - id: csv
    kind: tabular
    extensions: [".csv"]
    delimiter: ","
    encoding: [utf-8, windows-1252, iso-8859-1]
    rows:
      names_prefix: "DataName"
      data_prefix: "DataValue"
    columns:
      voltage:
        header: "V1"
        quantity: voltage
        unit: "V"
        label: "Voltage"
      current:
        header: "I2"
        aliases: ["I1"]
        quantity: current
        unit: "A"
        label: "Current"
modes:
  - id: dual-sweep
    format: csv
    detect: ["2-terminal dual Vsweep", "dual Vsweep"]
    extract:
      x: voltage
      y: [current]
"""

DUAL_SWEEP_CSV = (
    "\ufeffSetupTitle, 2-terminal dual Vsweep\n"
    "ApplicationTest, 2-terminal dual Vsweep, Public\n"
    "Dimension1, 5, 5\n"
    "DataName, V1, I1\n"
    "DataValue, 0, 1E-12\n"
    "DataValue, 0.1, 2E-12\n"
    "DataValue, 0.2, 3E-12\n"
    "DataValue, 0.1, 4E-12\n"
    "DataValue, 0, 5E-12\n"
)

KEITHLEY_PROFILE = """schema_version: 2
instrument:
  id: keithley-2400
  name: Keithley 2400 SourceMeter
formats:
  - id: lvm
    kind: tabular
    extensions: [".txt", ".lvm"]
    delimiter: "\\t"
    rows:
      names_prefix: "X_Value"
      data_prefix: ""
    columns:
      voltage:
        header: "Untitled"
        quantity: voltage
        unit: "V"
        label: "Voltage"
      current:
        header: "Untitled 1"
        quantity: current
        unit: "A"
        label: "Current"
      timestamp:
        header: "Untitled 2"
        quantity: time
        unit: "s"
        label: "Time"
        required: false
modes:
  - id: dual-sweep
    format: lvm
    detect: ["LabVIEW Measurement"]
    extract:
      x: voltage
      y: [current]
"""

LVM_SWEEP = (
    "LabVIEW Measurement\t\n"
    "Writer_Version\t2\n"
    "Separator\tTab\n"
    "***End_of_Header***\t\n"
    "Channels\t3\n"
    "Samples\t4\t4\t4\n"
    "***End_of_Header***\t\t\t\n"
    "X_Value\tUntitled\tUntitled 1\tUntitled 2\tComment\n"
    "\t-0.2\t1.25E-6\t1\n"
    "\t0.15\t2.5E-6\t2\n"
    "\t0.5\t-3.75E-6\t3\n"
    "\t0.85\t5E-6\t4\n\n"
)

HORIBA_PROFILE = """schema_version: 2
instrument:
  id: horiba-labram
  name: Horiba LabRAM HR Evolution Raman Spectrometer
formats:
  - id: tab_comma
    kind: comment-tsv
    extensions: [".txt"]
    delimiter: "\\t"
    decimal: ","
    encoding: [utf-8, windows-1252, iso-8859-1]
    columns:
      wavenumber:
        column_index: 0
        quantity: wavenumber
        unit: "cm-1"
        label: "Raman shift"
      intensity:
        column_index: 1
        quantity: intensity
        unit: "counts"
        label: "Intensity"
  - id: header_semicolon
    kind: tabular
    extensions: [".txt"]
    delimiter: ";"
    rows:
      names_prefix: "raman_shift"
      data_prefix: ""
    columns:
      wavenumber:
        header: "raman_shift"
        quantity: wavenumber
        unit: "cm-1"
        label: "Raman shift"
      intensity:
        header: "intensity"
        quantity: intensity
        unit: "counts"
        label: "Intensity"
modes:
  - id: raman-tsv
    format: tab_comma
    detect: ["#Laser="]
    extract:
      x: wavenumber
      y: [intensity]
  - id: raman-semicolon
    format: header_semicolon
    detect: ["raman_shift;intensity"]
    extract:
      x: wavenumber
      y: [intensity]
"""

RAMAN_TSV = (
    "#Instrument=\tLabRAM HR Evol\n"
    "#Laser=\t532nm\n"
    "#Acq. time (s)=\t5\n"
    "125,500\t3,25\n"
    "126,750\t4,5\n"
    "128,000\tNaN\n\n"
)


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / "profiles").mkdir(exist_ok=True)
    (FIXTURES / "sources").mkdir(exist_ok=True)
    GOLDEN.mkdir(parents=True, exist_ok=True)

    (FIXTURES / "profiles/keysight-b1500a.yaml").write_text(KEYSIGHT_PROFILE, encoding="utf-8")
    (FIXTURES / "profiles/keithley-2400.yaml").write_text(KEITHLEY_PROFILE, encoding="utf-8")
    (FIXTURES / "profiles/horiba-labram.yaml").write_text(HORIBA_PROFILE, encoding="utf-8")
    (FIXTURES / "sources/dual-sweep.csv").write_text(DUAL_SWEEP_CSV, encoding="utf-8")
    (FIXTURES / "sources/sweep.txt").write_text(LVM_SWEEP, encoding="utf-8")
    (FIXTURES / "sources/sers.txt").write_text(RAMAN_TSV, encoding="utf-8")

    manifest = {
        "cases": [
            {
                "id": "keysight-dual-sweep",
                "profile_files": {"keysight-b1500a.yaml": "profiles/keysight-b1500a.yaml"},
                "source_files": {
                    "data/raw/fixture-run/dual-sweep.csv": "sources/dual-sweep.csv"
                },
                "source_to_load": "data/raw/fixture-run/dual-sweep.csv",
            },
            {
                "id": "keithley-lvm",
                "profile_files": {"keithley-2400.yaml": "profiles/keithley-2400.yaml"},
                "source_files": {"data/raw/sweep.txt": "sources/sweep.txt"},
                "source_to_load": "data/raw/sweep.txt",
            },
            {
                "id": "horiba-raman-tsv",
                "profile_files": {"horiba-labram.yaml": "profiles/horiba-labram.yaml"},
                "source_files": {"data/raw/sers.txt": "sources/sers.txt"},
                "source_to_load": "data/raw/sers.txt",
            },
        ]
    }
    (FIXTURES / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )

    profile_hash_k = sha256_hex(KEYSIGHT_PROFILE.encode("utf-8"))
    source_hash_k = sha256_hex(DUAL_SWEEP_CSV.encode("utf-8"))
    keysight = {
        "application_mode": "dual-sweep",
        "channels": [
            channel("voltage", "Voltage", "V", "voltage", [0, 0.1, 0.2, 0.1, 0]),
            channel(
                "current",
                "Current",
                "A",
                "current",
                [1e-12, 2e-12, 3e-12, 4e-12, 5e-12],
            ),
        ],
        "contract_version": 1,
        "instrument": {
            "id": "keysight-b1500a",
            "model": "B1500A",
            "name": "Keysight B1500A Semiconductor Device Parameter Analyzer",
            "vendor": "Keysight Technologies",
        },
        "metadata_sections": [
            {
                "fields": [
                    meta_field("SetupTitle", "2-terminal dual Vsweep", "string"),
                    meta_field(
                        "ApplicationTest", "2-terminal dual Vsweep, Public", "string"
                    ),
                    meta_field("Dimension1", "5, 5", "string"),
                ],
                "title": "Acquisition",
            },
            {
                "fields": [
                    {
                        "key": "filename",
                        "kind": "string",
                        "label": "Filename",
                        "value": "dual-sweep.csv",
                    }
                ],
                "title": "Identity",
            },
            {
                "fields": [
                    {"key": "channel_count", "kind": "number", "label": "Channel count", "value": 2},
                    {"key": "point_count", "kind": "number", "label": "Point count", "value": 5},
                    {"key": "gap_count", "kind": "number", "label": "Gap count", "value": 0},
                ],
                "title": "Data",
            },
        ],
        "provenance": {
            "mode": "dual-sweep",
            "profile_hash": profile_hash_k,
            "profile_id": "keysight-b1500a",
            "profile_schema_version": "1",
            "reader_version": "1.3.0",
        },
        "source": {
            "path": "data/raw/fixture-run/dual-sweep.csv",
            "sha256": source_hash_k,
        },
        "support_status": "supported",
        "view": {
            "kind": "xy",
            "preserve_order": True,
            "x": "voltage",
            "y": ["current"],
        },
        "warnings": [],
    }

    profile_hash_ke = sha256_hex(KEITHLEY_PROFILE.encode("utf-8"))
    source_hash_ke = sha256_hex(LVM_SWEEP.encode("utf-8"))
    keithley = {
        "application_mode": "dual-sweep",
        "channels": [
            channel("voltage", "Voltage", "V", "voltage", [-0.2, 0.15, 0.5, 0.85]),
            channel(
                "current",
                "Current",
                "A",
                "current",
                [1.25e-6, 2.5e-6, -3.75e-6, 5e-6],
            ),
            channel("timestamp", "Time", "s", "time", [1, 2, 3, 4]),
        ],
        "contract_version": 1,
        "instrument": {"id": "keithley-2400", "name": "Keithley 2400 SourceMeter"},
        "metadata_sections": [
            {
                "fields": [
                    meta_field("Writer_Version", "2", "string"),
                    meta_field("Separator", "Tab", "string"),
                    meta_field("Channels", "3", "string"),
                    meta_field("Samples", "4, 4, 4", "string"),
                ],
                "title": "Acquisition",
            },
            {
                "fields": [
                    {
                        "key": "filename",
                        "kind": "string",
                        "label": "Filename",
                        "value": "sweep.txt",
                    }
                ],
                "title": "Identity",
            },
            {
                "fields": [
                    {"key": "channel_count", "kind": "number", "label": "Channel count", "value": 3},
                    {"key": "point_count", "kind": "number", "label": "Point count", "value": 4},
                    {"key": "gap_count", "kind": "number", "label": "Gap count", "value": 0},
                ],
                "title": "Data",
            },
        ],
        "provenance": {
            "mode": "dual-sweep",
            "profile_hash": profile_hash_ke,
            "profile_id": "keithley-2400",
            "profile_schema_version": "2",
            "reader_version": "1.3.0",
        },
        "source": {"path": "data/raw/sweep.txt", "sha256": source_hash_ke},
        "support_status": "supported",
        "view": {
            "kind": "xy",
            "preserve_order": True,
            "x": "voltage",
            "y": ["current"],
        },
        "warnings": [],
    }

    profile_hash_h = sha256_hex(HORIBA_PROFILE.encode("utf-8"))
    source_hash_h = sha256_hex(RAMAN_TSV.encode("utf-8"))
    horiba = {
        "application_mode": "raman-tsv",
        "channels": [
            channel(
                "wavenumber",
                "Raman shift",
                "cm-1",
                "wavenumber",
                [125.5, 126.75, 128.0],
            ),
            channel(
                "intensity",
                "Intensity",
                "counts",
                "intensity",
                [3.25, 4.5, None],
                gap_reasons=[None, None, "nan"],
            ),
        ],
        "contract_version": 1,
        "instrument": {
            "id": "horiba-labram",
            "name": "Horiba LabRAM HR Evolution Raman Spectrometer",
        },
        "metadata_sections": [
            {
                "fields": [
                    meta_field("Instrument", "LabRAM HR Evol", "string"),
                    meta_field("Laser", "532nm", "string"),
                    meta_field("Acq. time (s)", "5", "string"),
                ],
                "title": "Acquisition",
            },
            {
                "fields": [
                    {
                        "key": "filename",
                        "kind": "string",
                        "label": "Filename",
                        "value": "sers.txt",
                    }
                ],
                "title": "Identity",
            },
            {
                "fields": [
                    {"key": "channel_count", "kind": "number", "label": "Channel count", "value": 2},
                    {"key": "point_count", "kind": "number", "label": "Point count", "value": 3},
                    {"key": "gap_count", "kind": "number", "label": "Gap count", "value": 1},
                ],
                "title": "Data",
            },
        ],
        "provenance": {
            "mode": "raman-tsv",
            "profile_hash": profile_hash_h,
            "profile_id": "horiba-labram",
            "profile_schema_version": "2",
            "reader_version": "1.3.0",
        },
        "source": {"path": "data/raw/sers.txt", "sha256": source_hash_h},
        "support_status": "supported",
        "view": {
            "kind": "xy",
            "preserve_order": True,
            "x": "wavenumber",
            "y": ["intensity"],
        },
        "warnings": [],
    }

    (GOLDEN / "keysight-dual-sweep.json").write_bytes(dump(keysight))
    (GOLDEN / "keithley-lvm.json").write_bytes(dump(keithley))
    (GOLDEN / "horiba-raman-tsv.json").write_bytes(dump(horiba))
    print("Wrote fixtures and golden JSON under core/tests/")


if __name__ == "__main__":
    main()
