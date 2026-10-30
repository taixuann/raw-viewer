#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
RAWVIEW_WRITE_GOLDENS=1 swift test --filter GoldenMeasurementHarnessTests
