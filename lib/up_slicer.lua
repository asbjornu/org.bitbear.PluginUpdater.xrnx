local up_slicer = {}

function up_slicer.run(thread_func, on_done, is_cancelled)
  assert(type(thread_func) == "function", "expected a function")

  local thread = coroutine.create(thread_func)

  local function on_idle()
    if is_cancelled and is_cancelled() then
      renoise.tool().app_idle_observable:remove_notifier(on_idle)
      return
    end
    local status = coroutine.status(thread)
    if status == "suspended" then
      local ok, err = coroutine.resume(thread)
      if not ok then
        renoise.tool().app_idle_observable:remove_notifier(on_idle)
        renoise.app():show_warning("Plugin Updater error:\n" .. tostring(err))
        return
      end
    elseif status == "dead" then
      renoise.tool().app_idle_observable:remove_notifier(on_idle)
      if on_done then
        on_done()
      end
    end
  end

  renoise.tool().app_idle_observable:add_notifier(on_idle)
  return on_idle
end

return up_slicer
