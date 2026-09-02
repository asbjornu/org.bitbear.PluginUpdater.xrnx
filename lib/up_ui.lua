local up_core = require("up_core")
local up_scheduler = require("up_scheduler")
local up_util = require("up_util")
local up_inventory = require("up_inventory")
local up_matching = require("up_matching")
local up_preset = require("up_preset")

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
up_ui._pools = nil
up_ui._saved_sel = nil
up_ui._scanning = false
up_ui._upgrading = false
up_ui._dirty = false
up_ui._watch_fn = nil

-- Stable identity for a scanned entry, used to preserve the user's dropdown
-- choice across re-scans of the same song.
local function entry_sig(rec)
  if rec.kind == "instrument" then
    return "inst|" .. tostring(rec.instrument_index) .. "|" .. tostring(rec.device_path)
  end
  return "track|" .. tostring(rec.track_index) .. "|"
    .. tostring(rec.device_name) .. "|" .. tostring(rec.device_path)
end

-- Resolve the plugin's human-readable preset/ensemble name for display. Prefer
-- an explicit preset name (mapped from the live device's active preset), then a
-- "file://.../Name.ext" ensemble path embedded in the opaque state chunk (e.g.
-- Reaktor's loaded ensemble), then -- for plugins that failed to load -- the
-- Renoise instrument name. Missing plugins expose no preset API, so the instrument
-- name is the only remaining hint; it often carries the patch, either in
-- parentheses ("VST: Reaktor5 (Make It Bright)") or as a user-given label
-- ("Dark Dreams 1"). We surface that, but never the bare plugin name itself
-- ("Reaktor5"), which would wrongly read as the replacement's preset.
local function rec_preset_name(rec)
  -- Explicit preset recovered from the plugin's own state: the actual preset name
  -- (healthy plugin) or the loaded ensemble ("Razor" for a missing Reaktor).
  local explicit
  if type(rec.active_preset_name) == "string" and rec.active_preset_name ~= "" then
    explicit = rec.active_preset_name
  elseif type(rec.active_preset_data) == "string" and rec.active_preset_data ~= "" then
    explicit = up_preset.extract_name({ active_preset_data = rec.active_preset_data })
  end

  -- Normalise vendor-specific factory-default labels ("Init", "Def It Setting",
  -- "Default", ...) to a single "init" token for display only.
  if explicit and up_preset.is_init_preset(explicit) then
    explicit = "init"
  end

  -- For a missing/recovered plugin the live API exposes no real preset, so the
  -- user's instrument name is the meaningful label (e.g. "Dark Dreams 1", or
  -- "Make It Bright" from "VST: Reaktor5 (Make It Bright)"). Prefer that over the
  -- bare ensemble name and keep the ensemble ("Razor") as a secondary detail: the
  -- preset name must be preserved and carried over, not replaced by the synth name.
  if (rec.broken or rec.recovered) and rec.instrument_name then
    local instr_label = up_util.instrument_preset_label(rec.instrument_name,
      rec.analysis and rec.analysis.protocol, rec.analysis)
    if instr_label and instr_label ~= "" then
      if explicit and explicit ~= "" and explicit ~= instr_label then
        -- Ensemble first, then the user's preset name: "Razor: Dark Dreams 1".
        return explicit .. ": " .. instr_label
      end
      return instr_label
    end
  end

  if explicit and explicit ~= "" then
    return explicit
  end

  -- Last resort (healthy plugins with no preset state): use the instrument name
  -- when it carries a real preset label, e.g. a parenthetical "Make It Bright".
  if rec.kind == "instrument" and type(rec.instrument_name) == "string" and rec.instrument_name ~= "" then
    local paren = rec.instrument_name:match("%(([^()]+)%)")
    if paren and paren:match("%S") then
      return paren:gsub("%s+", " "):match("^%s*(.-)%s*$")
    end
    local proto = rec.analysis and rec.analysis.protocol
    local extra = up_util.strip_redundant_prefix(rec.instrument_name, proto, rec.analysis)
    if extra and extra ~= "" then
      local et = up_util.token_set(extra)
      local bt = up_util.token_set(rec.analysis and rec.analysis.base or "")
      if not (et and next(et) and up_util.token_subset(et, bt)) then
        return extra
      end
    end
  end
  return nil
end

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
  local preset = rec_preset_name(rec)
  if preset and preset ~= "" then
    local extra = up_util.strip_redundant_prefix(preset, proto, rec.analysis)
    if extra and extra ~= "" then
      return string.format("%s (%s)", plugin, extra)
    end
  end
  return plugin
end

function up_ui.stop_scan()
  if up_ui._scan_notifiers then
    for _, n in ipairs(up_ui._scan_notifiers) do
      pcall(function()
        renoise.tool().app_idle_observable:remove_notifier(n)
      end)
    end
    up_ui._scan_notifiers = nil
  end
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

-- Live refresh: re-scan when a new song loads or devices/tracks/instruments
-- change, so the grid stays in sync (a newly added device becomes a new row).
-- Refresh is coalesced and suppressed while we are ourselves scanning or
-- upgrading, to avoid recursion and clobbering in-progress work.

function up_ui.detach_observers()
  local song = renoise.song()
  if song then
    pcall(function() if up_ui._tn then song.tracks_observable:remove_notifier(up_ui._tn) end end)
    pcall(function() if up_ui._in then song.instruments_observable:remove_notifier(up_ui._in) end end)
    if up_ui._dn then
      for _, d in ipairs(up_ui._dn) do
        pcall(function() d.obs:remove_notifier(d.fn) end)
      end
    end
  end
  up_ui._nl, up_ui._tn, up_ui._in, up_ui._dn = nil, nil, nil, nil
end

function up_ui.attach_device_observers()
  local song = renoise.song()
  if not song then return end
  if up_ui._dn then
    for _, d in ipairs(up_ui._dn) do
      pcall(function() d.obs:remove_notifier(d.fn) end)
    end
  end
  up_ui._dn = {}
  for _, track in ipairs(song.tracks) do
    local fn = function() up_ui.reconcile() end
    pcall(function() track.devices_observable:add_notifier(fn) end)
    table.insert(up_ui._dn, { obs = track.devices_observable, fn = fn })
  end
end

-- Remove only the song-specific observers (used to silence the device-change
-- notifications that an in-progress upgrade itself generates, so the grid is
-- not rebuilt out from under the in-place "Current plugin" update).
function up_ui.detach_device_observers()
  local song = renoise.song()
  if song then
    pcall(function()
      if up_ui._tn then song.tracks_observable:remove_notifier(up_ui._tn) end
    end)
    pcall(function()
      if up_ui._in then song.instruments_observable:remove_notifier(up_ui._in) end
    end)
  end
  if up_ui._dn then
    for _, d in ipairs(up_ui._dn) do
      pcall(function() d.obs:remove_notifier(d.fn) end)
    end
  end
  up_ui._tn, up_ui._in, up_ui._dn = nil, nil, nil
end

function up_ui.ensure_doc_observers()
  if up_ui._doc_observers then return end
  up_ui._doc_observers = true
  up_ui._release_nl = function() up_ui.on_song_releasing() end
  up_ui._new_nl = function() up_ui.on_song_loaded() end
  pcall(function()
    renoise.tool().app_release_document_observable:add_notifier(up_ui._release_nl)
  end)
  pcall(function()
    renoise.tool().app_new_document_observable:add_notifier(up_ui._new_nl)
  end)
end

function up_ui.attach_observers()
  up_ui.ensure_doc_observers()
  up_ui.detach_observers()
  local song = renoise.song()
  if not song then return end
  pcall(function()
    up_ui._tn = function() up_ui.on_structure_changed() end
    song.tracks_observable:add_notifier(up_ui._tn)
  end)
  pcall(function()
    up_ui._in = function() up_ui.on_structure_changed() end
    song.instruments_observable:add_notifier(up_ui._in)
  end)
  up_ui.attach_device_observers()
end

-- A track/instrument was added or removed: re-read the song's devices and
-- update the grid, reusing the cached candidate pool. Existing rows (and their
-- selections) are preserved; a newly added device simply gains a new row.
function up_ui.on_structure_changed()
  up_ui.attach_device_observers()
  up_ui.reconcile()
end

-- The old song is about to be replaced: drop its observers so we don't leak
-- notifiers on a song that's going away (renoise.song() still points to it
-- here).
function up_ui.on_song_releasing()
  up_ui.detach_observers()
