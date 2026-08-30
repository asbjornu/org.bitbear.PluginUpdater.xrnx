local up_util = require("up_util")
local up_songxml = require("up_songxml")

local up_inventory = {}

local function inspect_track_device(track, track_index, dev_index)
  local dev = track.devices[dev_index]
  local rec = {
    kind = "track",
    track_index = track_index,
    track_name = track.name,
    device_index = dev_index,
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
  local ok_name, name = pcall(function() return dev.name end)
  rec.device_name = ok_name and name or nil
  local ok_path, path = pcall(function() return dev.device_path end)
  rec.device_path = ok_path and path or nil
  local ok_plugin, isp = pcall(function() return dev.is_plugin end)
  rec.is_plugin = (ok_plugin and isp) and true or false
  if rec.device_path and up_util.is_plugin_path(rec.device_path) then
    rec.is_plugin = true
  end
  if not rec.device_path or up_util.is_native_path(rec.device_path) then
    rec.is_plugin = false
  end
  local ok_pd, pd = pcall(function() return dev.active_preset_data end)
  if ok_pd then
    rec.readable = true
    rec.preset_data_accessible = true
    rec.preset_data_len = pd and #pd or 0
  else
    rec.broken = true
    table.insert(rec.notes, "active_preset_data error: " .. tostring(pd))
  end
  local ok_ap, ap = pcall(function() return dev.active_preset end)
  if ok_ap then
    rec.active_preset = ap
    if ap and ap > 0 then
      local ok_p, presets = pcall(function() return dev.presets end)
      if ok_p and presets and presets[ap] then
        rec.active_preset_name = presets[ap]
      end
    end
  end
  return rec
end

-- Resolve a recovered-plugin entry for an instrument, trying the live index
-- first and then the live instrument name (and a name with a trailing "()"
-- stripped, which Renoise sometimes appends). Index alignment breaks whenever
-- non-plugin instruments (ext. MIDI, etc.) sit between plugins in the song.
local function lookup_recovery(recovery, ii, inst)
  if not recovery then
    return nil
  end
  local info = recovery[ii]
  if info then
    return info
  end
  if inst and inst.name then
    info = recovery[inst.name]
    if info then
      return info
    end
    local stripped = inst.name:match("^(.-)%s*%(%)$")
    if stripped then
      info = recovery[stripped]
      if info then
        return info
      end
    end
  end
  return nil
end

-- Best-effort identity of a missing plugin from the live API. When the saved
-- .xrns can't be read (song unsaved, or the zip reader fails), Renoise still
-- retains the plugin's name on plugin_properties even though the device failed
-- to load, so we can still surface and match the instrument.
local function live_plugin_name(pp)
  for _, f in ipairs({ "plugin_name", "plugin_filename", "plugin_device_name" }) do
    local ok, v = pcall(function() return pp[f] end)
    if ok and type(v) == "string" and v ~= "" then
      return v
    end
  end
  return nil
end

-- Apply a recovered Song.xml identity to a rec. Returns false when the entry
-- carries no usable display name (caller should try another source). Also lifts
-- the loaded ensemble/preset name so the UI can show it and carry it over even
-- for a plugin that failed to load on this machine.
local function apply_recovered(rec, info)
  local dn = info.display_name or info.short_display_name or info.identifier
  if not dn then
    return false
  end
  -- An empty string is truthy in Lua, so a placeholder device with a blank name
  -- would otherwise survive and leave device_name empty -- exactly the case this
  -- recovery path exists to fix. Only keep an existing name that is actually set.
  rec.device_name = (rec.device_name ~= nil and rec.device_name ~= "") and rec.device_name or dn
  rec.analysis = up_util.analyze_plugin(nil, dn)
  rec.recovered = true
  if info.preset_name then
    rec.active_preset_name = info.preset_name
  end
  return true
end

local function inspect_instrument(inst, ii, recovery)
  local pp = inst.plugin_properties
  local ok_loaded, loaded = pcall(function() return pp.plugin_loaded end)
  local is_loaded = (ok_loaded and loaded) and true or false
  local ok_dev, dev = pcall(function() return pp.plugin_device end)
  local adev = (ok_dev and dev) or nil

  local rec = {
    kind = "instrument",
    instrument_index = ii,
    instrument_name = inst.name,
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
    local info = lookup_recovery(recovery, ii, inst)
    if info and apply_recovered(rec, info) then
      rec.notes = { "plugin not loaded; recovered identity from song.xml: " .. tostring(rec.device_name) }
      return rec
    end
  end

  if adev then
    local ok_path, path = pcall(function() return adev.device_path end)
    rec.device_path = ok_path and path or nil
    local ok_name, name = pcall(function() return adev.name end)
    rec.device_name = ok_name and name or nil
    local ok_pd, pd = pcall(function() return adev.active_preset_data end)
    if ok_pd then
      rec.readable = true
      rec.preset_data_accessible = true
      rec.preset_data_len = pd and #pd or 0
      rec.active_preset_data = pd
    end
    local ok_ap, ap = pcall(function() return adev.active_preset end)
    if ok_ap then
      rec.active_preset = ap
      -- Map the preset index to its name (e.g. a Reaktor ensemble) so the UI can
      -- show the current preset and indicate it carries over to the replacement.
      local ok_p, presets = pcall(function() return adev.presets end)
      if ok_p and presets and ap and ap > 0 and presets[ap] then
        rec.active_preset_name = presets[ap]
      end
    end
    if rec.device_path then
      rec.analysis = up_util.analyze_plugin(rec.device_path, rec.device_name or inst.name)
      return rec
    end
    -- Plugin present but its path is hidden by the API: try to recover the
    -- identity from the saved song so it can still be matched.
    local info = lookup_recovery(recovery, ii, inst)
    if info and apply_recovered(rec, info) then
      table.insert(rec.notes, "recovered identity from song.xml: " .. tostring(rec.device_name))
      return rec
    end
    -- Device present but unidentifiable: still surface it (defaults to Keep current).
    rec.analysis = up_util.analyze_plugin(nil, rec.device_name or inst.name)
    return rec
  end

  -- No live plugin device and (when the plugin was missing) song recovery above
  -- already failed. The saved Song.xml still records what the plugin was; we
  -- already tried that above. Fall back to the live plugin_properties name, then
  -- to a protocol token in the instrument name.
  local info = lookup_recovery(recovery, ii, inst)
  if info and apply_recovered(rec, info) then
    rec.notes = { "plugin not loaded; recovered identity from song.xml: " .. tostring(rec.device_name) }
    return rec
  end

  -- Not a plugin instrument we can identify (e.g. a sampler or ext. MIDI
  -- device with no recovered plugin identity) -- nothing to upgrade, so leave
  -- it out of the grid rather than show a blank/no-match row.
  local live = live_plugin_name(pp)
  if live then
    rec.device_name = live
    rec.analysis = up_util.analyze_plugin(nil, live)
    rec.recovered = true
    rec.notes = { "recovered identity from live plugin_properties: " .. tostring(live) }
    return rec
  end
  -- Last resort: a missing instrument whose name still carries a plugin protocol
  -- token (e.g. "VST: Kick - Nicky Romero ()") is treated as a plugin and
  -- surfaced using that name as its identity. Loose / shared-token matching can
  -- then still find an upgrade (Kick -> Kick 2). Nameless samplers and ext. MIDI
  -- devices are left out to avoid blank rows.
  if inst.name and inst.name ~= "" and up_util.detect_protocol(inst.name) then
    rec.device_name = inst.name
    rec.analysis = up_util.analyze_plugin(nil, inst.name)
    rec.recovered = false
    rec.notes = { "identity from live instrument name only (no plugin_properties/song.xml)" }
    return rec
  end
  return nil
end

function up_inventory.scan(song, yield_fn, on_progress, on_found, recovery)
  if not recovery and song then
    local ok, r = pcall(function() return up_songxml.recover(song) end)
    recovery = ok and r or nil
  end
  local entries = {}
  for ti = 1, #song.tracks do
    if on_progress then
      on_progress("Scanning tracks", ti, #song.tracks)
    end
    if yield_fn then
      yield_fn()
    end
    local track = song.tracks[ti]
    local ok_devs, devs = pcall(function() return track.devices end)
    if ok_devs and devs then
      for di = 2, #devs do
        local rec = inspect_track_device(track, ti, di)
        if rec.is_plugin then
          rec.analysis = up_util.analyze_plugin(rec.device_path, rec.device_name)
          table.insert(entries, rec)
          if on_found then
            on_found(rec)
          end
        end
      end
    end
  end
  for ii = 1, #song.instruments do
    if on_progress then
      on_progress("Scanning instruments", ii, #song.instruments)
    end
    if yield_fn then
      yield_fn()
    end
    local rec = inspect_instrument(song.instruments[ii], ii, recovery)
    if rec then
      table.insert(entries, rec)
      if on_found then
        on_found(rec)
      end
    end
  end
  return entries
end

-- Scan a single track device (di is the index into track.devices, >= 2).
function up_inventory.scan_track_device(track_index, track, di)
  local rec = inspect_track_device(track, track_index, di)
  if rec.is_plugin then
    rec.analysis = up_util.analyze_plugin(rec.device_path, rec.device_name)
    return rec
  end
  return nil
end

-- Scan a single instrument plugin.
function up_inventory.scan_instrument_device(inst, recovery)
  local song = renoise.song()
  if not song then
    return nil
  end
  if not recovery then
    local ok, r = pcall(function() return up_songxml.recover(song) end)
    recovery = ok and r or nil
  end
  local ii = nil
  for j, x in ipairs(song.instruments) do
    if rawequal(x, inst) then
      ii = j
      break
    end
  end
  if not ii then
    return nil
  end
  return inspect_instrument(inst, ii, recovery)
end

return up_inventory
