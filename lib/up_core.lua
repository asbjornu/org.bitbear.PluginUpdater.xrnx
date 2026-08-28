local up_inventory = require("up_inventory")
local up_matching = require("up_matching")
local up_swap = require("up_swap")

local up_core = {}

function up_core.analyze(song, yield_fn, on_found, on_entry, on_progress)
  local entries = up_inventory.scan(song, yield_fn, on_progress, on_found)
  local inst_pool = up_matching.build_instrument_pool(song, yield_fn, on_progress)
  up_matching.debug_dump_device_infos(song)
  local track_pool = up_matching.build_track_pool(song, yield_fn, on_progress, inst_pool)
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
    print(string.format(
      "[PluginUpdater] entry %d/%d: kind=%s path=%q base=%q vendor=%q proto=%s -> %d candidate(s)",
      i, n, rec.kind, tostring(rec.device_path), tostring(rec.analysis.base),
      tostring(rec.analysis.vendor), tostring(rec.analysis.protocol), #candidates))
    for k, c in ipairs(candidates) do
      print(string.format("    [%d] %q (proto=%s base=%q vendor=%q)", k, c.path,
        tostring(c.protocol), tostring(c.base), tostring(c.vendor)))
    end
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
  up_core._debug = { track = #track_pool, inst = #inst_pool }
  print(string.format("[PluginUpdater] track pool=%d inst pool=%d", #track_pool, #inst_pool))
  for k, a in ipairs(track_pool) do
    print(string.format("[PluginUpdater]   track_pool[%d] path=%q base=%q vendor=%q proto=%s",
      k, a.path, a.base, a.vendor, tostring(a.protocol)))
  end
  for k, a in ipairs(inst_pool) do
    print(string.format("[PluginUpdater]   inst_pool[%d] path=%q base=%q vendor=%q proto=%s",
      k, a.path, a.base, a.vendor, tostring(a.protocol)))
  end
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
