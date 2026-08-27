local up_preset = require("up_preset")

local up_swap = {}

local function transfer_state(new_dev, old_data, old_preset_name)
  if old_data and old_data ~= "" then
    local ok = pcall(function() new_dev.active_preset_data = old_data end)
    if ok then
      local ok2, got = pcall(function() return new_dev.active_preset_data end)
      if ok2 and got and got ~= "" then
        return "parameters"
      end
      return nil, "transplant resulted in empty/default state"
    end
    return nil, "transplant raised an error"
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
  local method, err = transfer_state(new_dev, old_data, old_preset_name)
  if method then
    pcall(function() track:delete_device_at(old_index + 1) end)
    return {
      status = method == "parameters" and "upgraded-with-parameters" or "upgraded-name-matched-preset",
      new_path = candidate.path,
      method = method,
    }
  end
  if was_broken then
    pcall(function() track:delete_device_at(old_index + 1) end)
    return {
      status = "upgraded-replaced-broken",
      new_path = candidate.path,
      detail = "old device was broken; new plugin loaded at default state (set preset manually)",
    }
  end
  pcall(function() track:delete_device_at(old_index) end)
  return {
    status = "skipped-transfer-rejected",
    new_path = candidate.path,
    detail = err,
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
  local method, err = transfer_state(new_dev, old_data, old_preset_name)
  if method then
    return {
      status = method == "parameters" and "upgraded-with-parameters" or "upgraded-name-matched-preset",
      new_path = candidate.path,
      method = method,
    }
  end
  if was_broken then
    return {
      status = "upgraded-replaced-broken",
      new_path = candidate.path,
      detail = "old plugin was broken; new loaded at default state (set preset manually)",
    }
  end
  if rec.device_path then
    pcall(function() pp:load_plugin(rec.device_path) end)
  else
    pcall(function() pp:load_plugin("") end)
  end
  return {
    status = "skipped-transfer-rejected",
    new_path = candidate.path,
    detail = err,
  }
end

return up_swap
