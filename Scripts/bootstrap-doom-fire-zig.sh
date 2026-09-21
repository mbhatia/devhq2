#!/bin/sh
# Fetches GPL-3.0-only upstream source outside this repository. Provenance:
# https://github.com/const-void/DOOM-fire-zig @ eb0631b141b5778eefc6f5767bb45f8974c1be71
set -eu

revision=eb0631b141b5778eefc6f5767bb45f8974c1be71
destination=${1:-/tmp/DOOM-fire-zig}

if [ ! -d "$destination/.git" ]; then
  git clone https://github.com/const-void/DOOM-fire-zig.git "$destination"
fi
git -C "$destination" fetch --tags origin
git -C "$destination" checkout --detach "$revision"

zig_bin=${ZIG:-}
if [ -z "$zig_bin" ] && [ -x /tmp/zig-aarch64-macos-0.14.1/zig ]; then
  zig_bin=/tmp/zig-aarch64-macos-0.14.1/zig
fi
zig_bin=${zig_bin:-zig}
version=$($zig_bin version)
case "$version" in
  0.14|0.14.*) ;;
  *)
    echo "error: DOOM-fire-zig $revision requires Zig 0.14.x (found $version)" >&2
    exit 1
    ;;
esac

echo "DOOM-fire-zig source: $destination"
echo "revision: $(git -C "$destination" rev-parse HEAD)"
echo "build: (cd $destination && $zig_bin build -Doptimize=ReleaseFast)"
