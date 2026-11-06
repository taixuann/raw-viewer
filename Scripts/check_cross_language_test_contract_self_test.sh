#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$root/Scripts/check_cross_language_test_contract.sh"

if [[ ! -x "$check" ]]; then
  echo "error: missing executable $check" >&2
  exit 2
fi

run_expect() {
  local name="$1"
  local expected="$2"
  shift 2
  set +e
  "$@"
  local actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    echo "FAIL $name: expected exit $expected, got $actual" >&2
    return 1
  fi
  echo "ok $name exit=$actual"
}

fail=0
run_expect clean 0 "$check" || fail=1

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/fixtures"
cp -a "$root/fixtures/grammar" "$tmpdir/fixtures/grammar"
cp "$check" "$tmpdir/check.sh"
chmod +x "$tmpdir/check.sh"

# Drift: Swift consumer no longer references the shared contract file.
broken_swift="$tmpdir/GrammarVectorTests.swift"
cp "$root/apps/macos/Tests/RawViewCoreTests/GrammarVectorTests.swift" "$broken_swift"
sed -i 's/cross_language_contract.yaml/disconnected_contract.yaml/g' "$broken_swift"
export REPO_ROOT="$tmpdir"
mkdir -p "$tmpdir/apps/macos/Tests/RawViewCoreTests"
cp "$broken_swift" "$tmpdir/apps/macos/Tests/RawViewCoreTests/GrammarVectorTests.swift"
cp "$root/apps/macos/Tests/RawViewCoreTests/ProjectLayoutConfigVectorsTests.swift" "$tmpdir/apps/macos/Tests/RawViewCoreTests/"
cp "$root/apps/macos/Tests/RawViewCoreTests/ProjectLayoutCacheVectorsTests.swift" "$tmpdir/apps/macos/Tests/RawViewCoreTests/"
mkdir -p "$tmpdir/core/tests"
cp "$root/core/tests/grammar_vectors.rs" "$tmpdir/core/tests/grammar_vectors.rs"
cp "$root/core/tests/project_layout_config.rs" "$tmpdir/core/tests/project_layout_config.rs"
cp "$root/core/tests/project_layout_cache.rs" "$tmpdir/core/tests/project_layout_cache.rs"
mkdir -p "$tmpdir/fixtures/config/cases"
cp -a "$root/fixtures/config/." "$tmpdir/fixtures/config/"
run_expect swift-contract-reference-removed 1 "$tmpdir/check.sh" || fail=1
cp "$root/apps/macos/Tests/RawViewCoreTests/GrammarVectorTests.swift" "$tmpdir/apps/macos/Tests/RawViewCoreTests/GrammarVectorTests.swift"
cp "$root/core/tests/grammar_vectors.rs" "$tmpdir/core/tests/grammar_vectors.rs"
cp "$root/core/tests/project_layout_config.rs" "$tmpdir/core/tests/project_layout_config.rs"
cp "$root/core/tests/project_layout_cache.rs" "$tmpdir/core/tests/project_layout_cache.rs"

# Drift: hardcoded vectors.yaml path in Rust (check must fail).
hardcoded_rust="$tmpdir/core/tests/grammar_vectors_hardcoded.rs"
cp "$root/core/tests/grammar_vectors.rs" "$hardcoded_rust"
sed -i 's/grammar_vectors_relative_path_from_contract()/String::from("vectors.yaml")/g' "$hardcoded_rust"
sed -i 's/value_for_key("grammar_vectors")/value_for_key("grammar_vectors_removed")/g' "$hardcoded_rust"
cp "$hardcoded_rust" "$tmpdir/core/tests/grammar_vectors.rs"
run_expect rust-hardcoded-vectors-path 1 "$tmpdir/check.sh" || fail=1
cp "$root/core/tests/grammar_vectors.rs" "$tmpdir/core/tests/grammar_vectors.rs"
cp "$root/core/tests/project_layout_config.rs" "$tmpdir/core/tests/project_layout_config.rs"
cp "$root/core/tests/project_layout_cache.rs" "$tmpdir/core/tests/project_layout_cache.rs"

# Contract points at renamed vectors copy; wiring check must still pass.
cp "$root/apps/macos/Tests/RawViewCoreTests/GrammarVectorTests.swift" "$tmpdir/apps/macos/Tests/RawViewCoreTests/GrammarVectorTests.swift"
cp "$root/apps/macos/Tests/RawViewCoreTests/ProjectLayoutConfigVectorsTests.swift" "$tmpdir/apps/macos/Tests/RawViewCoreTests/"
cp "$root/apps/macos/Tests/RawViewCoreTests/ProjectLayoutCacheVectorsTests.swift" "$tmpdir/apps/macos/Tests/RawViewCoreTests/"
cp "$root/core/tests/grammar_vectors.rs" "$tmpdir/core/tests/grammar_vectors.rs"
cp "$root/core/tests/project_layout_config.rs" "$tmpdir/core/tests/project_layout_config.rs"
cp "$root/core/tests/project_layout_cache.rs" "$tmpdir/core/tests/project_layout_cache.rs"
cp "$tmpdir/fixtures/grammar/vectors.yaml" "$tmpdir/fixtures/grammar/vectors_ci.yaml"
sed -i 's/file: vectors.yaml/file: vectors_ci.yaml/' "$tmpdir/fixtures/grammar/cross_language_contract.yaml"
run_expect contract-renamed-vectors-file 0 "$tmpdir/check.sh" || fail=1

unset REPO_ROOT

# Drift: shared compile pattern in fixture no longer matches compiled engine (Rust test must fail).
contract="$root/fixtures/grammar/cross_language_contract.yaml"
backup="$(mktemp)"
cp "$contract" "$backup"
restore_contract() {
  cp "$backup" "$contract"
  rm -f "$backup"
}
trap 'restore_contract; rm -rf "$tmpdir"' EXIT
sed -i "s/^  expected_pattern: '\\^/  expected_pattern: '^BAD/" "$contract"
set +e
( cd "$root/core" && cargo test shared_grammar_compile_pattern_matches_rust_reference -- --exact )
compile_actual=$?
set -e
if [[ "$compile_actual" -eq 0 ]]; then
  echo "FAIL compile-pattern-drift: expected cargo test failure, got success" >&2
  fail=1
else
  echo "ok compile-pattern-drift cargo test exit=$compile_actual"
fi
restore_contract
trap 'rm -rf "$tmpdir"' EXIT

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "all cross-language contract self-test cases passed"
