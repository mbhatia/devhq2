# Terminal benchmark reproduction

Fixtures are exactly **150 MiB** (`157286400` bytes), not decimal MB. They are
created locally and are not committed.

## PTY-to-terminal-state throughput

```sh
Scripts/terminal-benchmark.sh
```

This runs three release-mode repetitions of each fixture through `/bin/cat` in
a real `TerminalSession` PTY. It prints fixture name, exact processed bytes,
terminal geometry, and elapsed seconds. A run passes only when every result is
strictly below one second. This measures PTY ingestion and terminal state, not
SwiftUI/AppKit display refresh.

For diagnostics only, the raw Ghostty parser harness uses the same fixtures at
80x24 with a 10,000-line / 50,000,000-byte history policy. It bypasses PTY, Swift, and
rendering, so it is **not** an acceptance measurement. The core update follows
[Ghostty PR 13220](https://github.com/ghostty-org/ghostty/pull/13220) and
[PR 13226](https://github.com/ghostty-org/ghostty/pull/13226); retain this
policy when comparing parser-only results.

## DOOM-fire producer measurement

```sh
Scripts/prepare-doom-fire-benchmark.sh
Scripts/launch-terminal-validation.sh
```

In the separately named validation app, create a terminal tab, resize it, then
run `/tmp/devhq-doom-validation.sh`. Record its initial `Screen size`
(columns × rows) and the stabilized in-terminal FPS value. Pass only if that
**producer** FPS is greater than 500. It is not display-refresh FPS.

The preparer fetches GPL-3.0-only upstream `const-void/DOOM-fire-zig` at
`eb0631b141b5778eefc6f5767bb45f8974c1be71`. It requires Zig 0.14.x; use
`ZIG=/path/to/zig-0.14 Scripts/prepare-doom-fire-benchmark.sh` when the
provided `/tmp` toolchain is unavailable.
