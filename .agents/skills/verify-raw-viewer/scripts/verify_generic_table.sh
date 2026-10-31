#!/usr/bin/env bash
# Linux Rust-core verification for unprofiled delimited CSV (generic table reader).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$REPO_ROOT"

SHA="$(git rev-parse HEAD)"
LOG_DIR="$REPO_ROOT/target/verify"
LOG_PATH="$LOG_DIR/${SHA}.log"
mkdir -p "$LOG_DIR"

PROBE_MANIFEST="$REPO_ROOT/.agents/skills/verify-raw-viewer/probe-generic-table/Cargo.toml"
TEST_CMD=(cargo test -p raw-viewer-core --test generic_table -- --nocapture)
PROBE_CMD=(env CARGO_TARGET_DIR="$REPO_ROOT/target/verify-probe" cargo run -q --manifest-path "$PROBE_MANIFEST")

{
  echo "# verify-raw-viewer proof log"
  echo "git_sha=$SHA"
  echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "platform=linux"
  echo ""
  echo "## integration test"
  echo "command=${TEST_CMD[*]}"
} >"$LOG_PATH"

set +e
TEST_OUT="$("${TEST_CMD[@]}" 2>&1)"
TEST_EXIT=$?
set -e

{
  echo "exit_code=$TEST_EXIT"
  echo "--- output ---"
  echo "$TEST_OUT"
  echo ""
  echo "## measurement fields (probe)"
  echo "command=${PROBE_CMD[*]}"
} >>"$LOG_PATH"

set +e
PROBE_OUT="$("${PROBE_CMD[@]}" 2>&1)"
PROBE_EXIT=$?
set -e

{
  echo "exit_code=$PROBE_EXIT"
  echo "--- output ---"
  echo "$PROBE_OUT"
  echo ""
  echo "## expected key lines"
} >>"$LOG_PATH"

FAIL=0
if [[ $TEST_EXIT -ne 0 ]]; then
  echo "FAIL: integration test exited $TEST_EXIT" >>"$LOG_PATH"
  FAIL=1
fi
if [[ $PROBE_EXIT -ne 0 ]]; then
  echo "FAIL: probe exited $PROBE_EXIT" >>"$LOG_PATH"
  FAIL=1
fi

for line in \
  "instrument=generic-table" \
  "application_mode=table-view" \
  "view_x=col_0" \
  "view_y=[col_1]"; do
  if echo "$PROBE_OUT" | grep -Fq "$line"; then
    echo "ok $line" >>"$LOG_PATH"
  else
    echo "missing $line" >>"$LOG_PATH"
    FAIL=1
  fi
done

if [[ $FAIL -ne 0 ]]; then
  echo "result=FAIL" >>"$LOG_PATH"
  cat "$LOG_PATH"
  exit 1
fi

echo "result=PASS" >>"$LOG_PATH"
cat "$LOG_PATH"
exit 0
