#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$root/Scripts/check_pr_owned_files.sh"
fixtures="$root/Scripts/fixtures/pr_owned_files"

if [[ ! -f "$check" ]]; then
  echo "error: missing $check" >&2
  exit 2
fi

run_case() {
  local name="$1"
  local body="$2"
  local changed="$3"
  local expected="$4"
  set +e
  PR_BODY="$body" CHANGED_FILES="$changed" bash "$check" >/dev/null 2>&1
  local actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    echo "FAIL $name: expected exit $expected, got $actual" >&2
    return 1
  fi
  echo "ok $name exit=$actual"
}

run_case_file() {
  local name="$1"
  local body_file="$2"
  local changed_file="$3"
  local expected="$4"
  set +e
  "$check" "$body_file" "$changed_file" >/dev/null 2>&1
  local actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    echo "FAIL $name: expected exit $expected, got $actual" >&2
    return 1
  fi
  echo "ok $name exit=$actual"
}

fail=0

run_case missing-section "$(cat "$fixtures/missing-owned-section.txt")" $'README.md\n' 1 || fail=1
run_case fenced-only "$(cat "$fixtures/fenced-only.txt")" $'README.md\n' 1 || fail=1
run_case out-of-scope "$(cat "$fixtures/valid-owned.txt")" $'README.md\ncore/src/other.rs\n' 1 || fail=1
run_case exact-match "$(cat "$fixtures/valid-owned.txt")" $'README.md\ncore/src/profile/v4.rs\n' 0 || fail=1
run_case glob-prefix "$(cat "$fixtures/valid-owned.txt")" $'core/tests/golden/foo.json\n' 0 || fail=1
run_case_file crlf-valid "$fixtures/crlf-valid.txt" "$fixtures/changed-allowed.txt" 0 || fail=1
run_case empty-diff "$(cat "$fixtures/valid-owned.txt")" '' 0 || fail=1

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "all owned-files self-test cases passed"
