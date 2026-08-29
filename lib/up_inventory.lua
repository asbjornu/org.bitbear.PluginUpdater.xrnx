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
  end
  return rec
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
    end
    local ok_ap, ap = pcall(function() return adev.active_preset end)
    if ok_ap then
      rec.active_preset = ap
    end
    if rec.device_path then
      rec.analysis = up_util.analyze_plugin(rec.device_path, rec.device_name or inst.name)
    else
      -- Plugin present but its path is hidden by the API: try to recover the
      -- identity from the saved song so it can still be matched.
      local info = recovery and recovery[ii]
      if info and info.display_name then
        rec.device_name = rec.device_name or info.display_name
        rec.analysis = up_util.analyze_plugin(nil, info.display_name)
        rec.recovered = true
        table.insert(rec.notes, "recovered identity from song.xml: " .. tostring(info.display_name))
      else
        table.insert(rec.notes, "original plugin path unavailable; cannot auto-match")
      end
    end
    return rec
  end

  -- No live plugin device. When the plugin simply failed to load (missing on
  -- this machine) the API exposes nothing, but the saved Song.xml still records
  -- what it was. Recover that so the missing instrument can be matched + upgraded.
  local info = recovery and recovery[ii]
  if info and info.display_name then
    rec.device_name = info.display_name
    rec.analysis = up_util.analyze_plugin(nil, info.display_name)
    rec.recovered = true
    rec.notes = { "plugin not loaded; recovered identity from song.xml: " .. tostring(info.display_name) }
    return rec
  end

  -- Not a plugin instrument (e.g. a sampler) -- nothing to upgrade.
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
