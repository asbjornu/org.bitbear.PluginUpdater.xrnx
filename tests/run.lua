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
  .. (root == "." and "" or root .. "/") .. "lib/?.lua;" .. package.path

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
-- LibDeflate, plus the `renoise`/`LibStub`/`arg` shims this runner provides -- is
-- pre-declared so the strict writer only flags genuine accidental global
-- assignments in our own code.
do
  local g = _G
  local declared = { LibDeflate = true, LibStub = true, arg = true, luacov = true, renoise = true, unpack = true }
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
    song_filename = fixture,
    show_warning = function() end,
    show_custom_dialog = function(_title, _content) return { visible = true } end,
  } end,
  song = function() return ui_song end,
  tool = function() return tool_stub end,
  ViewBuilder = vb,
}

local up_util      = require("up_util")
local up_matching  = require("up_matching")
local up_preset    = require("up_preset")
local up_songxml   = require("up_songxml")
local up_xml       = require("up_xml") -- luacheck: ignore (pure-Lua XML parser exercised below)
local up_inventory = require("up_inventory")
local up_core      = require("up_core") -- luacheck: ignore (loaded so its module is counted in coverage)
local up_zip       = require("up_zip")
local up_swap      = require("up_swap")
local up_slicer    = require("up_slicer") -- luacheck: ignore (pure logic; safe to load headlessly)

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

section("up_util.is_native_path (native namespace, not vendor)")
do
  -- Renoise's built-in devices live under "Native/" (e.g. Audio/Effects/Native/Gainer).
  check(up_util.is_native_path("Audio/Effects/Native/Gainer"), "built-in native device path is native")
  check(up_util.is_native_path("Audio/Instruments/Native/Multi-Sampler"), "native instrument path is native")
  -- The vendor "Native Instruments" must NOT be mistaken for a built-in device,
  -- otherwise every plugin from that vendor (Reaktor, Kontakt, ...) is dropped
  -- from the candidate pool and can never be offered as an upgrade.
  check(not up_util.is_native_path("Native Instruments: Reaktor 6"),
    "vendor 'Native Instruments' is NOT native")
  check(not up_util.is_native_path("/Library/Audio/Plug-Ins/VST/Native Instruments/Reaktor 6.vst"),
    "filesystem path under 'Native Instruments' is NOT native")
  check(not up_util.is_native_path("VST: Native Instruments: Kontakt 7"),
    "display name with 'Native Instruments' is NOT native")
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

  -- Reaktor/Kontakt embed the loaded ensemble as a "file://.../Name.ext" string
  -- inside the opaque preset blob. Renoise returns it as the raw binary at
  -- runtime, and as base64-encoded CDATA in some code paths. The last path
  -- component minus its extension is the preset/ensemble name.
  local raw = "\000\000file://localhost/Users/Shared/Razor/Razor.rkplr\000\000"
  check(up_preset.extract_name({ active_preset_data = raw }) == "Razor",
    "extracts ensemble name from raw blob (file:// URL)")
  local razor_b64 = "AABmaWxlOi8vbG9jYWxob3N0L1VzZXJzL1NoYXJlZC9SYXpvci9SYXpvci5ya3Bscg" ..
    "AA"
  check(up_preset.extract_name({ active_preset_data = razor_b64 }) == "Razor",
    "extracts ensemble name from base64 chunk (file:// URL)")
  local legato_b64 = "AUtvbnRha3QAZmlsZTovLy9TYW1wbGVzL09yY2hlc3RyYS9MZWdhdG8ubmtp" ..
    "AA=="
  check(up_preset.extract_name({ active_preset_data = legato_b64 }) == "Legato",
    "extracts ensemble name from Kontakt-style base64 chunk")

  -- Secondary fallback branches inside active_preset_data.
  check(up_preset.extract_name({ active_preset_data = "<Name>EmbeddedPatch</Name>" }) == "EmbeddedPatch",
    "falls back to <Name> in chunk")
  check(up_preset.extract_name({ active_preset_data = '<device name="InlineName"></device>' }) == "InlineName",
    "falls back to name=\"...\" attribute in chunk")
end

section("up_preset._extract_chunk_name skips binary blobs before decoding")
do
  -- A binary active_preset_data blob (NUL bytes / non-base64 chars) can never carry a
  -- usable file:// URL, so the cheap heuristic must reject it without the expensive
  -- full base64 decode.
  check(up_preset._extract_chunk_name("\000\000\001\002binaryblob\255") == nil,
    "binary blob with NUL bytes is rejected before decoding")
  -- Valid base64 still decodes and yields the embedded ensemble name.
  local razor_b64 = "AABmaWxlOi8vbG9jYWxob3N0L1VzZXJzL1NoYXJlZC9SYXpvci9SYXpvci5ya3Bscg" .. "AA"
  check(up_preset._extract_chunk_name(razor_b64) == "Razor",
    "valid base64 chunk still yields the ensemble name")
  -- A filename with interior dots must keep every dot but the final extension.
  check(up_preset._extract_chunk_name("file:///Shared/My.Ensemble.rkplr") == "My.Ensemble",
    "interior dots are preserved (only the last extension is stripped)")
end

