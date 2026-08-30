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
------------------------------------------------------------------------------

-- Resolve the repo root so the suite is location-independent: it must work no
-- matter the current working directory. `arg[0]` can be a relative path, so
-- anchor it to $PWD when needed, normalise separators, then strip the
-- "/tests/run.lua" suffix to reach the repo root.
-- `arg` is a CLI convenience table and may be absent in embedded interpreters,
-- so guard it (type() is safe on nil) for the claimed "any Lua 5.1+" portability.
local src = (type(arg) == "table" and arg[0]) or "."
if not src:match("^/") then
  src = (os.getenv("PWD") or ".") .. "/" .. src
end
src = src:gsub("\\", "/")
local root = src:match("(.*)/tests/run%.lua$")
if not root or root == "" then root = "." end
package.path = (root == "." and "" or root .. "/") .. "lib/?.lua;" .. package.path

-- Renoise runs tool Lua in strict mode: reading *or writing* any undeclared
-- global is a hard error. The suite must fail the same way, otherwise
-- undeclared-global bugs (e.g. the LibDeflate `LibStub`/`arg` probes) only blow
-- up inside Renoise and never surface here. Enable a matching strict mode. A small
-- allow-list of globals that are *intentionally* created -- the vendored
-- LibDeflate, plus the `renoise`/`LibStub`/`arg` shims this runner provides -- is
-- pre-declared so the strict writer only flags genuine accidental global
-- assignments in our own code.
do
  local g = _G
  local declared = { LibDeflate = true, LibStub = true, arg = true, luacov = true, renoise = true }
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
local fixture = root .. "/tests/fixtures/sample.xrns"
_G.renoise = {
  app = function() return { song_filename = fixture } end,
}

local up_util      = require("up_util")
local up_matching  = require("up_matching")
local up_preset    = require("up_preset")
local up_songxml   = require("up_songxml")
local up_inventory = require("up_inventory")
local up_core      = require("up_core") -- loaded so its module is counted in coverage
local up_zip       = require("up_zip")
local up_slicer    = require("up_slicer") -- pure logic; safe to load headlessly

local failures = 0
local function check(cond, msg)
  if cond then
    print("  ok   " .. msg)
  else
    failures = failures + 1
    print("  FAIL " .. msg)
  end
end
local function section(name) print("\n== " .. name .. " ==") end

-- Helpers ---------------------------------------------------------------------
local function analyze(name, path, proto)
  local a = up_util.analyze_plugin(path, name)
  a.path = path or ""; a.name = name or ""; a.protocol = proto or a.protocol
  return a
end
local function candidates_for(old_name, pool, broken)
  return up_matching.find_candidates(pool, {
    analysis = up_util.analyze_plugin(nil, old_name),
    broken = broken or false,
    recovered = broken or false,
    kind = "track",
  })
end

-- 1. Compile-check every library file -----------------------------------------
section("compile-check all sources")
local sources = { "main.lua", "lib/up_core.lua", "lib/up_inventory.lua",
  "lib/up_matching.lua", "lib/up_preset.lua", "lib/up_slicer.lua",
  "lib/up_songxml.lua", "lib/up_swap.lua", "lib/up_ui.lua", "lib/up_util.lua",
  "lib/up_zip.lua" }
for _, s in ipairs(sources) do
  local f, err = loadfile(root .. "/" .. s)
  check(f ~= nil, "compiles: " .. s .. (err and (" (" .. err .. ")") or ""))
end

-- 2. up_util ----------------------------------------------------------------
section("up_util.analyze_plugin")
do
  local a = up_util.analyze_plugin(nil, "AU: Native Instruments: Reaktor5")
  check(a.protocol == "AU", "protocol detected from display name (AU)")
  check(a.base:find("reaktor5") ~= nil, "base keeps version (reaktor5)")
  check(up_util.family_base("native instruments: reaktor 6") == "native instruments: reaktor",
    "family_base strips trailing version")

  local a2 = up_util.analyze_plugin(nil, "VST: Sonic Academy: Kick - Nicky Romero")
  check(a2.base:find("kick") ~= nil and a2.base:find("nicky") ~= nil,
    "base includes artist suffix tokens")
