#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
WORK_DIR="${WORK_DIR:-$DIST_DIR/build-installer}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.github.mbhatia.devhq}"
VOLUME_NAME="${VOLUME_NAME:-DevHQ}"
ARCH="${ARCH:-$(uname -m)}"
OUTPUT_DMG="${OUTPUT_DMG:-$DIST_DIR/DevHQ-macos-$ARCH.dmg}"

APP_NAME="DevHQ"
APP_BUNDLE="$WORK_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LEGAL_DIR="$RESOURCES_DIR/legal"
DMG_ROOT="$WORK_DIR/dmg-root"
MOUNT_DIR="$WORK_DIR/mount"
MOUNTED=0

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

usage() {
  cat <<USAGE
Usage: ./build_installer.sh [--stage-only]

Builds a release DevHQ.app and a drag-to-Applications macOS DMG.

Environment overrides:
  VERSION              App version; default: $VERSION
  BUILD_NUMBER         Bundle build number; default: $BUILD_NUMBER
  BUNDLE_IDENTIFIER    Bundle identifier; default: $BUNDLE_IDENTIFIER
  ARCH                 Build architecture; default: $ARCH
  DIST_DIR             Output directory; default: $DIST_DIR
  WORK_DIR             Temporary staging directory; default: $WORK_DIR
  OUTPUT_DMG            DMG output path; default: $OUTPUT_DMG
  VOLUME_NAME          Mounted DMG name; default: $VOLUME_NAME
USAGE
}

STAGE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage-only) STAGE_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || die "macOS is required to build the app and DMG"
case "$ARCH" in
  arm64|x86_64) ;;
  *) die "unsupported ARCH '$ARCH' (expected arm64 or x86_64)" ;;
esac
case "$VERSION" in
  ''|*[!0-9.]*) die "VERSION must contain only digits and periods" ;;
esac
case "$BUILD_NUMBER" in
  ''|*[!0-9]*) die "BUILD_NUMBER must be a positive integer" ;;
esac
[ "$BUILD_NUMBER" -gt 0 ] || die "BUILD_NUMBER must be a positive integer"

need_cmd ditto
need_cmd hdiutil
need_cmd nm
need_cmd otool
need_cmd plutil
need_cmd swift

[ -f "$SCRIPT_DIR/assets/DevHQ.icns" ] || die "missing app icon: assets/DevHQ.icns"
[ -f "$SCRIPT_DIR/assets/Lua-LICENSE.txt" ] || die "missing Lua license: assets/Lua-LICENSE.txt"
[ -f "$SCRIPT_DIR/assets/THIRD-PARTY-NOTICES.md" ] || die "missing third-party notices"
[ -f "$SCRIPT_DIR/LICENSE" ] || die "missing DevHQ license"
[ -f "$SCRIPT_DIR/Vendor/ghostty/LICENSE" ] || die "missing Ghostty license; initialize the Ghostty submodule"
[ -d "$SCRIPT_DIR/ghostty-vt.xcframework" ] || die "missing ghostty-vt.xcframework; run ./Scripts/bootstrap-ghostty.sh"

log "Building release DevHQ for $ARCH..."
swift build --package-path "$SCRIPT_DIR" -c release --arch "$ARCH" --product DevHQ
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c release --arch "$ARCH" --show-bin-path)"
EXECUTABLE="$BIN_DIR/DevHQ"
LUA_SWIFT_LICENSE="$SCRIPT_DIR/.build/checkouts/LuaSwift/LICENSE"

[ -x "$EXECUTABLE" ] || die "release executable was not produced at $EXECUTABLE"
[ -f "$LUA_SWIFT_LICENSE" ] || die "LuaSwift license was not found after resolving dependencies"

if otool -L "$EXECUTABLE" | grep -Ei '(^|[/@])liblua[^/]*\.dylib' >/dev/null; then
  die "DevHQ unexpectedly links an external Lua dynamic library"
fi
if ! nm -gU "$EXECUTABLE" | grep -E '[[:space:]]T[[:space:]]+_luaL_newstate$' >/dev/null; then
  die "the release executable does not contain the statically linked Lua runtime"
fi

rm -rf "$WORK_DIR"
mkdir -p "$MACOS_DIR" "$LEGAL_DIR" "$DMG_ROOT"

