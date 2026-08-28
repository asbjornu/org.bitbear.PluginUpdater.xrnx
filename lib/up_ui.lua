local up_core = require("up_core")
local up_slicer = require("up_slicer")
local up_util = require("up_util")

local PLUGIN_ROWS_VISIBLE = 12
local LIST_HEIGHT = 340

local up_ui = {}
up_ui._dialog = nil
up_ui._vb = nil
up_ui._song = nil
up_ui._closed = false
up_ui._results = nil
up_ui._row_views = nil
up_ui._row_containers = nil
up_ui._status_text = nil
up_ui._list_box = nil
up_ui._upgrade_btn = nil
up_ui._scan_notifier = nil
up_ui._upgrade_notifier = nil
up_ui._visible = PLUGIN_ROWS_VISIBLE
up_ui._header_row = nil
up_ui._data_rows = nil
up_ui._mounted = nil
up_ui._scroll_first = 0
up_ui._scrollbar = nil
up_ui._row_h = nil
up_ui._header_h = nil
up_ui._list_col = nil

local function old_label(rec)
  local proto = rec.analysis and rec.analysis.protocol
  local plugin = up_util.format_plugin(rec.device_name, proto)
  if not plugin or plugin == "" then
    if rec.analysis then
      plugin = up_util.format_plugin(rec.analysis.raw, proto)
    else
      return "?"
    end
  end
  local preset
  if rec.kind == "instrument" then
    preset = rec.instrument_name
  elseif rec.active_preset then
    preset = rec.active_preset
  end
  if preset and preset ~= "" then
    local extra = up_util.strip_redundant_prefix(preset, proto, rec.analysis)
    if extra and extra ~= "" then
      return string.format("%s (%s)", plugin, extra)
    end
  end
  return plugin
end

function up_ui.stop_scan()
  if up_ui._scan_notifier then
    pcall(function()
      renoise.tool().app_idle_observable:remove_notifier(up_ui._scan_notifier)
    end)
    up_ui._scan_notifier = nil
  end
end

function up_ui.stop_upgrade()
  if up_ui._upgrade_notifier then
    pcall(function()
      renoise.tool().app_idle_observable:remove_notifier(up_ui._upgrade_notifier)
    end)
    up_ui._upgrade_notifier = nil
  end
end

function up_ui.stop_all()
  up_ui.stop_scan()
  up_ui.stop_upgrade()
end

function up_ui.summary()
  local results = up_ui._results or {}
  local counts = {}
  for _, r in ipairs(results) do
    local s = r.status or (r.candidate and "pending" or "no-candidate")
    counts[s] = (counts[s] or 0) + 1
  end
  local parts = {}
  for k, v in pairs(counts) do
    table.insert(parts, string.format("%s: %d", k, v))
  end
  return "Done. " .. table.concat(parts, "   ")
end

function up_ui.clear_list()
  local vb = up_ui._vb
  local list_box = up_ui._list_box
  if up_ui._mounted then
    for _, row in ipairs(up_ui._mounted) do
      list_box:remove_child(row)
    end
  end
  up_ui._mounted = {}
  up_ui._data_rows = {}
  up_ui._row_views = {}
  up_ui._scroll_first = 0

  local header = vb:row{
    spacing = 6,
    vb:text{ text = "Current plugin", width = 320 },
    vb:text{ text = "Replace with", width = 320 },
    vb:text{ text = "Result", width = 220 },
  }
  up_ui._header_row = header
  up_ui._header_h = header.height
  list_box:add_child(header)
  table.insert(up_ui._mounted, header)
  if up_ui._scrollbar then
    up_ui._scrollbar.max = up_ui._visible
    up_ui._scrollbar.value = 0
  end
end

