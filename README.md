# DevHQ prototype

A minimal native macOS code editor built with SwiftUI and AppKit's `NSTextView`.
Syntax highlighting uses CodeEdit's GitHub-hosted language bundle with SwiftTreeSitter.

## Run

```sh
swift run DevHQ
```

Use **Open Folder** to load a workspace, click files in the sidebar to open tabs,
edit in place, and press **Command-S** to save.

For a deterministic demo launch:

```sh
swift run DevHQ --workspace "$PWD" --open Package.swift Sources/DevHQ/ContentView.swift
```

This proof of concept intentionally omits LSP, git worktree switching, file watching,
binary-file handling, and unsaved-change confirmation. Those belong in later iterations.