end

-- A different song was loaded: rebuild everything from scratch, including the
-- candidate pool (the only "complete refresh" we do).
function up_ui.on_song_loaded()
  up_ui.attach_observers()
  up_ui.start_scan()
end

-- This Renoise build has no Dialog:add_close_notifier, so detect closure by
-- polling. A dialog's root content never gets a `parent` in this build, so use the
-- `visible` flag instead: it is true while shown and flips to false on close.
local function dialog_is_open()
  if not up_ui._dialog or up_ui._closed then
    return false
  end
  local ok, visible = pcall(function() return up_ui._dialog.visible end)
  if ok and visible == false then
    return false
  end
  return true
end

local _closed_blanks = 0
local function watch_tick()
  local ok, err = pcall(function()
    if up_ui._closed then
      return
    end
    if not dialog_is_open() then
      -- Tolerate a few transient "not open" ticks before tearing down, in case the
      -- visibility flag lags the dialog's actual show/close transition.
      _closed_blanks = _closed_blanks + 1
      if _closed_blanks >= 3 then
        up_ui._closed = true
        up_ui.stop_all()
        up_ui.detach_observers()
        pcall(function()
          if up_ui._watch_fn then
            renoise.tool().app_idle_observable:remove_notifier(up_ui._watch_fn)
          end
        end)
        up_ui._watch_fn = nil
      end
    else
      _closed_blanks = 0
    end
  end)
  if not ok then
    print(string.format("[PluginUpdater][watch] watch_tick ERROR: %s", tostring(err)))
  end
