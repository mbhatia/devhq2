# DevHQ prototype

A minimal native macOS code editor built with SwiftUI and CodeEditSourceEditor.
The editor includes syntax highlighting, line numbers, code folding, and a minimap.

## Lua customization

DevHQ embeds Lua 5.4 and loads `~/.config/devhq/init.lua` when it starts. A minimal
configuration looks like this:

```lua
local devhq = require "devhq"

devhq.window.set_theme("light") -- "system", "light", or "dark"
devhq.treeview.set_size(300)
```

The `devhq` module follows the same broad separation used by Lite XL:

- `core`: API version, configuration directory, and logging
- `window`: application theme
- `split`: horizontal or vertical pane direction
- `treeview`: visibility and pane size
- `docview`: gutter, minimap, and folding-ribbon visibility

Lua modules below the configuration directory can be loaded normally. For example,
`require "plugins.statusbar"` loads `~/.config/devhq/plugins/statusbar.lua`. See
[`Examples/init.lua`](Examples/init.lua) for a complete starter file. Restart DevHQ
after editing Lua configuration; live plugin reload is not implemented yet.

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
