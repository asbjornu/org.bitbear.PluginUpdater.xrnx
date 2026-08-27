local up_core = require("up_core")

local up_ui = {}
up_ui._dialog = nil

function up_ui.format_report(results, dry_run)
  local lines = {}
  table.insert(lines, "Plugin Updater - " .. (dry_run and "DRY RUN (no changes made)" or "UPGRADE REPORT"))
  table.insert(lines, string.rep("=", 64))
  if #results == 0 then
    table.insert(lines, "No plugin devices found in the current song.")
  end
  local counts = {}
  for _, r in ipairs(results) do
    counts[r.status] = (counts[r.status] or 0) + 1
    local rec = r.entry
    local loc = rec.kind == "track"
      and ("Track " .. rec.track_index .. " [" .. (rec.track_name or "?") .. "] device " .. rec.device_index)
      or ("Instrument " .. rec.instrument_index .. " [" .. (rec.instrument_name or "?") .. "]")
    local old_id = (rec.analysis and rec.analysis.raw) or rec.device_name or "?"
    local line = string.format("[%s]\n  %s\n  old: %s", r.status, loc, old_id)
    if r.candidate then
      line = line .. "\n  new: " .. (r.candidate.path or r.candidate.raw)
    end
    if rec.broken then
      line = line .. string.format(
        "\n  broken=%s path_readable=%s preset_data=%s",
        tostring(rec.broken),
        tostring(rec.device_path ~= nil),
        tostring(rec.preset_data_accessible))
    end
    if r.swap and r.swap.detail then
      line = line .. "\n  note: " .. r.swap.detail
    end
    table.insert(lines, line)
  end
  table.insert(lines, string.rep("=", 64))
  table.insert(lines, "Summary:")
  for k, v in pairs(counts) do
    table.insert(lines, string.format("  %s: %d", k, v))
  end
  return table.concat(lines, "\n")
end

function up_ui.show_dialog()
  local song = renoise.song()
  if not song then
    renoise.app():show_warning("Open a song first.")
    return
  end
  local vb = renoise.ViewBuilder()
  local dry_box = vb:checkbox{ value = true }
  local report_text = vb:multiline_text{
    text = "Press 'Scan' to analyze the current song.",
    width = 680,
    height = 380,
  }
  local function do_run(dry)
    local ok, results = pcall(function() return up_core.run(song, dry) end)
    if not ok then
      report_text.text = "Error while running:\n" .. tostring(results)
      renoise.app():show_status("Plugin Updater: error")
      return
    end
    report_text.text = up_ui.format_report(results, dry)
    local upgraded = 0
    for _, r in ipairs(results) do
      if r.status and r.status:find("^upgraded") then
        upgraded = upgraded + 1
      end
    end
    renoise.app():show_status(string.format(
      "Plugin Updater: %d device(s) %s",
      upgraded, dry and "would be upgraded" or "upgraded"))
  end
  local content = vb:column{
    margin = 10,
    spacing = 8,
    vb:row{ vb:text{ text = "Plugin Updater" } },
    vb:row{
      dry_box,
      vb:text{ text = "Dry run (report only)" },
      vb:button{ text = "Scan", notifier = function() do_run(dry_box.value) end },
      vb:button{ text = "Run Upgrades", notifier = function() do_run(false) end },
      vb:button{
        text = "Close",
        notifier = function()
          if up_ui._dialog then
            up_ui._dialog:close()
          end
        end,
      },
    },
    vb:row{ report_text },
  }
  up_ui._dialog = renoise.app():show_custom_dialog("Plugin Updater", content)
end

return up_ui