end

function up_ui.watch_dialog()
  if up_ui._watch_fn then
    pcall(function()
      renoise.tool().app_idle_observable:remove_notifier(up_ui._watch_fn)
    end)
  end
  up_ui._watch_fn = watch_tick
  pcall(function()
    renoise.tool().app_idle_observable:add_notifier(up_ui._watch_fn)
  end)
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

-- The "Result" column shows a coloured icon per row whose colour encodes the
-- outcome category (green = fully upgraded, yellow = partially upgraded, red =
-- failed, gray = not upgraded) and whose hover tooltip explains what happened.
-- Keeping the styles in one table means every upgrade outcome maps to exactly
-- one of the four colour categories the user asked for.
local RESULT_COLORS = {
  green = { 0, 180, 0 },
  yellow = { 200, 170, 0 },
  red = { 220, 60, 60 },
  gray = { 150, 150, 150 },
}

local RESULT_STYLES = {
  ["upgraded-with-parameters"] = {
    color = RESULT_COLORS.green, label = "Upgraded",
    tip = "Replacement loaded and the original preset/state was transferred exactly.",
  },
  ["upgraded-name-matched-preset"] = {
    color = RESULT_COLORS.green, label = "Upgraded",
    tip = "Replacement loaded with a matching factory preset of the same name; your patch should be intact.",
  },
  ["upgraded-parameter-synth"] = {
    color = RESULT_COLORS.yellow, label = "Partial",
    tip = "Replacement loaded; matching parameters were re-applied by name, so some "
      .. "settings may differ from the original.",
  },
  ["upgraded-default"] = {
    color = RESULT_COLORS.yellow, label = "Partial",
    tip = "Replacement loaded, but the original state could not be carried over, so it is at its default patch.",
  },
  ["up-to-date"] = {
    color = RESULT_COLORS.gray, label = "Current",
    tip = "Already the selected replacement; nothing to change.",
  },
  ["skipped-up-to-date"] = {
    color = RESULT_COLORS.gray, label = "Current",
    tip = "Already up to date; no replacement needed.",
  },
  ["skipped-no-candidate-broken"] = {
    color = RESULT_COLORS.gray, label = "No match",
    tip = "No replacement plugin could be found for this (broken) plugin.",
  },
  ["skipped-transfer-rejected"] = {
    color = RESULT_COLORS.red, label = "Failed",
    tip = "The replacement could not be loaded or inserted.",
  },
  ["error"] = {
    color = RESULT_COLORS.red, label = "Failed",
    tip = "The upgrade failed with an error.",
  },
}

