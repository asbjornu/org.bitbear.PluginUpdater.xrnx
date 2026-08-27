local up_util = require("up_util")

local up_matching = {}

function up_matching.build_track_pool(song)
  local pool = {}
  local seen = {}
  for ti = 1, #song.tracks do
    local track = song.tracks[ti]
    local ok, infos = pcall(function() return track.available_device_infos end)
    if ok and infos then
      for _, info in ipairs(infos) do
        if info.is_plugin and info.device_path and not seen[info.device_path] then
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

function up_matching.build_instrument_pool(song)
  local pool = {}
  local seen = {}
  for ii = 1, #song.instruments do
    local ok, infos = pcall(function()
      return song.instruments[ii].plugin_properties.available_plugin_infos
    end)
    if ok and infos then
      for _, info in ipairs(infos) do
        local p = info.path or info.name
        if p and not seen[p] then
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

function up_matching.find_candidate(pool, old_analysis)
  if not old_analysis then
    return nil
  end
  local best = nil
  local best_rank = nil
  for _, c in ipairs(pool) do
    if c.family_key == old_analysis.family_key and c.path ~= old_analysis.raw then
      if up_util.rank(c) > up_util.rank(old_analysis) then
        if best == nil or up_util.rank(c) > best_rank then
          best = c
          best_rank = up_util.rank(c)
        end
      end
    end
  end
  return best
end

return up_matching
