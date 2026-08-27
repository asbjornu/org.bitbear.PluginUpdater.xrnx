local up_util = {}

up_util.PROTOCOL_RANK = { CLAP = 4, VST3 = 3, VST2 = 2, VST = 2, AU = 1, LV2 = 0, DSSI = 0 }

local DETECT_ORDER = { "CLAP", "VST3", "VST2", "VST", "AU", "LV2", "DSSI" }

local NOISE = { audio = true, effects = true, generators = true, native = true, plugin = true }

function up_util.detect_protocol(s)
  if not s then return nil end
  local lower = s:lower()
  for _, tok in ipairs(DETECT_ORDER) do
    if lower:find(tok:lower(), 1, true) then
      return tok
    end
  end
  return nil
end

function up_util.is_native_path(path)
  if not path then return false end
  return path:lower():find("native") ~= nil
end

function up_util.is_plugin_path(path)
  if not path or up_util.is_native_path(path) then
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

function up_util.analyze_plugin(path, fallback_name)
  local raw = path and path or (fallback_name or "")
  local protocol = up_util.detect_protocol(raw) or up_util.detect_protocol(fallback_name)

  -- Choose the string we derive the human-readable vendor/product from.
  -- A plugin path may be a "Protocol: Name" identifier, or a filesystem-style
  -- category path ("Audio/Generators/VST3/<id>") as returned by instrument
  -- plugin infos. In the latter case the readable name lives in fallback_name.
  local display = fallback_name or raw
  if path and up_util.detect_protocol(path) then
    local after = path:match("^.-:%s*(.*)$")
    if after and after ~= "" then
      display = after
    end
  elseif path and path:find("/", 1, true) and fallback_name then
    display = fallback_name
  end

  local work = display:lower()
  local segs = split_segments(work)
  local vendor = ""
  local product = ""
  if #segs >= 2 then
    product = segs[#segs]
    vendor = table.concat(segs, " ", 1, #segs - 1)
  elseif #segs == 1 then
    local first, rest = segs[1]:match("^(%S+)%s+(.+)$")
    if first and rest then
      vendor = first
      product = rest
    else
      product = segs[1]
    end
  else
    product = (fallback_name or raw)
  end
  if vendor == "" then
    local f, r = product:match("^(%S+)%s+(.+)$")
    if f and r then
      vendor = f
      product = r
    end
  end
  local base = up_util.strip_version(product)
  if base == "" then
    base = product
  end
  local version = up_util.extract_version(product)
  local family_key = (vendor ~= "" and vendor or "?"):lower() .. "::" .. base:lower()
  return {
    raw = raw,
    protocol = protocol,
    vendor = vendor,
    product = product,
    base = base,
    version = version,
    family_key = family_key,
  }
end

function up_util.rank(info)
  local v = info.version or 0
  return up_util.protocol_rank(info.protocol) * 1000 + v
end

return up_util
