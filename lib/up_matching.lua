local up_util = require("up_util")

local up_matching = {}

local function track_infos(track)
  -- Prefer available_devices: it returns a plain string list of full device
  -- paths (e.g. "Audio/Effects/VST/FabFilter Pro-Q 3"). available_device_infos
  -- returns DeviceInfo objects whose device_path field is nil in this binding.
  local ok, strs = pcall(function() return track.available_devices end)
  if ok and strs and #strs > 0 then
    if not up_matching._dbg_track then
      up_matching._dbg_track = true
      local plugin_n, native_n = 0, 0
      for _, p in ipairs(strs) do
        if up_util.is_native_path(p) then native_n = native_n + 1 else plugin_n = plugin_n + 1 end
      end
      print(string.format("[PluginUpdater] available_devices: total=%d plugin=%d native=%d",
        #strs, plugin_n, native_n))
      local shown = 0
      for i, p in ipairs(strs) do
        if not up_util.is_native_path(p) then
          shown = shown + 1
          if shown <= 8 then
            print(string.format("    plugin %s", tostring(p)))
          end
        end
      end
    end
    local out = {}
    for _, p in ipairs(strs) do
      out[#out + 1] = { device_path = p, device_name = p }
    end
    return out
  end
  local ok2, infos = pcall(function() return track.available_device_infos end)
  if ok2 and infos and #infos > 0 and infos[1] and infos[1].device_path then
    return infos
  end
  return nil
end

function up_matching.build_track_pool(song, yield_fn, on_progress, fallback_pool)
  local pool = {}
  local seen = {}
  local infos = nil
  for ti = 1, #song.tracks do
    if on_progress then
      on_progress("Indexing track plugins", ti, #song.tracks)
    end
    if yield_fn then
      yield_fn()
    end
    if not infos then
      local t = track_infos(song.tracks[ti])
      if t and #t > 0 then
        infos = t
      end
    else
      break
    end
  end
  if infos then
    for j, info in ipairs(infos) do
      local dp
      if type(info) == "table" then
        dp = info.device_path
      elseif type(info) == "string" then
        dp = info
      end
      local dn = (type(info) == "table") and info.device_name or nil
      if dp and not up_util.is_native_path(dp) and not seen[dp] then
        seen[dp] = true
        local a = up_util.analyze_plugin(dp, dn)
        a.path = dp
        table.insert(pool, a)
      end
      if yield_fn and (j % 50 == 0) then
        yield_fn()
      end
    end
  end
  if #pool == 0 and fallback_pool then
    for _, a in ipairs(fallback_pool) do
      local p = tostring(a.path or "")
        :gsub("[Gg]enerators", "Effects")
        :gsub("[Gg]enerator", "Effect")
      if p ~= "" and not up_util.is_native_path(p) and not seen[p] then
        seen[p] = true
        local a2 = up_util.analyze_plugin(p, a.product or a.name)
        a2.path = p
        table.insert(pool, a2)
      end
    end
  end
  return pool
end

function up_matching.build_instrument_pool(song, yield_fn, on_progress)
  local pool = {}
  local seen = {}
  local infos = nil
  for ii = 1, #song.instruments do
    if on_progress then
      on_progress("Indexing instrument plugins", ii, #song.instruments)
    end
    if yield_fn then
      yield_fn()
    end
    if not infos then
      local ok, i = pcall(function()
        return song.instruments[ii].plugin_properties.available_plugin_infos
      end)
      if ok and i and #i > 0 then
        infos = i
      end
    else
      break
    end
  end
  if infos then
    for j, info in ipairs(infos) do
      local p = info.path or info.name
      if p and up_util.is_plugin_path(p) and not seen[p] then
        seen[p] = true
        local a = up_util.analyze_plugin(p, info.name)
        a.path = p
        table.insert(pool, a)
      end
      if yield_fn and (j % 50 == 0) then
        yield_fn()
      end
    end
  end
  return pool
end

function up_matching.vendor_ok(c, old)
  if old.vendor == "" or c.vendor == "" then
    return true
  end
  return c.vendor == old.vendor
end

function up_matching.candidate_matches(c, old)
  if not old then
    return false
  end
  if c.path == old.raw then
    return false
  end
  if c.base ~= old.base then
    return false
  end
  return up_matching.vendor_ok(c, old)
end

function up_matching.find_candidate(pool, old_analysis)
  if not old_analysis then
    return nil
  end
  local best = nil
  local best_rank = nil
  for _, c in ipairs(pool) do
    if up_matching.candidate_matches(c, old_analysis) then
      if best == nil or up_util.rank(c) > best_rank then
        best = c
        best_rank = up_util.rank(c)
      end
    end
  end
  return best
end

function up_matching.find_candidates(pool, old_analysis)
  if not old_analysis then
    return {}
  end
  local list = {}
  for _, c in ipairs(pool) do
    if up_matching.candidate_matches(c, old_analysis) then
      table.insert(list, c)
    end
  end
  table.sort(list, function(a, b) return up_util.rank(a) > up_util.rank(b) end)
  return list
end

return up_matching
