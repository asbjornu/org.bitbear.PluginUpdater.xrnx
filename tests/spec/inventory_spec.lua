-- Tests for up_inventory: scanning the song's tracks and instruments into
-- upgradeable entries, with all the missing/broken-plugin recovery paths
-- (name-based, live plugin_properties, protocol token, song.xml identity).

section("up_inventory.scan surfaces missing plugin found by name")
do
  -- The Kick lives at live index 1, but its recovered identity sits at a
  -- different position in Song.xml (a MIDI instrument precedes it). Name-based
  -- lookup must still surface it as a recoverable, broken plugin.
  local mock_song = {
    instruments = {
      { name = "VST: Kick - Nicky Romero ()", plugin_properties = { plugin_loaded = false, plugin_device = nil } },
    },
    tracks = {},
  }
  local recovery = {
    [1] = nil, -- MIDI instrument (no plugin)
    [2] = { index = 2, instrument_name = "VST: Kick - Nicky Romero ()",
            protocol = "VST", identifier = "Kick - Nicky Romero",
            display_name = "VST: Sonic Academy: Kick - Nicky Romero" },
    ["VST: Kick - Nicky Romero ()"] = { index = 2, instrument_name = "VST: Kick - Nicky Romero ()",
            protocol = "VST", identifier = "Kick - Nicky Romero",
            display_name = "VST: Sonic Academy: Kick - Nicky Romero" },
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil, recovery)
  local kick
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "VST: Kick - Nicky Romero ()" then kick = e end
  end
  check(kick ~= nil, "missing Kick surfaced via name-based recovery")
  check(kick and kick.broken and kick.recovered and kick.analysis
    and kick.analysis.base:find("kick") ~= nil, "Kick recovered as broken plugin with analysis")
end

section("up_inventory.scan recovers missing plugin from live plugin_properties")
do
  -- When the .xrns can't be read, Renoise still keeps the plugin name on
  -- plugin_properties for a missing plugin; that must surface the instrument.
  local mock_song = {
    instruments = {
      { name = "VST: Kick - Nicky Romero ()", plugin_properties = {
          plugin_loaded = false, plugin_device = nil,
          plugin_name = "VST: Sonic Academy: Kick - Nicky Romero" } },
    },
    tracks = {},
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil, {})
  local kick
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "VST: Kick - Nicky Romero ()" then kick = e end
  end
  check(kick ~= nil, "missing Kick surfaced via live plugin_name")
  check(kick and kick.analysis and kick.analysis.base:find("kick") ~= nil,
    "Kick analysis derived from live plugin name")
end

section("up_inventory.scan surfaces missing plugin by instrument name (protocol token)")
do
  -- When no .xrns recovery and no plugin_properties name exist, a missing plugin
  -- whose name still carries a protocol token must still be surfaced.
  local mock_song = {
    instruments = {
      { name = "VST: Kick - Nicky Romero ()", plugin_properties = {
          plugin_loaded = false, plugin_device = nil } },
    },
    tracks = {},
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil, {})
  local kick
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "VST: Kick - Nicky Romero ()" then kick = e end
  end
  check(kick ~= nil, "missing Kick surfaced via instrument name")
  check(kick and kick.device_name == "VST: Kick - Nicky Romero ()", "surfaced with its name as identity")
end

section("up_inventory.scan recovers missing AU plugin from song.xml (placeholder path)")
do
  -- When a plugin fails to load, Renoise may keep a placeholder device whose
  -- device_path is an opaque AU 4-char code and whose name is blank. Trusting
  -- that path misidentifies the plugin (e.g. Reaktor5 -> base "ni") so it gets
  -- no candidate and is effectively "not added". The saved song's authoritative
  -- display name + ensemble must win instead.
  local mock_song = {
    instruments = {
      { name = "Dark Dreams 1", plugin_properties = {
          plugin_loaded = false,
          plugin_device = { device_path = "aumu:NiR5:-NI-", name = nil } } },
    },
    tracks = {},
  }
  local recovery = {
    [1] = { index = 1, instrument_name = "Dark Dreams 1",
            protocol = "AU", identifier = "aumu:NiR5:-NI-",
            display_name = "AU: Native Instruments: Reaktor5",
            preset_name = "Razor" },
    ["Dark Dreams 1"] = { index = 1, instrument_name = "Dark Dreams 1",
            protocol = "AU", identifier = "aumu:NiR5:-NI-",
            display_name = "AU: Native Instruments: Reaktor5",
            preset_name = "Razor" },
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil, recovery)
  local dd
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "Dark Dreams 1" then dd = e end
  end
  check(dd ~= nil, "missing AU Reaktor surfaced (not dropped)")
  check(dd and dd.analysis and dd.analysis.base:find("reaktor") ~= nil,
    "recovered from song.xml as Reaktor5 (not the opaque 'aumu:NiR5' path)")
  check(dd and dd.active_preset_name == "Razor",
    "loaded Reaktor ensemble ('Razor') recovered as preset name")
  check(dd and dd.recovered and dd.broken, "marked recovered + broken")
