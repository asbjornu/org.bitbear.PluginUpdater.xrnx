-- Tests for up_core: the orchestration layer that builds the candidate pools
-- (with caching), matches entries to candidates, and applies a single upgrade.

section("coverage: up_core.apply_one success and error path")
do
  local track = {
    devices = { [1] = { is_active = true, active_preset_data = "", parameters = {} } },
    insert_device_at = function(self, _path, idx)
      local dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
      table.insert(self.devices, idx, dev)
      return dev
    end,
    delete_device_at = function(self, idx) table.remove(self.devices, idx) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 1, is_plugin = true,
    device_path = "/P/Sylenth1.vst", device_name = "VST: Lennardigital Sylenth1",
    analysis = analyze("VST: Lennardigital Sylenth1", "/P/Sylenth1.vst", "VST") }
  local candidate = { name = "Sylenth1", protocol = "VST", path = "/P/Sylenth1-VST3.vst", analysis = rec.analysis }
  local ok, res = pcall(function()
    return up_core.apply_one(song, { entry = rec, candidate = candidate }, candidate)
  end)
  check(ok and res and res.status ~= nil, "apply_one runs swap_track_device and returns a status")

  -- A result whose swap throws must be caught and reported, never aborting the run.
  local bad_rec = { kind = "weird", instrument_index = 1, analysis = rec.analysis }
  local ok2, res2 = pcall(function()
    return up_core.apply_one({ instruments = {} }, { entry = bad_rec, candidate = candidate }, candidate)
  end)
  check(ok2 and res2 and res2.status == "error", "apply_one catches a swap error and reports status 'error'")
end

section("coverage: up_core pools, cache, match, analyze, apply_one")
do
  local song = {
    instruments = {
      { name = "Reaktor 5", plugin_properties = { plugin_loaded = true,
          plugin_device = { device_path = "aumuRk5----", name = "NI: Reaktor5", available_devices = {} },
          available_plugin_infos = { { path = "/P/Reaktor6.vst", name = "Reaktor 6" } } } },
    },
    tracks = {},
  }
  up_core.invalidate_pool_cache()
  local t1, i1 = up_core.build_pools(song)
  local t2, i2 = up_core.build_pools(song)
  check(t1 == t2 and i1 == i2, "build_pools caches by signature")
  up_core.invalidate_pool_cache()
  local _, i3 = up_core.build_pools(song)
  check(#i3 >= 1, "build_pools rebuilds after invalidate")

  -- match_entries finds the Reaktor 6 candidate for a Reaktor 5 entry.
  local r6 = up_plugin_analysis.analyze_plugin("/P/Reaktor6.vst", "Reaktor 6"); r6.path = "/P/Reaktor6.vst"
  local rec = { kind = "instrument", analysis = up_plugin_analysis.analyze_plugin(nil, "Reaktor5") }
  local results = up_core.match_entries({ rec }, { track_pool = {}, instrument_pool = { r6 } }, nil, nil, nil)
  check(results[1] and #results[1].candidates >= 1, "match_entries offers Reaktor 6 for Reaktor 5")

  -- analyze runs scan + match end to end.
  up_core.invalidate_pool_cache()
  local ares = up_core.analyze(song, nil, nil, nil, nil)
  check(#ares >= 1, "analyze scans and matches the song")

  -- The scan and match phases expose different callback shapes: on_scan gets an
  -- entry record, on_match gets a result table. Verify both contracts hold.
  up_core.invalidate_pool_cache()
  local scan_shapes, match_shapes = {}, {}
  up_core.analyze(song, nil, nil,
    function(entry)
      scan_shapes[#scan_shapes + 1] = (entry and entry.analysis and not entry.candidates) or false
    end,
    function(result)
      match_shapes[#match_shapes + 1] = (result and result.entry and result.candidates ~= nil) or false
    end)
  check(#scan_shapes >= 1 and scan_shapes[1] == true, "analyze on_scan receives an entry record")
  check(#match_shapes >= 1 and match_shapes[1] == true, "analyze on_match receives a result table")

  -- apply_one with no candidate reports a skip (broken vs up-to-date).
  local broken = up_core.apply_one(song, { entry = { kind = "instrument", broken = true,
    analysis = up_plugin_analysis.analyze_plugin(nil, "Reaktor5") }, candidate = nil }, nil)
  check(broken.status == "skipped-no-candidate-broken", "apply_one skips a broken plugin with no candidate")
  local uptodate = up_core.apply_one(song, { entry = { kind = "instrument", broken = false,
    analysis = up_plugin_analysis.analyze_plugin(nil, "Reaktor5") }, candidate = nil }, nil)
  check(uptodate.status == "skipped-up-to-date", "apply_one skips an up-to-date plugin with no candidate")
end
