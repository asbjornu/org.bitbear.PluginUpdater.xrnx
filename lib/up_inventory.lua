local up_util = require("up_util")

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

function up_inventory.scan(song)
  local entries = {}
  for ti = 1, #song.tracks do
    local track = song.tracks[ti]
    local ok_devs, devs = pcall(function() return track.devices end)
    if ok_devs and devs then
      for di = 2, #devs do
        local rec = inspect_track_device(track, ti, di)
        if rec.is_plugin then
          rec.analysis = up_util.analyze_plugin(rec.device_path, rec.device_name)
          table.insert(entries, rec)
        end
      end
    end
  end
  for ii = 1, #song.instruments do
    local inst = song.instruments[ii]
    local pp = inst.plugin_properties
    local ok_loaded, loaded = pcall(function() return pp.plugin_loaded end)
    local is_loaded = (ok_loaded and loaded) and true or false
    local ok_dev, dev = pcall(function() return pp.plugin_device end)
    local adev = (ok_dev and dev) or nil
    if not is_loaded and not adev then
      -- not a currently identifiable plugin instrument: skip samplers / unassigned
    else
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
      else
        table.insert(rec.notes, "plugin_device is nil (plugin not loaded)")
      end
      if rec.device_path then
        rec.analysis = up_util.analyze_plugin(rec.device_path, rec.device_name or inst.name)
      else
        table.insert(rec.notes, "original plugin path unavailable; cannot auto-match")
      end
      table.insert(entries, rec)
    end
  end
  return entries
end

return up_inventory