end

section("up_inventory.scan recovers over a placeholder device with a blank name")
do
  -- A loaded-but-unresolvable plugin may leave a placeholder device whose name is
  -- an empty string (truthy in Lua). apply_recovered must overwrite that blank name
  -- with the authoritative display name from the saved song, not keep the empty one.
  local mock_song = {
    instruments = {
      { name = "Dark Dreams 1", plugin_properties = {
          plugin_loaded = true,
          plugin_device = { device_path = nil, name = "", active_preset_data = "" } } },
    },
    tracks = {},
  }
  local recovery = {
    [1] = { index = 1, instrument_name = "Dark Dreams 1",
            protocol = "AU", identifier = "aumu:NiR5:-NI-",
            display_name = "AU: Native Instruments: Reaktor5",
            preset_name = "Razor" },
    ["Dark Dreams 1"] = { index = 1, instrument_name = "Dark Dreams 1",
            protocol = "AU", identifier = "aumu:NiR5:-NI-",
            display_name = "AU: Native Instruments: Reaktor5",
            preset_name = "Razor" },
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil, recovery)
  local dd
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "Dark Dreams 1" then dd = e end
  end
  check(dd ~= nil, "placeholder device surfaced")
  check(dd and dd.device_name == "AU: Native Instruments: Reaktor5",
    "blank device_name overwritten by the recovered display name")
  check(dd and dd.analysis and dd.analysis.base:find("reaktor") ~= nil,
    "recovered identity analysed as Reaktor5")
  check(dd and dd.active_preset_name == "Razor", "recovered preset name carried over")
end

