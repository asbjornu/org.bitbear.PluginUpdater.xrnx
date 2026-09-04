local up_plugin_analysis = require("up_plugin_analysis")
local up_song_xml = require("up_song_xml")

local up_inventory = {}

local function inspect_track_device(track, track_index, device_index)
  local device = track.devices[device_index]
  local record = {
    kind = "track",
    track_index = track_index,
    track_name = track.name,
    device_index = device_index,
    is_plugin = false,
    device_path = nil,
    device_name = nil,
    readable = false,
    preset_data_accessible = false,
    preset_data_len = 0,
    active_preset = nil,
    broken = false,
    notes = {},
  }
  local name_ok, device_name = pcall(function() return device.name end)
  record.device_name = name_ok and device_name or nil
  local path_ok, device_path = pcall(function() return device.device_path end)
  record.device_path = path_ok and device_path or nil
  local plugin_ok, is_plugin = pcall(function() return device.is_plugin end)
  record.is_plugin = (plugin_ok and is_plugin) and true or false
  if record.device_path and up_plugin_analysis.is_plugin_path(record.device_path) then
    record.is_plugin = true
  end
  if not record.device_path or up_plugin_analysis.is_native_path(record.device_path) then
    record.is_plugin = false
  end
  local preset_data_ok, preset_data = pcall(function() return device.active_preset_data end)
  if preset_data_ok then
    record.readable = true
    record.preset_data_accessible = true
    record.preset_data_len = preset_data and #preset_data or 0
  else
    record.broken = true
    table.insert(record.notes, "active_preset_data error: " .. tostring(preset_data))
  end
  local active_preset_ok, active_preset = pcall(function() return device.active_preset end)
  if active_preset_ok then
    record.active_preset = active_preset
    if active_preset and active_preset > 0 then
      local presets_ok, presets = pcall(function() return device.presets end)
      if presets_ok and presets and presets[active_preset] then
        record.active_preset_name = presets[active_preset]
      end
    end
  end
  return record
end

-- Resolve a recovered-plugin entry for an instrument, trying the live index
-- first and then the live instrument name (and a name with a trailing "()"
-- stripped, which Renoise sometimes appends). Index alignment breaks whenever
-- non-plugin instruments (ext. MIDI, etc.) sit between plugins in the song.
local function lookup_recovery(recovery, instrument_index, instrument)
  if not recovery then
    return nil
  end
  local recovery_entry = recovery[instrument_index]
  if recovery_entry then
    return recovery_entry
  end
  if instrument and instrument.name then
    recovery_entry = recovery[instrument.name]
    if recovery_entry then
      return recovery_entry
    end
    local stripped = instrument.name:match("^(.-)%s*%(%)$")
    if stripped then
      recovery_entry = recovery[stripped]
      if recovery_entry then
        return recovery_entry
      end
    end
  end
  return nil
end

-- Best-effort identity of a missing plugin from the live API. When the saved
-- .xrns can't be read (song unsaved, or the zip reader fails), Renoise still
-- retains the plugin's name on plugin_properties even though the device failed
-- to load, so we can still surface and match the instrument.
local function live_plugin_name(plugin_properties)
  for _, field in ipairs({ "plugin_name", "plugin_filename", "plugin_device_name" }) do
    local ok, value = pcall(function() return plugin_properties[field] end)
    if ok and type(value) == "string" and value ~= "" then
      return value
    end
  end
  return nil
end

-- Apply a recovered Song.xml identity to a record. Returns false when the entry
-- carries no usable display name (caller should try another source). Also lifts
-- the loaded ensemble/preset name so the UI can show it and carry it over even
-- for a plugin that failed to load on this machine.
local function apply_recovered(record, recovery_entry)
  local display_name = recovery_entry.display_name
    or recovery_entry.short_display_name
    or recovery_entry.identifier
  if not display_name then
    return false
  end
  -- An empty string is truthy in Lua, so a placeholder device with a blank name
  -- would otherwise survive and leave device_name empty -- exactly the case this
  -- recovery path exists to fix. Only keep an existing name that is actually set.
  record.device_name = (record.device_name ~= nil and record.device_name ~= "") and record.device_name or display_name
  record.analysis = up_plugin_analysis.analyze_plugin(nil, display_name)
  record.recovered = true
  if recovery_entry.preset_name then
    record.active_preset_name = recovery_entry.preset_name
  end
  return true
