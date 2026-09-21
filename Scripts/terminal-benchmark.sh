#!/bin/sh
# PTY-to-terminal-state benchmark. This deliberately uses /bin/cat through a
# TerminalSession; it does not claim to measure SwiftUI/AppKit display refresh.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixtures=${DEVHQ_TERMINAL_BENCHMARK_FIXTURES:-"$root/.build/terminal-benchmarks"}
threshold=${DEVHQ_TERMINAL_BENCHMARK_MAX_SECONDS:-1}
repeats=${DEVHQ_TERMINAL_BENCHMARK_REPEATS:-3}

python3 "$root/Scripts/generate-terminal-benchmark-fixtures.py" --output "$fixtures"
cd "$root"
exec env \
  DEVHQ_RUN_TERMINAL_BENCHMARKS=1 \
  DEVHQ_TERMINAL_BENCHMARK_FIXTURES="$fixtures" \
  DEVHQ_TERMINAL_BENCHMARK_MAX_SECONDS="$threshold" \
  DEVHQ_TERMINAL_BENCHMARK_REPEATS="$repeats" \
  swift test -c release --jobs 4 --filter TerminalBenchmarkTests
