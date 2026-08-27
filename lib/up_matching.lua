local up_util = require("up_util")

local up_matching = {}

function up_matching.build_track_pool(song, yield_fn, on_progress)
  local pool = {}
  local seen = {}
  for ti = 1, #song.tracks do
    if on_progress then
      on_progress("Indexing track plugins", ti, #song.tracks)
    end
    if yield_fn then
      yield_fn()
    end
    local track = song.tracks[ti]
    local ok, infos = pcall(function() return track.available_device_infos end)
    if ok and infos then
      for _, info in ipairs(infos) do
        if up_util.is_plugin_path(info.device_path) and info.device_path and not seen[info.device_path] then
          seen[info.device_path] = true
          local a = up_util.analyze_plugin(info.device_path, info.device_name)
          a.path = info.device_path
          table.insert(pool, a)
        end
      end
    end
  end
  return pool
end

function up_matching.build_instrument_pool(song, yield_fn, on_progress)
  local pool = {}
  local seen = {}
  for ii = 1, #song.instruments do
    if on_progress then
      on_progress("Indexing instrument plugins", ii, #song.instruments)
    end
    if yield_fn then
      yield_fn()
    end
    local ok, infos = pcall(function()
      return song.instruments[ii].plugin_properties.available_plugin_infos
    end)
    if ok and infos then
      for _, info in ipairs(infos) do
        local p = info.path or info.name
        if p and up_util.is_plugin_path(p) and not seen[p] then
          seen[p] = true
          local a = up_util.analyze_plugin(p, info.name)
          a.path = p
          table.insert(pool, a)
        end
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
