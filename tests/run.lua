#!/usr/bin/env lua
------------------------------------------------------------------------------
-- Dependency-free test runner for the Plugin Updater tool.
--
-- Runs under any Lua 5.1+ interpreter (CI uses lua5.1 to match Renoise's
-- LuaJIT). It mocks the `renoise` global, loads every module, and exercises the
-- pure logic that can be verified without a live Renoise session: plugin-name
-- analysis, candidate matching (exact + version/name-flexible), preset-name
-- extraction, Song.xml recovery (incl. a real zipped fixture), and the inventory
-- scan wired to a mocked song. Each library file is also compile-checked.
--
-- The test logic itself lives in tests/spec/*.lua (one file per module); this
-- file only sets up the environment, the shared helpers, and loads the specs.
------------------------------------------------------------------------------

-- Resolve the repo root so the suite is location-independent: it must work no
-- matter the current working directory. `arg[0]` can be a relative path, so
-- anchor it to $PWD when needed, normalise separators, then strip the
-- "/tests/run.lua" suffix to reach the repo root.
-- `arg` is a CLI convenience table and may be absent in embedded interpreters,
-- so guard it (type() is safe on nil) for the claimed "any Lua 5.1+" portability.
local src = (type(arg) == "table" and arg[0]) or "."
-- Normalise Windows separators first so the absolute-path checks below work on
-- any platform. An absolute path is Unix-style (^/), a Windows drive path
-- (C:/...), or a UNC share (//server/...); only a relative path is anchored to
-- $PWD, which keeps the runner portable to Windows (Renoise is commonly run there).
src = src:gsub("\\", "/")
if not (src:match("^/") or src:match("^[A-Za-z]:/")) then
  src = (os.getenv("PWD") or ".") .. "/" .. src
end
-- Collapse "/./" segments so the suite still resolves the repo root when it is
-- invoked as e.g. "lua ./tests/run.lua" from a non-root working directory
-- (arg[0] then holds "/abs/path/./tests/run.lua", which the pattern wouldn't
-- otherwise match).
src = src:gsub("/%./", "/")
local root = src:match("(.*)/tests/run%.lua$")
if not root or root == "" then root = "." end
package.path = (root == "." and "" or root .. "/") .. "?.lua;"
  .. (root == "." and "" or root .. "/") .. "lib/?.lua;"
  .. (root == "." and "" or root .. "/") .. "tests/?.lua;"
  .. package.path

-- SLAXML is vendored into lib/ (committed), so it resolves via the lib/?.lua
-- entry already on package.path above; no LuaRocks install or copy step needed.
local ok_slaxml, slaxml_err = pcall(require, "slaxml")
if not ok_slaxml then
  error("slaxml parser not found; expected lib/slaxml.lua to be vendored: "
        .. tostring(slaxml_err), 2)
end

-- Renoise runs tool Lua in strict mode: reading *or writing* any undeclared
-- global is a hard error. The suite must fail the same way, otherwise
-- undeclared-global bugs (e.g. the LibDeflate `LibStub`/`arg` probes) only blow
-- up inside Renoise and never surface here. Enable a matching strict mode. A small
-- allow-list of globals that are *intentionally* created -- the vendored
-- LibDeflate, plus the `renoise`/`LibStub`/`arg` shims this runner provides, the
-- product modules, and the shared test helpers -- is pre-declared so the strict
-- writer only flags genuine accidental global assignments in our own code.
do
  local g = _G
  local declared = {
    LibDeflate = true, LibStub = true, arg = true, luacov = true, renoise = true, unpack = true,
    -- Product modules, exposed as globals so the spec files can use them.
    up_plugin_analysis = true, up_matching = true, up_preset = true, up_song_xml = true,
    up_xml = true, up_inventory = true, up_core = true, up_zip = true,
    up_swap = true, up_scheduler = true, up_ui = true,
    -- Shared test helpers, exposed as globals.
    check = true, section = true, analyze = true, candidates_for = true,
    failures = true, fixture = true, observable = true,
  }
  setmetatable(g, {
    __index = function(_, k)
      if rawget(g, k) ~= nil or declared[k] then return rawget(g, k) end
      error("variable '" .. k .. "' is not declared", 2)
    end,
    __newindex = function(_, k, v)
      if rawget(g, k) == nil and not declared[k] then
        error("assign to undeclared global '" .. k .. "'", 2)
      end
      rawset(g, k, v)
    end,
  })
end
rawset(_G, "LibStub", false)
rawset(_G, "arg", false)

-- Mock the Renoise global. The fixture path is resolved from the script location
-- so the suite runs regardless of the current working directory.
_G.fixture = root .. "/tests/fixtures/sample.xrns"

-- Minimal observable stub: records notifiers so tests can manually "fire" them
-- (Renoise drives these on the app-idle / document events; headless we pump them).
local function observable()
  local nots = {}
  return {
    add_notifier = function(_, fn) nots[fn] = true end,
    remove_notifier = function(_, fn) nots[fn] = nil end,
    _fire = function()
      -- Snapshot keys so notifiers can safely remove themselves during callbacks.
      local fns = {}
      for fn in pairs(nots) do fns[#fns + 1] = fn end
      for _, fn in ipairs(fns) do
        if nots[fn] then fn() end
      end
    end,
  }
end

-- Chainable ViewBuilder stub. Every constructor returns a control object with
-- just the fields/methods up_ui actually touches (height, value, items, active,
-- text, add_child/remove_child), so the UI code runs without a real GUI.
local function control(attrs)
  attrs = attrs or {}
  local c = {}
  for k, v in pairs(attrs) do c[k] = v end
  c._children = {}
  c.height = c.height or 20
  function c:add_child(child) table.insert(self._children, child) end
  function c:remove_child(child)
    for i = #self._children, 1, -1 do
      if self._children[i] == child then table.remove(self._children, i); break end
    end
  end
  return c
end
local vb = setmetatable({}, {
  -- `renoise.ViewBuilder()` yields the factory itself; its methods (`:row`,
  -- `:text`, ...) are what create individual controls.
  __call = function(self) return self end,
  -- Each constructor is invoked as `vb:row{...}` -> row(vb, attrs); swallow the
  -- self argument and build the control from the real attrs table.
  __index = function(_, k)
    if k == "DEFAULT_CONTROL_HEIGHT" then return 20 end
    return function(_, attrs) return control(attrs) end
  end,
})

-- A mock song with a couple of devices, mirroring the inventory scan fixture.
local ui_song = {
  instruments = {
    { name = "Sampler", plugin_properties = { plugin_loaded = false, plugin_device = nil } },
    { name = "Dark Dreams 2", plugin_properties = { plugin_loaded = false, plugin_device = nil } },
    { name = "Healthy", plugin_properties = { plugin_loaded = true, plugin_device = {
        device_path = "/P/ProMB.vst3", name = "VST3: FabFilter Pro-MB",
        active_preset_data = "x", parameters = {} } } },
  },
  tracks = {
    { name = "Master", devices = {
        [1] = { name = "Mixer" },
        [2] = { name = "VST3: FabFilter Pro-MB", device_path = "/P/ProMB.vst3",
                 active_preset_data = "x", parameters = {} } } },
  },
}

-- renoise.tool() must return the SAME object on every call (as it does in
-- Renoise) so the app-idle observable shared by the scan/slicer is stable.
local tool_stub = {
  bundle_path = root .. "/",
  add_menu_entry = function() end,
  add_keybinding = function() end,
  app_idle_observable = observable(),
  app_new_document_observable = observable(),
  app_release_document_observable = observable(),
}

_G.renoise = {
  app = function() return {
    song_filename = _G.fixture,
    show_warning = function() end,
    show_custom_dialog = function(_title, _content) return { visible = true } end,
  } end,
  song = function() return ui_song end,
  tool = function() return tool_stub end,
  ViewBuilder = vb,
}
_G.observable = observable

-- Load every product module once and expose it as a global so the spec files can
-- reference it by its module name.
_G.up_plugin_analysis      = require("up_plugin_analysis")
_G.up_matching  = require("up_matching")
_G.up_preset    = require("up_preset")
_G.up_song_xml   = require("up_song_xml")
_G.up_xml       = require("up_xml") -- pure-Lua XML parser exercised by the xml spec
_G.up_inventory = require("up_inventory")
_G.up_core      = require("up_core") -- loaded so its module is counted in coverage
_G.up_zip       = require("up_zip")
_G.up_swap      = require("up_swap")
_G.up_scheduler = require("up_scheduler") -- pure logic; safe to load headlessly
_G.up_ui = require("up_ui")

-- Shared test helpers ---------------------------------------------------------
_G.failures = 0
function _G.check(cond, msg)
  if cond then
    print("  ok   " .. msg)
  else
    _G.failures = _G.failures + 1
    print("  FAIL " .. msg)
  end
end
function _G.section(name) print("\n== " .. name .. " ==") end

-- Helpers ---------------------------------------------------------------------
function _G.analyze(name, path, proto)
  local a = _G.up_plugin_analysis.analyze_plugin(path, name)
  a.path = path or ""; a.name = name or ""; a.protocol = proto or a.protocol
  return a
end
function _G.candidates_for(old_name, pool, broken)
  return _G.up_matching.find_candidates(pool, {
    analysis = _G.up_plugin_analysis.analyze_plugin(nil, old_name),
    broken = broken or false,
    recovered = broken or false,
    kind = "track",
  })
end

-- Compile-check every library file ------------------------------------------
_G.section("compile-check all sources")
local sources = { "main.lua", "lib/up_core.lua", "lib/up_inventory.lua",
  "lib/up_matching.lua", "lib/up_preset.lua", "lib/up_scheduler.lua",
  "lib/up_song_xml.lua", "lib/up_swap.lua", "lib/up_ui.lua", "lib/up_plugin_analysis.lua",
  "lib/up_zip.lua" }
for _, s in ipairs(sources) do
  local f, err = loadfile(root .. "/" .. s)
  _G.check(f ~= nil, "compiles: " .. s .. (err and (" (" .. err .. ")") or ""))
end

-- Load the per-module spec files (order is not significant; each is
-- self-contained and only depends on the helpers/globals set up above).
require("spec.name_analysis_spec")
require("spec.preset_spec")
require("spec.xml_spec")
require("spec.matching_spec")
require("spec.song_xml_spec")
require("spec.inventory_spec")
require("spec.swap_spec")
require("spec.scheduler_spec")
require("spec.zip_spec")
require("spec.core_spec")
require("spec.interface_spec")

-- ---------------------------------------------------------------------------
print("\n" .. (_G.failures == 0 and "ALL TESTS PASSED" or (_G.failures .. " TEST(S) FAILED")))
os.exit(_G.failures == 0 and 0 or 1)