function up_ui.recompute_visible()
  local hb = renoise.ViewBuilder
  local header_h = (up_ui._header_h and up_ui._header_h > 0) and up_ui._header_h or hb.DEFAULT_CONTROL_HEIGHT
  local row_h = (up_ui._row_h and up_ui._row_h > 0) and up_ui._row_h or hb.DEFAULT_CONTROL_HEIGHT
  local visible = math.max(1, math.floor((LIST_HEIGHT - header_h) / row_h))
  up_ui._visible = visible
  if up_ui._scrollbar then
    up_ui._scrollbar.max = math.max(visible, #up_ui._data_rows)
    up_ui._scrollbar.pagestep = visible
  end
  up_ui.refresh_scroll()
end

function up_ui.apply_scroll()
  local list_box = up_ui._list_box
  if up_ui._mounted then
    for _, row in ipairs(up_ui._mounted) do
      list_box:remove_child(row)
    end
  end
  up_ui._mounted = {}
  list_box:add_child(up_ui._header_row)
  table.insert(up_ui._mounted, up_ui._header_row)
  local n = #up_ui._data_rows
  local first = up_ui._scroll_first + 1
  local last = math.min(up_ui._scroll_first + up_ui._visible, n)
  for i = first, last do
    local row = up_ui._data_rows[i]
    list_box:add_child(row)
    table.insert(up_ui._mounted, row)
  end
  if up_ui._scrollbar and up_ui._list_col then
    local h = up_ui._list_col.height
    if not h or h <= 0 then
      h = 0
      for _, r in ipairs(up_ui._mounted) do
        h = h + (r.height or 0)
      end
    end
    if h > 0 then
      up_ui._scrollbar.height = h
    end
  end
end

function up_ui.wheel_scroll(event)
  if event.type ~= "wheel" then
    return event
  end
  local sb = up_ui._scrollbar
  if sb then
    local dir = event.direction
    local step = (dir == "down") and 1 or (dir == "up" and -1 or 0)
    if step ~= 0 then
      local upper = sb.max - sb.pagestep
      if upper < 0 then upper = 0 end
      local nv = sb.value + step * sb.step
      if nv < 0 then nv = 0 end
      if nv > upper then nv = upper end
      sb.value = nv
    end
  end
  return nil
end

function up_ui.refresh_scroll()
  local n = #up_ui._data_rows
  local sb = up_ui._scrollbar
  if sb then
    sb.max = math.max(up_ui._visible, n)
    if n <= up_ui._visible then
  up_ui._scroll_first = 0
  up_ui._fill_idx = 0
    else
      up_ui._scroll_first = n - up_ui._visible
    end
    sb.value = up_ui._scroll_first
  else
    up_ui._scroll_first = 0
  end
  up_ui.apply_scroll()
end

function up_ui.on_scroll(value)
  up_ui._scroll_first = value
  up_ui.apply_scroll()
end

function up_ui.found_row(rec)
  local vb = up_ui._vb
  local old_tf = vb:textfield{ text = old_label(rec), active = false, width = 320 }
  local popup = vb:popup{ items = { "(gathering replacements...)" }, value = 1, active = false, width = 320 }
  local result_txt = vb:text{ text = "", width = 220 }
  local row = vb:row{
    margin = 0,
    spacing = 6,
    mouse_events = { "wheel" },
    mouse_handler = up_ui.wheel_scroll,
    old_tf, popup, result_txt,
  }
  table.insert(up_ui._data_rows, row)
  table.insert(up_ui._row_views, { popup = popup, candidates = {}, result_txt = result_txt })
  up_ui.refresh_scroll()
  if not up_ui._row_h and row.height and row.height > 0 then
    up_ui._row_h = row.height
    up_ui.recompute_visible()
  end
end

function up_ui.fill_row(result)
  up_ui._fill_idx = (up_ui._fill_idx or 0) + 1
  local rv = up_ui._row_views[up_ui._fill_idx]
  if not rv then
    return
  end
  local rec = result.entry
  local cands = result.candidates or {}
  local items = { "Keep current: " .. old_label(rec) }
  for _, c in ipairs(cands) do
    table.insert(items, up_util.format_plugin(c.name, c.protocol))
  end
  rv.popup.items = items
  rv.popup.value = (#cands > 0 and 2 or 1)
  rv.popup.active = true
  rv.candidates = cands
end

function up_ui.start_scan()
  up_ui.stop_scan()
  local song = up_ui._song
  if up_ui._upgrade_btn then
    up_ui._upgrade_btn.active = false
  end
  if up_ui._status_text then
    up_ui._status_text.text = "Scanning the song..."
  end
  up_ui.clear_list()
  local on_progress = function(phase, cur, total)
    if up_ui._status_text then
      up_ui._status_text.text = string.format("%s (%d/%d)...", phase, cur, total)
    end
  end
  up_ui._scan_notifier = up_slicer.run(
    function()
      local count = 0
      up_ui._results = up_core.analyze(
        song,
        function() coroutine.yield() end,
        function(rec)
          up_ui.found_row(rec)
        end,
        function(result)
          up_ui.fill_row(result)
          count = count + 1
          if up_ui._status_text then
            up_ui._status_text.text = string.format("Found %d: %s", count, old_label(result.entry))
          end
        end,
        on_progress)
      coroutine.yield()
      if up_ui._status_text then
        up_ui._status_text.text = string.format(
          "Found %d plugin device(s). Choose a replacement per row, then press 'Upgrade'.", count)
      end
      if up_ui._upgrade_btn then
        up_ui._upgrade_btn.active = true
      end
    end,
    nil,
    function() return up_ui._closed end)
end

function up_ui.do_upgrade()
  if not up_ui._results then
    return
  end
  local song = up_ui._song
  local selected = {}
  for i, r in ipairs(up_ui._results) do
    local rv = up_ui._row_views[i]
    local cands = r.candidates or {}
    if rv and rv.popup and #cands > 0 then
      local idx = rv.popup.value
      if idx >= 2 then
        local chosen = cands[idx - 1]
        if chosen then
          table.insert(selected, { result = r, chosen = chosen, rv = rv })
        end
      end
    end
  end
  if #selected == 0 then
    up_ui._status_text.text = "No replacements selected."
    return
  end

  up_ui.stop_scan()
  up_ui.stop_upgrade()
  up_ui._upgrade_btn.active = false
  up_ui._status_text.text = string.format("Upgrading %d plugin(s)...", #selected)

  up_ui._upgrade_notifier = up_slicer.run(
    function()
      for _, s in ipairs(selected) do
        local res = up_core.apply_one(song, s.result, s.chosen)
        s.result.status = res.status
        s.result.detail = res.detail
        if s.rv and s.rv.result_txt then
          s.rv.result_txt.text = (res.status or "")
            .. (res.detail and (" - " .. res.detail) or "")
        end
        coroutine.yield()
      end
    end,
    function()
      up_ui._upgrade_btn.active = true
      up_ui._status_text.text = up_ui.summary()
      up_ui._upgrade_notifier = nil
    end,
    function() return up_ui._closed end)
end

function up_ui.show_dialog()
  local song = renoise.song()
  if not song then
    renoise.app():show_warning("Open a song first.")
    return
  end
  up_ui._song = song
  up_ui._closed = false
  up_ui._results = nil
  up_ui._row_views = nil

  local vb = renoise.ViewBuilder()
  up_ui._vb = vb

  local status_text = vb:text{ text = "Opening..." }
  local list_box = vb:column{
    width = 880,
    spacing = 1,
    mouse_events = { "wheel" },
    mouse_handler = up_ui.wheel_scroll,
  }
  local scrollbar = vb:scrollbar{
    width = 16,
    height = LIST_HEIGHT,
    min = 0,
    max = PLUGIN_ROWS_VISIBLE,
    step = 1,
    pagestep = PLUGIN_ROWS_VISIBLE,
    autohide = true,
    notifier = function(v) up_ui.on_scroll(v) end,
  }
  local upgrade_btn = vb:button{
    text = "Upgrade",
    active = false,
    notifier = function() up_ui.do_upgrade() end,
  }

  local list_col = vb:column{ width = 880, list_box }
  local content = vb:column{
    margin = 10,
    spacing = 8,
    mouse_events = { "wheel" },
    mouse_handler = up_ui.wheel_scroll,
    vb:row{
      list_col,
      scrollbar,
    },
    vb:horizontal_aligner{
      mode = "justify",
      width = "100%",
      status_text,
      upgrade_btn,
    },
  }

  up_ui._status_text = status_text
  up_ui._list_box = list_box
  up_ui._upgrade_btn = upgrade_btn
  up_ui._scrollbar = scrollbar
  up_ui._list_col = list_col
  up_ui._visible = PLUGIN_ROWS_VISIBLE

  up_ui._dialog = renoise.app():show_custom_dialog("Plugin Updater", content)
  up_ui.start_scan()
end

return up_ui
