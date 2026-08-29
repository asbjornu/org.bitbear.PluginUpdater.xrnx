local up_songxml = {}

-- When a plugin is missing on the machine, renoise.song().instruments[i]
-- .plugin_properties.plugin_device is nil, so the live API exposes no path or
-- name for it. But the .xrns song file is a zip archive containing Song.xml,
-- which stores <PluginType>/<PluginIdentifier>/<PluginDisplayName> for EVERY
-- plugin -- including missing ones. We parse that to learn what the song
-- referenced, so a missing instrument can still be matched against an installed
-- candidate and upgraded.
--
-- This only recovers the *identity* (so we can match + swap). The actual plugin
-- state lives in the host/plugin, not the song, so a replacement loads at
-- default state unless the user's preset name (the instrument name) resolves in
-- the installed plugin's own bank.

local _cache = { file = nil, data = nil }

local function quote_arg(s)
  return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

local function read_song_xml(song)
  local ok_app, app = pcall(function() return renoise.app() end)
  if not ok_app or not app then
    return nil
  end
  local path = app.song_filename
  if not path or path == "" then
    return nil
  end
  if _cache.file == path and _cache.data then
    return _cache.data
  end
  -- Prefer streaming via io.popen; fall back to extracting to a temp file.
  local cmd = "unzip -p " .. quote_arg(path) .. " Song.xml 2>/dev/null"
  local xml
  local ok_p, f = pcall(function() return io.popen(cmd, "r") end)
  if ok_p and f then
    xml = f:read("*a")
    pcall(function() f:close() end)
  end
  if not xml or xml == "" then
    local tmp = os.tmpname()
    local ec = os.execute("unzip -o -p " .. quote_arg(path) .. " Song.xml > " .. quote_arg(tmp) .. " 2>/dev/null")
    local tf = io.open(tmp, "r")
    if tf then
      xml = tf:read("*a")
      tf:close()
    end
    pcall(function() os.remove(tmp) end)
    if (not xml or xml == "") and ec ~= 0 then
      xml = nil
    end
  end
  if xml and xml ~= "" then
    _cache.file = path
    _cache.data = xml
  end
  return xml
end

-- Parse a Song.xml string into per-instrument plugin identities, keyed by
-- 1-based instrument index (parallel to song.instruments). Only instruments
-- that actually have a plugin (a <PluginType> element) are included, so samplers
-- are skipped. Exposed separately from recover() so it can be unit-tested
-- without a real .xrns file.
function up_songxml.parse_instruments(xml)
  local out = {}
  if type(xml) ~= "string" or xml == "" then
    return out
  end
  local idx = 0
  for block in xml:gmatch("<Instrument[^>]*>(.-)</Instrument>") do
    idx = idx + 1
    local ptype = block:match("<PluginType>(.-)</PluginType>")
    if ptype then
      local identifier = block:match("<PluginIdentifier>(.-)</PluginIdentifier>")
      local disp = block:match("<PluginDisplayName>(.-)</PluginDisplayName>")
      local sdisp = block:match("<PluginShortDisplayName>(.-)</PluginShortDisplayName>")
      local iname = block:match("<Name>(.-)</Name>")
      out[idx] = {
        index = idx,
        instrument_name = iname,
        protocol = ptype,
        identifier = identifier,
        display_name = disp or sdisp,
        short_display_name = sdisp or disp,
      }
    end
  end
  return out
end

-- Recover plugin identity per instrument, keyed by 1-based instrument index
-- (parallel to song.instruments). Only instruments that actually have a plugin
-- (a <PluginType> element) are included, so samplers are skipped.
function up_songxml.recover(song)
  local xml = read_song_xml(song)
  if not xml then
    return {}
  end
  return up_songxml.parse_instruments(xml)
end

function up_songxml.invalidate_cache()
  _cache.file = nil
  _cache.data = nil
end

return up_songxml
