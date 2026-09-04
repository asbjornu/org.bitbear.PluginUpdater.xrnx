-- LuaCheck configuration (https://luacheck.readthedocs.io).
-- The `renoise` global is the Renoise API, provided by the host at runtime; it
-- is available to both production sources and the test suite, so it stays in
-- the top-level read_globals.
read_globals = {
  "renoise",
}

-- Vendored third-party libraries: we must not modify them, and their style
-- (globals, legacy patterns) differs from ours, so exclude them from checks.
exclude_files = {
  "lib/LibDeflate.lua",
  "lib/slaxml.lua",
}

-- The test suite (tests/run.lua and tests/spec/*.lua) reads the product modules
-- and shared test helpers as globals, which the runner declares on _G at
-- runtime. Scope them to `tests/**` only so production sources (lib/*.lua) keep
-- the stricter default and accidental undeclared-global reads there are still
-- flagged (the test harness would also catch them at runtime).
files = {
  ["tests/**"] = {
    read_globals = {
      -- Product modules, exposed as globals by the test runner.
      "up_plugin_analysis", "up_matching", "up_preset", "up_xml",
      "up_inventory",   "up_core", "up_zip", "up_swap", "up_scheduler", "up_ui", "up_song_xml",
      -- Shared test helpers, exposed as globals by the test runner.
      "check", "section", "analyze", "candidates_for", "failures", "fixture", "observable",
    },
  },
}
