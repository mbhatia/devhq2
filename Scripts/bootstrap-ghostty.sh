#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ghostty="$root/Vendor/ghostty"
required_zig=0.15.2
required_commit=41ab6c5ab650465dd65c9957ae0a95225e2c1048

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

(cd "$ghostty" && zig build \
  --prefix "$ghostty/zig-out" \
  -Demit-lib-vt=true \
  -Demit-xcframework=true \
  -Demit-terminfo=true)

rm -rf "$root/ghostty-vt.xcframework"
cp -R "$ghostty/zig-out/lib/ghostty-vt.xcframework" "$root/ghostty-vt.xcframework"

terminfo="$root/Sources/DevHQ/Resources/terminfo"
rm -rf "$terminfo"
mkdir -p "$terminfo"
cp -R "$ghostty/zig-out/share/terminfo/." "$terminfo/"

case "${1:-build}" in
  build) exec swift build ;;
  test) exec swift test ;;
  *) echo "usage: $0 [build|test]" >&2; exit 2 ;;
esac
