# Core Text terminal renderer validation plan

## Scope

Validate the general Core Text terminal renderer with real offscreen Core
Graphics drawing. This is a redraw-cost measurement, not PTY ingestion,
window-server presentation, or end-to-end frame-rate evidence.

The opt-in benchmark will exercise a fixed terminal-sized bitmap for three
workloads:

1. Repeated unchanged snapshots, to expose renderer cache-hit redraw cost.
2. Rows changed with mixed Latin, Arabic, Devanagari, CJK, emoji, combining
   marks, and styled cells, to exercise layout and fallback-font work.
3. DOOM-like high-churn ASCII/color rows, to exercise invalidation and drawing
   under a rapidly changing full grid.

For comparison, the benchmark retains an explicit per-cell `NSAttributedString`
draw path representing the prior renderer. It is a workload comparator only;
it is not a reconstruction of the full historical app.

## Implementation

- `TerminalRendererBenchmarkTests` is opt-in through
  `DEVHQ_RUN_TERMINAL_RENDERER_BENCHMARKS=1`.
- Run it with `DEVHQ_RUN_TERMINAL_RENDERER_BENCHMARKS=1 swift test -c release
  --filter TerminalRendererBenchmarkTests` after the source tree is frozen.
- Each case draws into an `NSBitmapImageRep` graphics context, not a synthetic
  layout-only loop.
- It prints median and per-iteration timing rather than asserting a narrow
  machine-dependent latency threshold.
- Correctness is protected separately by renderer/unit tests; the benchmark
  only verifies that each measured draw completes and reports its result.

## Validation status

- Pre-change package build was attempted with `swift test -c release
  --disable-sandbox --jobs 4 --filter TerminalGlyphLayoutTests`.
- It could not establish a baseline: concurrent bridge work left
  `TerminalSession` expecting `DevHQTerminalCell.codepoint0...7` and
  `codepoint_count` that the imported bridge declaration did not yet expose.
  No timing comparison is claimed from that failed build.
- The final paired post-freeze release benchmark passed. Focused renderer tests
  are reported with their owning implementation change.
- Results must be reported as configuration-specific observations, not Unicode
  coverage or performance guarantees across fonts, window sizes, or system
  load.

## Final paired release observation

The final opt-in release benchmark passed at the fixed 120x40 bitmap workload in
5.039 seconds. Every Core Text value below is paired with the previous
per-cell AppKit drawing shape using the same rows, styles, background fill, and
repetitions in that run.

| Workload | Core Text median | Per-cell median |
| --- | ---: | ---: |
| Unchanged cache-hit rows | 9.105 ms | 36.992 ms |
| Changed multilingual rows | 44.646 ms | 97.855 ms |
| DOOM-like churn | 46.964 ms | 65.765 ms |

The run recorded 678 layout-cache hits, 235 multilingual misses, and 640
DOOM-workload misses. It is a configuration-specific offscreen redraw
observation, not an end-to-end display-frame-rate result or a guarantee across
fonts, window sizes, Unicode content, or system load.

## Final verification

- The frozen-source release suite passed: 390 tests, 2 opt-in skips, and 0
  failures in 47.087 seconds. It includes default-mode ZWJ scalar preservation
  across Ghostty's split cells and mode-2027 clustered-ZWJ coverage.
- The strict production PTY benchmark passed at 80x24 with exact byte counts:
  ASCII 150 MiB took 0.877697 / 0.712413 / 0.760422 s; mixed-Unicode 150 MiB
  took 0.944153 / 0.956774 / 0.848040 s. Each result is below the configured
  one-second limit.
- Final GUI/CUA display verification was unavailable: the native CUA pipe was
  not available in this environment. No claim is made about visible window
  presentation or display-refresh performance from these offscreen and PTY
  results.
