local up_util = {}

up_util.PROTOCOL_RANK = { CLAP = 4, VST3 = 3, VST2 = 2, VST = 2, AU = 1, LV2 = 0, DSSI = 0 }

local DETECT_ORDER = { "CLAP", "VST3", "VST2", "VST", "AU", "LV2", "DSSI" }

local NOISE = { audio = true, effects = true, generators = true, native = true, plugin = true }

function up_util.detect_protocol(s)
  if type(s) ~= "string" then return nil end
  local lower = s:lower()
  for _, tok in ipairs(DETECT_ORDER) do
    if lower:find(tok:lower(), 1, true) then
      return tok
    end
  end
  return nil
end

function up_util.is_native_path(path)
  if type(path) ~= "string" then return false end
  -- Renoise's built-in (non-plugin) devices live under the "Native/" namespace,
  -- e.g. "Audio/Effects/Native/Gainer". Match that namespace only -- not the
  -- bare word "native", which also appears in vendor names such as
  -- "Native Instruments" and would wrongly exclude every plugin from that vendor
  -- (e.g. Reaktor) from the candidate pool, so a newer version could never be
  -- offered as an upgrade.
  return path:lower():find("native[/\\]") ~= nil
end

function up_util.is_plugin_path(path)
  if type(path) ~= "string" or up_util.is_native_path(path) then
    return false
  end
  return up_util.detect_protocol(path) ~= nil
end

function up_util.protocol_rank(p)
  return up_util.PROTOCOL_RANK[p or ""] or 0
end

function up_util.strip_version(product)
  return (product:gsub("%s+[vV]?%d+%.?%d*%s*$", ""))
end

function up_util.extract_version(product)
  local v = product:match("%s+[vV]?(%d+%.?%d*)%s*$")
  if v then
    return tonumber(v)
  end
  return nil
end

-- Product stem with any trailing version stripped, so different major versions
-- of the same plugin collapse to one family key, e.g. "reaktor5" and "reaktor6"
-- both become "reaktor" (and "native instruments: reaktor 6" -> the same). Used
-- for best-effort matching of missing plugins, where we can't transfer state
-- anyway, so a newer major version is an acceptable replacement.
function up_util.family_base(s)
  if type(s) ~= "string" then return "" end
  local t = s:lower()
  t = t:gsub("%s*[vV]?%d+%.?%d*%s*$", "")
  t = t:gsub("%s+", " "):match("^%s*(.-)%s*$") or t
  return t
end

-- Significant word tokens of a plugin base (version stripped, lowercased),
-- used for best-effort matching of missing plugins. e.g.
-- "Sonic Academy: Kick - Nicky Romero" -> {sonic, academy, kick, nicky, romero}
-- and "Kick 2" -> {kick}. Single-char tokens are kept (so "Pro-Q" keeps "q",
-- which distinguishes it from "Pro-MB"); subset comparison makes stray
-- single-char tokens harmless because a match requires ALL of one side's tokens
-- to appear in the other.
function up_util.token_set(s)
  if type(s) ~= "string" then return {} end
  local t = s:lower()
  t = t:gsub("%s*[vV]?%d+%.?%d*%s*$", "")
  t = t:gsub("%s+", " ")
  local set = {}
  for tok in t:gmatch("[%w%.]+") do
    local w = tok:gsub("[%.%-]", "")
    -- Strip a version suffix that is glued to the product word (e.g. "reaktor5"
    -- -> "reaktor"), so major-version variants still share a token and match.
    w = w:gsub("%d+$", "")
    if #w > 0 then set[w] = true end
  end
  return set
end

-- True when every significant token of `a` also appears in `b`.
function up_util.token_subset(a, b)
  for k in pairs(a) do
    if not b[k] then return false end
  end
  return true
end

local function split_segments(s)
  s = s:gsub("[:/\\]+", "|")
  local segs = {}
  for raw_seg in s:gmatch("[^|]+") do
    local seg = raw_seg:match("^%s*(.-)%s*$")
    if seg ~= "" and not NOISE[seg:lower()] then
      table.insert(segs, seg)
    end
  end
  return segs
end

-- Category prefixes that may appear at the start of a device name, e.g.
-- "Effects: FabFilter Pro-Q 3" or "Generators: Sylenth1".
local CATEGORY = { effects = true, generators = true, native = true, instruments = true }

-- Strip a single leading "Tag:" prefix (protocol or category) so that names
-- sourced from different APIs normalize the same way, e.g.
--   "VST: FabFilter Pro-Q 3"  -> "FabFilter Pro-Q 3"
--   "Effects: FabFilter Pro-Q 3" -> "FabFilter Pro-Q 3"
-- A genuine mid-name colon (e.g. "Lennardigital: Sylenth1") is preserved.
local function strip_leading_tag(s, protocol)
  local tag = s:match("^%s*([%w%+%-]+)%s*:%s*")
  if tag then
    local t = tag:lower()
    if t == (protocol and protocol:lower()) or CATEGORY[t] then
      return s:gsub("^%s*[%w%+%-]+%s*:%s*", "", 1)
    end
  end
  return s
