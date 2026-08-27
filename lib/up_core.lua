local up_inventory = require("up_inventory")
local up_matching = require("up_matching")
local up_swap = require("up_swap")

local up_core = {}

function up_core.analyze(song, yield_fn)
  local entries = up_inventory.scan(song, yield_fn)
  local track_pool = up_matching.build_track_pool(song, yield_fn)
  local inst_pool = up_matching.build_instrument_pool(song, yield_fn)
  local results = {}
  for _, rec in ipairs(entries) do
    if yield_fn then
      yield_fn()
    end
    local pool = (rec.kind == "track") and track_pool or inst_pool
    local candidates = up_matching.find_candidates(pool, rec.analysis)
    table.insert(results, {
      entry = rec,
      candidates = candidates,
      candidate = candidates[1],
    })
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
