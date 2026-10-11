#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building rawview-index CLI..."
swift build --product rawview-index

CLI=".build/debug/rawview-index"
if [[ ! -x "$CLI" ]]; then
    echo "Error: CLI executable not found at $CLI" >&2
    exit 1
fi

TMP_ROOT=$(mktemp -d -t rawview-cli-test-XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "Running CLI end-to-end tests in $TMP_ROOT..."

# 1. Missing arguments -> exit 2
set +e
"$CLI" 2>/dev/null
STATUS=$?
set -e
if [[ $STATUS -ne 2 ]]; then
    echo "FAIL: Expected exit 2 for missing arguments, got $STATUS" >&2
    exit 1
fi

# 2. Synthetic project without settings and without --data-root -> exit 2
PROJ_A="$TMP_ROOT/proj_a"
mkdir -p "$PROJ_A/data/raw"
cat << 'CSV' > "$PROJ_A/data/raw/f1.csv"
voltage,current
0.1,1.0
0.2,2.0
CSV
cat << 'CSV' > "$PROJ_A/data/raw/f2.csv"
voltage,current
0.3,3.0
0.4,4.0
CSV

set +e
"$CLI" --project "$PROJ_A" 2>/dev/null
STATUS=$?
set -e
if [[ $STATUS -ne 2 ]]; then
    echo "FAIL: Expected exit 2 for unconfigured project, got $STATUS" >&2
    exit 1
fi

# Record initial mtime and sha256 of raw files to verify immutability
F1_HASH=$(shasum -a 256 "$PROJ_A/data/raw/f1.csv" | awk '{print $1}')
F1_MTIME=$(stat -f "%m" "$PROJ_A/data/raw/f1.csv")

# 3. Explicit --data-root with --save-settings -> exit 0, outputs JSON
JSON_OUT=$("$CLI" --project "$PROJ_A" --data-root "data/raw" --save-settings --json)
STATUS=$?
if [[ $STATUS -ne 0 ]]; then
    echo "FAIL: Expected exit 0 for indexing with save-settings, got $STATUS" >&2
    exit 1
fi

# Verify settings file exists
if [[ ! -f "$PROJ_A/.rawviewer/setting.yaml" ]]; then
    echo "FAIL: Settings file was not created by --save-settings" >&2
    exit 1
fi

# Verify raw files were not mutated
F1_HASH_AFTER=$(shasum -a 256 "$PROJ_A/data/raw/f1.csv" | awk '{print $1}')
F1_MTIME_AFTER=$(stat -f "%m" "$PROJ_A/data/raw/f1.csv")
if [[ "$F1_HASH" != "$F1_HASH_AFTER" || "$F1_MTIME" != "$F1_MTIME_AFTER" ]]; then
    echo "FAIL: Raw source file f1.csv was mutated during indexing!" >&2
    exit 1
fi

# 4. Subsequent run using saved settings (no --data-root needed) -> exit 0
"$CLI" --project "$PROJ_A" --json >/dev/null
STATUS=$?
if [[ $STATUS -ne 0 ]]; then
    echo "FAIL: Expected exit 0 when indexing with saved settings, got $STATUS" >&2
    exit 1
fi

# 5. Rebuild run -> exit 0
"$CLI" --project "$PROJ_A" --rebuild --json >/dev/null
STATUS=$?
if [[ $STATUS -ne 0 ]]; then
    echo "FAIL: Expected exit 0 for --rebuild, got $STATUS" >&2
    exit 1
fi

# 6. Unknown flag -> exit 2
set +e
"$CLI" --project "$PROJ_A" --invalid-flag 2>/dev/null
STATUS=$?
set -e
if [[ $STATUS -ne 2 ]]; then
    echo "FAIL: Expected exit 2 for unknown flag, got $STATUS" >&2
    exit 1
fi

# 7. --save-settings without --data-root -> exit 2
set +e
"$CLI" --project "$PROJ_A" --save-settings 2>/dev/null
STATUS=$?
set -e
if [[ $STATUS -ne 2 ]]; then
    echo "FAIL: Expected exit 2 for save-settings without data-root, got $STATUS" >&2
    exit 1
fi

# 8. Escape boundary -> exit 2
set +e
"$CLI" --project "$PROJ_A" --data-root "../outside" 2>/dev/null
STATUS=$?
set -e
if [[ $STATUS -ne 2 ]]; then
    echo "FAIL: Expected exit 2 for boundary escaping data-root, got $STATUS" >&2
    exit 1
fi

echo "All rawview-index CLI checks passed!"
