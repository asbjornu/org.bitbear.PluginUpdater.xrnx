local up_plugin_analysis = {}

up_plugin_analysis.PROTOCOL_RANK = { CLAP = 4, VST3 = 3, VST2 = 2, VST = 2, AU = 1, LV2 = 0, DSSI = 0 }

local DETECT_ORDER = { "CLAP", "VST3", "VST2", "VST", "AU", "LV2", "DSSI" }

-- Words that are purely structural (category folders, the "native" namespace)
-- and must never become the matched identity of a plugin.
local IGNORED_SEGMENTS = { audio = true, effects = true, generators = true, native = true, plugin = true }

-- Manufacturer / generic words to ignore when matching on a shared token. A shared
-- vendor (e.g. "fabfilter") must not by itself count as a product match -- that
-- would wrongly pair "Pro-MB" with "Pro-Q". Only a shared product word (e.g.
-- "kick", "reaktor") is significant.
local NON_PRODUCT_TOKENS = {
  fabfilter = true, native = true, instruments = true, sonic = true, academy = true,
  ["u"] = true, ["he"] = true, apple = true, spitfire = true, orchestral = true,
  tools = true, lennardigital = true, tal = true, togu = true, alliance = true,
  hornet = true, syntheway = true, mlvst = true, unfiltered = true, knif = true,
  dio = true, wedge = true, force = true, born = true, net = true, hatch = true,
  fish = true, rhy = true, generator = true, oberhausen = true, bx = true,
  ds = true, ace = true, midi = true, dls = true, music = true, device = true,
  pg = true, sampler = true, ["8x"] = true, one = true, keemun = true,
  matcha = true, oolong = true, knifonium = true, mega = true, lion = true,
  thorne = true, audio = true, line = true, synth = true, synthe = true,
  way = true, ho = true, plugin = true,
}

function up_plugin_analysis.is_product_token(token)
  return not NON_PRODUCT_TOKENS[token]
end

function up_plugin_analysis.detect_protocol(text)
  if type(text) ~= "string" then return nil end
  local lowercased = text:lower()
  for _, candidate in ipairs(DETECT_ORDER) do
    if lowercased:find(candidate:lower(), 1, true) then
      return candidate
    end
  end
  return nil
end

function up_plugin_analysis.is_native_path(path)
  if type(path) ~= "string" then return false end
  -- Renoise's built-in (non-plugin) devices live under the "Native/" namespace,
  -- e.g. "Audio/Effects/Native/Gainer". Match that namespace only -- not the
  -- bare word "native", which also appears in vendor names such as
  -- "Native Instruments" and would wrongly exclude every plugin from that vendor
  -- (e.g. Reaktor) from the candidate pool, so a newer version could never be
  -- offered as an upgrade.
  return path:lower():find("native[/\\]") ~= nil
end

function up_plugin_analysis.is_plugin_path(path)
  if type(path) ~= "string" or up_plugin_analysis.is_native_path(path) then
    return false
  end
  return up_plugin_analysis.detect_protocol(path) ~= nil
end

function up_plugin_analysis.protocol_rank(protocol)
  return up_plugin_analysis.PROTOCOL_RANK[protocol or ""] or 0
end

function up_plugin_analysis.strip_version(product)
  return (product:gsub("%s+[vV]?%d+%.?%d*%s*$", ""))
end

function up_plugin_analysis.extract_version(product)
  local version = product:match("%s+[vV]?(%d+%.?%d*)%s*$")
  if version then
    return tonumber(version)
  end
  return nil
end

-- Product stem with any trailing version stripped, so different major versions
-- of the same plugin collapse to one family key, e.g. "reaktor5" and "reaktor6"
-- both become "reaktor" (and "native instruments: reaktor 6" -> the same). Used
-- for best-effort matching of missing plugins, where we can't transfer state
-- anyway, so a newer major version is an acceptable replacement.
function up_plugin_analysis.family_base(text)
  if type(text) ~= "string" then return "" end
  local lowercased = text:lower()
  lowercased = lowercased:gsub("%s*[vV]?%d+%.?%d*%s*$", "")
  lowercased = lowercased:gsub("%s+", " "):match("^%s*(.-)%s*$") or lowercased
  return lowercased
