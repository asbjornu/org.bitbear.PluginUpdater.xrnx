local up_preset = {}

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
  end
  return nil
end

return up_preset
