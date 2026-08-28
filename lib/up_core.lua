local up_inventory = require("up_inventory")
local up_matching = require("up_matching")
local up_swap = require("up_swap")

local up_core = {}

function up_core.build_pools(song, yield_fn, on_progress, verbose)
  local inst_pool = up_matching.build_instrument_pool(song, yield_fn, on_progress)
  up_matching.debug_dump_device_infos(song)
  local track_pool = up_matching.build_track_pool(song, yield_fn, on_progress, inst_pool)
  if verbose then
    print(string.format("[PluginUpdater] track pool=%d inst pool=%d", #track_pool, #inst_pool))
    for k, a in ipairs(track_pool) do
      print(string.format("[PluginUpdater]   track_pool[%d] path=%q base=%q vendor=%q proto=%s",
        k, a.path, a.base, a.vendor, tostring(a.protocol)))
    end
    for k, a in ipairs(inst_pool) do
      print(string.format("[PluginUpdater]   inst_pool[%d] path=%q base=%q vendor=%q proto=%s",
        k, a.path, a.base, a.vendor, tostring(a.protocol)))
    end
  end
  return track_pool, inst_pool
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
    local candidates = up_matching.find_candidates(pool, rec.analysis)
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
    track_pool, inst_pool = up_core.build_pools(song, yield_fn, on_progress, false)
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
  local swap
  if rec.kind == "track" then
    swap = up_swap.swap_track_device(song, rec, candidate)
  else
    swap = up_swap.swap_instrument(song, rec, candidate)
  end
  return { status = swap.status, detail = swap.detail }
end

return up_core