end

-- Significant word tokens of a plugin base (version stripped, lowercased),
-- used for best-effort matching of missing plugins. e.g.
-- "Sonic Academy: Kick - Nicky Romero" -> {sonic, academy, kick, nicky, romero}
-- and "Kick 2" -> {kick}. Single-char tokens are kept (so "Pro-Q" keeps "q",
-- which distinguishes it from "Pro-MB"); subset comparison makes stray
-- single-char tokens harmless because a match requires ALL of one side's tokens
-- to appear in the other.
function up_plugin_analysis.token_set(text)
  if type(text) ~= "string" then return {} end
  local lowercased = text:lower()
  lowercased = lowercased:gsub("%s*[vV]?%d+%.?%d*%s*$", "")
  lowercased = lowercased:gsub("%s+", " ")
  local set = {}
  for token in lowercased:gmatch("[%w%.]+") do
    local word = token:gsub("[%.%-]", "")
    -- Strip a version suffix that is glued to the product word (e.g. "reaktor5"
    -- -> "reaktor"), so major-version variants still share a token and match.
    word = word:gsub("%d+$", "")
    if #word > 0 then set[word] = true end
  end
  return set
end

-- True when every significant token of `a` also appears in `b`.
function up_plugin_analysis.token_subset(a, b)
  for token in pairs(a) do
    if not b[token] then return false end
  end
  return true
end

local function split_segments(text)
  text = text:gsub("[:/\\]+", "|")
  local segments = {}
  for raw_segment in text:gmatch("[^|]+") do
    local segment = raw_segment:match("^%s*(.-)%s*$")
    if segment ~= "" and not IGNORED_SEGMENTS[segment:lower()] then
      table.insert(segments, segment)
    end
  end
  return segments
end

-- Category prefixes that may appear at the start of a device name, e.g.
-- "Effects: FabFilter Pro-Q 3" or "Generators: Sylenth1".
local CATEGORY_PREFIXES = { effects = true, generators = true, native = true, instruments = true }

-- Strip a single leading "Tag:" prefix (protocol or category) so that names
-- sourced from different APIs normalize the same way, e.g.
--   "VST: FabFilter Pro-Q 3"  -> "FabFilter Pro-Q 3"
--   "Effects: FabFilter Pro-Q 3" -> "FabFilter Pro-Q 3"
-- A genuine mid-name colon (e.g. "Lennardigital: Sylenth1") is preserved.
local function strip_leading_tag(text, protocol)
  local tag = text:match("^%s*([%w%+%-]+)%s*:%s*")
  if tag then
    local lowercased_tag = tag:lower()
    if lowercased_tag == (protocol and protocol:lower()) or CATEGORY_PREFIXES[lowercased_tag] then
      return text:gsub("^%s*[%w%+%-]+%s*:%s*", "", 1)
    end
  end
  return text
end

-- Architecture/marker tokens that are pure metadata and must not participate
-- in cross-protocol matching, e.g. "ValhallaRoom_x64" vs "ValhallaRoom".
local ARCHITECTURE_TOKENS = { "x64", "x86", "win64", "win32", "aax", "vst3", "vst2", "au" }

-- Normalize a human-readable plugin name into a comparable lowercase token:
-- drop "(...)" annotations, a leading category/protocol tag, any embedded
-- protocol token, architecture markers, and unify separators/spacing. The
-- version is intentionally kept so that different major versions do NOT collide
-- (Pro-Q 2 != Pro-Q 3).
local function clean_display_name(name, protocol)
  local text = tostring(name or ""):lower()
  text = strip_leading_tag(text, protocol)
  text = text:gsub("%b()", " ")
  if protocol then
    text = text:gsub(protocol:lower(), " ")
  end
  text = text:gsub("[%._%-]+", " ")
  for _, token in ipairs(ARCHITECTURE_TOKENS) do
    text = text:gsub("%s*" .. token .. "%s*", " ")
  end
  text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
  return text
