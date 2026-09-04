local tool_bundle = renoise.tool().bundle_path
package.path = tool_bundle .. "/?.lua;"
            .. tool_bundle .. "/lib/?.lua;"
            .. package.path

-- LibDeflate (vendored external dependency) probes for some globals that only
-- exist in a standalone Lua CLI, not in Renoise. Renoise runs Lua in strict mode
-- that errors on any undeclared global read, so we declare these as benign false
-- via rawset (a plain `_G.x = false` would still trip the strict writer, and a
-- nil value would still trip the strict reader). This keeps the dependency
-- unmodified while letting it skip its CLI harness.
rawset(_G, "LibStub", false)
rawset(_G, "arg", false)

local up_ui = require("up_ui")

renoise.tool():add_menu_entry{
  name = "Main Menu:Tools:Plup",
  invoke = function() up_ui.show_dialog() end,
}

renoise.tool():add_keybinding{
  name = "Global:Plup:Plup",
  invoke = function() up_ui.show_dialog() end,
}
