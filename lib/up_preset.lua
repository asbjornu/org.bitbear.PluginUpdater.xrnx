local up_preset = {}

-- Pure-Lua base64 decoder (RFC 4648), used to read preset/ensemble names that
-- plugins embed inside their opaque state chunk (group 4 chars -> 3 bytes).
local function _b64decode(s)
  local map = {}
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, #chars do map[chars:sub(i, i)] = i - 1 end
  s = s:gsub("[^A-Za-z0-9+/=]", "")
  local out = {}
  local i = 1
  while i <= #s do
    local a = map[s:sub(i, i)] or 0; i = i + 1
    local b = map[s:sub(i, i)] or 0; i = i + 1
    local c = s:sub(i, i); i = i + 1
    local d = s:sub(i, i); i = i + 1
    local ca = (c ~= "" and c ~= "=") and map[c] or nil
    local da = (d ~= "" and d ~= "=") and map[d] or nil
    local n = a * 262144 + b * 4096 + (ca or 0) * 64 + (da or 0)
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if ca then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
    if da then out[#out + 1] = string.char(n % 256) end
    if not ca then break end
  end
  return table.concat(out)
end

-- Reaktor/Kontakt/etc. store the loaded ensemble as a "file://.../Name.ext"
-- string inside the preset blob; treat the last path component (minus the
-- extension) as the preset/ensemble name.
local function _scan_chunk_for_name(blob)
  local function base_of(url)
    local b = url:match("([^/\\]+)%.%w+$")
    if b and b ~= "" then return b:gsub("%.[^%.]+$", "") end
    return nil
  end
  for url in blob:gmatch("file://[^%z%s\"'<>]+") do
    local n = base_of(url)
    if n and n ~= "" then return n end
  end
  return nil
end

-- Recover a preset/ensemble name embedded in a plugin's opaque state chunk.
-- Renoise hands this back as the raw binary blob at runtime (so scan it
-- directly); some code paths pass the base64-encoded .xrns CDATA, so also try
-- after base64-decoding.
function up_preset._extract_chunk_name(data)
  if type(data) ~= "string" or data == "" then return nil end
  local n = _scan_chunk_for_name(data)
  if n then return n end
  -- Only attempt the (potentially expensive) full base64 decode when the data could
  -- actually be base64. Binary preset blobs contain NUL bytes and other non-base64
  -- characters and never carry a usable file:// URL, so skip the decode up front.
  if data:find("\0") or data:find("[^A-Za-z0-9+/=%s]") then
    return nil
  end
  local ok, dec = pcall(_b64decode, data)
  if ok and dec and dec ~= "" then
    n = _scan_chunk_for_name(dec)
    if n then return n end
  end
  return nil
end

function up_preset.extract_name(device)
  if not device then
    return nil
  end
  local ok_ap, ap = pcall(function() return device.active_preset end)
  local ok_p, presets = pcall(function() return device.presets end)
  if ok_ap and ok_p and ap and ap > 0 and presets and presets[ap] then
    return presets[ap]
  end
  local ok_pd, pd = pcall(function() return device.active_preset_data end)
  if ok_pd and pd and pd ~= "" then
    local name = pd:match("<PresetName>([^<]*)</PresetName>")
    if name and name ~= "" then
      return name
    end
    name = pd:match("<Name>([^<]*)</Name>")
    if name and name ~= "" then
      return name
    end
    name = pd:match('name="([^"]*)"')
    if name and name ~= "" then
      return name
    end
    -- Fallback: many plugin formats embed the loaded ensemble/preset as a
    -- "file://.../Name.ext" string in the opaque chunk (e.g. Reaktor's loaded
    -- ensemble), which Renoise exposes only inside active_preset_data.
    name = up_preset._extract_chunk_name(pd)
    if name and name ~= "" then
      return name
    end
  end
  return nil
end

return up_preset
