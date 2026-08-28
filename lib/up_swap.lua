local up_preset = require("up_preset")

local up_swap = {}

-- Try to move the old plugin's state onto the newly inserted device.
-- Returns ("parameters"|"name") on success, or (nil, reason) on failure.
-- A parameter-chunk transplant only works within the SAME plugin format, so
-- when the source and target protocols differ we skip it (the chunk is
-- inherently incompatible, e.g. VST<->VST3) and go straight to preset-name
-- matching; that keeps the upgrade and only loses the saved state.
local function transfer_state(new_dev, old_data, old_preset_name, same_format)
  print(string.format(
    "[PluginUpdater] transfer_state: old_data type=%s len=%s preset=%s same_format=%s",
    type(old_data),
    (type(old_data) == "string") and tostring(#old_data) or "-",
    tostring(old_preset_name),
    tostring(same_format)))

  if old_data and old_data ~= "" and same_format then
    local ok, errmsg = pcall(function() new_dev.active_preset_data = old_data end)
    if ok then
      local ok2, got = pcall(function() return new_dev.active_preset_data end)
      if ok2 and got and got ~= "" then
        return "parameters"
      end
      errmsg = "transplant resulted in empty/default state"
    else
      print(string.format("[PluginUpdater]   active_preset_data assignment failed: %s",
        tostring(errmsg)))
    end
    -- fall through to preset-name matching
    local ok_p, presets = pcall(function() return new_dev.presets end)
    if ok_p and presets then
      for i, pname in ipairs(presets) do
        if pname == old_preset_name then
          local ok_set = pcall(function() new_dev.active_preset = i end)
          if ok_set then
            return "name"
          end
        end
      end
    end
    return nil, errmsg or "transplant raised an error"
  end

  if old_preset_name then
    local ok_p, presets = pcall(function() return new_dev.presets end)
    if ok_p and presets then
      for i, pname in ipairs(presets) do
        if pname == old_preset_name then
          local ok_set = pcall(function() new_dev.active_preset = i end)
          if ok_set then
            return "name"
          end
        end
      end
    end
  end
  return nil, "no transfer method succeeded"
end

function up_swap.swap_track_device(song, rec, candidate)
  local track = song.tracks[rec.track_index]
  local old_index = rec.device_index
  local old_device = track.devices[old_index]
  local old_data = nil
  local ok_pd, pd = pcall(function() return old_device.active_preset_data end)
  if ok_pd then
    old_data = pd
  end
  local old_preset_name = up_preset.extract_name(old_device)
  local was_broken = rec.broken
  local old_proto = rec.analysis and rec.analysis.protocol
  local same_format = (old_proto and old_proto == candidate.protocol)

  local ok_ins, dev_or_err = pcall(function()
    return track:insert_device_at(candidate.path, old_index)
  end)
  if not ok_ins or not dev_or_err then
    return {
      status = "skipped-transfer-rejected",
      new_path = candidate.path,
      detail = "insert failed: " .. tostring(dev_or_err),
    }
  end
  local new_dev = dev_or_err
  local method, err = transfer_state(new_dev, old_data, old_preset_name, same_format)
  if method then
    pcall(function() track:delete_device_at(old_index + 1) end)
    return {
      status = method == "parameters" and "upgraded-with-parameters" or "upgraded-name-matched-preset",
      new_path = candidate.path,
      method = method,
    }
  end
  -- The new plugin is inserted and valid. The upgrade (protocol change) still
  -- happens; only the old state couldn't be carried over. Remove the old device
  -- and keep the new one at default state rather than silently reverting.
  pcall(function() track:delete_device_at(old_index + 1) end)
  return {
    status = "upgraded-default",
    new_path = candidate.path,
    detail = (was_broken and "old plugin was broken; " or "preset not transferred: ") .. tostring(err),
  }
end

function up_swap.swap_instrument(song, rec, candidate)
  local inst = song.instruments[rec.instrument_index]
  local pp = inst.plugin_properties
  local old_data = nil
  local old_preset_name = nil
  if rec.plugin_loaded and pp.plugin_device then
    local ok_pd, pd = pcall(function() return pp.plugin_device.active_preset_data end)
    if ok_pd then
      old_data = pd
    end
    old_preset_name = up_preset.extract_name(pp.plugin_device)
  end
  local was_broken = rec.broken
  local old_proto = rec.analysis and rec.analysis.protocol
  local same_format = (old_proto and old_proto == candidate.protocol)

  local ok_load, loaded = pcall(function() return pp:load_plugin(candidate.path) end)
  if not ok_load or not loaded then
    return {
      status = "skipped-transfer-rejected",
      new_path = candidate.path,
      detail = "load_plugin failed: " .. tostring(loaded),
    }
  end
  local ok_dev, adev = pcall(function() return pp.plugin_device end)
  local new_dev = (ok_dev and adev) or nil
  if not new_dev then
    if rec.device_path then
      pcall(function() pp:load_plugin(rec.device_path) end)
    end
    return {
      status = "skipped-transfer-rejected",
      new_path = candidate.path,
      detail = "new plugin device unavailable after load",
    }
  end
  local method, err = transfer_state(new_dev, old_data, old_preset_name, same_format)
  if method then
    return {
      status = method == "parameters" and "upgraded-with-parameters" or "upgraded-name-matched-preset",
      new_path = candidate.path,
      method = method,
    }
  end
  -- load_plugin already replaced the instrument plugin in place, so the upgrade
  -- is effective; only the old state couldn't be carried over.
  return {
    status = "upgraded-default",
    new_path = candidate.path,
    detail = (was_broken and "old plugin was broken; " or "preset not transferred: ") .. tostring(err),
  }
end

return up_swap
