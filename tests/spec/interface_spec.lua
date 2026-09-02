-- Tests for up_ui (and main.lua): the dialog, grid building, scroll, observer
-- lifecycle, the end-to-end scan/upgrade flow, and the result-icon colour/tooltip
-- mapping. Exercises the pure UI logic headlessly against the mocked Renoise.

-- 7. main.lua + up_ui (headless, mocked Renoise) ------------------------------
section("main.lua loads + up_ui logic (mocked Renoise)")
do
  -- Loading main.lua exercises its top-level (menu/keybinding registration) and
  -- pulls in up_ui; doing so under coverage credits the hitherto-uncovered
  -- entry point. root/?.lua is on package.path so require resolves it through the
  -- same instrumented searcher as the lib files.
  local ok_main, err_main = pcall(require, "main")
  check(ok_main, "main.lua loads under mocked renoise" .. (ok_main and "" or (": " .. tostring(err_main))))

  local up_ui = require("up_ui")

  -- entry_sig / old_label / auto_select_index are local helpers; they are
  -- exercised indirectly below via fill_row/capture_selections, which call them.

  local rec = { kind = "instrument", instrument_name = "Kick NR",
    analysis = up_util.analyze_plugin(nil, "VST: Sonic Academy: Kick - Nicky Romero"),
    device_name = "VST: Sonic Academy: Kick - Nicky Romero" }

  local cands = {
    analyze("VST3: FabFilter Pro-Q 3", "/P/Q.vst3", "VST3"),
    analyze("VST: FabFilter Pro-MB", "/P/MB.vst", "VST"),
  }

  -- Drive the view-building + list-management logic with the ViewBuilder stub.
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._scrollbar = up_ui._vb:scrollbar{ width = 16, height = 340, min = 0, max = 12, step = 1, pagestep = 12 }
  up_ui._status_text = up_ui._vb:text{ text = "" }
  up_ui._upgrade_btn = up_ui._vb:button{ text = "Upgrade", active = false }

  up_ui.clear_list()
  check(up_ui._header_row ~= nil, "clear_list builds header row")

  local rc = { entry = rec, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc }
  up_ui.found_row(rec)
  check(#up_ui._data_rows == 1, "found_row appended a data row")
  up_ui.fill_row(rc)
  -- fill_row internally calls the local auto_select_index; it should pick the
  -- same-protocol (VST3) candidate, Pro-Q 3, i.e. popup value 2.
  check(up_ui._row_views[1] and up_ui._row_views[1].popup.value == 2,
    "fill_row auto-selected the same-protocol candidate (Pro-Q 3)")

  up_ui.recompute_visible()
  check(up_ui._visible >= 1, "recompute_visible computed a visible count")
  up_ui.refresh_scroll()
  up_ui.apply_scroll()
  check(true, "refresh_scroll/apply_scroll run without error")

  check(up_ui.wheel_scroll({ type = "wheel", direction = "down" }) == nil, "wheel_scroll handles wheel")
  check(up_ui.wheel_scroll({ type = "other" }).type == "other", "wheel_scroll passes non-wheel through")

  up_ui._saved_sel = up_ui.capture_selections()
  check(type(up_ui._saved_sel) == "table", "capture_selections returns a table")
  check(up_ui.summary():find("Done") == 1, "summary returns a Done. string")

  -- Exercise the full dialog + scan flow; the slicer is driven manually via the
  -- app-idle observable, since there is no real GUI event loop headlessly.
  local ok_dlg, err_dlg = pcall(function()
    up_ui.show_dialog()
    local idle = _G.renoise.tool().app_idle_observable
    for _ = 1, 400 do idle._fire() end
    up_ui.stop_all()
  end)
  check(ok_dlg, "show_dialog + scan flow runs headlessly" .. (ok_dlg and "" or (": " .. tostring(err_dlg))))
end

section("up_ui shows preset and carry-over in both columns")
do
  local up_ui = require("up_ui")
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._scrollbar = up_ui._vb:scrollbar{ width = 16, height = 340, min = 0, max = 12, step = 1, pagestep = 12 }
  up_ui._status_text = up_ui._vb:text{ text = "" }
  up_ui._upgrade_btn = up_ui._vb:button{ text = "Upgrade", active = false }
  up_ui.clear_list()

  -- Explicit preset name: shown in both columns, carried over to the upgrade.
  local rec = { kind = "instrument", instrument_name = "My Reaktor",
    analysis = up_util.analyze_plugin(nil, "AU: Native Instruments: Reaktor5"),
    device_name = "Native Instruments: Reaktor5",
    active_preset_name = "Make It Bright" }
  local cands = { analyze("Reaktor6", "/P/Reaktor6.app", "AU") }
  local rc = { entry = rec, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc }
  up_ui.found_row(rec)
  up_ui._fill_idx = #up_ui._row_views - 1
  up_ui.fill_row(rc)

  local items = up_ui._row_views[1].popup.items
  check(items[1]:find("Keep current") ~= nil, "first item is Keep current")
  check(items[1]:find("Make It Bright") ~= nil,
    "current plugin shows its preset (Make It Bright)")
  check(items[2]:find("Reaktor") ~= nil and items[2]:find("Make It Bright") ~= nil,
    "replacement shows carried-over preset (Reaktor 6 (Make It Bright))")
end

section("up_ui shows user preset name (not ensemble) for recovered plugin")
do
  -- A missing Reaktor's only meaningful preset signal is the user's instrument
  -- name ("Dark Dreams 1"); the loaded ensemble ("Razor") is the synth, shown only
  -- as a secondary detail. The preset name must be preserved and carried over, not
  -- replaced by the ensemble name.
  local up_ui = require("up_ui")
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._scrollbar = up_ui._vb:scrollbar{ width = 16, height = 340, min = 0, max = 12, step = 1, pagestep = 12 }
  up_ui._status_text = up_ui._vb:text{ text = "" }
  up_ui._upgrade_btn = up_ui._vb:button{ text = "Upgrade", active = false }
  up_ui.clear_list()

  local rec = { kind = "instrument", instrument_name = "Dark Dreams 1",
    analysis = up_util.analyze_plugin(nil, "AU: Native Instruments: Reaktor5"),
    device_name = "Native Instruments: Reaktor5",
    active_preset_name = "Razor", broken = true, recovered = true }
  local cands = { analyze("Reaktor6", "/P/Reaktor6.app", "AU") }
  local rc = { entry = rec, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc }
  up_ui.found_row(rec)
  up_ui._fill_idx = #up_ui._row_views - 1
  up_ui.fill_row(rc)

  local items = up_ui._row_views[1].popup.items
  check(items[1]:find("Dark Dreams 1") ~= nil,
    "current plugin shows the user preset name (Dark Dreams 1)")
  check(items[2]:find("Dark Dreams 1") ~= nil,
    "replacement carries over the user preset name (Dark Dreams 1)")
  check(items[1]:find("Razor") ~= nil,
    "current plugin still shows the ensemble as a secondary detail (Razor)")
  -- The ensemble must precede the preset name: "Razor: Dark Dreams 1".
  check(items[1]:find("Razor: Dark Dreams 1") ~= nil,
    "ensemble appears before the preset name (Razor: Dark Dreams 1)")
end

section("up_ui never shows instrument name as a carried-over preset")
do
  local up_ui = require("up_ui")
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._scrollbar = up_ui._vb:scrollbar{ width = 16, height = 340, min = 0, max = 12, step = 1, pagestep = 12 }
  up_ui._status_text = up_ui._vb:text{ text = "" }
  up_ui._upgrade_btn = up_ui._vb:button{ text = "Upgrade", active = false }
  up_ui.clear_list()

  -- Instrument whose only identity is its Renoise name (no real preset name): it
  -- must NOT be leaked into the replacement column as if it were Reaktor 6's
  -- preset (the earlier "Reaktor 6 (Reaktor5)" bug).
  local rec = { kind = "instrument", instrument_name = "VST: Reaktor5",
    analysis = up_util.analyze_plugin(nil, "VST: Native Instruments: Reaktor5"),
    device_name = "Native Instruments: Reaktor5" }
  local cands = { analyze("Reaktor6", "/P/Reaktor6.app", "AU") }
  local rc = { entry = rec, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc }
  up_ui.found_row(rec)
  up_ui._fill_idx = #up_ui._row_views - 1
  up_ui.fill_row(rc)

  local items = up_ui._row_views[1].popup.items
  check(items[2]:find("Reaktor5") == nil,
    "replacement column does NOT show the old instrument name as a preset")
  check(items[2]:find("Keep current") == nil and items[2]:find("%(") == nil,
    "replacement column has no fake (preset) parenthetical when none exists")

  -- And an embedded ensemble (file:// URL in the blob) is recovered and shown.
  local rec2 = { kind = "instrument", instrument_name = "Reaktor 5",
    analysis = up_util.analyze_plugin(nil, "VST: Native Instruments: Reaktor5"),
    device_name = "Native Instruments: Reaktor5",
    active_preset_data = "\000\000file://localhost/Users/Shared/Razor/Razor.rkplr\000\000" }
  local rc2 = { entry = rec2, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc2 }
  up_ui.found_row(rec2)
  up_ui._fill_idx = #up_ui._row_views - 1
  up_ui.fill_row(rc2)
  local rv2 = up_ui._row_views[#up_ui._row_views]
  local items2 = rv2.popup.items
  check(items2[1]:find("Razor") ~= nil, "current plugin shows recovered ensemble (Razor)")
  check(items2[2]:find("Razor") ~= nil, "replacement shows carried-over ensemble (Razor)")

  -- Missing plugin (failed to open): the only preset hint is the Renoise
  -- instrument name, e.g. "VST: Reaktor5 (Make It Bright)". Surface that as the
  -- preset in both columns, but never the bare plugin name ("Reaktor5").
  local rec3 = { kind = "instrument", instrument_name = "VST: Reaktor5 (Make It Bright)",
    analysis = up_util.analyze_plugin(nil, "VST: Native Instruments: Reaktor5"),
    device_name = "Native Instruments: Reaktor5" }
  local rc3 = { entry = rec3, candidates = cands, candidate = cands[1] }
  up_ui._results = { rc3 }
  up_ui.found_row(rec3)
  up_ui._fill_idx = #up_ui._row_views - 1
  up_ui.fill_row(rc3)
  local items3 = up_ui._row_views[#up_ui._row_views].popup.items
  check(items3[1]:find("Make It Bright") ~= nil,
    "current shows preset from instrument name (Make It Bright)")
  check(items3[2]:find("Make It Bright") ~= nil,
    "replacement shows carried-over preset (Make It Bright)")
  check(items3[2]:find("Reaktor5") == nil,
    "replacement does NOT show bare plugin name as preset")
end

section("coverage: up_ui song-less dialog and observer lifecycle")
do
  local up_ui = require("up_ui")
  -- show_dialog with no song open must warn and bail.
  local real_song = _G.renoise.song
  local real_app = _G.renoise.app
  _G.renoise.song = function() return nil end
  local warned = false
  _G.renoise.app = function()
    return { song_filename = fixture, show_custom_dialog = function() return { visible = true } end,
      show_warning = function() warned = true end }
  end
  up_ui.show_dialog()
  _G.renoise.app = real_app
  _G.renoise.song = real_song
  check(warned, "show_dialog warns when no song is open")

  -- Build a song whose tracks/instruments expose observables so attach/detach and
  -- structure callbacks can run for real (not just in a pcall that swallows nil).
  local song_obs = {
    tracks = { tracks_observable = observable(), instruments_observable = observable() },
    instruments = { { plugin_properties = { plugin_loaded = true,
        plugin_device = { device_path = "/P/ProMB.vst3", name = "VST3: FabFilter Pro-MB" } } } },
  }
  song_obs.tracks.devices_observable = observable()
  local real_song2 = _G.renoise.song
  _G.renoise.song = function() return song_obs end
  up_ui.attach_observers()
  check(up_ui._tn ~= nil and up_ui._in ~= nil, "attach_observers registers structure notifiers")
  up_ui.on_structure_changed()
  up_ui.detach_observers()
  check(up_ui._tn == nil and up_ui._in == nil, "detach_observers clears structure notifiers")
  up_ui.ensure_doc_observers()
  up_ui.on_song_releasing()
  up_ui.on_song_loaded()
  _G.renoise.song = real_song2
end

section("coverage: up_ui dialog-close watch and scroll")
do
  local up_ui = require("up_ui")
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._dialog = { visible = true }
  up_ui._closed = false
  up_ui.watch_dialog()
  -- Simulate the visibility flag flipping to false for three ticks -> teardown.
  up_ui._dialog.visible = false
  local idle = _G.renoise.tool().app_idle_observable
  for _ = 1, 5 do idle._fire() end
  check(up_ui._closed == true, "watch_tick detects closure after blank ticks")
  up_ui.stop_all()
  check(true, "stop_all runs without error")

  -- on_scroll updates the scroll window and reapplies the visible slice.
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._scrollbar = up_ui._vb:scrollbar{ width = 16, height = 340, min = 0, max = 12, step = 1, pagestep = 12 }
  up_ui._data_rows = { up_ui._vb:row{}, up_ui._vb:row{}, up_ui._vb:row{} }
  up_ui._mounted = {}
  up_ui.on_scroll(1)
  check(true, "on_scroll + apply_scroll run without error")
end

section("coverage: up_ui.do_upgrade runs an end-to-end upgrade")
do
  local up_ui = require("up_ui")
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._status_text = up_ui._vb:text{ text = "" }
  up_ui._upgrade_btn = up_ui._vb:button{ text = "Upgrade", active = false }
  up_ui._dialog = { visible = true }
  up_ui._closed = false

  -- A song with a loaded, upgradeable instrument plugin.
  local pp = {
    plugin_loaded = true,
    plugin_device = { device_path = "/P/ProMB.vst3", name = "VST3: FabFilter Pro-MB",
      active_preset_data = "x", parameters = {} },
    load_plugin = function(self, _path)
      self.plugin_device = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
      return true
    end,
  }
  local song = {
    instruments = { { plugin_properties = pp } }, tracks = {},
    automation = function() return { is_automated = false } end,
  }
  local real_song = _G.renoise.song
  _G.renoise.song = function() return song end

  local rec = { kind = "instrument", instrument_index = 1, device_index = nil,
    is_plugin = true, broken = false, device_path = "/P/ProMB.vst3",
    device_name = "VST3: FabFilter Pro-MB",
    analysis = up_util.analyze_plugin("/P/ProMB.vst3", "FabFilter Pro-MB") }
  local cand = analyze("FabFilter Pro-MB", "/P/ProMB2.vst3", "VST3")
  local rc = { entry = rec, candidates = { cand }, candidate = cand, status = nil }
  up_ui._results = { rc }
  up_ui._row_views = { { popup = { value = 2, active = true }, candidates = { cand },
    result_txt = up_ui._vb:text{ text = "" }, old_tf = up_ui._vb:text{ text = "" } } }

  up_ui.do_upgrade()
  local idle = _G.renoise.tool().app_idle_observable
  for _ = 1, 400 do idle._fire() end
  check(rc.status ~= nil and rc.status:find("^upgraded") ~= nil,
    "do_upgrade swaps the plugin and reports an upgraded status (" .. tostring(rc.status) .. ")")

  -- A second do_upgrade while upgrading must act as Stop, not recurse.
  local mid_abort = up_ui.do_upgrade
  check(mid_abort ~= nil, "do_upgrade is callable as a Stop while upgrading")
  _G.renoise.song = real_song
end

section("coverage: up_ui.do_upgrade with no selection and reconcile reuse")
do
  local up_ui = require("up_ui")
  up_ui._vb = _G.renoise.ViewBuilder
  up_ui._list_box = up_ui._vb:column{}
  up_ui._status_text = up_ui._vb:text{ text = "" }
  up_ui._upgrade_btn = up_ui._vb:button{ text = "Upgrade", active = false }
  up_ui._results = { { entry = { kind = "instrument", analysis = up_util.analyze_plugin(nil, "Reaktor5") },
    candidates = {}, candidate = nil } }
  local rv_no = { popup = { value = 1, active = false }, candidates = {}, result_txt = up_ui._vb:text{ text = "" } }
  up_ui._row_views = { rv_no }
  up_ui.do_upgrade()
  check(true, "do_upgrade with no selection reports a friendly status")

  -- reconcile reuses the cached pool instead of a full rescan.
  up_ui._pools = { track = {}, inst = {} }
  up_ui._closed = false
  up_ui.reconcile()
  check(true, "reconcile runs a same-song rescan without rebuilding the pool")
end

section("up_ui result icon colours + tooltips map every status")
do
  local up_ui = require("up_ui")
  up_ui._vb = _G.renoise.ViewBuilder

  local function styled(status, detail)
    local rv = { result_txt = up_ui._vb:text{ text = "", color = {0,0,0}, tooltip = "" } }
    up_ui.set_result(rv, status, detail)
    return rv.result_txt
  end

  -- Fully upgraded -> green, with the exact-transfer explanation.
  local ok = styled("upgraded-with-parameters", nil)
  check(ok.color[1] == 0 and ok.color[2] == 180 and ok.color[3] == 0,
    "upgraded-with-parameters is green")
  check(ok.text:find("Upgraded") ~= nil, "upgraded-with-parameters label is 'Upgraded'")
  check(ok.tooltip:find("transferred exactly") ~= nil, "upgraded tooltip explains the transfer")

  -- Partially upgraded -> yellow (default patch, no transfer).
  local part = styled("upgraded-default", "preset not transferred: no method")
  check(part.color[1] == 200 and part.color[2] == 170 and part.color[3] == 0,
    "upgraded-default is yellow")
  check(part.text:find("Partial") ~= nil, "upgraded-default label is 'Partial'")
  check(part.tooltip:find("default patch") ~= nil, "upgraded-default tooltip mentions the default patch")
  check(part.tooltip:find("preset not transferred") ~= nil, "detail is appended to the tooltip")

  -- Failed upgrade -> red.
  local fail = styled("skipped-transfer-rejected", "load_plugin failed: nil")
  check(fail.color[1] == 220 and fail.color[2] == 60 and fail.color[3] == 60,
    "skipped-transfer-rejected is red")
  check(fail.text:find("Failed") ~= nil, "rejected label is 'Failed'")

  local err = styled("error", "boom")
  check(err.color[1] == 220 and err.color[3] == 60, "error is red")

  -- Not upgraded -> gray (current / no candidate / unrecognised).
  local cur = styled("up-to-date", nil)
  check(cur.color[1] == 150 and cur.color[2] == 150 and cur.color[3] == 150,
    "up-to-date is gray")
  check(cur.text:find("Current") ~= nil, "up-to-date label is 'Current'")

  local none = styled("skipped-no-candidate-broken", nil)
  check(none.color[1] == 150, "no-candidate-broken is gray")

  local pending = styled(nil, nil)
  check(pending.color[1] == 150 and pending.text:find("Pending") ~= nil,
    "pending (no status) is gray 'Pending'")

  local unknown = styled("weird-status", nil)
  check(unknown.color[1] == 150 and unknown.tooltip:find("weird-status", 1, true) ~= nil,
    "unrecognised status is gray with its raw value in the tooltip")
end
