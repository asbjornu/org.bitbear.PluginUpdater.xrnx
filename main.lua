local tool_bundle = renoise.tool().bundle_path
package.path = tool_bundle .. "/?.lua;"
            .. tool_bundle .. "/lib/?.lua;"
            .. package.path

local up_ui = require("up_ui")

renoise.tool():add_menu_entry{
  name = "Main Menu:Tools:Plugin Updater",
  invoke = function() up_ui.show_dialog() end,
}

renoise.tool():add_keybinding{
  name = "Global:PluginUpdater:Plugin Updater",
  invoke = function() up_ui.show_dialog() end,
}
