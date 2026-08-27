local up_inventory = require("up_inventory")
local up_matching = require("up_matching")
local up_swap = require("up_swap")

local up_core = {}

function up_core.run(song, dry_run)
  local entries = up_inventory.scan(song)
  local track_pool = up_matching.build_track_pool(song)
  local inst_pool = up_matching.build_instrument_pool(song)
  local results = {}
  for _, rec in ipairs(entries) do
    local pool = (rec.kind == "track") and track_pool or inst_pool
    local candidate = up_matching.find_candidate(pool, rec.analysis)
    local res = { entry = rec, candidate = candidate }
    if not candidate then
      res.status = rec.broken and "skipped-no-candidate-broken" or "skipped-up-to-date"
    elseif dry_run then
      res.status = "dry-run-candidate"
    else
      if rec.kind == "track" then
        res.swap = up_swap.swap_track_device(song, rec, candidate)
      else
        res.swap = up_swap.swap_instrument(song, rec, candidate)
      end
      res.status = res.swap.status
    end
    table.insert(results, res)
  end
  return results
end

return up_core
