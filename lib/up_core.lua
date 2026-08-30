local up_inventory = require("up_inventory")
local up_matching = require("up_matching")
local up_swap = require("up_swap")

local up_core = {}

-- The candidate pool depends only on the (session-global) set of installed
-- plugins, not on the song. Building it (analyze_plugin per plugin) is the slow
-- "gathering replacements" phase, so cache it and rebuild only when the plugin
-- universe changes.
local _pool_cache = nil

local function pool_signature(song)
  local parts = {}
  pcall(function()
    for ii = 1, #song.instruments do
      local infos = song.instruments[ii].plugin_properties.available_plugin_infos
      if infos then
        for _, info in ipairs(infos) do
          if info.path then parts[#parts + 1] = info.path end
        end
      end
      if #parts > 0 then break end
    end
  end)
  pcall(function()
    for ti = 1, #song.tracks do
      local devs = song.tracks[ti].available_devices
      if devs then
        for _, p in ipairs(devs) do
          if type(p) == "string" then parts[#parts + 1] = p end
        end
      end
      if #parts > 0 then break end
    end
  end)
  table.sort(parts)
  return table.concat(parts, "|")
end

function up_core.build_pools(song, yield_fn, on_progress)
  local sig = pool_signature(song)
  if _pool_cache and _pool_cache.sig == sig then
    return _pool_cache.track, _pool_cache.inst
  end
  local inst_pool = up_matching.build_instrument_pool(song, yield_fn, on_progress)
  local track_pool = up_matching.build_track_pool(song, yield_fn, on_progress, inst_pool)
  if sig ~= "" then
    _pool_cache = { sig = sig, track = track_pool, inst = inst_pool }
  end
  return track_pool, inst_pool
end

function up_core.invalidate_pool_cache()
  _pool_cache = nil
end

function up_core.match_entries(entries, pools, yield_fn, on_progress, on_entry)
  local track_pool, inst_pool = pools.track, pools.inst
  local results = {}
  local n = #entries
  for i, rec in ipairs(entries) do
    if on_progress then
      on_progress("Matching replacements", i, n)
    end
    if yield_fn then
      yield_fn()
    end
    local pool = (rec.kind == "track") and track_pool or inst_pool
    local candidates = up_matching.find_candidates(pool, rec)
    local result = {
      entry = rec,
      candidates = candidates,
      candidate = candidates[1],
    }
    table.insert(results, result)
    if on_entry then
      on_entry(result)
    end
  end
  return results
end

function up_core.analyze(song, yield_fn, on_found, on_entry, on_progress, pools)
  local entries = up_inventory.scan(song, yield_fn, on_progress, on_found)
  local track_pool, inst_pool
  if pools then
    track_pool, inst_pool = pools.track, pools.inst
  else
    track_pool, inst_pool = up_core.build_pools(song, yield_fn, on_progress)
  end
  local results = up_core.match_entries(entries, { track = track_pool, inst = inst_pool },
    yield_fn, on_progress, on_entry)
  up_core._debug = { track = #track_pool, inst = #inst_pool }
  return results
end

function up_core.apply_one(song, result, chosen)
  local rec = result.entry
  local candidate = chosen or result.candidate
  if not candidate then
    return { status = rec.broken and "skipped-no-candidate-broken" or "skipped-up-to-date" }
  end
  -- Guard the swap so a single problematic plugin (e.g. a heavy synth whose
  -- load_plugin exceeds Renoise's script-time budget) cannot abort the entire
  -- upgrade run; record the failure as a result instead.
  local ok_swap, swap = pcall(function()
    if rec.kind == "track" then
      return up_swap.swap_track_device(song, rec, candidate)
    else
      return up_swap.swap_instrument(song, rec, candidate)
    end
  end)
  if not ok_swap or not swap then
    return { status = "error", detail = tostring(swap) }
  end
  return { status = swap.status, detail = swap.detail }
end

return up_core