local RESULT_PENDING = {
  color = RESULT_COLORS.gray, label = "Pending",
  tip = "Not upgraded yet. Choose a replacement and press Upgrade.",
}

local function result_style(status)
  if not status or status == "" then
    return RESULT_PENDING
  end
  return RESULT_STYLES[status] or {
    color = RESULT_COLORS.gray, label = "Unknown",
    tip = "Unrecognised result: " .. tostring(status),
  }
end

-- Paint the row's Result icon from an upgrade outcome. The text colour is the
-- category signal; the tooltip is the human-readable explanation the user asked
-- for on hover.
function up_ui.set_result(rv, status, detail)
  if not rv or not rv.result_txt then
    return
  end
  local st = result_style(status)
  rv.result_txt.text = "● " .. st.label
  rv.result_txt.color = st.color
  local tip = st.tip
  if detail and detail ~= "" then
    tip = tip .. "\n\n" .. detail
  end
  rv.result_txt.tooltip = tip
end

-- Snapshot the current dropdown choices, keyed by entry signature, so a
-- re-scan of the same song can restore them.
function up_ui.capture_selections()
  local saved = {}
  local views = up_ui._row_views or {}
  local results = up_ui._results or {}
  for i, rv in ipairs(views) do
    local r = results[i]
    if r and rv.popup and rv.candidates and #rv.candidates > 0 then
      saved[entry_sig(r.entry)] = rv.popup.value
    end
  end
  return saved
end

function up_ui.clear_list()
  local vb = up_ui._vb
  local list_box = up_ui._list_box
  if up_ui._mounted then
    for _, row in ipairs(up_ui._mounted) do
      pcall(function() list_box:remove_child(row) end)
    end
  end
  up_ui._mounted = {}
  up_ui._data_rows = {}
  up_ui._row_views = {}
  up_ui._scroll_first = 0
  up_ui._fill_idx = 0

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
      pcall(function() list_box:remove_child(row) end)
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
  local result_txt = vb:text{ text = "", width = 220, color = RESULT_COLORS.gray, tooltip = "" }
  local row = vb:row{
    margin = 0,
    spacing = 6,
    mouse_events = { "wheel" },
    mouse_handler = up_ui.wheel_scroll,
    old_tf, popup, result_txt,
  }
  table.insert(up_ui._data_rows, row)
  local rv = { popup = popup, candidates = {}, result_txt = result_txt, old_tf = old_tf }
  table.insert(up_ui._row_views, rv)
  up_ui.set_result(rv, nil)
  up_ui.refresh_scroll()
  if not up_ui._row_h and row.height and row.height > 0 then
    up_ui._row_h = row.height
    up_ui.recompute_visible()
  end
end

-- Re-read a single device after an upgrade so we can refresh its "Current
-- plugin" label. The device stays at the same index, so the original rec's
-- indices still point at it.
function up_ui.reinspect_entry(rec)
  local song = renoise.song()
  if not song then return nil end
  if rec.kind == "track" then
    local track = song.tracks[rec.track_index]
    if not track then return nil end
    return up_inventory.scan_track_device(rec.track_index, track, rec.device_index)
  else
    local inst = song.instruments[rec.instrument_index]
    if not inst then return nil end
    return up_inventory.scan_instrument_device(inst)
  end
end

