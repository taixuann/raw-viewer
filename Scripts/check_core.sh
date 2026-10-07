#!/bin/sh
# Dependency-free verification gate. In CLT-only environments `swift test` needs
# explicit Swift Testing framework flags; this script compiles and runs the core
# self-check and type-checks the app layer with the plain toolchain.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache="${TMPDIR:-/tmp}/rawview-swift-module-cache"
binary="${TMPDIR:-/tmp}/rawview-core-self-check"
mkdir -p "$cache"
swiftc -module-cache-path "$cache" \
  "$repo_root/Sources/RawViewCore/"*.swift \
  "$repo_root/Scripts/CoreSelfCheck.swift" \
  -o "$binary"
"$binary"
echo "Type-checking app layer..."
swiftc -module-cache-path "$cache" -emit-module -module-name RawViewCore \
  "$repo_root/Sources/RawViewCore/"*.swift \
  -o "$cache/RawViewCore.swiftmodule"
swiftc -module-cache-path "$cache" -I "$cache" -typecheck \
  "$repo_root/Sources/RawViewCore/"*.swift \
  "$repo_root/Sources/RawViewApp/"*.swift
echo "App layer type-check passed"
