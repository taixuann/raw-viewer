#!/usr/bin/env python3
"""Generate the small native plot palette from FigRecipe's Nature preset."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
OUTPUT = PACKAGE_ROOT / "Sources/RawViewApp/Resources/NativePlotStyle.json"


def figrecipe_source() -> Path:
    override = os.environ.get("FIGRECIPE_ROOT")
    base = Path(override) if override else PACKAGE_ROOT.parent / "figrecipe"
    return base / "presets/nature-single.yaml"


def render() -> str:
    source = figrecipe_source()
    if not source.is_file():
        raise FileNotFoundError(
            f"FigRecipe Nature preset not found at {source}; "
            "set FIGRECIPE_ROOT to the figrecipe checkout "
            "(default is the old sibling ../figrecipe location)."
        )
    raw = source.read_bytes()
    text = raw.decode("utf-8")
    fonts = re.search(r"(?ms)^fonts:\n(.*?)(?=^\S|\Z)", text)
    palette = re.search(r"(?ms)^colors:\s*\n\s+palette:\n(.*?)(?=^\s+rgb:|^\S|\Z)", text)
    if not fonts or not palette:
        raise ValueError("Nature preset is missing fonts.family or colors.palette")
    family = re.search(r'^\s+family:\s*["\']?([^"\'\n]+)', fonts.group(1), re.M)
    colors = re.findall(r"^\s+-\s+\[(\d+),\s*(\d+),\s*(\d+)\]", palette.group(1), re.M)
    if not family or not colors:
        raise ValueError("Could not read native font or palette from Nature preset")
    payload = {
        "schema_version": 1,
        "source": "figrecipe/presets/nature-single.yaml",
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "font_family": family.group(1).strip(),
        "grid": False,
        "full_box": True,
        "tick_direction": "out",
        "palette_rgb": [[int(v) for v in color] for color in colors],
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        expected = render()
    except FileNotFoundError as error:
        print(str(error))
        return 1
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != expected:
            print("Native style is stale; run Scripts/generate_native_style.py")
            return 1
        print("Native style matches the canonical Nature preset")
        return 0
    OUTPUT.write_text(expected, encoding="utf-8")
    print(f"Wrote {OUTPUT.relative_to(PACKAGE_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
