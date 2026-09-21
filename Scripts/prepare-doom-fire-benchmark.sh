#!/bin/sh
# Build the upstream producer. Rendering/FPS is assessed in a DevHQ terminal,
# not by piping output elsewhere (which would not exercise DevHQ's PTY path).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${DOOM_FIRE_ZIG_DIR:-/tmp/DOOM-fire-zig}
zig_bin=${ZIG:-}
if [ -z "$zig_bin" ] && [ -x /tmp/zig-aarch64-macos-0.14.1/zig ]; then
  zig_bin=/tmp/zig-aarch64-macos-0.14.1/zig
fi
zig_bin=${zig_bin:-zig}
export ZIG="$zig_bin"
"$root/Scripts/bootstrap-doom-fire-zig.sh" "$destination"

if ! (cd "$destination" && "$zig_bin" build -Doptimize=ReleaseFast); then
  # Zig 0.14's linker cannot consume some newer Xcode SDKs. Keep upstream
  # source untouched and let Apple's linker resolve the same libc requirement.
  if [ "$(uname)" != Darwin ]; then
    echo "error: upstream build failed; no non-macOS linker fallback exists" >&2
    exit 1
  fi
  sdk=$(xcrun --show-sdk-path)
  mkdir -p "$destination/zig-out/bin"
  "$zig_bin" build-obj "$destination/src/main.zig" -O ReleaseFast -lc \
    -femit-bin="$destination/doom-fire.o"
  xcrun clang -isysroot "$sdk" -Wl,-syslibroot,"$sdk" \
    "$destination/doom-fire.o" -o "$destination/zig-out/bin/DOOM-fire" -lSystem
fi

cat <<EOF
Built $destination/zig-out/bin/DOOM-fire.

To make a valid manual DevHQ measurement:
  1. Launch: Scripts/launch-terminal-validation.sh
  2. Create a terminal tab and resize it before starting DOOM-fire. Record the
     exact columns x rows shown by DOOM-fire's initial "Screen size" line.
  3. Run: /tmp/devhq-doom-validation.sh
  4. Continue through its capability screen, then read its in-terminal
     "[ N.NN fps ]" producer value after the animation has stabilized.
  5. Pass only when the recorded geometry and producer value exceed 500 fps.

The cleanup wrapper preserves DOOM-fire exit status and does not filter its output; on exit or interruption it restores the primary screen, SGR styles, margins, and cursor.

This is producer FPS, not display-refresh FPS. Upstream warns it varies with
terminal geometry, font, monitor, OS, terminal version, and Zig version.
EOF