end

local function inspect_instrument(instrument, instrument_index, recovery)
  local plugin_properties = instrument.plugin_properties
  local loaded_ok, plugin_loaded = pcall(function() return plugin_properties.plugin_loaded end)
  local is_loaded = (loaded_ok and plugin_loaded) and true or false
  local device_ok, device_value = pcall(function() return plugin_properties.plugin_device end)
  local plugin_device = (device_ok and device_value) or nil

  local record = {
    kind = "instrument",
    instrument_index = instrument_index,
    instrument_name = instrument.name,
    is_plugin = true,
    plugin_loaded = is_loaded,
    device_path = nil,
    device_name = nil,
    readable = false,
    preset_data_accessible = false,
    preset_data_len = 0,
    active_preset = nil,
    broken = not is_loaded,
    recovered = false,
    notes = {},
  }

  -- A missing plugin's live device (when Renoise keeps one as a placeholder) is
  -- unreliable: its path may be an opaque AU 4-char code or empty, its name may
  -- be blank, and its preset state is inaccessible. Recover the authoritative
  -- identity AND the loaded ensemble/preset name from the saved song FIRST, so
  -- the grid row is correct and the preset carries over. We only fall back to the
  -- (possibly broken) live device when the song yields nothing.
  if not is_loaded then
    local recovery_entry = lookup_recovery(recovery, instrument_index, instrument)
    if recovery_entry and apply_recovered(record, recovery_entry) then
      record.notes = { "plugin not loaded; recovered identity from song.xml: " .. tostring(record.device_name) }
      return record
    end
  end

  if plugin_device then
    local path_ok, device_path = pcall(function() return plugin_device.device_path end)
    record.device_path = path_ok and device_path or nil
    local name_ok, device_name = pcall(function() return plugin_device.name end)
    record.device_name = name_ok and device_name or nil
    local preset_data_ok, preset_data = pcall(function() return plugin_device.active_preset_data end)
    if preset_data_ok then
      record.readable = true
      record.preset_data_accessible = true
      record.preset_data_len = preset_data and #preset_data or 0
      record.active_preset_data = preset_data
    end
    local active_preset_ok, active_preset = pcall(function() return plugin_device.active_preset end)
    if active_preset_ok then
      record.active_preset = active_preset
      -- Map the preset index to its name (e.g. a Reaktor ensemble) so the UI can
      -- show the current preset and indicate it carries over to the replacement.
      local presets_ok, presets = pcall(function() return plugin_device.presets end)
      if presets_ok and presets and active_preset and active_preset > 0 and presets[active_preset] then
        record.active_preset_name = presets[active_preset]
      end
    end
    if record.device_path then
      record.analysis = up_plugin_analysis.analyze_plugin(record.device_path, record.device_name or instrument.name)
      return record
    end
    -- Plugin present but its path is hidden by the API: try to recover the
    -- identity from the saved song so it can still be matched.
    local recovery_entry = lookup_recovery(recovery, instrument_index, instrument)
    if recovery_entry and apply_recovered(record, recovery_entry) then
      table.insert(record.notes, "recovered identity from song.xml: " .. tostring(record.device_name))
      return record
    end
    -- Device present but unidentifiable: still surface it (defaults to Keep current).
    record.analysis = up_plugin_analysis.analyze_plugin(nil, record.device_name or instrument.name)
    return record
  end

  -- No live plugin device and (when the plugin was missing) song recovery above
  -- already failed. The saved Song.xml still records what the plugin was; we
  -- already tried that above. Fall back to the live plugin_properties name, then
  -- to a protocol token in the instrument name.
  local recovery_entry = lookup_recovery(recovery, instrument_index, instrument)
  if recovery_entry and apply_recovered(record, recovery_entry) then
    record.notes = { "plugin not loaded; recovered identity from song.xml: " .. tostring(record.device_name) }
    return record
  end

  -- Not a plugin instrument we can identify (e.g. a sampler or ext. MIDI
  -- device with no recovered plugin identity) -- nothing to upgrade, so leave
  -- it out of the grid rather than show a blank/no-match row.
  local live_name = live_plugin_name(plugin_properties)
  if live_name then
    record.device_name = live_name
    record.analysis = up_plugin_analysis.analyze_plugin(nil, live_name)
    record.recovered = true
    record.notes = { "recovered identity from live plugin_properties: " .. tostring(live_name) }
    return record
  end
  -- Last resort: a missing instrument whose name still carries a plugin protocol
  -- token (e.g. "VST: Kick - Nicky Romero ()") is treated as a plugin and
  -- surfaced using that name as its identity. Loose / shared-token matching can
  -- then still find an upgrade (Kick -> Kick 2). Nameless samplers and ext. MIDI
  -- devices are left out to avoid blank rows.
  if instrument.name and instrument.name ~= "" and up_plugin_analysis.detect_protocol(instrument.name) then
    record.device_name = instrument.name
    record.analysis = up_plugin_analysis.analyze_plugin(nil, instrument.name)
    record.recovered = false
    record.notes = { "identity from live instrument name only (no plugin_properties/song.xml)" }
    return record
  end
  return nil
