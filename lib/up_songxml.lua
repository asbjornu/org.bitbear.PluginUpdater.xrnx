local up_songxml = {}

local up_zip = require("up_zip")
local up_preset = require("up_preset")

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

local function read_song_xml(song)
  local ok_app, app = pcall(function() return renoise.app() end)
  if not ok_app or not app then
    return nil
  end
  -- The absolute path to the loaded/saved song is exposed as song().file_name
  -- (empty string when the song has never been saved). Older/incorrect spellings
  -- (app.song_filename, song().song_filename) are kept only as fallbacks in case a
  -- Renoise build differs. Guarding each access is essential: reading a property
  -- that does not exist on the API object throws, which would otherwise silence
  -- recovery entirely -- and without recovery, missing plugins whose instrument
  -- name carries no protocol token (e.g. "Dark Dreams 1") can never be matched.
  local path
  local ok_f, fv = pcall(function() return song.file_name end)
  if ok_f and fv and fv ~= "" then
    path = fv
  else
    local ok_p, pv = pcall(function() return app.song_filename end)
    if ok_p and pv and pv ~= "" then
      path = pv
    else
      local ok_s, sv = pcall(function() return renoise.song().song_filename end)
      if ok_s and sv and sv ~= "" then
        path = sv
      end
    end
  end
  if not path or path == "" then
    return nil
  end
  if _cache.file == path and _cache.data then
    return _cache.data
  end
  -- Pure-Lua ZIP reader only: no system dependency, and no shell-out (which
  -- would be a command-injection risk on `app.song_filename`). Renoise `.xrns`
  -- files use the stored or deflate methods, both of which this covers; if
  -- extraction fails we simply report that no XML could be recovered.
  local ok_z, xml = pcall(function() return up_zip.extract(path, "Song.xml") end)
  if ok_z and xml and xml ~= "" then
    _cache.file = path
    _cache.data = xml
    return xml
  end
  return nil
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
  -- Tolerate attributes on the tags and skip <InstrumentGroup> wrappers (which
  -- would otherwise desync the index from song.instruments). We also index each
  -- entry by name/display/identifier so callers can look a plugin up by the live
  -- instrument's name -- robust against any reordering or non-plugin instruments
  -- (e.g. ext. MIDI) that shift the indices between the song and its Song.xml.
  for open, block in xml:gmatch("<(Instrument[^>]*)>(.-)</Instrument>") do
    if not open:match("^Group") then
      idx = idx + 1
      local ptype = block:match("<PluginType[^>]*>(.-)</PluginType>")
      if ptype then
        local identifier = block:match("<PluginIdentifier[^>]*>(.-)</PluginIdentifier>")
        local disp = block:match("<PluginDisplayName[^>]*>(.-)</PluginDisplayName>")
        local sdisp = block:match("<PluginShortDisplayName[^>]*>(.-)</PluginShortDisplayName>")
        local iname = block:match("<Name[^>]*>(.-)</Name>")
        -- Recover the loaded ensemble/preset name that Renoise stores inside the
        -- plugin's opaque ParameterChunk (base64-encoded CDATA). For Reaktor /
        -- Kontakt this is the "file://.../Name.ext" path of the loaded ensemble;
        -- surfacing it lets the tool show the preset even when the plugin itself
        -- failed to load on this machine (so the live API exposes no preset name).
        local preset_name
        local cdata = block:match("<ParameterChunk><%!%[CDATA%[(.-)%]%]></ParameterChunk>")
        if cdata then
          preset_name = up_preset.extract_name({ active_preset_data = cdata })
        end
        local entry = {
          index = idx,
          instrument_name = iname,
          protocol = ptype,
          identifier = identifier,
          display_name = disp or sdisp,
          short_display_name = sdisp or disp,
          preset_name = preset_name,
        }
        out[idx] = entry
        if iname then out[iname] = entry end
        if disp then out[disp] = entry end
        if sdisp then out[sdisp] = entry end
        if identifier then out[identifier] = entry end
      end
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