section("up_inventory.scan with mocked song + recovered missing plugin")
do
  local mock_song = {
    instruments = {
      { name = "Sampler", plugin_properties = { plugin_loaded = false, plugin_device = nil } },
      { name = "Dark Dreams 2", plugin_properties = { plugin_loaded = false, plugin_device = nil } },
      { name = "Healthy", plugin_properties = { plugin_loaded = true, plugin_device = {
          device_path = "/P/ProMB.vst3", name = "VST3: FabFilter Pro-MB",
          active_preset_data = "x", parameters = {} } } },
    },
    tracks = {
      { name = "Master", devices = {
          [1] = { name = "Mixer" },
          [2] = { name = "VST3: FabFilter Pro-MB", device_path = "/P/ProMB.vst3",
                   active_preset_data = "x", parameters = {} } } },
    },
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil)
  check(#entries == 3, "scan produced 3 entries (2 instruments + 1 track)")

  local dd, healthy, track
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.instrument_name == "Dark Dreams 2" then dd = e end
    if e.kind == "instrument" and e.instrument_name == "Healthy" then healthy = e end
    if e.kind == "track" then track = e end
  end
  check(dd and dd.broken and dd.recovered, "missing plugin recovered as broken+recovered")
  check(dd and dd.analysis and dd.analysis.base:find("reaktor") ~= nil, "recovered analysis has Reaktor base")
  check(healthy and (not healthy.broken) and healthy.analysis, "healthy plugin scanned normally")
  check(track and track.is_plugin and track.analysis, "track plugin scanned")
end

section("up_inventory.scan recovers missing plugins via song.file_name")
do
  -- End-to-end regression for the "not all Reaktor devices are added" bug: with
  -- the wrong song-filename property, recovery came back empty and every missing
  -- plugin whose instrument name carried no protocol token (e.g. "Dark Dreams 1")
  -- was dropped. Scanning with song.file_name set must surface them.
  local xml = up_zip.extract(fixture, "Song.xml")
  local recovery = up_songxml.parse_instruments(xml)
  local instruments = {}
  for _, e in pairs(recovery) do
    if type(e) == "table" then
      instruments[e.index] = { name = e.instrument_name,
        plugin_properties = { plugin_loaded = false, plugin_device = nil } }
    end
  end
  local maxi = 0
  for _, e in pairs(recovery) do if type(e) == "table" and e.index > maxi then maxi = e.index end end
  for i = 1, maxi do
    if not instruments[i] then
      instruments[i] = { name = "Sampler " .. i,
        plugin_properties = { plugin_loaded = false, plugin_device = nil } }
    end
  end
  -- recovery left nil so scan() calls up_songxml.recover(song) itself, exercising
  -- the real song.file_name path.
  local mock_song = { file_name = fixture, instruments = instruments, tracks = {} }
  local entries = up_inventory.scan(mock_song, nil, nil, nil)
  local reaktor = 0
  for _, e in ipairs(entries) do
    if (e.analysis and e.analysis.base or ""):find("reaktor") then reaktor = reaktor + 1 end
  end
  check(reaktor >= 1, "Reaktor recovered end-to-end via song.file_name (was dropped before)")
  -- A non-protocol-named missing plugin must also be recovered, not skipped.
  local named
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.analysis and e.analysis.base:find("kick") then named = e end
  end
  check(named ~= nil, "protocol-less missing plugin (Kick) recovered via song.xml")
end

section("up_inventory.scan captures instrument preset name")
do
  -- A plugin instrument with a selected preset (e.g. a Reaktor ensemble) must
  -- expose the preset name + chunk so the UI can show it and carry it over.
  local mock_song = {
    instruments = {
      { name = "Reaktor Inst", plugin_properties = { plugin_loaded = true,
        plugin_device = { device_path = "aumuRk5----", name = "Native Instruments: Reaktor5",
          active_preset = 3, presets = { "Init", "Foo", "Make It Bright" },
          active_preset_data = "<PresetName>Make It Bright</PresetName>", parameters = {} } } },
    },
    tracks = {},
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil)
  local e
  for _, x in ipairs(entries) do if x.kind == "instrument" then e = x end end
  check(e and e.active_preset_name == "Make It Bright",
    "instrument active_preset_name captured from presets[index]")
  check(e and type(e.active_preset_data) == "string" and e.active_preset_data ~= "",
    "instrument active_preset_data captured")
end

section("coverage: up_inventory.scan surfaces a track plugin device")
do
  local mock_song = {
    instruments = { { name = "Sampler", plugin_properties = { plugin_loaded = false, plugin_device = nil } } },
    tracks = { { devices = { {}, { is_plugin = true, device_path = "/P/Pro-Q.vst3",
      device_name = "VST3: FabFilter Pro-Q 3", available_devices = {} } } } },
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil)
  local found = false
  for _, e in ipairs(entries) do if e.kind == "track" then found = true; break end end
  check(found, "scan surfaces a track plugin device as a track entry")
end

section("coverage: up_inventory.scan capture of track device preset")
do
  local mock_song = {
    instruments = {},
    tracks = { { devices = { {}, { is_plugin = true, device_path = "/P/Sylenth1.vst",
      device_name = "VST: Lennardigital Sylenth1", active_preset = 2,
      presets = { "Init", "ARP 303 Saw" }, available_devices = {} } } } },
  }
  local rec = up_inventory.scan_track_device(1, mock_song.tracks[1], 2)
  check(rec ~= nil, "scan_track_device returns the plugin rec")
  check(rec.active_preset_name == "ARP 303 Saw", "active preset name captured from presets[index]")
end

section("coverage: up_inventory.scan skips non-plugin instruments (sampler)")
do
  local mock_song = {
    instruments = { { name = "Sampler", plugin_properties = { plugin_loaded = true,
      plugin_device = { device_path = "Native/Sampler", name = "Sampler" } } } },
    tracks = {},
  }
  local entries = up_inventory.scan(mock_song, nil, nil, nil)
  local found = false
  for _, e in ipairs(entries) do
    if e.kind == "instrument" and e.device_name == "Sampler" then found = true end
  end
  check(found, "native Sampler instrument is surfaced by scan")
end

section("coverage: up_inventory.scan recovery paths")
do
  -- Recovery indexed by live instrument index.
  local recovery_a = { [1] = { index = 1, instrument_name = "Kick NR",
    protocol = "VST", identifier = "Kick", display_name = "VST: Kick" } }
  local song_a = { instruments = {
    { name = "Kick NR", plugin_properties = { plugin_loaded = false, plugin_device = nil } } }, tracks = {} }
  local ea = up_inventory.scan(song_a, nil, nil, nil, recovery_a)
  check(ea[1] and ea[1].device_name == "VST: Kick", "recovery resolved by live index")

  -- Recovery indexed by instrument name.
  local recovery_b = { ["Foo Inst"] = { index = 2, instrument_name = "Foo Inst",
    display_name = "VST: Foo" } }
  local song_b = { instruments = {
    { name = "Foo Inst", plugin_properties = { plugin_loaded = false, plugin_device = nil } } }, tracks = {} }
  local eb = up_inventory.scan(song_b, nil, nil, nil, recovery_b)
  check(eb[1] and eb[1].device_name == "VST: Foo", "recovery resolved by instrument name")

  -- Recovery indexed by name with a trailing "()" (Renoise appends it).
  local recovery_c = { ["Kick NR"] = { index = 2, instrument_name = "Kick NR",
    display_name = "VST: Kick" } }
  local song_c = { instruments = {
    { name = "Kick NR ()", plugin_properties = { plugin_loaded = false, plugin_device = nil } } }, tracks = {} }
  local ec = up_inventory.scan(song_c, nil, nil, nil, recovery_c)
  check(ec[1] and ec[1].device_name == "VST: Kick", "recovery resolved by name with trailing ()")

  -- apply_recovered rejects an entry with no usable display name.
  local recovery_d = { [1] = { index = 1, instrument_name = "Mystery", identifier = nil } }
  local song_d = { instruments = {
    { name = "Mystery", plugin_properties = { plugin_loaded = false, plugin_device = nil } } }, tracks = {} }
  local ed = up_inventory.scan(song_d, nil, nil, nil, recovery_d)
  check(#ed == 0, "instrument with no recoverable identity is dropped")

  -- Missing plugin with no recovery but a live plugin_properties name.
  local song_e = { instruments = {
    { name = "Something", plugin_properties = { plugin_loaded = false, plugin_device = nil,
        plugin_name = "VST: Recovered Foo" } } }, tracks = {} }
  local ee = up_inventory.scan(song_e, nil, nil, nil, {})
  check(ee[1] and ee[1].device_name == "VST: Recovered Foo",
    "missing plugin surfaced from live plugin_properties name")

  -- Missing plugin surfaced by an instrument name carrying a protocol token.
  local song_f = { instruments = {
    { name = "VST: Kick - Nicky Romero ()", plugin_properties = { plugin_loaded = false,
        plugin_device = nil } } }, tracks = {} }
  local ef = up_inventory.scan(song_f, nil, nil, nil, {})
  check(ef[1] and ef[1].device_name == "VST: Kick - Nicky Romero ()" and ef[1].recovered == false,
    "missing plugin surfaced from live instrument name (protocol token)")

  -- Recovered plugin whose loaded placeholder device is blank: the authoritative
  -- display name from the saved song must overwrite the empty device name.
  local recovery_g = { [1] = { index = 1, instrument_name = "DD",
    display_name = "AU: Reaktor5", preset_name = "Razor" } }
  local song_g = { instruments = {
    { name = "DD", plugin_properties = { plugin_loaded = false,
        plugin_device = { device_path = "", name = "", active_preset_data = "" } } } }, tracks = {} }
  local eg = up_inventory.scan(song_g, nil, nil, nil, recovery_g)
  check(eg[1] and eg[1].device_name == "AU: Reaktor5" and eg[1].active_preset_name == "Razor",
    "blank placeholder device name overwritten by recovered display name + preset")

  -- A loaded plugin whose path is hidden by the API recovers identity from the song.
  local recovery_h = { [1] = { index = 1, instrument_name = "DD", display_name = "AU: Reaktor5" } }
  local song_h = { instruments = {
    { name = "DD", plugin_properties = { plugin_loaded = true,
        plugin_device = { name = "X", active_preset_data = "y" } } } }, tracks = {} }
  local eh = up_inventory.scan(song_h, nil, nil, nil, recovery_h)
  check(eh[1] and eh[1].recovered == true, "identity recovered for path-less loaded plugin")

  -- A loaded plugin with an unidentifiable device is still surfaced by its name.
  local song_i = { instruments = {
    { name = "Named Dev", plugin_properties = { plugin_loaded = true,
        plugin_device = { name = "Named Dev", active_preset_data = "y" } } } }, tracks = {} }
  local ei = up_inventory.scan(song_i, nil, nil, nil, {})
  check(ei[1] and ei[1].device_name == "Named Dev", "path-less device surfaced by its name")
end
