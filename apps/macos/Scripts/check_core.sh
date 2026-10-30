#!/bin/sh
# Dependency-free verification gate. In CLT-only environments `swift test` needs
# explicit Swift Testing framework flags; this script compiles and runs the core
# self-check and type-checks the app layer with the plain toolchain.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache="${TMPDIR:-/tmp}/rawview-swift-module-cache"
binary="${TMPDIR:-/tmp}/rawview-core-self-check"
mkdir -p "$cache"
core_sources=$(find "$repo_root/Sources/RawViewCore" -name "*.swift")
app_sources=$(find "$repo_root/Sources/RawViewApp" -name "*.swift")

swiftc -module-cache-path "$cache" \
  $core_sources \
  "$repo_root/Scripts/CoreSelfCheck.swift" \
  -o "$binary"
"$binary"
echo "Type-checking app layer..."
swiftc -module-cache-path "$cache" -emit-module -module-name RawViewCore \
  $core_sources \
  -o "$cache/RawViewCore.swiftmodule"
swiftc -module-cache-path "$cache" -I "$cache" -typecheck \
  $core_sources \
  $app_sources
echo "App layer type-check passed"