end

section("up_util.token_set / token_subset")
do
  local t1 = up_util.token_set("Sonic Academy: Kick - Nicky Romero")
  check(t1.kick and t1.nicky and t1.romero, "token_set splits significant words (e.g. Kick - Nicky - Romero)")
  local t2 = up_util.token_set("FabFilter Pro-Q 3")
  check(t2["q"], "single-char token 'q' is preserved (Pro-Q)")
  check(up_util.token_subset(up_util.token_set("fabfilter pro mb"),
                             up_util.token_set("fabfilter pro mb")),
    "token_subset: equal sets")
  check(not up_util.token_subset(up_util.token_set("fabfilter pro q"),
                                 up_util.token_set("fabfilter pro mb")),
    "token_subset: Pro-Q not subset of Pro-MB")
end

section("up_util.strip_redundant_prefix")
do
  local a = up_util.analyze_plugin(nil, "AU: Native Instruments: Reaktor5")
  local extra = up_util.strip_redundant_prefix("Reaktor5 Make It Bright", "AU", a)
  check(extra == "Make It Bright", "strips plugin-name tokens, keeps patch name")
end

section("up_util.format_plugin")
do
  check(up_util.format_plugin("VST: Lennardigital Sylenth1", "VST") == "VST: Lennardigital Sylenth1",
    "format_plugin re-emits protocol + name")
end

-- 3. up_preset ----------------------------------------------------------------
section("up_preset.extract_name")
do
  local dev = { active_preset = 3, presets = { "A", "B", "C" },
    active_preset_data = "<PresetName>IgnoreMe</PresetName>" }
  check(up_preset.extract_name(dev) == "C", "returns presets[index] when active_preset set")

  local dev2 = { active_preset_data = "<PresetName>MyPatch</PresetName>" }
  check(up_preset.extract_name(dev2) == "MyPatch", "falls back to <PresetName> in chunk")

  check(up_preset.extract_name(nil) == nil, "nil device -> nil")
end

-- 4. up_matching --------------------------------------------------------------
section("up_matching.candidate_matches (exact)")
do
  local old = up_util.analyze_plugin(nil, "VST3: FabFilter Pro-MB")
  local same = analyze("VST3: FabFilter Pro-MB", "/P/ProMB.vst3", "VST3")
  local diffver = analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3")
  check(up_matching.candidate_matches(same, old), "exact match same product+version")
  check(not up_matching.candidate_matches(diffver, old), "exact rejects different product")
end

section("up_matching.candidate_matches_loose")
do
  local old = up_util.analyze_plugin(nil, "VST: Sonic Academy: Kick - Nicky Romero")
  local kick2 = analyze("VST: Sonic Academy: Kick 2", "/P/Kick2.vst", "VST")
  check(up_matching.candidate_matches_loose(kick2, old), "Kick - Nicky Romero -> Kick 2")

  local oldr = up_util.analyze_plugin(nil, "AU: Native Instruments: Reaktor5")
  local r6 = analyze("Reaktor6", "/P/Reaktor6.app", "AU")
  check(up_matching.candidate_matches_loose(r6, oldr), "Reaktor5 -> Reaktor6 (vendor asymmetry)")

  local pq = analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3")
  check(not up_matching.candidate_matches_loose(pq, oldr), "Reaktor vs Pro-Q: no false match")
end

