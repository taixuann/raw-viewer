#!/bin/sh
# swift test is unusable in CLT-only environments (Swift Testing missing); this script is the verification gate.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cache="${TMPDIR:-/tmp}/rawview-swift-module-cache"
binary="${TMPDIR:-/tmp}/rawview-core-self-check"
mkdir -p "$cache"
swiftc -module-cache-path "$cache" \
  "$repo_root/tools/raw-viewer/Sources/RawViewCore/NormalizedMeasurement.swift" \
  "$repo_root/tools/raw-viewer/Sources/RawViewCore/RawSource.swift" \
  "$repo_root/tools/raw-viewer/Sources/RawViewCore/SourceInspection.swift" \
  "$repo_root/tools/raw-viewer/Sources/RawViewCore/SourceGrouping.swift" \
  "$repo_root/tools/raw-viewer/Sources/RawViewCore/SourceFilter.swift" \
  "$repo_root/tools/raw-viewer/Sources/RawViewCore/ReaderClient.swift" \
  "$repo_root/tools/raw-viewer/Scripts/CoreSelfCheck.swift" \
  -o "$binary"
"$binary"
echo "Type-checking app layer..."
swiftc -module-cache-path "$cache" -emit-module -module-name RawViewCore \
  "$repo_root/tools/raw-viewer/Sources/RawViewCore/"*.swift \
  -o "$cache/RawViewCore.swiftmodule"
swiftc -module-cache-path "$cache" -I "$cache" -typecheck \
  "$repo_root/tools/raw-viewer/Sources/RawViewCore/"*.swift \
  "$repo_root/tools/raw-viewer/Sources/RawViewApp/"*.swift
echo "App layer type-check passed"
