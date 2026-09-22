#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ghostty="$root/Vendor/ghostty"
required_zig=0.16.0
required_commit=3c47ca159368eb4a860ffe5333abdf4a85b2767b

if ! command -v zig >/dev/null 2>&1; then
  echo "error: Zig $required_zig is required" >&2
  exit 1
fi
actual_zig=$(zig version)
if [ "$actual_zig" != "$required_zig" ]; then
  echo "error: Zig $required_zig is required (found $actual_zig)" >&2
  exit 1
fi
if [ ! -f "$ghostty/build.zig" ]; then
  echo "error: initialize Vendor/ghostty with: git submodule update --init" >&2
  exit 1
fi
actual_commit=$(git -C "$ghostty" rev-parse HEAD)
if [ "$actual_commit" != "$required_commit" ]; then
  echo "error: Vendor/ghostty must be at $required_commit (found $actual_commit)" >&2
  exit 1
fi

# Ghostty does not attach its resource install steps to a lib-vt-only build,
# even when emit-terminfo is enabled. Wire those steps into the pinned build
# without carrying a permanent modification in the submodule.
build_file="$ghostty/build.zig"
build_backup=$(mktemp)
cp "$build_file" "$build_backup"
restore_build_file() {
  cp "$build_backup" "$build_file"
  rm -f "$build_backup"
}
trap restore_build_file EXIT HUP INT TERM
awk '
  { print }
  $0 == "    const resources = try buildpkg.GhosttyResources.init(b, &config, &deps);" {
    print "    if (config.emit_terminfo) resources.install();"
    patched = 1
  }
  END { if (!patched) exit 1 }
' "$build_backup" > "$build_file"

(cd "$ghostty" && zig build \
  --prefix "$ghostty/zig-out" \
  -Doptimize=ReleaseFast \
  -Demit-lib-vt=true \
  -Demit-xcframework=true \
  -Demit-terminfo=true)

restore_build_file
trap - EXIT HUP INT TERM

rm -rf "$root/ghostty-vt.xcframework"
cp -R "$ghostty/zig-out/lib/ghostty-vt.xcframework" "$root/ghostty-vt.xcframework"

terminfo="$root/Sources/DevHQ/Resources/terminfo"
rm -rf "$terminfo"
mkdir -p "$terminfo"
cp -R "$ghostty/zig-out/share/terminfo/." "$terminfo/"

case "${1:-build}" in
  bootstrap) exit 0 ;;
  build) exec swift build ;;
  test) exec swift test ;;
  *) echo "usage: $0 [bootstrap|build|test]" >&2; exit 2 ;;
esac
