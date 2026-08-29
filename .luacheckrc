--[[
  Luacheck configuration for the Plugin Updater Renoise tool.

  The tool runs inside Renoise, whose runtime exposes the `renoise` global
  (and the Renoise Lua API). That global is declared here so Luacheck does not
  raise false "undefined global" warnings, while still catching genuine mistakes
  such as typos in global names or use of undeclared globals.

  The remaining warnings are pre-existing style nits in this codebase that cannot
  be unit-tested outside of Renoise, so they are intentionally ignored to keep
  this check focused on real problems.
--]]

globals = {
  "renoise",
}

ignore = {
  "211", -- unused variable
  "212", -- unused argument
  "213", -- unused loop variable
  "421", -- shadowing upvalue
  "431", -- shadowing definition
  "542", -- empty if branch
  "631", -- line too long
}

-- Vendored third-party library; not part of this project's code.
exclude_files = {
  "lib/LibDeflate.lua",
}