section("up_matching.find_candidates (exact preferred, loose fallback)")
do
  local poolMB = { analyze("VST3: FabFilter Pro-MB", "/P/ProMB.vst3", "VST3") }
  check(#candidates_for("VST3: FabFilter Pro-MB", poolMB, false) == 1, "exact match used when present")

  local poolReak = { analyze("Reaktor6", "/P/Reaktor6.app", "AU") }
  check(#candidates_for("AU: Native Instruments: Reaktor5", poolReak, true) == 1,
    "missing Reaktor5 -> Reaktor6 (loose, broken)")

  local poolKick = { analyze("VST: Sonic Academy: Kick 2", "/P/Kick2.vst", "VST") }
  check(#candidates_for("VST: Sonic Academy: Kick - Nicky Romero", poolKick, true) == 1,
    "missing Kick-NR -> Kick 2 (loose, broken)")

  -- healthy cross-format / branding: previously not possible
  local poolProMB = { analyze("VST3: FabFilter Pro-MB", "/P/ProMB.vst3", "VST3") }
  check(#candidates_for("AU: FabFilter FF Pro MB", poolProMB, false) == 1,
    "healthy AU 'FF Pro MB' -> VST3 'Pro-MB' (loose fallback)")

  local poolQ = { analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3") }
  check(#candidates_for("AU: FabFilter FF Pro MB", poolQ, false) == 0,
    "FF Pro MB -> Pro-Q 3: no cross-product match")
end

-- 5. up_songxml ---------------------------------------------------------------
section("up_songxml.parse_instruments")
do
  local xml = [[<?xml version="1.0"?>
<Song>
  <Instrument><Name>Sampler Inst</Name></Instrument>
  <Instrument><Name>Dark Dreams 2</Name><PluginGenerator><PluginDevice>
    <PluginType>AU</PluginType>
    <PluginIdentifier>aumu:NiR5:-NI-</PluginIdentifier>
    <PluginDisplayName>AU: Native Instruments: Reaktor5</PluginDisplayName>
    <PluginShortDisplayName>Reaktor5</PluginShortDisplayName>
  </PluginDevice></PluginGenerator></Instrument>
  <Instrument><Name>Kick NR</Name><PluginGenerator><PluginDevice>
    <PluginType>VST</PluginType>
    <PluginIdentifier>Kick - Nicky Romero</PluginIdentifier>
    <PluginDisplayName>VST: Sonic Academy: Kick - Nicky Romero</PluginDisplayName>
  </PluginDevice></PluginGenerator></Instrument>
</Song>]]
  local info = up_songxml.parse_instruments(xml)
  check(info[1] == nil, "sampler (no PluginType) skipped")
  check(info[2] and info[2].display_name == "AU: Native Instruments: Reaktor5",
    "recovered instrument #2 identity")
  check(info[3] and info[3].display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "recovered instrument #3 identity")
end

section("up_songxml.recover (real zipped fixture)")
do
  local info = up_songxml.recover({})
  check(info[2] and info[2].display_name == "AU: Native Instruments: Reaktor5",
    "recover() parses the .xrns fixture")
  check(info[3] and info[3].instrument_name == "Kick NR", "recover() reads instrument <Name>")
end

section("up_zip.extract (pure-Lua zip reader)")
do
  local xml = up_zip.extract(fixture, "Song.xml")
  check(xml ~= nil and xml ~= "", "extracts Song.xml from the .xrns fixture")
  check(xml and xml:find("<Song>") ~= nil, "extracted Song.xml is well-formed XML")
  check(xml and xml:find("PluginDisplayName") ~= nil, "extracted Song.xml has plugin identities")
  local missing = up_zip.extract(fixture, "no-such-entry.xml")
  check(missing == nil, "missing entry returns nil")
end

-- 6. up_inventory.scan (mocked song) ------------------------------------------
section("up_inventory.scan with mocked song + recovered missing plugin")
do
  local mock_song = {
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
  local entries = up_inventory.scan(mock_song, nil, nil, nil)
  check(#entries == 3, "scan produced 3 entries (2 instruments + 1 track)")

  local dd, healthy, track
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "Dark Dreams 2" then dd = e end
    if e.kind == "instrument" and e.instrument_name == "Healthy" then healthy = e end
    if e.kind == "track" then track = e end
  end
  check(dd and dd.broken and dd.recovered, "missing plugin recovered as broken+recovered")
  check(dd and dd.analysis and dd.analysis.base:find("reaktor") ~= nil, "recovered analysis has Reaktor base")
  check(healthy and (not healthy.broken) and healthy.analysis, "healthy plugin scanned normally")
  check(track and track.is_plugin and track.analysis, "track plugin scanned")
end

-- ---------------------------------------------------------------------------
print("\n" .. (failures == 0 and "ALL TESTS PASSED" or (failures .. " TEST(S) FAILED")))
os.exit(failures == 0 and 0 or 1)
