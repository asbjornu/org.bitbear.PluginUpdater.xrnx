-- LuaCheck configuration (https://luacheck.readthedocs.io).
-- The `renoise` global is the Renoise API, provided by the host at runtime.
-- The test suite (tests/run.lua and tests/spec/*.lua) also reads the product
-- modules and the shared test helpers as globals, which the runner declares on
-- _G at runtime; list them here so LuaCheck does not flag them as undefined.
read_globals = {
  "renoise",
  -- Product modules, exposed as globals by the test runner.
  "up_util", "up_matching", "up_preset", "up_songxml", "up_xml",
  "up_inventory", "up_core", "up_zip", "up_swap", "up_slicer", "up_ui",
  -- Shared test helpers, exposed as globals by the test runner.
  "check", "section", "analyze", "candidates_for", "failures", "fixture", "observable",
}