end

function up_inventory.scan(song, yield_function, on_progress, on_found, recovery)
  if not recovery and song then
    local ok, recovered = pcall(function() return up_song_xml.recover(song) end)
    recovery = ok and recovered or nil
  end
  local entries = {}
  for track_index = 1, #song.tracks do
    if on_progress then
      on_progress("Scanning tracks", track_index, #song.tracks)
    end
    if yield_function then
      yield_function()
    end
    local track = song.tracks[track_index]
    local devices_ok, devices = pcall(function() return track.devices end)
    if devices_ok and devices then
      for device_index = 2, #devices do
        local record = inspect_track_device(track, track_index, device_index)
        if record.is_plugin then
          record.analysis = up_plugin_analysis.analyze_plugin(record.device_path, record.device_name)
          table.insert(entries, record)
          if on_found then
            on_found(record)
          end
        end
      end
    end
  end
  for instrument_index = 1, #song.instruments do
    if on_progress then
      on_progress("Scanning instruments", instrument_index, #song.instruments)
    end
    if yield_function then
      yield_function()
    end
    local record = inspect_instrument(song.instruments[instrument_index], instrument_index, recovery)
    if record then
      table.insert(entries, record)
      if on_found then
        on_found(record)
      end
    end
  end
  return entries
end

-- Scan a single track device (device_index is the index into track.devices, >= 2).
function up_inventory.scan_track_device(track_index, track, device_index)
  local record = inspect_track_device(track, track_index, device_index)
  if record.is_plugin then
    record.analysis = up_plugin_analysis.analyze_plugin(record.device_path, record.device_name)
    return record
  end
  return nil
end

-- Scan a single instrument plugin.
function up_inventory.scan_instrument_device(instrument, recovery)
  local song = renoise.song()
  if not song then
    return nil
  end
  if not recovery then
    local ok, recovered = pcall(function() return up_song_xml.recover(song) end)
    recovery = ok and recovered or nil
  end
  local instrument_index = nil
  for index, candidate in ipairs(song.instruments) do
    if rawequal(candidate, instrument) then
      instrument_index = index
      break
    end
  end
  if not instrument_index then
    return nil
  end
  return inspect_instrument(instrument, instrument_index, recovery)
end

return up_inventory
