#!/usr/bin/env bash
# Pre-push verification: fast local sanity checks before pushing to CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> 1/6 Checking Rust format..."
cargo fmt --check

echo "==> 2/6 Checking Rust clippy..."
cargo clippy --workspace --all-targets -- -D warnings

echo "==> 3/6 Running Rust workspace tests..."
cargo test --workspace

echo "==> 4/6 Running Swift check_core..."
if command -v swift >/dev/null 2>&1; then
  ./apps/macos/Scripts/check_core.sh
fi

echo "==> 5/6 Checking cross-language contract & self-tests..."
if (( BASH_VERSINFO[0] >= 4 )); then
  ./Scripts/check_cross_language_test_contract_self_test.sh
  ./Scripts/check_cross_language_test_contract.sh
else
  echo "==> [Notice] Skipping bash 4+ contract check on host with Bash ${BASH_VERSION} (runs on Ubuntu CI)"
fi

echo "==> 6/6 Checking PR self-tests..."
./Scripts/check_pr_owned_files_self_test.sh
./Scripts/check_pr_acceptance_mapping_self_test.sh

echo "==> All local pre-push checks passed successfully!"