end

-- Architecture/marker tokens that are pure metadata and must not participate
-- in cross-protocol matching, e.g. "ValhallaRoom_x64" vs "ValhallaRoom".
local ARCH_TOKENS = { "x64", "x86", "win64", "win32", "aax", "vst3", "vst2", "au" }

-- Normalize a human-readable plugin name into a comparable lowercase token:
-- drop "(...)" annotations, a leading category/protocol tag, any embedded
-- protocol token, architecture markers, and unify separators/spacing. The
-- version is intentionally kept so that different major versions do NOT collide
-- (Pro-Q 2 != Pro-Q 3).
local function clean_display_name(name, protocol)
  local s = tostring(name or ""):lower()
  s = strip_leading_tag(s, protocol)
  s = s:gsub("%b()", " ")
  if protocol then
    s = s:gsub(protocol:lower(), " ")
  end
  s = s:gsub("[%._%-]+", " ")
  for _, tok in ipairs(ARCH_TOKENS) do
    s = s:gsub("%s*" .. tok .. "%s*", " ")
  end
  s = s:gsub("%s+", " "):match("^%s*(.-)%s*$")
  return s
end

function up_util.analyze_plugin(path, name)
  local protocol = up_util.detect_protocol(path) or up_util.detect_protocol(name)

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
    local segs = split_segments(work)
    if #segs >= 1 then
      product = clean_display_name(segs[#segs], protocol)
    end
  end

  -- base keeps the version: this keeps major versions distinct (Pro-Q 2 vs
  -- Pro-Q 3) while still matching the same plugin across VST/VST3/AU.
  local base = product
  if base == "" then
    base = (type(path) == "string" and path or "") or ""
  end
  local version = up_util.extract_version(product)
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

function up_util.rank(info)
  local v = info.version or 0
  return up_util.protocol_rank(info.protocol) * 1000 + v
end

-- Given a preset/instrument name and the owning plugin's analysis, return the
-- part of the preset that is NOT just a restatement of the plugin name. e.g.
-- plugin product "lennardigital sylenth1" + preset "VST: Sylenth1 (ARP 303 Saw)"
-- -> "ARP 303 Saw". Returns "" when the preset adds nothing new.
function up_util.strip_redundant_prefix(preset, protocol, analysis)
  local basetoks = {}
  local base = (analysis and analysis.product) or ""
  for w in base:gmatch("%S+") do
    basetoks[w] = true
  end
  if not preset or preset == "" then
    return ""
  end
  local s = tostring(preset)
  local tag = s:match("^%s*([%w%+%-]+)%s*:%s*")
  if tag then
    local t = tag:lower()
    if t == (protocol and protocol:lower()) or CATEGORY[t] then
      s = s:gsub("^%s*[%w%+%-]+%s*:%s*", "", 1)
    end
  end
  s = s:gsub("%b()", " ")
  s = s:gsub("[%._%:%-]+", " ")
  local low = s:lower()
  for _, tok in ipairs(ARCH_TOKENS) do
    local st, en = low:find("%s*" .. tok .. "%s*")
    while st do
      s = s:sub(1, st - 1) .. " " .. s:sub(en + 1)
      low = s:lower()
      st, en = low:find("%s*" .. tok .. "%s*")
    end
  end
  while true do
    local w = s:match("^%s*(%S+)")
    if not w or not basetoks[w:lower()] then
      break
    end
    s = s:gsub("^%s*%S+%s*", "", 1)
  end
  return s:gsub("%s+", " "):match("^%s*(.-)%s*$")
end

-- Unified human-readable name used for BOTH the "Current plugin" and
-- "Replace with" columns. Emits the protocol moniker first, then the readable
-- name with original case, e.g. "VST: Lennardigital Sylenth1" or
-- "VST3: FabFilter Pro-Q 3". Strips a leading category/protocol tag (since we
-- re-emit the protocol), drops architecture markers, and unifies separators.
function up_util.format_plugin(name, protocol)
  local s = tostring(name or "")
  local tag = s:match("^%s*([%w%+%-]+)%s*:%s*")
  if tag then
    local t = tag:lower()
    if t == (protocol and protocol:lower()) or CATEGORY[t] then
      s = s:gsub("^%s*[%w%+%-]+%s*:%s*", "", 1)
    end
  end
  s = s:gsub("%b()", " ")
  s = s:gsub("[%._%:%-]+", " ")
  local low = s:lower()
  for _, tok in ipairs(ARCH_TOKENS) do
    local st, en = low:find("%s*" .. tok .. "%s*")
    while st do
      s = s:sub(1, st - 1) .. " " .. s:sub(en + 1)
      low = s:lower()
      st, en = low:find("%s*" .. tok .. "%s*")
    end
  end
  s = s:gsub("%s+", " "):match("^%s*(.-)%s*$")
  if protocol and protocol ~= "" then
    return protocol:upper() .. ": " .. s
  end
  return s
end

return up_util
