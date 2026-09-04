local up_inventory = require("up_inventory")
local up_matching = require("up_matching")
local up_swap = require("up_swap")

local up_core = {}

local _pool_cache = { signature = nil, track_pool = nil, instrument_pool = nil }

-- A signature of the installed plugin universe, built from the de-duplicated
-- set of available device/plugin paths, so build_pools can return the cached
-- pools whenever the same plugins are installed regardless of which song (and
-- how many tracks/instruments) is open. Counts alone would allow false cache
-- hits when the plugin set changes but the counts stay the same. We mirror
-- build_track_pool/build_instrument_pool and stop at the first track/instrument
-- that exposes a non-empty list, since Renoise reports the session-global plugin
-- set on the first such entry (probing every track/instrument is an avoidable
-- O(tracks+instruments) cost on large songs).
local function pool_signature(tracks, instruments)
  local seen = {}
  local parts = {}
  for _, track in ipairs(tracks) do
    local ok_devices, device_paths = pcall(function() return track.available_devices end)
    if ok_devices and device_paths and #device_paths > 0 then
      for _, path in ipairs(device_paths) do
        if type(path) == "string" and not seen[path] then
          seen[path] = true
          parts[#parts + 1] = path
        end
      end
      break
    end
  end
  for _, instrument in ipairs(instruments) do
    local ok_infos, plugin_infos = pcall(function() return instrument.plugin_properties.available_plugin_infos end)
    if ok_infos and plugin_infos and #plugin_infos > 0 then
      for _, info in ipairs(plugin_infos) do
        if type(info.path) == "string" and not seen[info.path] then
          seen[info.path] = true
          parts[#parts + 1] = info.path
        end
      end
      break
    end
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

function up_core.invalidate_pool_cache()
  _pool_cache.signature = nil
  _pool_cache.track_pool = nil
  _pool_cache.instrument_pool = nil
end

function up_core.build_pools(song, yield, on_progress)
  local signature = pool_signature(song.tracks, song.instruments)
  if signature ~= ""
    and _pool_cache.signature == signature
    and _pool_cache.track_pool
    and _pool_cache.instrument_pool then
    return _pool_cache.track_pool, _pool_cache.instrument_pool
  end
  local instrument_pool = up_matching.build_instrument_pool(song, yield, on_progress)
  local track_pool = up_matching.build_track_pool(song, yield, on_progress, instrument_pool)
  if signature ~= "" then
    _pool_cache.signature = signature
    _pool_cache.track_pool = track_pool
    _pool_cache.instrument_pool = instrument_pool
  end
  return track_pool, instrument_pool
end

local function match_entries(entries, pools, yield, on_progress, on_found)
  local results = {}
  for _, entry in ipairs(entries) do
    if on_progress then
      on_progress("Matching replacements", #results + 1, #entries)
    end
    if yield then yield() end
    local pool = (entry.kind == "track") and pools.track_pool or pools.instrument_pool
    local candidates = up_matching.find_candidates(pool, entry)
    local candidate = candidates[1]
    table.insert(results, { entry = entry, candidates = candidates, candidate = candidate })
    if on_found then on_found(results[#results]) end
  end
  return results
end

local function apply_single_entry(song, result, chosen)
  local record = result.entry
  local candidate = chosen or result.candidate
  -- Nothing to upgrade to: split the outcome by whether the plugin was already
  -- up to date (a healthy plugin with no replacement found) or broken (a missing
  -- plugin with no recovery), so the result column can explain both cases.
  if not candidate then
    return { status = record.broken and "skipped-no-candidate-broken" or "skipped-up-to-date" }
  end
  -- Guard the swap so a single problematic plugin (e.g. a heavy synth whose
  -- load_plugin exceeds Renoise's script-time budget) cannot abort the entire
  -- upgrade run; record the failure as a result instead.
  local succeeded, swap_result = pcall(function()
    if record.kind == "track" then
      return up_swap.swap_track_device(song, record, candidate)
    else
      return up_swap.swap_instrument(song, record, candidate)
    end
  end)
  if not succeeded or not swap_result then
    return { status = "error", detail = tostring(swap_result) }
  end
  return { status = swap_result.status, detail = swap_result.detail }
end

function up_core.analyze(song, yield, on_progress, on_scan, on_match, recovery)
  -- `on_scan` is invoked per scanned entry record (during the scan phase);
  -- `on_match` is invoked per matched result `{entry, candidates, candidate}`
  -- (during the match phase). They receive different argument shapes, so they
  -- are kept as separate callbacks to avoid a single overloaded contract.
  local entries = up_inventory.scan(song, yield, on_progress, on_scan, recovery)
  local track_pool, instrument_pool = up_core.build_pools(song, yield, on_progress)
  local pools = { track_pool = track_pool, instrument_pool = instrument_pool }
  return match_entries(entries, pools, yield, on_progress, on_match)
end

function up_core.match_entries(entries, pools, yield, on_progress, on_found)
  return match_entries(entries, pools, yield, on_progress, on_found)
end

function up_core.apply_one(song, result, candidate)
  return apply_single_entry(song, result, candidate)
end

return up_core
