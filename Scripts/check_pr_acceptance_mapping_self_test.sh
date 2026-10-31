#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$root/Scripts/check_pr_acceptance_mapping.sh"
fixtures="$root/Scripts/fixtures/pr_acceptance_mapping"

if [[ ! -x "$check" ]]; then
  echo "error: missing executable $check" >&2
  exit 2
fi

run_case() {
  local name="$1"
  local file="$2"
  local expected="$3"
  set +e
  "$check" "$file" >/dev/null 2>&1
  local actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    echo "FAIL $name: expected exit $expected, got $actual" >&2
    return 1
  fi
  echo "ok $name exit=$actual"
}

fail=0
run_case missing "$fixtures/missing.txt" 1 || fail=1
run_case example-only "$fixtures/example-only.txt" 1 || fail=1
run_case fenced-only "$fixtures/fenced-only.txt" 1 || fail=1
run_case crlf-valid "$fixtures/crlf-valid.txt" 0 || fail=1
run_case ascii-arrow-valid "$fixtures/ascii-arrow-valid.txt" 0 || fail=1
run_case valid "$fixtures/valid.txt" 0 || fail=1

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "all acceptance-mapping self-test cases passed"
