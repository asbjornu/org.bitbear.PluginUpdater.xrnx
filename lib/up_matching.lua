local up_util = require("up_util")

local up_matching = {}

local function safeget(obj, k)
  local ok, v = pcall(function() return obj[k] end)
  if not ok then return nil end
  return v
end

local NAME_KEYS = { "name", "device_name", "display_name", "plugin_name", "product_name", "short_name" }

local function track_name_of(info)
  for _, k in ipairs(NAME_KEYS) do
    local v = safeget(info, k)
    if type(v) == "string" and v ~= "" then
      return v
    end
    if type(v) == "function" then
      local ok, r = pcall(v, info)
      if ok and type(r) == "string" and r ~= "" then
        return r
      end
    end
  end
  return nil
end

local function track_infos(track)
  -- available_devices  -> loadable full paths (VST = readable, VST3 = opaque UID,
  --   AU = 4-char code). available_device_infos -> DeviceInfo objects, PARALLEL
  --   to available_devices. Zip them so each pool entry keeps a loadable path AND
  --   a readable name, which is the only reliable key for matching across
  --   protocols (DeviceInfo.device_path is nil in this binding).
  local okD, strs = pcall(function() return track.available_devices end)
  local okI, infos = pcall(function() return track.available_device_infos end)
  if not up_matching._dbg_track then
    up_matching._dbg_track = true
    print(string.format("[PluginUpdater] devices n=%s  infos n=%s",
      (okD and strs) and tostring(#strs) or "ERR",
      (okI and infos) and tostring(#infos) or "ERR"))
    if okI and infos then
      local funcs = {}
      for i = 1, math.min(#infos, 4) do
        local d = infos[i]
        local parts = {}
        for _, k in ipairs(NAME_KEYS) do
          local v = safeget(d, k)
          if type(v) == "string" then
            parts[#parts + 1] = string.format("%s=%q", k, v)
          elseif type(v) == "function" then
            funcs[k] = true
          end
        end
        print(string.format("    infos[%d] %s", i,
          #parts > 0 and table.concat(parts, " ") or "(no string name field)"))
      end
      local fk = {}
      for k in pairs(funcs) do fk[#fk + 1] = k end
      if #fk > 0 then
        print("[PluginUpdater] name fields present as methods: " .. table.concat(fk, ", "))
      end
    end
    if okD and strs and okI and infos then
      for i = 1, math.min(#strs, #infos) do
        if type(strs[i]) == "string" and strs[i]:find("VST3") then
          print(string.format("    align[%d] dev=%s -> name=%s",
            i, strs[i], tostring(track_name_of(infos[i]))))
          break
        end
      end
    end
  end
  if okD and strs and #strs > 0 then
    local out = {}
    for i, p in ipairs(strs) do
      local nm
      if okI and infos and infos[i] then
        nm = track_name_of(infos[i])
      end
      out[#out + 1] = { device_path = p, device_name = nm }
    end
    return out
  end
  return nil
end

-- Structural dump of a track's available_device_infos to discover which field
-- carries the human-readable plugin name. Renoise DeviceInfo is opaque userdata,
-- so we probe a candidate list of property getters and report type/value.
local DEVICE_INFO_KEYS = {
  "device_path", "device_name", "name", "path", "display_name",
  "short_name", "plugin_name", "product_name", "vendor_name",
  "type", "device_type", "is_plugin", "is_active", "active_preset",
  "parameters", "presets",
}

local function dump_device_info(info, idx)
  print(string.format("[PluginUpdater] device_info[%d] type=%s", idx, type(info)))
  if type(info) ~= "userdata" and type(info) ~= "table" then
    print(string.format("    value=%s", tostring(info)))
    return
  end
  for _, key in ipairs(DEVICE_INFO_KEYS) do
    local ok, v = pcall(function() return info[key] end)
    if ok then
      local t = type(v)
      local desc
      if t == "string" then
        desc = string.format("%q", v)
      elseif t == "userdata" or t == "table" then
        desc = string.format("<%s len=%s>", t, tostring(#v))
      elseif t == "boolean" then
        desc = tostring(v)
      else
        desc = string.format("<%s> %s", t, tostring(v))
      end
      print(string.format("    .%s -> %s", key, desc))
    end
    local ok_m, v2 = pcall(function() return info[key .. "_observable"] end)
    if ok_m and v2 ~= nil then
      print(string.format("    .%s_observable -> present", key))
    end
  end
end

function up_matching.debug_dump_device_infos(song)
  for ti = 1, #song.tracks do
    local ok, infos = pcall(function() return song.tracks[ti].available_device_infos end)
    if ok and infos and #infos > 0 then
      print(string.format("[PluginUpdater] dumping available_device_infos for track %d (n=%d)", ti, #infos))
      for i = 1, math.min(#infos, 6) do
        dump_device_info(infos[i], i)
      end
      return
    end
  end
  print("[PluginUpdater] no available_device_infos found on any track")
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
        a.name = dn
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
        a.name = info.name
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
