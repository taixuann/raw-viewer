#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
build="${RAWVIEW_BUILD_DIR:-/private/tmp/RawView-TAI73-build}"
app="${RAWVIEW_APP_PATH:-/private/tmp/RawView-TAI73.app}"
bundle_id="${RAWVIEW_BUNDLE_ID:-org.taixuann.rawview}"
cache="${CLANG_MODULE_CACHE_PATH:-/private/tmp/RawView-TAI73-module-cache}"
mkdir -p "$cache"
bin_dir=$(CLANG_MODULE_CACHE_PATH="$cache" swift build --disable-sandbox --scratch-path "$build" --package-path "$root/tools/raw-viewer" -c release --show-bin-path)
CLANG_MODULE_CACHE_PATH="$cache" swift build --disable-sandbox --scratch-path "$build" --package-path "$root/tools/raw-viewer" -c release
binary="$bin_dir/RawView"
if [ ! -x "$binary" ]; then
  echo "Release executable not found: $binary" >&2
  exit 1
fi
rm -rf -- "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/RawView"
cp "$root/tools/raw-viewer/Sources/RawViewApp/Resources/NativePlotStyle.json" "$app/Contents/Resources/NativePlotStyle.json"
python3 - "$app/Contents/Info.plist" "$bundle_id" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as stream:
    plistlib.dump({
        "CFBundleExecutable": "RawView",
        "CFBundleIdentifier": sys.argv[2],
        "CFBundleName": "RawView",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }, stream)
PY
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Packaged and verified %s\n' "$app"
