# DevHQ prototype

A minimal native macOS code editor built with SwiftUI and CodeEditSourceEditor.
The editor includes syntax highlighting, line numbers, code folding, and a minimap.

## Lua customization

DevHQ embeds Lua 5.4 and loads `~/.config/devhq/init.lua` when it starts. A minimal
configuration looks like this:

```lua
local devhq = require "devhq"

devhq.window.theme = "light" -- "system", "light", or "dark"
devhq.treeview.size = 300
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

### Extending the Lua API

The Swift-facing plugin API uses compile-time macros. Add a module table with
`@LuaModule`, readable table values with `@LuaField`, and callable methods with
`@LuaFunction`:

```swift
@LuaModule("status")
final class LuaStatusAPI {
    @LuaField("api_version")
    let apiVersion = "0.1"

    @LuaField("message")
    var message = ""

    @LuaFunction("format")
    func format(_ text: String, count: Int) -> String {
        "\(text): \(count)"
    }
}
```

The macro generates the `LuaModuleRegistrable` conformance, Lua table creation,
argument decoding, Swift invocation, return-value encoding, and thrown-error
propagation. Method arguments currently support `String`, `Bool`, `Int`, and
`Double`; more types can be added by conforming them to `LuaPluginValue`. Read-only fields
and return values can use any LuaSwift `Pushable` type. A `var` field on a class is
live and writable from Lua when its type conforms to `LuaPluginValue`:

```lua
devhq.status.message = "Building"
print(devhq.status.message)
```

`let` and get-only fields reject Lua assignment. Writable fields require reference
semantics so the macro rejects them on structs.

## Run

```sh
swift run DevHQ
```

Use **Open Folder** to load a workspace, click files in the sidebar to open tabs,
edit in place, and press **Command-S** to save.

## Terminal tabs

DevHQ supports live terminal tabs in the editor area. Press **Control-Shift-`**
or run `terminal:new` from the command palette. Terminals start a login shell in
the active worktree, remain alive while switching worktrees, and terminate when
their tab or DevHQ closes. Terminal tabs are intentionally not restored after an
application restart.

The native VT dependency is built locally and is not committed as a binary. On a
new checkout, initialize the pinned submodule and bootstrap it before building:

```sh
git submodule update --init
./Scripts/bootstrap-ghostty.sh test
```

The bootstrap requires Zig 0.15.2, verifies Ghostty commit
`41ab6c5ab650465dd65c9957ae0a95225e2c1048`, builds
`ghostty-vt.xcframework`, and installs Ghostty's `xterm-ghostty` terminfo data.
Ghostty is licensed under the MIT license; its license is retained at
`Vendor/ghostty/LICENSE`.

For a deterministic demo launch:

```sh
swift run DevHQ --workspace "$PWD" --open Package.swift Sources/DevHQ/ContentView.swift
```

This proof of concept intentionally omits LSP, binary-file handling, and
unsaved-change confirmation. Those belong in later iterations.