end

function up_plugin_analysis.analyze_plugin(path, name)
  local protocol = up_plugin_analysis.detect_protocol(path) or up_plugin_analysis.detect_protocol(name)

  -- Prefer the human-readable display name (from DeviceInfo/PluginInfo or
  -- device.name). This is the only reliable key for matching across protocols,
  -- because VST3 paths are opaque UIDs and AU paths are 4-char codes. Fall back
  -- to the last path segment only when no name is available.
  local product = clean_display_name(name, protocol)
  if product == "" then
    local work = (type(path) == "string" and path or ""):lower()
    if protocol then
      work = work:gsub(protocol:lower(), "", 1)
    end
    local segments = split_segments(work)
    if #segments >= 1 then
      product = clean_display_name(segments[#segments], protocol)
    end
  end

  -- base keeps the version: this keeps major versions distinct (Pro-Q 2 vs
  -- Pro-Q 3) while still matching the same plugin across VST/VST3/AU.
  local base = product
  if base == "" then
    base = (type(path) == "string" and path or "") or ""
  end
  local version = up_plugin_analysis.extract_version(product)
  return {
    raw = path,
    protocol = protocol,
    vendor = "",
    product = product,
    base = base,
    version = version,
    family_key = base:lower(),
  }
end

function up_plugin_analysis.rank(info)
  local version = info.version or 0
  return up_plugin_analysis.protocol_rank(info.protocol) * 1000 + version
end

-- Given a preset/instrument name and the owning plugin's analysis, return the
-- part of the preset that is NOT just a restatement of the plugin name. e.g.
-- plugin product "lennardigital sylenth1" + preset "VST: Sylenth1 (ARP 303 Saw)"
-- -> "ARP 303 Saw". Returns "" when the preset adds nothing new.
function up_plugin_analysis.strip_redundant_prefix(preset, protocol, analysis)
  local base_tokens = {}
  local base = (analysis and analysis.product) or ""
  for word in base:gmatch("%S+") do
    base_tokens[word] = true
  end
  if not preset or preset == "" then
    return ""
  end
  local text = tostring(preset)
  local tag = text:match("^%s*([%w%+%-]+)%s*:%s*")
  if tag then
    local lowercased_tag = tag:lower()
    if lowercased_tag == (protocol and protocol:lower()) or CATEGORY_PREFIXES[lowercased_tag] then
      text = text:gsub("^%s*[%w%+%-]+%s*:%s*", "", 1)
    end
  end
  text = text:gsub("%b()", " ")
  -- Note: colons are intentionally preserved (not folded to spaces) so a combined
  -- "Ensemble: Preset" label like "Razor: Dark Dreams 1" survives intact; a leading
  -- protocol-style tag is still stripped by the block above when it matches.
  text = text:gsub("[%._%-]+", " ")
  local lower = text:lower()
  for _, token in ipairs(ARCHITECTURE_TOKENS) do
    local start, finish = lower:find("%s*" .. token .. "%s*")
    while start do
      text = text:sub(1, start - 1) .. " " .. text:sub(finish + 1)
      lower = text:lower()
      start, finish = lower:find("%s*" .. token .. "%s*")
    end
  end
  while true do
    local word = text:match("^%s*(%S+)")
    if not word or not base_tokens[word:lower()] then
      break
    end
    text = text:gsub("^%s*%S+%s*", "", 1)
  end
  return text:gsub("%s+", " "):match("^%s*(.-)%s*$")
end

-- Recover the user's preset label from an instrument's *name*, when that name is
-- more than a restatement of the plugin's own identity. For a plugin that failed
-- to load the live API exposes nothing, and Renoise reports the instrument name
-- (e.g. "Instrument 03 (Dark Dreams 1)"), which is the only meaningful preset
-- signal available. Examples:
--   "Dark Dreams 1"                   -> "Dark Dreams 1"
--   "Cinematic Pad 1"                 -> "Cinematic Pad 1"
--   "VST: Reaktor5 (Make It Bright)"  -> "Make It Bright"
--   "VST: Reaktor5"                   -> ""            (just the plugin itself)
-- Unlike strip_redundant_prefix this PRESERVES parenthetical content, because that
-- is exactly where the user's preset frequently lives.
function up_plugin_analysis.instrument_preset_label(name, protocol, analysis)
  local text = tostring(name or ""):match("^%s*(.-)%s*$")
  if text == "" then return "" end
  -- Drop a leading "PROTO: " (protocol) tag.
  local tag = text:match("^%s*([%w%+%-]+)%s*:%s*")
  if tag then
    local lowercased_tag = tag:lower()
    if lowercased_tag == (protocol and protocol:lower()) or CATEGORY_PREFIXES[lowercased_tag] then
      text = text:gsub("^%s*[%w%+%-]+%s*:%s*", "", 1)
    end
  end
  -- Drop leading words that are part of the plugin's own product identity; stop at
  -- the first word that is not the plugin, or at an opening parenthesis.
  local base = (analysis and analysis.product) or ""
  local base_tokens = {}
  for token in base:lower():gmatch("[%w%.%-]+") do
    local word = token:gsub("[%.%-]", ""):gsub("%d+$", "")
    if word ~= "" then base_tokens[word] = true end
  end
  local function is_plugin_word(word)
    local count = 0
    for word_token in word:gsub("[%.%-_]", " "):lower():gmatch("[^%s]+") do
      count = count + 1
      local stripped = word_token:gsub("%d+$", "")
      if stripped == "" or not base_tokens[stripped] then return false end
    end
    return count > 0
  end
  local cursor = 1
  while cursor <= #text do
    while cursor <= #text and text:sub(cursor, cursor):match("%s") do cursor = cursor + 1 end
    if cursor > #text then break end
    if text:sub(cursor, cursor) == "(" then break end
    local j = cursor
    while j <= #text and text:sub(j, j):match("[%w%.%-]") do j = j + 1 end
    local word = text:sub(cursor, j - 1)
    if is_plugin_word(word) then
      cursor = j
    else
      break
    end
  end
  local rest = text:sub(cursor):match("^%s*(.-)%s*$")
  if not rest or rest == "" then return "" end
  -- Drop a single surrounding pair of parentheses so the label reads cleanly.
  rest = rest:match("^%(%s*(.-)%s*%)$") or rest
  return rest
end

-- Unified human-readable name used for BOTH the "Current plugin" and
-- "Replace with" columns. Emits the protocol moniker first, then the readable
-- name with original case, e.g. "VST: Lennardigital Sylenth1" or
-- "VST3: FabFilter Pro-Q 3". Strips a leading category/protocol tag (since we
-- re-emit the protocol), drops architecture markers, and unifies separators.
function up_plugin_analysis.format_plugin(name, protocol)
  local text = tostring(name or "")
  local tag = text:match("^%s*([%w%+%-]+)%s*:%s*")
  if tag then
    local lowercased_tag = tag:lower()
    if lowercased_tag == (protocol and protocol:lower()) or CATEGORY_PREFIXES[lowercased_tag] then
      text = text:gsub("^%s*[%w%+%-]+%s*:%s*", "", 1)
    end
  end
  text = text:gsub("%b()", " ")
  text = text:gsub("[%._%:%-]+", " ")
  local lower = text:lower()
  for _, token in ipairs(ARCHITECTURE_TOKENS) do
    local start, finish = lower:find("%s*" .. token .. "%s*")
    while start do
      text = text:sub(1, start - 1) .. " " .. text:sub(finish + 1)
      lower = text:lower()
      start, finish = lower:find("%s*" .. token .. "%s*")
    end
  end
  text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
  if protocol and protocol ~= "" then
    return protocol:upper() .. ": " .. text
  end
  return text
end

return up_plugin_analysis
