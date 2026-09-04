-- Spreads a long-running body of work across Renoise's app-idle ticks so the
-- script-time watchdog is never tripped. The caller passes a function that does
-- its work in chunks (yielding with `coroutine.yield()` between chunks); this
-- module drives that coroutine from the idle observable until it finishes.

local up_scheduler = {}

function up_scheduler.run(thread_function, on_completion, is_cancelled)
  assert(type(thread_function) == "function", "expected a function")

  local thread = coroutine.create(thread_function)

  local function on_idle_tick()
    if is_cancelled and is_cancelled() then
      renoise.tool().app_idle_observable:remove_notifier(on_idle_tick)
      return
    end
    local status = coroutine.status(thread)
    if status == "suspended" then
      local succeeded, error_message = coroutine.resume(thread)
      if not succeeded then
        renoise.tool().app_idle_observable:remove_notifier(on_idle_tick)
        renoise.app():show_warning("Plup error:\n" .. tostring(error_message))
        return
      end
    elseif status == "dead" then
      renoise.tool().app_idle_observable:remove_notifier(on_idle_tick)
      if on_completion then
        on_completion()
      end
    end
  end

  renoise.tool().app_idle_observable:add_notifier(on_idle_tick)
  return on_idle_tick
end

return up_scheduler
