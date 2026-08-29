local up_preset = require("up_preset")

local up_swap = {}

-- Debug helper: set to false for release. When true, dumps every parameter of a
-- device (name, is_automatable, value) and reports synth-match outcomes so we
-- can see why a given parameter (e.g. "Mix") is or isn't carried across.
local DEBUG_PARAMS = true

local function dump_params(device, label)
  if not DEBUG_PARAMS then return end
  local ok, params = pcall(function() return device.parameters end)
  if not ok or not params then
    print(string.format("[PluginUpdater]   %s: no parameters available", label))
    return
  end
  print(string.format("[PluginUpdater]   %s: %d parameters", label, #params))
  for i, p in ipairs(params) do
    local okv, v = pcall(function() return p.value end)
    local okn, n = pcall(function() return p.name end)
    local oka, a = pcall(function() return p.is_automatable end)
    print(string.format("      [%d] name=%q automatable=%s value=%s",
      i, (okn and type(n) == "string" and n) or "?",
      tostring(oka and a), (okv and tostring(v)) or "?"))
  end
end

local function dump_synth_outcome(old_params, new_dev)
  if not DEBUG_PARAMS then return end
  local ok_p, params = pcall(function() return new_dev.parameters end)
  if not ok_p or not params then return end
  local by_name = {}
  for i, p in ipairs(params) do
    local okn, n = pcall(function() return p.name end)
    if okn and type(n) == "string" and n ~= "" then by_name[n] = p end
  end
  print("[PluginUpdater]   synth match results:")
  for _, op in ipairs(old_params) do
    local np = by_name[op.name]
    if np then
      local oka, a = pcall(function() return np.is_automatable end)
      local why = (oka and a) and "applied" or "SKIPPED (not automatable)"
      print(string.format("      old %q -> %s", op.name, why))
    else
      print(string.format("      old %q -> NO MATCH in new device", op.name))
    end
  end
end

-- Capture the old plugin's exposed parameter values so we can re-apply them to
-- the replacement plugin as a best-effort "synthesized" preset when the native
-- preset chunk can't be transferred (e.g. across plugin formats). Only
-- automatable parameters are captured; internal/non-parameter state is skipped.
local function snapshot_params(device)
  local out = {}
  if not device then return out end
  local ok, params = pcall(function() return device.parameters end)
  if not ok or not params then return out end
  for i, p in ipairs(params) do
    local okv, v = pcall(function() return p.value end)
    if okv then
      local okn, n = pcall(function() return p.name end)
      local oka, auto = pcall(function() return p.is_automatable end)
      out[#out + 1] = {
        name = (okn and type(n) == "string") and n or "",
        value = v,
        is_automatable = (oka and auto) and true or false,
      }
    end
  end
  return out
end

-- Re-apply captured parameter values onto the new device, matched strictly by
-- parameter name. Only automatable parameters are written. Returns the number
-- of parameters that were transferred.
local function apply_param_values(new_dev, old_params)
  local ok_p, params = pcall(function() return new_dev.parameters end)
  if not ok_p or not params then return 0 end
  local by_name = {}
  for i, p in ipairs(params) do
    local okn, n = pcall(function() return p.name end)
    if okn and type(n) == "string" and n ~= "" then
      by_name[n] = i
    end
  end
  local applied = 0
  for _, op in ipairs(old_params) do
    local idx = by_name[op.name]
    if idx then
      local np = params[idx]
      local ok_set = pcall(function()
        if np.is_automatable then np.value = op.value end
      end)
      if ok_set then applied = applied + 1 end
    end
  end
  dump_synth_outcome(old_params, new_dev)
  return applied
end

-- Try to move the old plugin's state onto the newly inserted device.
-- Returns ("parameters"|"name"|"params") on success, or (nil, reason) on
-- failure. A parameter-chunk transplant only works within the SAME plugin
-- format, so when the source and target protocols differ we skip it (the chunk
-- is inherently incompatible, e.g. VST<->VST3). In that cross-format case we
-- load a same-named factory preset as a base (so unmapped parameters keep a
-- sensible default), then overlay the old plugin's captured parameter values
-- (matched by name) on top -- which is what actually carries the user's tweaks
-- such as Mix. If no parameters map, we keep the loaded preset; otherwise we
-- return the synthesized result.
local function transfer_state(new_dev, old_data, old_preset_name, same_format, old_params)
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
    else
      print(string.format("[PluginUpdater]   active_preset_data assignment failed: %s",
        tostring(errmsg)))
    end
  end

  -- Establish a base state from a same-named factory preset (if one exists in
  -- the new plugin). This gives unmapped parameters a sensible starting point.
  local preset_loaded = false
  if old_preset_name then
    local ok_p, presets = pcall(function() return new_dev.presets end)
    if ok_p and presets then
      for i, pname in ipairs(presets) do
        if pname == old_preset_name then
          local ok_set = pcall(function() new_dev.active_preset = i end)
          if ok_set then
            preset_loaded = true
            break
          end
        end
      end
    end
  end

  -- Overlay the old plugin's saved parameter values on top of the base. This is
  -- what actually carries the user's tweaks (e.g. Mix) across formats, since it
  -- applies the captured values rather than resetting to a factory default.
  if old_params and #old_params > 0 then
    local applied = apply_param_values(new_dev, old_params)
    if applied > 0 then
      return "params", tostring(applied)
    end
  end

  -- If we couldn't map any parameters but did load a base preset, keep it.
  if preset_loaded then
    return "name"
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
  local old_params = snapshot_params(old_device)
  local old_preset_name = up_preset.extract_name(old_device)
  local old_active = nil
  local ok_act, act = pcall(function() return old_device.is_active end)
  if ok_act then old_active = act end
  dump_params(old_device, "OLD")
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
  dump_params(new_dev, "NEW")
  local method, err = transfer_state(new_dev, old_data, old_preset_name, same_format, old_params)
  -- Set is_active last: transfer_state may load a base preset, which can reset
  -- the device to active; applying it afterwards keeps the old bypass state.
  if old_active ~= nil then
    pcall(function() new_dev.is_active = old_active end)
  end
  if method then
    pcall(function() track:delete_device_at(old_index + 1) end)
    local status = method == "parameters" and "upgraded-with-parameters"
      or method == "name" and "upgraded-name-matched-preset"
      or "upgraded-parameter-synth"
    return {
      status = status,
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
  local old_params = {}
  local old_preset_name = nil
  local old_active = nil
  if rec.plugin_loaded and pp.plugin_device then
    local ok_pd, pd = pcall(function() return pp.plugin_device.active_preset_data end)
    if ok_pd then
      old_data = pd
    end
    old_params = snapshot_params(pp.plugin_device)
    old_preset_name = up_preset.extract_name(pp.plugin_device)
    local ok_act, act = pcall(function() return pp.plugin_device.is_active end)
    if ok_act then old_active = act end
  end
  -- Missing plugin: the live API exposes no preset, but the instrument name is
  -- usually the user's patch/preset (e.g. a Reaktor ensemble). The replacement
  -- plugin keeps its own presets (stored in the plugin, not the song), so try to
  -- load it by that name in the newly inserted plugin.
  if not old_preset_name and rec.broken and rec.instrument_name and rec.instrument_name ~= "" then
    old_preset_name = rec.instrument_name
  end
  dump_params(pp.plugin_device, "OLD")
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
  if old_active ~= nil and new_dev then
    pcall(function() new_dev.is_active = old_active end)
  end
  if new_dev then dump_params(new_dev, "NEW") end
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
  local method, err = transfer_state(new_dev, old_data, old_preset_name, same_format, old_params)
  if method then
    local status = method == "parameters" and "upgraded-with-parameters"
      or method == "name" and "upgraded-name-matched-preset"
      or "upgraded-parameter-synth"
    return {
      status = status,
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