-- Pick the auto-selected replacement: prefer a candidate on the same protocol
-- as the entry, otherwise a higher-ranked protocol (a real upgrade). Never
-- auto-switch to a *lower* protocol (e.g. don't move a VST3 instance onto AU).
-- Returns the 1-based popup index, or 1 ("Keep current") when none qualify.
local function auto_select_index(cands, entry)
  local ep = entry.analysis and entry.analysis.protocol
  local er = up_util.protocol_rank(ep)
  local best_i, best_score
  for i, c in ipairs(cands) do
    local cr = up_util.protocol_rank(c.protocol)
    if cr >= er then
      local score = cr * 1000 + (c.version or 0)
      if not best_score or score > best_score then
        best_score = score
        best_i = i
      end
    end
  end
  return best_i and (best_i + 1) or 1
end

function up_ui.fill_row(result, preset_value)
  up_ui._fill_idx = (up_ui._fill_idx or 0) + 1
  local rv = up_ui._row_views[up_ui._fill_idx]
  if not rv then
    return
  end
  local rec = result.entry
  local cands = result.candidates or {}
  local items = { "Keep current: " .. old_label(rec) }
  -- Show the preset that will carry over to the replacement, so the user can see
  -- the upgrade keeps their patch (e.g. "Reaktor 6 (Make It Bright)").
  local carry = rec_preset_name(rec)
  for _, c in ipairs(cands) do
    local label = up_util.format_plugin(c.name, c.protocol)
    if carry and carry ~= "" then
      local extra = up_util.strip_redundant_prefix(carry, c.protocol, c)
      if extra and extra ~= "" then
        label = string.format("%s (%s)", label, extra)
      end
    end
    table.insert(items, label)
  end
  rv.popup.items = items
  local v = preset_value or auto_select_index(cands, rec)
  if not v or v < 1 or v > #items then
    v = 1
  end
  rv.popup.value = v
  rv.popup.active = true
  rv.candidates = cands
  rv._sig = entry_sig(rec)
  -- Restore the user's previous choice for this entry, if any (same song).
  if up_ui._saved_sel then
    local sv = up_ui._saved_sel[rv._sig]
    if sv and sv >= 1 and sv <= #items then
      rv.popup.value = sv
    end
  end
end

function up_ui.spawn_scan(full)
  up_ui.stop_scan()
  up_ui._scanning = true
  up_ui._dirty = false
  local song = renoise.song()
  if up_ui._upgrade_btn then
    up_ui._upgrade_btn.active = false
  end
  if up_ui._status_text then
    up_ui._status_text.text = full and "Scanning the song..." or "Updating list..."
  end
  up_ui._saved_sel = full and {} or up_ui.capture_selections()
  up_ui.clear_list()
  if full then
    up_ui._pools = nil
  end
  local on_progress = function(phase, cur, total)
    if up_ui._status_text then
      up_ui._status_text.text = string.format("%s (%d/%d)...", phase, cur, total)
    end
  end

  if full then
    -- Overlap the two independent, order-independent phases:
    --   * scanning the song's devices (so rows appear immediately), and
    --   * building the candidate pool ("gathering replacements", the slow part).
    -- Once both are done we match + fill the rows.
    up_ui._scan_entries = {}
    up_ui._scan_done = false
    up_ui._pool_done = false
    up_ui._results = {}

    local yield = function() coroutine.yield() end

    local function finalize_match()
      if not (up_ui._scan_done and up_ui._pool_done) then
        return
      end
      up_ui._results = up_core.match_entries(
        up_ui._scan_entries, up_ui._pools, yield, on_progress,
        function(result)
          up_ui.fill_row(result)
          if up_ui._status_text then
            up_ui._status_text.text = string.format("Found %d: %s", #up_ui._results, old_label(result.entry))
          end
        end)
      if up_ui._status_text then
        up_ui._status_text.text = string.format(
          "Found %d plugin device(s). Choose a replacement per row, then press 'Upgrade'.", #up_ui._results)
      end
      if up_ui._upgrade_btn then
        up_ui._upgrade_btn.active = true
      end
      up_ui._saved_sel = nil
    end

    -- Shared completion bookkeeping, run when the last concurrent task ends.
    up_ui._scan_pending = 3
    local function task_done()
      up_ui._scan_pending = up_ui._scan_pending - 1
      if up_ui._scan_pending <= 0 then
        up_ui._scan_pending = nil
        up_ui._scan_notifiers = nil
        up_ui._scan_notifier = nil
        up_ui._scanning = false
        if up_ui._dirty then
          up_ui._dirty = false
          up_ui.reconcile()
        end
      end
    end

    -- Task A: scan the song's devices (rows appear immediately).
    local na = up_scheduler.run(
      function()
        local ok, err = pcall(function()
          up_inventory.scan(song, yield, on_progress, function(rec)
            table.insert(up_ui._scan_entries, rec)
            up_ui.found_row(rec)
          end)
        end)
        if not ok then
          renoise.app():show_warning("Plugin Updater error (scan):\n" .. tostring(err))
        end
        up_ui._scan_done = true
      end,
      task_done,
      function() return up_ui._closed end)

    -- Task B: build the candidate pool (the long "gathering replacements" phase).
    local nb = up_scheduler.run(
      function()
        local tp, ip
        local ok, err = pcall(function()
          tp, ip = up_core.build_pools(song, yield, on_progress)
        end)
        if not ok then
          renoise.app():show_warning("Plugin Updater error (pool):\n" .. tostring(err))
        end
        up_ui._pools = { track = tp, inst = ip }
        up_ui._pool_done = true
      end,
      task_done,
      function() return up_ui._closed end)

    -- Task C: wait for both, then match + fill.
    local nc = up_scheduler.run(
      function()
        while not (up_ui._scan_done and up_ui._pool_done) do
          coroutine.yield()
        end
        local ok, err = pcall(finalize_match)
        if not ok then
          renoise.app():show_warning("Plugin Updater error (match):\n" .. tostring(err))
        end
      end,
      task_done,
      function() return up_ui._closed end)

    up_ui._scan_notifiers = { na, nb, nc }
    up_ui._scan_notifier = na
  else
    -- Same-song reconcile: reuse the cached candidate pool so this stays
    -- cheap; only re-read the song's current devices and re-match them.
    up_ui._scan_notifier = up_scheduler.run(
      function()
        local entries = up_inventory.scan(song, function() coroutine.yield() end, on_progress,
          function(rec) up_ui.found_row(rec) end)
        up_ui._results = {}
        local n = #entries
        for i, rec in ipairs(entries) do
          if on_progress then
            on_progress("Matching replacements", i, n)
          end
          coroutine.yield()
          local pool = (rec.kind == "track") and up_ui._pools.track or up_ui._pools.inst
          local cands = up_matching.find_candidates(pool, rec)
          local result = { entry = rec, candidates = cands, candidate = cands[1] }
          table.insert(up_ui._results, result)
          up_ui.fill_row(result)
        end
        coroutine.yield()
        if up_ui._status_text then
          up_ui._status_text.text = string.format(
            "Found %d plugin device(s). Choose a replacement per row, then press 'Upgrade'.", #up_ui._results)
        end
        if up_ui._upgrade_btn then
          up_ui._upgrade_btn.active = true
        end
        up_ui._saved_sel = nil
      end,
      function()
        up_ui._scanning = false
        up_ui._scan_notifier = nil
        if up_ui._dirty then
          up_ui._dirty = false
          up_ui.reconcile()
        end
      end,
      function() return up_ui._closed end)
  end
end

function up_ui.start_scan()
  up_ui.spawn_scan(true)
end

-- Update the grid for the same song without rebuilding the candidate pool.
-- Existing selections are preserved; added/removed devices get/lose rows.
function up_ui.reconcile()
  if up_ui._closed then
    return
  end
  if not up_ui._pools then
    up_ui.start_scan()
    return
  end
  if up_ui._scanning or up_ui._upgrading then
    up_ui._dirty = true
    return
  end
  up_ui.spawn_scan(false)
end

function up_ui.do_upgrade()
  -- While an upgrade is running, the button acts as "Stop".
  if up_ui._upgrading then
    up_ui._abort = true
    return
  end
  if not up_ui._results then
    return
  end
  local song = renoise.song()
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

  -- Disable all row controls up front; re-enabled when the run finishes.
  if up_ui._row_views then
    for _, rv in ipairs(up_ui._row_views) do
      if rv.popup then rv.popup.active = false end
    end
  end

  if #selected == 0 then
    if up_ui._upgrade_btn then up_ui._upgrade_btn.active = true end
    if up_ui._status_text then up_ui._status_text.text = "No replacements selected." end
    up_ui.recompute_visible()
    return
  end

  up_ui.stop_scan()
  up_ui._upgrading = true
  up_ui._abort = false
  if up_ui._upgrade_btn then
    up_ui._upgrade_btn.text = "Stop"
    up_ui._upgrade_btn.active = true
  end
  up_ui._status_text.text = string.format("Upgrading %d plugin(s)...", #selected)

  -- Silence the device-change notifications our own swaps will generate, so the
  -- grid isn't rebuilt (wiping the Result column) while we update rows in place.
  up_ui.detach_device_observers()

  up_ui._upgrade_notifier = up_scheduler.run(
    function()
      local n = #selected
      for i, s in ipairs(selected) do
        if up_ui._abort then
          break
        end
        local res = up_core.apply_one(song, s.result, s.chosen)
        s.result.status = res.status
        s.result.detail = res.detail
        up_ui.set_result(s.rv, res.status, res.detail)
        if up_ui._status_text then
          up_ui._status_text.text = string.format(
            "Upgrading %d/%d: %s", i, n, old_label(s.result.entry))
        end
        coroutine.yield()
      end
      -- Re-read each upgraded row's current plugin in place. This must run inside
      -- the coroutine (yielding between rows): doing it all at once in on_done for
      -- many heavy plugins re-reads every preset chunk at once and trips Renoise's
      -- script-busy watchdog. Keep the "Replace with" dropdown and Result text as-is.
      local can_refresh = up_ui._dialog
        and pcall(function() return up_ui._dialog.visible end)
      if can_refresh then
        -- Count the rows that need refreshing so the status text can show progress.
        local n_refresh = 0
        for _, s in ipairs(selected) do
          local status = s.result.status or ""
          if string.sub(status, 1, 8) == "upgraded" and s.rv and s.rv.old_tf then
            n_refresh = n_refresh + 1
          end
        end
        local j = 0
        for _, s in ipairs(selected) do
          if up_ui._abort then break end
          local status = s.result.status or ""
          if string.sub(status, 1, 8) == "upgraded" and s.rv and s.rv.old_tf then
            j = j + 1
            if up_ui._status_text then
              up_ui._status_text.text = string.format(
                "Refreshing %d/%d: %s", j, n_refresh, old_label(s.result.entry))
            end
            local new_rec = up_ui.reinspect_entry(s.result.entry)
            if new_rec then
              s.rv.old_tf.text = old_label(new_rec)
              s.result.entry = new_rec
            end
          end
          coroutine.yield()
        end
      end
    end,
    function()
      local aborted = up_ui._abort
      up_ui._upgrading = false
      up_ui._abort = false
      up_ui._dirty = false
      if up_ui._row_views then
        for _, rv in ipairs(up_ui._row_views) do
          if rv.popup and rv.candidates and #rv.candidates > 0 then
            rv.popup.active = true
          end
        end
      end
      if up_ui._upgrade_btn then
        up_ui._upgrade_btn.text = "Upgrade"
        up_ui._upgrade_btn.active = true
      end
      up_ui._upgrade_notifier = nil
      -- The per-row reinspection that refreshes each upgraded row's "Current plugin"
      -- label is done inside the coroutine (yielding between rows) so it never runs
      -- as one big synchronous block. Here we just restore the rest of the UI.
      if up_ui._status_text then
        up_ui._status_text.text = (aborted and "Stopped. " or "") .. up_ui.summary()
      end
      -- Restore device observers we detached for the duration of the upgrade.
      up_ui.attach_observers()
    end,
    function() return up_ui._closed end)
end

function up_ui.show_dialog()
  local song = renoise.song()
  if not song then
    renoise.app():show_warning("Open a song first.")
    return
  end
  if dialog_is_open() then
    return
  end
  up_ui._song = song
  up_ui._closed = false
  up_ui._results = nil
  up_ui._row_views = nil
  up_ui._scan_pending = nil
  up_ui._scan_notifiers = nil
  up_ui._scan_entries = nil
  up_ui._scan_done = nil
  up_ui._pool_done = nil
  -- A fresh dialog gets a brand-new ViewBuilder/list_box, so any rows still
  -- referenced from a previous (now-destroyed) dialog must be discarded. Without
  -- this, clear_list tries to remove them from the new list_box and throws
  -- "view not added to parent", aborting the scan before it starts.
  up_ui._mounted = {}
  up_ui._data_rows = {}
  up_ui._header_row = nil

  if up_ui._idle_notifier then
    pcall(function()
      renoise.tool().app_idle_observable:remove_notifier(up_ui._idle_notifier)
    end)
    up_ui._idle_notifier = nil
  end

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
  up_ui.watch_dialog()
  up_ui.attach_observers()
  up_ui.start_scan()
end

return up_ui
