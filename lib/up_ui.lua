local up_core = require("up_core")
local up_slicer = require("up_slicer")

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

local function old_label(rec)
  local plugin = rec.device_name
  local preset
  if rec.kind == "instrument" then
    preset = rec.instrument_name
  elseif rec.active_preset then
    preset = rec.active_preset
  end
  if not plugin or plugin == "" then
    if rec.analysis then
      plugin = rec.analysis.raw
    else
      plugin = preset
      preset = nil
    end
  end
  if plugin and preset and preset ~= "" then
    return string.format("%s  —  %s", plugin, preset)
  end
  return plugin or "?"
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
  if up_ui._row_containers then
    for _, row in ipairs(up_ui._row_containers) do
      list_box:remove_child(row)
    end
  end
  up_ui._row_containers = {}
  up_ui._row_views = {}

  local header = vb:row{
    spacing = 6,
    vb:text{ text = "Current plugin", width = 320 },
    vb:text{ text = "Replace with", width = 320 },
    vb:text{ text = "Result", width = 220 },
  }
  list_box:add_child(header)
  table.insert(up_ui._row_containers, header)
end

function up_ui.add_row(result)
  local vb = up_ui._vb
  local list_box = up_ui._list_box
  local rec = result.entry
  local cands = result.candidates or {}
  local old_tf = vb:textfield{ text = old_label(rec), active = false, width = 320 }

  local items = { "Keep current (" .. old_label(rec) .. ")" }
  for _, c in ipairs(cands) do
    table.insert(items, c.path or c.raw)
  end
  local popup = vb:popup{ items = items, value = (#cands > 0 and 2 or 1), width = 320 }

  local result_txt = vb:text{ text = "", width = 220 }
  table.insert(up_ui._row_views, { popup = popup, candidates = cands, result_txt = result_txt })

  local row = vb:row{ margin = 0, spacing = 6, old_tf, popup, result_txt }
  list_box:add_child(row)
  table.insert(up_ui._row_containers, row)
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
        function(result)
          up_ui.add_row(result)
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
  local list_box = vb:column{ width = 880, spacing = 1 }
  local upgrade_btn = vb:button{
    text = "Upgrade",
    active = false,
    notifier = function() up_ui.do_upgrade() end,
  }

  local content = vb:column{
    margin = 10,
    spacing = 8,
    vb:row{ list_box },
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

  up_ui._dialog = renoise.app():show_custom_dialog("Plugin Updater", content)
  up_ui.start_scan()
end

return up_ui