section("up_xml.parse (pure-Lua XML tree)")
do
  -- Validates the tree parser used by up_songxml: nested elements, attributes,
  -- <InstrumentGroup> handling, descendant text, and CDATA.
  local xml = [==[<?xml version="1.0"?>
<Song>
  <InstrumentGroup>
    <Instrument name="a"><PluginType>VST</PluginType><Name>Kick A</Name></Instrument>
    <Instrument name="b"><PluginType>AU</PluginType><Name>Reaktor B</Name></Instrument>
  </InstrumentGroup>
  <Instrument foo="bar"><Name>VST C</Name><PluginType>VST3</PluginType>
    <ParameterChunk preset="x">  <![CDATA[hello]]></ParameterChunk>
  </Instrument>
</Song>]==]
  local doc = up_xml.parse(xml)
  check(doc and doc.tag == "Song", "root element is Song")
  local insts = up_xml.find_all(doc, "Instrument")
  check(#insts == 3, "all <Instrument> found at any depth (group + plain + attributed)")
  check(insts[3].attrs.foo == "bar", "attribute parsed from tag")
  check(insts[1].attrs.name == "a", "attribute parsed (first grouped instrument)")
  check(up_xml.descendant_text(insts[1], "Name") == "Kick A", "descendant text extracted")
  check(up_xml.descendant_cdata(insts[3], "ParameterChunk") == "hello",
    "CDATA extracted despite surrounding whitespace")
end

section("up_xml.parse handles high codepoints and inner-quote attribute values")
do
  -- &#8217; is a curly apostrophe (U+2019), a codepoint > 255 that string.char() would
  -- reject; it must decode to UTF-8 without raising and without aborting the parse.
  local xml = [==[<Song><Name>Don&#8217;t</Name>
    <Instrument name='a "quoted" value'><PluginType>VST</PluginType></Instrument>
  </Song>]==]
  local doc = up_xml.parse(xml)
  check(doc ~= nil, "parses despite a high codepoint entity")
  local name = up_xml.descendant_text(doc, "Name")
  check(name and name:find("&#8217;") == nil and name:find("Don") and name:find("t"),
    "high codepoint entity decoded to UTF-8 (not left raw)")
  local inst = up_xml.find_all(doc, "Instrument")[1]
  check(inst.attrs.name == 'a "quoted" value',
    "attribute value containing the other quote is parsed correctly")
end

section("up_xml.parse (pure-Lua XML tree)")
do
  -- Validates the tree parser used by up_songxml: nested elements, attributes,
  -- <InstrumentGroup> handling, descendant text, and CDATA.
  local xml = [==[<?xml version="1.0"?>
<Song>
  <InstrumentGroup>
    <Instrument name="a"><PluginType>VST</PluginType><Name>Kick A</Name></Instrument>
    <Instrument name="b"><PluginType>AU</PluginType><Name>Reaktor B</Name></Instrument>
  </InstrumentGroup>
  <Instrument foo="bar"><Name>VST C</Name><PluginType>VST3</PluginType>
    <ParameterChunk preset="x">  <![CDATA[hello]]></ParameterChunk>
  </Instrument>
</Song>]==]
  local doc = up_xml.parse(xml)
  check(doc and doc.tag == "Song", "root element is Song")
  local insts = up_xml.find_all(doc, "Instrument")
  check(#insts == 3, "all <Instrument> found at any depth (group + plain + attributed)")
  check(insts[3].attrs.foo == "bar", "attribute parsed from tag")
  check(insts[1].attrs.name == "a", "attribute parsed (first grouped instrument)")
  check(up_xml.descendant_text(insts[1], "Name") == "Kick A", "descendant text extracted")
  check(up_xml.descendant_cdata(insts[3], "ParameterChunk") == "hello",
    "CDATA extracted despite surrounding whitespace")
end

section("up_xml.parse handles high codepoints and inner-quote attribute values")
do
  -- &#8217; is a curly apostrophe (U+2019), a codepoint > 255 that string.char() would
  -- reject; it must decode to UTF-8 without raising and without aborting the parse.
  local xml = [==[<Song><Name>Don&#8217;t</Name>
    <Instrument name='a "quoted" value'><PluginType>VST</PluginType></Instrument>
  </Song>]==]
  local doc = up_xml.parse(xml)
  check(doc ~= nil, "parses despite a high codepoint entity")
  local name = up_xml.descendant_text(doc, "Name")
  check(name and name:find("&#8217;") == nil and name:find("Don") and name:find("t"),
    "high codepoint entity decoded to UTF-8 (not left raw)")
  local inst = up_xml.find_all(doc, "Instrument")[1]
  check(inst.attrs.name == 'a "quoted" value',
    "attribute value containing the other quote is parsed correctly")
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

  -- cross-version upgrade: when both the old and new release are installed the
  -- tool must offer the newer version (not just mirror the old one back).
  local poolProL = {
    analyze("VST: FabFilter Pro-L", "/P/ProL1.vst", "VST"),
    analyze("VST: FabFilter Pro-L 2", "/P/ProL2.vst", "VST"),
  }
  local proL = candidates_for("VST: FabFilter Pro-L", poolProL, false)
  check(#proL == 2, "Pro-L -> [Pro-L, Pro-L 2] both offered")
  check(proL[1].name:find("Pro%-L 2") ~= nil, "Pro-L auto-upgrades to Pro-L 2 (newest first)")

  local poolKickBoth = {
    analyze("VST: Sonic Academy: Kick", "/P/Kick1.vst", "VST"),
    analyze("VST: Sonic Academy: Kick 2", "/P/Kick2.vst", "VST"),
  }
  local kick = candidates_for("VST: Sonic Academy: Kick", poolKickBoth, false)
  check(#kick == 2, "Kick -> [Kick, Kick 2] both offered")
  check(kick[1].name:find("Kick 2") ~= nil, "Kick auto-upgrades to Kick 2 (newest first)")

  -- only the new release installed (old one missing) still matches.
  local newProL = { analyze("VST: FabFilter Pro-L 2", "/P/ProL2.vst", "VST") }
  check(#candidates_for("VST: FabFilter Pro-L", newProL, false) == 1,
    "Pro-L -> Pro-L 2 when only the new release is installed")
  local newKick = { analyze("VST: Sonic Academy: Kick 2", "/P/Kick2.vst", "VST") }
  check(#candidates_for("VST: Sonic Academy: Kick", newKick, false) == 1,
    "Kick -> Kick 2 when only the new release is installed")

  -- fallback when only the live instrument name is known (no .xrns recovery, no
  -- plugin_properties name): the name "Kick - Nicky Romero" shares the significant
  -- product token "kick" with "Kick 2".
  check(#candidates_for("VST: Kick - Nicky Romero ()", newKick, false) == 1,
    "Kick - Nicky Romero (name only) -> Kick 2 via shared token")
  -- same-product upgrade still matches on the shared product token.
  local reaktor = { analyze("Reaktor6", "/P/Reaktor6.app", "AU") }
  check(#candidates_for("VST: Reaktor5 (Make It Bright)", reaktor, false) == 1,
    "Reaktor5 (name only) -> Reaktor6 via shared product token")
  -- but a DIFFERENT product must not match (no shared product token).
  local pq = { analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3") }
  check(#candidates_for("VST: Reaktor5 (Make It Bright)", pq, false) == 0,
    "Reaktor5 (name only) does NOT match Pro-Q 3 (different product)")
end

-- 4b. Instrument pool must keep VST3 plugins whose `info.path` is an opaque UID
-- (no "vst3" token), otherwise they are silently dropped and never surface as a
-- replacement (e.g. "Kick 2" would be missing entirely).
section("up_matching.build_instrument_pool (VST3 opaque paths)")
do
  local vst3_kick = { path = "{A1B2C3D4-0000-0000-0000-000000000000}", name = "Sonic Academy: Kick 2" }
  local vst_pl = { path = "/P/ProL2.vst", name = "FabFilter Pro-L 2" }
  local mock_song = {
    instruments = {
      { plugin_properties = { available_plugin_infos = { vst3_kick, vst_pl } } },
    },
  }
  local pool = up_matching.build_instrument_pool(mock_song, nil, nil)
  local names = {}
  for _, a in ipairs(pool) do names[a.name] = true end
  check(names["Sonic Academy: Kick 2"], "VST3 instrument with opaque path is kept in pool")
  check(names["FabFilter Pro-L 2"], "VST instrument with real path is kept in pool")
  local cands = up_matching.find_candidates(pool,
    { analysis = up_util.analyze_plugin(nil, "Sonic Academy: Kick") })
  check(#cands == 1 and cands[1].name:find("Kick 2") ~= nil,
    "old Kick -> Kick 2 candidate found in instrument pool")
end

-- 4c. Native Instruments plugins (vendor name contains the word "native") must
-- NOT be filtered out of the instrument pool, otherwise Reaktor 6 could never be
-- offered as an upgrade to Reaktor 5. Regression test for the is_native_path
-- false-positive on the "Native Instruments" vendor.
section("up_matching.build_instrument_pool keeps Native Instruments plugins")
do
  local reaktor6_au = { path = "aumuRk6----", name = "Native Instruments: Reaktor 6" }
  local reaktor6_vst3 = { path = "{B2C3D4E5-0000-0000-0000-000000000000}", name = "Reaktor 6" }
  local mock_song = {
    instruments = {
      { plugin_properties = { available_plugin_infos = { reaktor6_au, reaktor6_vst3 } } },
    },
  }
  local pool = up_matching.build_instrument_pool(mock_song, nil, nil)
  local names = {}
  for _, a in ipairs(pool) do names[a.name] = true end
  check(names["Native Instruments: Reaktor 6"], "AU 'Native Instruments: Reaktor 6' kept in pool")
  check(names["Reaktor 6"], "VST3 'Reaktor 6' kept in pool")
   local cands = up_matching.find_candidates(pool,
     { analysis = up_util.analyze_plugin(nil, "AU: Native Instruments: Reaktor5") })
   check(#cands >= 1 and cands[1].name:find("Reaktor 6") ~= nil,
     "Reaktor 5 -> Reaktor 6 offered as upgrade")
end

-- 4c2. available_plugin_infos entries without a loadable path (path nil or "")
-- must be skipped: they cannot be loaded and would otherwise surface as pool
-- candidates whose .path later blows up in pp:load_plugin / insert_device_at.
section("up_matching.build_instrument_pool skips entries without a path")
do
  local good = { path = "/P/ProQ3.vst3", name = "FabFilter Pro-Q 3" }
  local nil_path = { path = nil, name = "Ghost Plugin" }
  local empty_path = { path = "", name = "Also Ghost" }
  local mock_song = {
    instruments = {
      { plugin_properties = { available_plugin_infos = { good, nil_path, empty_path } } },
    },
  }
  local pool = up_matching.build_instrument_pool(mock_song, nil, nil)
  check(#pool == 1, "only the entry with a real path is pooled (nil/empty dropped)")
  check(pool[1] and pool[1].path == "/P/ProQ3.vst3",
    "pooled entry keeps its valid path as the load handle")
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
  -- read_song_xml reads the song path from song().file_name (the real Renoise
  -- property). This previously used non-existent app.song_filename /
  -- song().song_filename, which left recovery empty and dropped every missing
  -- plugin whose instrument name carried no protocol token.
  local info = up_songxml.recover({ file_name = fixture })
  check(info[2] and info[2].display_name == "AU: Native Instruments: Reaktor5",
    "recover() parses the .xrns fixture via song.file_name")
  check(info[3] and info[3].instrument_name == "Kick NR", "recover() reads instrument <Name>")
end

section("up_songxml.recover falls back to app.song_filename")
do
  local info = up_songxml.recover({})
  check(info[2] and info[2].display_name == "AU: Native Instruments: Reaktor5",
    "recover() still works via app.song_filename fallback")
end

section("up_songxml.parse_instruments (attributes, groups, name keys)")
do
  -- Mirrors a real song: a non-plugin (ext. MIDI) instrument, then a plugin
  -- instrument nested in an <InstrumentGroup>, with attribute-bearing tags.
  local xml = [[<?xml version="1.0"?>
<Song>
  <Instrument>
    <Name>MIDI In</Name>
    <InstrumentType>ext. MIDI</InstrumentType>
  </Instrument>
  <InstrumentGroup>
    <Instrument>
      <Name>VST: Kick - Nicky Romero ()</Name>
      <PluginGenerator><PluginDevice>
        <PluginType>VST</PluginType>
        <PluginIdentifier>Kick - Nicky Romero</PluginIdentifier>
        <PluginDisplayName>VST: Sonic Academy: Kick - Nicky Romero</PluginDisplayName>
      </PluginDevice></PluginGenerator>
    </Instrument>
  </InstrumentGroup>
</Song>]]
  local info = up_songxml.parse_instruments(xml)
  check(info[1] == nil, "non-plugin (MIDI) instrument skipped")
  check(info[2] and info[2].display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "plugin inside InstrumentGroup still indexed (idx 2)")
  -- Name-keyed lookups must resolve regardless of index alignment.
  check(info["VST: Kick - Nicky Romero ()"]
    and info["VST: Kick - Nicky Romero ()"].display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "recoverable by live instrument name (index-independent)")
  check(info["VST: Sonic Academy: Kick - Nicky Romero"]
    and info["VST: Sonic Academy: Kick - Nicky Romero"].display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "recoverable by plugin display name")
end

section("up_songxml.parse_instruments treats blank name fields as absent")
do
  -- Empty / self-closing name elements must not defeat the display_name <-> short
  -- fallback, and must never become lookup keys (out[""] would make any blank-name
  -- lookup resolve to an unrelated instrument).
  local xml = [[<?xml version="1.0"?>
<Song>
  <Instrument><Name></Name><PluginGenerator><PluginDevice>
    <PluginType>AU</PluginType>
    <PluginIdentifier />
    <PluginDisplayName/>
    <PluginShortDisplayName>Reaktor5</PluginShortDisplayName>
  </PluginDevice></PluginGenerator></Instrument>
  <Instrument><Name>Kick NR</Name><PluginGenerator><PluginDevice>
    <PluginType>VST</PluginType>
    <PluginDisplayName>VST: Sonic Academy: Kick - Nicky Romero</PluginDisplayName>
    <PluginShortDisplayName>   </PluginShortDisplayName>
  </PluginDevice></PluginGenerator></Instrument>
</Song>]]
  local info = up_songxml.parse_instruments(xml)
  check(info[1] and info[1].display_name == "Reaktor5",
    "empty <PluginDisplayName/> falls back to the short display name")
  check(info[1] and info[1].instrument_name == nil and info[1].identifier == nil,
    "blank <Name> / <PluginIdentifier> are nil, not empty strings")
  check(info[2] and info[2].short_display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "whitespace-only short display name falls back to the display name")
  check(info[""] == nil, "no entry is indexed under an empty-string key")
end

section("up_songxml.parse_instruments recovers Reaktor ensemble (preset) from chunk")
do
  -- Reaktor/Kontakt embed the loaded ensemble as a base64 "file://.../Name.ext"
  -- inside the opaque ParameterChunk. Renoise exposes that name nowhere on the
  -- live API once the plugin fails to load, so it must be lifted from Song.xml.
  local chunk = "cHJlZml4AGZpbGU6Ly8vVXNlcnMvU2hhcmVkL1Jhem9yL1Jhem9yLnJrcGxyAHN1ZmZpeA=="
  local xml = '<?xml version="1.0"?>\n<Song>\n<Instrument>\n<Name>Dark Dreams 1</Name>\n'
    .. '<PluginGenerator><PluginDevice>\n<PluginType>AU</PluginType>\n'
    .. '<PluginIdentifier>aumu:NiR5:-NI-</PluginIdentifier>\n'
    .. '<PluginDisplayName>AU: Native Instruments: Reaktor5</PluginDisplayName>\n'
    .. '<ParameterChunk><![CDATA[' .. chunk .. ']]></ParameterChunk>\n'
    .. '</PluginDevice></PluginGenerator>\n</Instrument>\n</Song>'
  local info = up_songxml.parse_instruments(xml)
  check(info[1] and info[1].preset_name == "Razor",
    "loaded Reaktor ensemble recovered from ParameterChunk (Razor)")
  check(info["Dark Dreams 1"] and info["Dark Dreams 1"].preset_name == "Razor",
    "preset recoverable by live instrument name")
end

section("up_songxml.parse_instruments keeps every instrument inside a group")
do
  -- Regression: <InstrumentGroup> must not swallow the first inner <Instrument>
  -- (the old pattern matched the group as an instrument open and consumed it).
  local xml = [[<?xml version="1.0"?>
<Song>
  <InstrumentGroup>
    <Instrument>
      <Name>VST: Kick - Nicky Romero ()</Name>
      <PluginGenerator><PluginDevice>
        <PluginType>VST</PluginType>
        <PluginIdentifier>Kick - Nicky Romero</PluginIdentifier>
        <PluginDisplayName>VST: Sonic Academy: Kick - Nicky Romero</PluginDisplayName>
      </PluginDevice></PluginGenerator>
    </Instrument>
    <Instrument>
      <Name>AU: Native Instruments: Reaktor5</Name>
      <PluginGenerator><PluginDevice>
        <PluginType>AU</PluginType>
        <PluginDisplayName>AU: Native Instruments: Reaktor5</PluginDisplayName>
      </PluginDevice></PluginGenerator>
    </Instrument>
  </InstrumentGroup>
  <Instrument>
    <Name>Sampler</Name>
    <InstrumentType>Sampler</InstrumentType>
  </Instrument>
</Song>]]
  local info = up_songxml.parse_instruments(xml)
  check(info[1] and info[1].display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "first grouped instrument kept (idx 1)")
  check(info[2] and info[2].display_name == "AU: Native Instruments: Reaktor5",
    "second grouped instrument kept (idx 2, not dropped)")
  check(info["AU: Native Instruments: Reaktor5"],
    "second grouped instrument found by live instrument name")
end

section("up_songxml.parse_instruments recovers preset from attributed/indented chunk")
do
  -- Regression: a real ParameterChunk may carry attributes and leading whitespace
  -- before the CDATA, which the strict match previously failed to recover.
  local chunk = "cHJlZml4AGZpbGU6Ly8vVXNlcnMvU2hhcmVkL1Jhem9yL1Jhem9yLnJrcGxyAHN1ZmZpeA=="
  local xml = '<?xml version="1.0"?>\n<Song>\n<Instrument>\n<Name>Dark Dreams 1</Name>\n'
    .. '<PluginGenerator><PluginDevice>\n<PluginType>AU</PluginType>\n'
    .. '<PluginDisplayName>AU: Native Instruments: Reaktor5</PluginDisplayName>\n'
    .. '<ParameterChunk preset="Razor.rkplr">  <![CDATA[' .. chunk .. ']]></ParameterChunk>\n'
    .. '</PluginDevice></PluginGenerator>\n</Instrument>\n</Song>'
  local info = up_songxml.parse_instruments(xml)
  check(info[1] and info[1].preset_name == "Razor",
    "preset recovered from attributed/indented ParameterChunk")
end

section("up_inventory.scan surfaces missing plugin found by name")
do
  -- The Kick lives at live index 1, but its recovered identity sits at a
  -- different position in Song.xml (a MIDI instrument precedes it). Name-based
  -- lookup must still surface it as a recoverable, broken plugin.
  local mock_song = {
    instruments = {
      { name = "VST: Kick - Nicky Romero ()", plugin_properties = { plugin_loaded = false, plugin_device = nil } },
    },
    tracks = {},
  }
  local recovery = {
    [1] = nil, -- MIDI instrument (no plugin)
    [2] = { index = 2, instrument_name = "VST: Kick - Nicky Romero ()",
            protocol = "VST", identifier = "Kick - Nicky Romero",
            display_name = "VST: Sonic Academy: Kick - Nicky Romero" },
    ["VST: Kick - Nicky Romero ()"] = { index = 2, instrument_name = "VST: Kick - Nicky Romero ()",
            protocol = "VST", identifier = "Kick - Nicky Romero",
            display_name = "VST: Sonic Academy: Kick - Nicky Romero" },
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil, recovery)
  local kick
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "VST: Kick - Nicky Romero ()" then kick = e end
  end
  check(kick ~= nil, "missing Kick surfaced via name-based recovery")
  check(kick and kick.broken and kick.recovered and kick.analysis
    and kick.analysis.base:find("kick") ~= nil, "Kick recovered as broken plugin with analysis")
end

section("up_inventory.scan recovers missing plugin from live plugin_properties")
do
  -- When the .xrns can't be read, Renoise still keeps the plugin name on
  -- plugin_properties for a missing plugin; that must surface the instrument.
  local mock_song = {
    instruments = {
      { name = "VST: Kick - Nicky Romero ()", plugin_properties = {
          plugin_loaded = false, plugin_device = nil,
          plugin_name = "VST: Sonic Academy: Kick - Nicky Romero" } },
    },
    tracks = {},
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil, {})
  local kick
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "VST: Kick - Nicky Romero ()" then kick = e end
  end
  check(kick ~= nil, "missing Kick surfaced via live plugin_name")
  check(kick and kick.analysis and kick.analysis.base:find("kick") ~= nil,
    "Kick analysis derived from live plugin name")
end

section("up_inventory.scan surfaces missing plugin by instrument name (protocol token)")
do
  -- When no .xrns recovery and no plugin_properties name exist, a missing plugin
  -- whose name still carries a protocol token must still be surfaced.
  local mock_song = {
    instruments = {
      { name = "VST: Kick - Nicky Romero ()", plugin_properties = {
          plugin_loaded = false, plugin_device = nil } },
    },
    tracks = {},
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil, {})
  local kick
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "VST: Kick - Nicky Romero ()" then kick = e end
  end
  check(kick ~= nil, "missing Kick surfaced via instrument name")
  check(kick and kick.device_name == "VST: Kick - Nicky Romero ()", "surfaced with its name as identity")
end

section("up_inventory.scan recovers missing AU plugin from song.xml (placeholder path)")
do
  -- When a plugin fails to load, Renoise may keep a placeholder device whose
  -- device_path is an opaque AU 4-char code and whose name is blank. Trusting
  -- that path misidentifies the plugin (e.g. Reaktor5 -> base "ni") so it gets
  -- no candidate and is effectively "not added". The saved song's authoritative
  -- display name + ensemble must win instead.
  local mock_song = {
    instruments = {
      { name = "Dark Dreams 1", plugin_properties = {
          plugin_loaded = false,
          plugin_device = { device_path = "aumu:NiR5:-NI-", name = nil } } },
    },
    tracks = {},
  }
  local recovery = {
    [1] = { index = 1, instrument_name = "Dark Dreams 1",
            protocol = "AU", identifier = "aumu:NiR5:-NI-",
            display_name = "AU: Native Instruments: Reaktor5",
            preset_name = "Razor" },
    ["Dark Dreams 1"] = { index = 1, instrument_name = "Dark Dreams 1",
            protocol = "AU", identifier = "aumu:NiR5:-NI-",
            display_name = "AU: Native Instruments: Reaktor5",
            preset_name = "Razor" },
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil, recovery)
  local dd
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "Dark Dreams 1" then dd = e end
  end
  check(dd ~= nil, "missing AU Reaktor surfaced (not dropped)")
  check(dd and dd.analysis and dd.analysis.base:find("reaktor") ~= nil,
    "recovered from song.xml as Reaktor5 (not the opaque 'aumu:NiR5' path)")
  check(dd and dd.active_preset_name == "Razor",
    "loaded Reaktor ensemble ('Razor') recovered as preset name")
  check(dd and dd.recovered and dd.broken, "marked recovered + broken")
end

section("up_swap.swap_instrument handles missing (unloaded) plugin")
do
  -- A missing plugin has no live device, so captured_auto would be nil; this must
  -- not crash on pairs(nil) in restore_automation_data.
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
  local pp = {
    plugin_loaded = false,
    plugin_device = nil,
    load_plugin = function(self)
      self.plugin_device = new_dev
      return true
    end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "VST: Kick - Nicky Romero ()", analysis = { protocol = "VST" }, device_path = nil,
  }
  local candidate = { path = "/P/Kick2.vst" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  if not ok then print("SWAP ERROR:", tostring(res)) end
  check(ok, "swap_instrument does not crash on a missing plugin")
  check(ok and res and res.status ~= nil, "swap_instrument returns a status for a missing plugin")
end

section("up_swap.swap_instrument skips an already-current plugin")
do
  -- When the auto-selected candidate is the plugin already loaded at an instrument,
  -- reloading it via load_plugin is wasted work and, for heavy synths, can exceed
  -- Renoise's script-time budget and trip the "script busy" watchdog. The swap
  -- must be skipped (status up-to-date) instead of reloading the same plugin.
  local captured_count = 0
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
  local pp = {
    plugin_loaded = true,
    plugin_device = new_dev,
    load_plugin = function(self, _path)
      captured_count = captured_count + 1
      self.plugin_device = new_dev
      return true
    end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "LD SidMon", analysis = { protocol = "VST" }, device_path = "/P/Sylenth1.vst",
  }
  local candidate = { path = "/P/Sylenth1.vst" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok, "swap_instrument handles an already-current plugin")
  check(ok and res and res.status == "up-to-date", "already-current plugin is skipped (no reload)")
  check(captured_count == 0, "load_plugin was NOT called for an already-current plugin")
end

section("up_swap.swap_instrument uses parenthetical label as preset for broken plugins")
do
  -- For a missing/recovered plugin named "VST: Reaktor5 (Make It Bright)", the
  -- parenthetical is the real preset; it must be extracted (not the full identity)
  -- so it can match a factory preset on the replacement plugin.
  local new_dev = {
    is_active = true, active_preset_data = "", presets = { "Make It Bright", "Other" }, parameters = {} }
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "VST: Reaktor5 (Make It Bright)", analysis = { protocol = "VST" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.vst", protocol = "VST" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "broken plugin's parenthetical preset name matches a factory preset")
end

section("upgrade reinspection yields across ticks (no watchdog stall)")
do
  -- Regression for the post-upgrade "script busy" stall: the per-row reinspection
  -- used to run as one synchronous block inside on_done, re-reading every preset
  -- chunk at once. It now lives in the coroutine and yields between rows, so the
  -- work is spread across idle ticks instead of tripping Renoise's time budget.
  local obs = {
    _fn = nil,
    add_notifier = function(self, f) self._fn = f end,
    remove_notifier = function(self) self._fn = nil end,
    _fire = function(self) if self._fn then self._fn() end end,
  }
  local real_tool = _G.renoise.tool
  _G.renoise.tool = function()
    return {
      bundle_path = "", app_idle_observable = obs,
      app_new_document_observable = { add_notifier = function() end, remove_notifier = function() end },
      app_release_document_observable = { add_notifier = function() end, remove_notifier = function() end },
    }
  end
  local phase2 = {}
  local done = false
  up_slicer.run(
    function()
      for _ = 1, 3 do coroutine.yield() end          -- upgrade loop
      for i = 1, 4 do table.insert(phase2, i); coroutine.yield() end  -- reinspection loop
    end,
    function() done = true end,
    function() return false end)
  local ticks = 0
  while obs._fn and ticks < 100 do obs:_fire(); ticks = ticks + 1 end
  check(#phase2 == 4, "reinspection phase ran all iterations inside the coroutine")
  check(done, "the coroutine completed and on_done fired")
  check(ticks > 1, "work was spread over multiple idle ticks (yields), not one block")
  _G.renoise.tool = real_tool
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

section("up_inventory.scan recovers missing plugins via song.file_name")
do
  -- End-to-end regression for the "not all Reaktor devices are added" bug: with
  -- the wrong song-filename property, recovery came back empty and every missing
  -- plugin whose instrument name carried no protocol token (e.g. "Dark Dreams 1")
  -- was dropped. Scanning with song.file_name set must surface them.
  local xml = up_zip.extract(fixture, "Song.xml")
  local recovery = up_songxml.parse_instruments(xml)
  local instruments = {}
  for _, e in pairs(recovery) do
    if type(e) == "table" then
      instruments[e.index] = { name = e.instrument_name,
        plugin_properties = { plugin_loaded = false, plugin_device = nil } }
    end
  end
  local maxi = 0
  for _, e in pairs(recovery) do if type(e) == "table" and e.index > maxi then maxi = e.index end end
  for i = 1, maxi do
    if not instruments[i] then
      instruments[i] = { name = "Sampler " .. i,
        plugin_properties = { plugin_loaded = false, plugin_device = nil } }
    end
  end
  -- recovery left nil so scan() calls up_songxml.recover(song) itself, exercising
  -- the real song.file_name path.
  local mock_song = { file_name = fixture, instruments = instruments, tracks = {} }
  local entries = up_inventory.scan(mock_song, nil, nil, nil)
  local reaktor = 0
  for _, e in ipairs(entries) do
    if (e.analysis and e.analysis.base or ""):find("reaktor") then reaktor = reaktor + 1 end
  end
  check(reaktor >= 1, "Reaktor recovered end-to-end via song.file_name (was dropped before)")
  -- A non-protocol-named missing plugin must also be recovered, not skipped.
  local named
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.analysis and e.analysis.base:find("kick") then named = e end
  end
  check(named ~= nil, "protocol-less missing plugin (Kick) recovered via song.xml")
end

section("up_inventory.scan captures instrument preset name")
do
  -- A plugin instrument with a selected preset (e.g. a Reaktor ensemble) must
  -- expose the preset name + chunk so the UI can show it and carry it over.
  local mock_song = {
    instruments = {
      { name = "Reaktor Inst", plugin_properties = { plugin_loaded = true,
        plugin_device = { device_path = "aumuRk5----", name = "Native Instruments: Reaktor5",
          active_preset = 3, presets = { "Init", "Foo", "Make It Bright" },
          active_preset_data = "<PresetName>Make It Bright</PresetName>", parameters = {} } } },
    },
    tracks = {},
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil)
  local e
  for _, x in ipairs(entries) do if x.kind == "instrument" then e = x end end
  check(e and e.active_preset_name == "Make It Bright",
    "instrument active_preset_name captured from presets[index]")
  check(e and type(e.active_preset_data) == "string" and e.active_preset_data ~= "",
    "instrument active_preset_data captured")
end

-- 7. main.lua + up_ui (headless, mocked Renoise) ------------------------------
-- These two files were previously never loaded by the suite, so Codecov counted
-- them as 0% and dragged the project number down. Loading main.lua (which pulls
-- in up_ui) plus exercising up_ui's pure logic and the full dialog/scan flow
-- with mocked Renoise views gives them real coverage.
section("main.lua loads + up_ui logic (mocked Renoise)")
do
  -- Loading main.lua exercises its top-level (menu/keybinding registration) and
  -- pulls in up_ui; doing so under coverage credits the hitherto-uncovered
  -- entry point. root/?.lua is on package.path so require resolves it through the
  -- same instrumented searcher as the lib files.
  local ok_main, err_main = pcall(require, "main")
  check(ok_main, "main.lua loads under mocked renoise" .. (ok_main and "" or (": " .. tostring(err_main))))

  local up_ui = require("up_ui")

  -- entry_sig / old_label / auto_select_index are local helpers; they are
  -- exercised indirectly below via fill_row/capture_selections, which call them.

  local rec = { kind = "instrument", instrument_name = "Kick NR",
    analysis = up_util.analyze_plugin(nil, "VST: Sonic Academy: Kick - Nicky Romero"),
    device_name = "VST: Sonic Academy: Kick - Nicky Romero" }

  local cands = {
    analyze("VST3: FabFilter Pro-Q 3", "/P/Q.vst3", "VST3"),
    analyze("VST: FabFilter Pro-MB", "/P/MB.vst", "VST"),
  }

  -- Drive the view-building + list-management logic with the ViewBuilder stub.
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._scrollbar = up_ui._vb:scrollbar{ width = 16, height = 340, min = 0, max = 12, step = 1, pagestep = 12 }
  up_ui._status_text = up_ui._vb:text{ text = "" }
  up_ui._upgrade_btn = up_ui._vb:button{ text = "Upgrade", active = false }

  up_ui.clear_list()
  check(up_ui._header_row ~= nil, "clear_list builds header row")

  local rc = { entry = rec, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc }
  up_ui.found_row(rec)
  check(#up_ui._data_rows == 1, "found_row appended a data row")
  up_ui.fill_row(rc)
  -- fill_row internally calls the local auto_select_index; it should pick the
  -- same-protocol (VST3) candidate, Pro-Q 3, i.e. popup value 2.
  check(up_ui._row_views[1] and up_ui._row_views[1].popup.value == 2,
    "fill_row auto-selected the same-protocol candidate (Pro-Q 3)")

  up_ui.recompute_visible()
  check(up_ui._visible >= 1, "recompute_visible computed a visible count")
  up_ui.refresh_scroll()
  up_ui.apply_scroll()
  check(true, "refresh_scroll/apply_scroll run without error")

  check(up_ui.wheel_scroll({ type = "wheel", direction = "down" }) == nil, "wheel_scroll handles wheel")
  check(up_ui.wheel_scroll({ type = "other" }).type == "other", "wheel_scroll passes non-wheel through")

  up_ui._saved_sel = up_ui.capture_selections()
  check(type(up_ui._saved_sel) == "table", "capture_selections returns a table")
  check(up_ui.summary():find("Done") == 1, "summary returns a Done. string")

  -- Exercise the full dialog + scan flow; the slicer is driven manually via the
  -- app-idle observable, since there is no real GUI event loop headlessly.
  local ok_dlg, err_dlg = pcall(function()
    up_ui.show_dialog()
    local idle = _G.renoise.tool().app_idle_observable
    for _ = 1, 400 do idle._fire() end
    up_ui.stop_all()
  end)
  check(ok_dlg, "show_dialog + scan flow runs headlessly" .. (ok_dlg and "" or (": " .. tostring(err_dlg))))
end

section("up_ui shows preset and carry-over in both columns")
do
  local up_ui = require("up_ui")
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._scrollbar = up_ui._vb:scrollbar{ width = 16, height = 340, min = 0, max = 12, step = 1, pagestep = 12 }
  up_ui._status_text = up_ui._vb:text{ text = "" }
  up_ui._upgrade_btn = up_ui._vb:button{ text = "Upgrade", active = false }
  up_ui.clear_list()

  -- Explicit preset name: shown in both columns, carried over to the upgrade.
  local rec = { kind = "instrument", instrument_name = "My Reaktor",
    analysis = up_util.analyze_plugin(nil, "AU: Native Instruments: Reaktor5"),
    device_name = "Native Instruments: Reaktor5",
    active_preset_name = "Make It Bright" }
  local cands = { analyze("Reaktor6", "/P/Reaktor6.app", "AU") }
  local rc = { entry = rec, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc }
  up_ui.found_row(rec)
  up_ui._fill_idx = #up_ui._row_views - 1
  up_ui.fill_row(rc)

  local items = up_ui._row_views[1].popup.items
  check(items[1]:find("Keep current") ~= nil, "first item is Keep current")
  check(items[1]:find("Make It Bright") ~= nil,
    "current plugin shows its preset (Make It Bright)")
  check(items[2]:find("Reaktor") ~= nil and items[2]:find("Make It Bright") ~= nil,
    "replacement shows carried-over preset (Reaktor 6 (Make It Bright))")
end

section("up_ui shows user preset name (not ensemble) for recovered plugin")
do
  -- A missing Reaktor's only meaningful preset signal is the user's instrument
  -- name ("Dark Dreams 1"); the loaded ensemble ("Razor") is the synth, shown only
  -- as a secondary detail. The preset name must be preserved and carried over, not
  -- replaced by the ensemble name.
  local up_ui = require("up_ui")
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._scrollbar = up_ui._vb:scrollbar{ width = 16, height = 340, min = 0, max = 12, step = 1, pagestep = 12 }
  up_ui._status_text = up_ui._vb:text{ text = "" }
  up_ui._upgrade_btn = up_ui._vb:button{ text = "Upgrade", active = false }
  up_ui.clear_list()

  local rec = { kind = "instrument", instrument_name = "Dark Dreams 1",
    analysis = up_util.analyze_plugin(nil, "AU: Native Instruments: Reaktor5"),
    device_name = "Native Instruments: Reaktor5",
    active_preset_name = "Razor", broken = true, recovered = true }
  local cands = { analyze("Reaktor6", "/P/Reaktor6.app", "AU") }
  local rc = { entry = rec, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc }
  up_ui.found_row(rec)
  up_ui._fill_idx = #up_ui._row_views - 1
  up_ui.fill_row(rc)

  local items = up_ui._row_views[1].popup.items
  check(items[1]:find("Dark Dreams 1") ~= nil,
    "current plugin shows the user preset name (Dark Dreams 1)")
  check(items[2]:find("Dark Dreams 1") ~= nil,
    "replacement carries over the user preset name (Dark Dreams 1)")
  check(items[1]:find("Razor") ~= nil,
    "current plugin still shows the ensemble as a secondary detail (Razor)")
  -- The ensemble must precede the preset name: "Razor: Dark Dreams 1".
  check(items[1]:find("Razor: Dark Dreams 1") ~= nil,
    "ensemble appears before the preset name (Razor: Dark Dreams 1)")
end

section("up_ui never shows instrument name as a carried-over preset")
do
  local up_ui = require("up_ui")
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._scrollbar = up_ui._vb:scrollbar{ width = 16, height = 340, min = 0, max = 12, step = 1, pagestep = 12 }
  up_ui._status_text = up_ui._vb:text{ text = "" }
  up_ui._upgrade_btn = up_ui._vb:button{ text = "Upgrade", active = false }
  up_ui.clear_list()

  -- Instrument whose only identity is its Renoise name (no real preset name): it
  -- must NOT be leaked into the replacement column as if it were Reaktor 6's
  -- preset (the earlier "Reaktor 6 (Reaktor5)" bug).
  local rec = { kind = "instrument", instrument_name = "VST: Reaktor5",
    analysis = up_util.analyze_plugin(nil, "VST: Native Instruments: Reaktor5"),
    device_name = "Native Instruments: Reaktor5" }
  local cands = { analyze("Reaktor6", "/P/Reaktor6.app", "AU") }
  local rc = { entry = rec, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc }
  up_ui.found_row(rec)
  up_ui._fill_idx = #up_ui._row_views - 1
  up_ui.fill_row(rc)

  local items = up_ui._row_views[1].popup.items
  check(items[2]:find("Reaktor5") == nil,
    "replacement column does NOT show the old instrument name as a preset")
  check(items[2]:find("Keep current") == nil and items[2]:find("%(") == nil,
    "replacement column has no fake (preset) parenthetical when none exists")

  -- And an embedded ensemble (file:// URL in the blob) is recovered and shown.
  local rec2 = { kind = "instrument", instrument_name = "Reaktor 5",
    analysis = up_util.analyze_plugin(nil, "VST: Native Instruments: Reaktor5"),
    device_name = "Native Instruments: Reaktor5",
    active_preset_data = "\000\000file://localhost/Users/Shared/Razor/Razor.rkplr\000\000" }
  local rc2 = { entry = rec2, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc2 }
  up_ui.found_row(rec2)
  up_ui._fill_idx = #up_ui._row_views - 1
  up_ui.fill_row(rc2)
  local rv2 = up_ui._row_views[#up_ui._row_views]
  local items2 = rv2.popup.items
  check(items2[1]:find("Razor") ~= nil, "current plugin shows recovered ensemble (Razor)")
  check(items2[2]:find("Razor") ~= nil, "replacement shows carried-over ensemble (Razor)")

  -- Missing plugin (failed to open): the only preset hint is the Renoise
  -- instrument name, e.g. "VST: Reaktor5 (Make It Bright)". Surface that as the
  -- preset in both columns, but never the bare plugin name ("Reaktor5").
  local rec3 = { kind = "instrument", instrument_name = "VST: Reaktor5 (Make It Bright)",
    analysis = up_util.analyze_plugin(nil, "VST: Native Instruments: Reaktor5"),
    device_name = "Native Instruments: Reaktor5" }
  local rc3 = { entry = rec3, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc3 }
  up_ui.found_row(rec3)
  up_ui._fill_idx = #up_ui._row_views - 1
  up_ui.fill_row(rc3)
  local items3 = up_ui._row_views[#up_ui._row_views].popup.items
  check(items3[1]:find("Make It Bright") ~= nil,
    "current shows preset from instrument name (Make It Bright)")
  check(items3[2]:find("Make It Bright") ~= nil,
    "replacement shows carried-over preset (Make It Bright)")
  check(items3[2]:find("Reaktor5") == nil,
    "replacement does NOT show bare plugin name as preset")
end

-- ---------------------------------------------------------------------------
section("coverage: matching fallbacks + find_candidates")
do
  -- These exercise the newer candidate-matching code paths (family, loose token,
  -- shared-token, and the multi-stage find_candidates fallback chain).
  local old = analyze("AU: Native Instruments: Reaktor5", "Reaktor5.au", "AU")
  local c = up_matching.find_candidates({
    analyze("AU: Native Instruments: Reaktor6", "Reaktor6.au", "AU"),
    analyze("VST: Lennardigital Sylenth1", "/P/Sylenth1.vst", "VST"),
  }, old)
  check(c and #c >= 1 and c[1].base:find("reaktor"), "find_candidates offers Reaktor6 for missing Reaktor5")

  local oldf = analyze("VST3: FabFilter Pro-L", "/P/ProL.vst3", "VST3")
  local cf = analyze("VST3: FabFilter Pro-L 2", "/P/ProL2.vst3", "VST3")
  check(up_matching.candidate_matches_family(cf, oldf), "family matches Pro-L -> Pro-L 2")

  local oldk = analyze("VST: Kick - Nicky Romero ()", "/P/Kick.vst", "VST")
  local ck = analyze("VST: Kick 2", "/P/Kick2.vst", "VST")
  check(up_matching.candidate_matches_loose(ck, oldk), "loose matches Kick -> Kick 2 (artist suffix)")
  check(up_matching.candidate_matches_shared(ck, oldk), "shared token matches Kick -> Kick 2 by name")

  local exact = analyze("VST3: FabFilter Pro-MB", "/P/ProMB.vst3", "VST3")
  local diff = analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3")
  check(not up_matching.candidate_matches(diff, exact), "exact match rejects different product")
  check(up_matching.vendor_ok({ vendor = "fabfilter" }, { vendor = "fabfilter" }), "vendor_ok true when vendors match")
  check(not up_matching.vendor_ok({ vendor = "fabfilter" }, { vendor = "native" }),
    "vendor_ok false when vendors differ")
end

section("coverage: up_util.instrument_preset_label variants")
do
  local reaktor_a = up_util.analyze_plugin(nil, "VST: Native Instruments: Reaktor5")
  check(up_util.instrument_preset_label("VST: Reaktor5 (Make It Bright)", "VST", reaktor_a) == "Make It Bright",
    "label recovered from parenthetical preset")
  check(up_util.instrument_preset_label("Cinematic Pad 1", "AU", nil) == "Cinematic Pad 1",
    "label is a bare user patch name")
  check(up_util.instrument_preset_label("Dark Dreams 1", "AU", reaktor_a) == "Dark Dreams 1",
    "label is the user patch when unrelated to the plugin name")
  check(up_util.instrument_preset_label("VST: Reaktor5", "VST", reaktor_a) == "",
    "empty label when the name is only the plugin itself")
end

section("coverage: up_core.apply_one success and error path")
do
  local track = {
    devices = { [1] = { is_active = true, active_preset_data = "", parameters = {} } },
    insert_device_at = function(self, _path, idx)
      local dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
      table.insert(self.devices, idx, dev)
      return dev
    end,
    delete_device_at = function(self, idx) table.remove(self.devices, idx) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 1, is_plugin = true,
    device_path = "/P/Sylenth1.vst", device_name = "VST: Lennardigital Sylenth1",
    analysis = analyze("VST: Lennardigital Sylenth1", "/P/Sylenth1.vst", "VST") }
  local candidate = { name = "Sylenth1", protocol = "VST", path = "/P/Sylenth1-VST3.vst", analysis = rec.analysis }
  local ok, res = pcall(function()
    return up_core.apply_one(song, { entry = rec, candidate = candidate }, candidate)
  end)
  check(ok and res and res.status ~= nil, "apply_one runs swap_track_device and returns a status")

  -- A result whose swap throws must be caught and reported, never aborting the run.
  local bad_rec = { kind = "weird", instrument_index = 1, analysis = rec.analysis }
  local ok2, res2 = pcall(function()
    return up_core.apply_one({ instruments = {} }, { entry = bad_rec, candidate = candidate }, candidate)
  end)
  check(ok2 and res2 and res2.status == "error", "apply_one catches a swap error and reports status 'error'")
end

section("coverage: up_inventory.scan surfaces a track plugin device")
do
  local mock_song = {
    instruments = { { name = "Sampler", plugin_properties = { plugin_loaded = false, plugin_device = nil } } },
    tracks = { { devices = { {}, { is_plugin = true, device_path = "/P/Pro-Q.vst3",
      device_name = "VST3: FabFilter Pro-Q 3", available_devices = {} } } } },
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil)
  local found = false
  for _, e in ipairs(entries) do if e.kind == "track" then found = true; break end end
  check(found, "scan surfaces a track plugin device as a track entry")
end

section("up_xml.parse rejects malformed (mismatched) closing tags")
do
  -- Malformed XML with a mismatched or unopened closing tag must be rejected
  -- (fail the parse) rather than silently producing an incorrect tree.
  check(up_xml.parse("<Root><A></B></Root>") == nil,
    "mismatched closing tag fails the parse")
  check(up_xml.parse("<Root><A></Root>") == nil,
    "closing tag without an open element fails the parse")
end

-- ---------------------------------------------------------------------------
print("\n" .. (failures == 0 and "ALL TESTS PASSED" or (failures .. " TEST(S) FAILED")))
os.exit(failures == 0 and 0 or 1)
