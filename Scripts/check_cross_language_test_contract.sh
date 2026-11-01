#!/usr/bin/env bash
# Ensures grammar cross-language fixtures and paired Rust/Swift tests stay wired together.
set -euo pipefail

root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
contract="$root/fixtures/grammar/cross_language_contract.yaml"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "$contract" ]] || die "missing contract: $contract"

scalar_after_key() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ": " {
      line = $0
      sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", line)
      gsub(/^'\''|'\''$/, "", line)
      gsub(/^"/, "", line)
      gsub(/"$/, "", line)
      print line
      exit
    }
  ' "$file"
}

nested_scalar() {
  local file="$1"
  local section="$2"
  local key="$3"
  awk -v section="$section" -v key="$key" '
    $0 ~ "^" section ":$" { in_section = 1; next }
    in_section && /^[^[:space:]#]/ && $0 !~ /^  / { in_section = 0 }
    in_section && $0 ~ "^  " key ": " {
      line = $0
      sub(/^  [^:]*:[[:space:]]*/, "", line)
      gsub(/^'\''|'\''$/, "", line)
      print line
      exit
    }
  ' "$file"
}

nested_pair() {
  local file="$1"
  local section="$2"
  local lang="$3"
  local key="$4"
  awk -v section="$section" -v lang="$lang" -v key="$key" '
    $0 ~ "^" section ":$" { in_section = 1; next }
    in_section && /^[^[:space:]#]/ && $0 !~ /^  / { in_section = 0 }
    in_section && $0 ~ "^  " lang ":$" { in_lang = 1; next }
    in_lang && /^  [^ ]/ && $0 !~ /^    / { in_lang = 0 }
    in_lang && $0 ~ "^    " key ": " {
      line = $0
      sub(/^    [^:]*:[[:space:]]*/, "", line)
      print line
      exit
    }
  ' "$file"
}

vectors_file="$(nested_scalar "$contract" "grammar_vectors" "file")"
[[ -n "$vectors_file" ]] || die "grammar_vectors.file is empty"
vectors="$root/fixtures/grammar/$vectors_file"
[[ -f "$vectors" ]] || die "missing vectors file from contract: fixtures/grammar/$vectors_file"

expected_pattern="$(nested_scalar "$contract" "grammar_compile_pattern" "expected_pattern")"
[[ -n "$expected_pattern" ]] || die "grammar_compile_pattern.expected_pattern is empty"

mapfile -t vector_ids < <(grep -E '^  - id: ' "$vectors" | sed 's/^  - id: //')
[[ "${#vector_ids[@]}" -gt 0 ]] || die "vectors file defines no vector ids"

declare -A seen_ids=()
for id in "${vector_ids[@]}"; do
  [[ -n "$id" ]] || die "empty vector id in vectors file"
  if [[ -n "${seen_ids[$id]:-}" ]]; then
    die "duplicate vector id in vectors file: $id"
  fi
  seen_ids["$id"]=1
done

assert_vectors_path_from_contract() {
  local test_file="$1"
  local lang="$2"
  case "$lang" in
    rust)
      grep -q 'value_for_key("grammar_vectors")' "$test_file" || die "$test_file must read grammar_vectors from cross_language_contract.yaml"
      grep -q 'value_for_key("file")' "$test_file" || die "$test_file must read grammar_vectors.file from cross_language_contract.yaml"
      if grep -qE 'join\("vectors\.yaml"\)|fixtures/grammar/vectors\.yaml' "$test_file"; then
        die "$test_file must not hardcode vectors.yaml; use grammar_vectors.file from cross_language_contract.yaml"
      fi
      ;;
    swift)
      grep -q 'value(for: "grammar_vectors")' "$test_file" || die "$test_file must read grammar_vectors from cross_language_contract.yaml"
      grep -q 'value(for: "file")' "$test_file" || die "$test_file must read grammar_vectors.file from cross_language_contract.yaml"
      if grep -q 'appendingPathComponent("fixtures/grammar/vectors.yaml")' "$test_file"; then
        die "$test_file must not hardcode vectors.yaml; use grammar_vectors.file from cross_language_contract.yaml"
      fi
      ;;
    *)
      die "unknown language: $lang"
      ;;
  esac
}

require_consumer() {
  local section="$1"
  local lang="$2"
  local require_contract="$3"
  local test_file rel test_name
  rel="$(nested_pair "$contract" "$section" "$lang" "test_file")"
  test_name="$(nested_pair "$contract" "$section" "$lang" "test_name")"
  [[ -n "$rel" && -n "$test_name" ]] || die "$section.$lang metadata incomplete in contract"
  test_file="$root/$rel"
  [[ -f "$test_file" ]] || die "missing $lang test file: $rel"
  grep -q "$test_name" "$test_file" || die "$rel must define consumer test $test_name"
  if [[ "$section" == "grammar_vectors" ]]; then
    assert_vectors_path_from_contract "$test_file" "$lang"
  fi
  if [[ "$require_contract" == "yes" ]]; then
    grep -q "cross_language_contract.yaml" "$test_file" || die "$rel must load fixtures/grammar/cross_language_contract.yaml"
  fi
}

require_consumer "grammar_vectors" "rust" "no"
require_consumer "grammar_vectors" "swift" "no"
require_consumer "grammar_compile_pattern_tests" "rust" "yes"
require_consumer "grammar_compile_pattern_tests" "swift" "yes"

rust_vectors="$root/$(nested_pair "$contract" "grammar_vectors" "rust" "test_file")"
swift_vectors="$root/$(nested_pair "$contract" "grammar_vectors" "swift" "test_file")"
grep -q 'for case in cases' "$rust_vectors" || die "rust vector consumer must iterate all loaded cases"
grep -q 'for vector in cases' "$swift_vectors" || die "swift vector consumer must iterate all loaded cases"

echo "cross-language grammar contract ok (${#vector_ids[@]} vector ids via $vectors_file, compile pattern pinned)"
