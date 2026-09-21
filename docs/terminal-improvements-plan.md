# Terminal improvements validation report

This document records observed evidence for the terminal-improvements branch. It
does not claim timing guarantees outside the configurations measured here.

## Acceptance evidence

| Requirement | Result | Evidence |
| --- | --- | --- |
| Native Ghostty default and Nerd/powerlevel10k glyph coverage | Pass | The app bundles JetBrains Mono regular/bold/italic/bold-italic and a Symbols Nerd Font fallback. In the isolated validation app, CUA observed `U+E0B0`–`U+E0B3`, `U+F013`, `U+F120`, and `U+F0001`, including bold and italic, without tofu. A fresh launch and automatic relaunch retained its isolated name, empty repository state, and worktree. |
| 150 MiB ASCII and Unicode `cat` under 1 s in DevHQ | Pass for the measured configurations | Fresh isolated-app runs at 140x49: ASCII 0.68/0.58/0.57 s; Unicode 0.81/0.80/0.78 s. Each set has three passing runs. |
| Upstream DOOM-fire-zig producer exceeds 500 FPS | Pass | Fresh isolated-app CUA verification at 140x49 showed animated upstream DOOM-fire-zig at 666.49 then 665.38 producer FPS. Ctrl-C through the cleanup wrapper restored a clean primary-shell prompt. This is producer throughput, not display refresh rate. |
| Regression suite | Pass | Release suite: 376 tests, 1 opt-in benchmark skipped, 0 failures (`/tmp/terminal-noop-frozen-suite.log`). |
| Separate app verified with computer use | Pass | `Scripts/launch-terminal-validation.sh` launches release `swift run` with a distinct bundle (`com.github.mbhatia.devhq.terminal-validation`) and isolated state. CUA observations/screenshots reside in the root conversation, not in the repository. |

## Reproduction and benchmark evidence

Measured platform: macOS 26.5.2 on arm64. For commands and constraints, see
[the terminal benchmark guide](../Scripts/TERMINAL_BENCHMARKS.md).

The benchmark uses a real `TerminalSession` PTY path through `/bin/cat`,
terminal-state ingestion, exact byte accounting, and an on-screen EOF marker.
It does not measure AppKit/SwiftUI redraw completion.

| Run | Geometry | ASCII | Unicode | Integrity |
| --- | --- | ---: | ---: | --- |
| Release production PTY, strict 3 repetitions | 80x24 | 0.659121 / 0.703814 / 0.643306 s | 0.867814 / 0.836331 / 0.815658 s | All runs passed with exact expected bytes and visible EOF markers (`/tmp/terminal-noop-frozen-benchmark.log`). |
| Visible isolated app, fresh runs | 140x49 | 0.68 / 0.58 / 0.57 s | 0.81 / 0.80 / 0.78 s | Three complete passes each; timing files `/tmp/devhq-final-gui-*.time`. |

## Fixture provenance and configuration

- Generator: `Scripts/generate-terminal-benchmark-fixtures.py`, SHA-256
  `b8c0fc7a52bd8933840117cba4f07c56ce854712e2538b348da6cb72ee9fa7c9`.
- Fixtures are deterministic and exactly 157,286,400 bytes (150 MiB): ASCII
  SHA-256 `abefdf5a239e990f4ea2ac13de1fbc20eefc446a8a05d48281206d95e183bd0b`;
  mixed-Unicode SHA-256 `b84c1ba6fe10f3f8ab550894df361daa52c59b606a5b9096086ec2fd0bf33061`.
  Unicode includes Latin, Greek, Cyrillic, Arabic, Devanagari, CJK, Hangul,
  emoji, and a combining mark.
- Terminal history: 10,000 lines with a 50 MB native history budget
  (`Sources/TerminalBridge/TerminalBridge.c`).
- Ghostty: bootstrap-pinned at `3c47ca159368eb4a860ffe5333abdf4a85b2767b`
  (`Scripts/bootstrap-ghostty.sh`). `TerminalFontTests` verify packaged font
  registration and powerline/supplementary-plane fallback coverage.
- DOOM-fire source: upstream `const-void/DOOM-fire-zig`, pinned at
  `eb0631b141b5778eefc6f5767bb45f8974c1be71`
  (`Scripts/bootstrap-doom-fire-zig.sh`).

## Historical observations and limitations

The worktree began clean at `9ddad09`. Before the Ghostty engine update, a
parser-only diagnostic at 80x24 measured ASCII 1.611455 s and Unicode 1.870975
s; it bypassed PTY and rendering, so is not an acceptance measurement.

An earlier 80x24 three-repeat PTY invocation had one Unicode outlier of
1.016616 s (other runs 0.829825 s and 0.814010 s;
`/tmp/terminal-final-reviewed-benchmark.log`), with no proven cause. Earlier
127x49 GUI slow results (Unicode 2.47 s and 2.62 s) followed DOOM Ctrl-C while
its alternate-screen/margins state remained active. Explicitly restoring the
primary screen, margins, and attributes produced 0.94/0.82/1.58 s before the
final no-op metadata/resize guard; that third result remains unexplained. The
fresh 140x49 results above are the current GUI evidence, but they do not prove
universal performance across window sizes, system load, or terminal state.
