local up_inventory = require("up_inventory")
local up_matching = require("up_matching")
local up_swap = require("up_swap")

local up_core = {}

function up_core.analyze(song, yield_fn, on_found, on_entry, on_progress)
  local entries = up_inventory.scan(song, yield_fn, on_progress, on_found)
  local track_pool = up_matching.build_track_pool(song, yield_fn, on_progress)
  local inst_pool = up_matching.build_instrument_pool(song, yield_fn, on_progress)
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
