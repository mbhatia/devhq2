local devhq = require "devhq"

-- Loaded from ~/.config/devhq/init.lua when DevHQ starts.
devhq.window.theme = "light"
devhq.treeview.size = 300
devhq.fonts.ui = "Avenir Next"
devhq.fonts.code = "MartianMonoNFM"
devhq.fonts.terminal = "MartianMonoNFM"

-- Key bindings use Lite XL-shaped modifier+key strings and command IDs.
local keymap = require "keymap"
keymap.add {
  ["cmd+option+t"] = "terminal:toggle-drawer",
}

-- Register a Lua command before binding it.
local command = require "command"
command.add("user:toggle-theme", nil, function()
  devhq.window.theme = devhq.window.theme == "dark" and "light" or "dark"
end)
keymap.add {
  ["cmd+option+d"] = "user:toggle-theme",
}

devhq.core.log("Loaded user configuration")
