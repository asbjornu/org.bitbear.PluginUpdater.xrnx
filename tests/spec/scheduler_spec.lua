-- Tests for up_slicer: the coroutine scheduler that spreads long-running work
-- (scan / swap) across Renoise's app-idle ticks so the script-busy watchdog is
-- never tripped.

section("upgrade reinspection yields across ticks (no watchdog stall)")
do
  -- Regression for the post-upgrade "script busy" stall: the per-row reinspection
  -- used to run as one synchronous block inside on_done, re-reading every preset
  -- chunk at once. It now lives in the coroutine and yields between rows, so the
  -- work is spread across idle ticks instead of tripping Renoise's time budget.
  local obs = {
    _fn = nil,
    add_notifier = function(self, f) self._fn = f end,
    remove_notifier = function(self) self._fn = nil end,
    _fire = function(self) if self._fn then self._fn() end end,
  }
  local real_tool = _G.renoise.tool
  _G.renoise.tool = function()
    return {
      bundle_path = "", app_idle_observable = obs,
      app_new_document_observable = { add_notifier = function() end, remove_notifier = function() end },
      app_release_document_observable = { add_notifier = function() end, remove_notifier = function() end },
    }
  end
  local phase2 = {}
  local done = false
  up_slicer.run(
    function()
      for _ = 1, 3 do coroutine.yield() end          -- upgrade loop
      for i = 1, 4 do table.insert(phase2, i); coroutine.yield() end  -- reinspection loop
    end,
    function() done = true end,
    function() return false end)
  local ticks = 0
  while obs._fn and ticks < 100 do obs:_fire(); ticks = ticks + 1 end
  check(#phase2 == 4, "reinspection phase ran all iterations inside the coroutine")
  check(done, "the coroutine completed and on_done fired")
  check(ticks > 1, "work was spread over multiple idle ticks (yields), not one block")
  _G.renoise.tool = real_tool
end
