#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
umask 077
scratch=""
if [ -z "${RAWVIEW_BUILD_DIR:-}" ] || [ -z "${RAWVIEW_APP_PATH:-}" ] || [ -z "${CLANG_MODULE_CACHE_PATH:-}" ]; then
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/RawView-XXXXXX")
fi
build="${RAWVIEW_BUILD_DIR:-$scratch/build}"
app="${RAWVIEW_APP_PATH:-$scratch/RawView.app}"
bundle_id="${RAWVIEW_BUNDLE_ID:-org.taixuann.rawview}"
cache="${CLANG_MODULE_CACHE_PATH:-$scratch/module-cache}"
mkdir -p "$cache"
bin_dir=$(CLANG_MODULE_CACHE_PATH="$cache" swift build --disable-sandbox --scratch-path "$build" --package-path "$root" -c release --show-bin-path)
CLANG_MODULE_CACHE_PATH="$cache" swift build --disable-sandbox --scratch-path "$build" --package-path "$root" -c release
binary="$bin_dir/RawView"
if [ ! -x "$binary" ]; then
  echo "Release executable not found: $binary" >&2
  exit 1
fi
rm -rf -- "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/RawView"
cp "$root/Sources/RawViewApp/Resources/NativePlotStyle.json" "$app/Contents/Resources/NativePlotStyle.json"
if [ -f "$root/Sources/RawViewApp/Resources/AppIcon.icns" ]; then
  cp "$root/Sources/RawViewApp/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi
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
        "CFBundleIconFile": "AppIcon",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }, stream)
PY
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Packaged and verified %s\n' "$app"

if [ "${RAWVIEW_CREATE_DMG:-0}" = "1" ]; then
  dmg_path="${RAWVIEW_DMG_PATH:-${root}/RawView-Installer.dmg}"
  dmg_temp=$(mktemp -d "${TMPDIR:-/tmp}/RawView-DMG-XXXXXX")
  cp -R "$app" "$dmg_temp/"
  ln -s /Applications "$dmg_temp/Applications"
  rm -f "$dmg_path"
  hdiutil create -volname "RawView" -srcfolder "$dmg_temp" -ov -format UDZO "$dmg_path" >/dev/null
  rm -rf "$dmg_temp"
  printf 'Created DMG installer at %s\n' "$dmg_path"
fi
