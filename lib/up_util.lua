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
  return path:lower():find("native") ~= nil
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

-- Normalize a human-readable plugin name into a comparable lowercase token:
-- drop "(...)" annotations, any protocol token, and unify separators/spacing.
local function clean_display_name(name, protocol)
  local s = tostring(name or ""):lower()
  s = s:gsub("%b()", " ")
  if protocol then
    s = s:gsub(protocol:lower(), " ")
  end
  s = s:gsub("[%._%-]+", " ")
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

  local base = up_util.strip_version(product)
  if base == "" then
    base = product
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

return up_util