log "Assembling $APP_BUNDLE..."
ditto "$EXECUTABLE" "$MACOS_DIR/DevHQ"
chmod 755 "$MACOS_DIR/DevHQ"
ditto "$SCRIPT_DIR/assets/DevHQ.icns" "$RESOURCES_DIR/DevHQ.icns"

# SwiftPM's generated Bundle.module accessors look beside Bundle.main.bundleURL.
# In a native app that is the .app root, not Contents/Resources.
bundle_count=0
while IFS= read -r -d '' resource_bundle; do
  ditto "$resource_bundle" "$APP_BUNDLE/$(basename "$resource_bundle")"
  bundle_count=$((bundle_count + 1))
done < <(find "$BIN_DIR" -maxdepth 1 -type d -name '*.bundle' -print0)
[ "$bundle_count" -gt 0 ] || die "no SwiftPM resource bundles were produced"
[ -d "$APP_BUNDLE/DevHQ_DevHQ.bundle" ] || die "DevHQ resource bundle was not staged at the app root"
[ -d "$APP_BUNDLE/CodeEditLanguages_CodeEditLanguages.bundle" ] || die "CodeEditLanguages resource bundle was not staged at the app root"

ditto "$SCRIPT_DIR/LICENSE" "$LEGAL_DIR/DevHQ-LICENSE.txt"
ditto "$SCRIPT_DIR/assets/Lua-LICENSE.txt" "$LEGAL_DIR/Lua-LICENSE.txt"
ditto "$LUA_SWIFT_LICENSE" "$LEGAL_DIR/LuaSwift-LICENSE.txt"
ditto "$SCRIPT_DIR/Vendor/ghostty/LICENSE" "$LEGAL_DIR/Ghostty-LICENSE.txt"
ditto "$SCRIPT_DIR/assets/THIRD-PARTY-NOTICES.md" "$LEGAL_DIR/THIRD-PARTY-NOTICES.md"
chmod 644 "$RESOURCES_DIR/DevHQ.icns" "$LEGAL_DIR"/*

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>DevHQ</string>
  <key>CFBundleExecutable</key>
  <string>DevHQ</string>
  <key>CFBundleIconFile</key>
  <string>DevHQ.icns</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_IDENTIFIER</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>DevHQ</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

log "Leaving the local development app unsigned."

if [ "$STAGE_ONLY" -eq 1 ]; then
  log "Created staged app: $APP_BUNDLE"
  exit 0
fi

ditto "$APP_BUNDLE" "$DMG_ROOT/DevHQ.app"
ln -s /Applications "$DMG_ROOT/Applications"
mkdir -p "$(dirname "$OUTPUT_DMG")"

log "Creating $OUTPUT_DMG..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  -ov \
  "$OUTPUT_DMG" >/dev/null
hdiutil verify "$OUTPUT_DMG" >/dev/null
mkdir -p "$MOUNT_DIR"
log "Mounting the DMG for final verification..."
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$OUTPUT_DMG" >/dev/null
MOUNTED=1
[ -x "$MOUNT_DIR/DevHQ.app/Contents/MacOS/DevHQ" ] || die "mounted DMG is missing the DevHQ executable"
[ -L "$MOUNT_DIR/Applications" ] || die "mounted DMG is missing the Applications symlink"
[ "$(readlink "$MOUNT_DIR/Applications")" = "/Applications" ] || die "mounted DMG has an invalid Applications symlink"
[ -d "$MOUNT_DIR/DevHQ.app/DevHQ_DevHQ.bundle" ] || die "mounted DMG is missing DevHQ resources"
[ -d "$MOUNT_DIR/DevHQ.app/CodeEditLanguages_CodeEditLanguages.bundle" ] || die "mounted DMG is missing CodeEditLanguages resources"
[ -f "$MOUNT_DIR/DevHQ.app/Contents/Resources/DevHQ.icns" ] || die "mounted DMG is missing the app icon"
for legal_file in DevHQ-LICENSE.txt Ghostty-LICENSE.txt Lua-LICENSE.txt LuaSwift-LICENSE.txt THIRD-PARTY-NOTICES.md; do
  [ -f "$MOUNT_DIR/DevHQ.app/Contents/Resources/legal/$legal_file" ] || die "mounted DMG is missing $legal_file"
done
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=0
log "Created $OUTPUT_DMG"
