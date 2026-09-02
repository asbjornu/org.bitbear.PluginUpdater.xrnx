-- Tests for up_song_xml: recovering per-instrument plugin identity (and the loaded
-- preset/ensemble name) from a saved .xrns Song.xml, including a real zipped
-- fixture, groups, attributes, blank fields, and the cache.

section("up_song_xml.parse_instruments")
do
  local xml = [[<?xml version="1.0"?>
 <Song>
   <Instrument><Name>Sampler Inst</Name></Instrument>
   <Instrument><Name>Dark Dreams 2</Name><PluginGenerator><PluginDevice>
     <PluginType>AU</PluginType>
     <PluginIdentifier>aumu:NiR5:-NI-</PluginIdentifier>
     <PluginDisplayName>AU: Native Instruments: Reaktor5</PluginDisplayName>
     <PluginShortDisplayName>Reaktor5</PluginShortDisplayName>
   </PluginDevice></PluginGenerator></Instrument>
   <Instrument><Name>Kick NR</Name><PluginGenerator><PluginDevice>
     <PluginType>VST</PluginType>
     <PluginIdentifier>Kick - Nicky Romero</PluginIdentifier>
     <PluginDisplayName>VST: Sonic Academy: Kick - Nicky Romero</PluginDisplayName>
   </PluginDevice></PluginGenerator></Instrument>
 </Song>]]
  local info = up_song_xml.parse_instruments(xml)
  check(info[1] == nil, "sampler (no PluginType) skipped")
  check(info[2] and info[2].display_name == "AU: Native Instruments: Reaktor5",
    "recovered instrument #2 identity")
  check(info[3] and info[3].display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "recovered instrument #3 identity")
end

section("up_song_xml.recover (real zipped fixture)")
do
  -- read_song_xml reads the song path from song().file_name (the real Renoise
  -- property). This previously used non-existent app.song_filename /
  -- song().song_filename, which left recovery empty and dropped every missing
  -- plugin whose instrument name carried no protocol token.
  local info = up_song_xml.recover({ file_name = fixture })
  check(info[2] and info[2].display_name == "AU: Native Instruments: Reaktor5",
    "recover() parses the .xrns fixture via song.file_name")
  check(info[3] and info[3].instrument_name == "Kick NR", "recover() reads instrument <Name>")
end

section("up_song_xml.recover falls back to app.song_filename")
do
  local info = up_song_xml.recover({})
  check(info[2] and info[2].display_name == "AU: Native Instruments: Reaktor5",
    "recover() still works via app.song_filename fallback")
end

section("up_song_xml.parse_instruments (attributes, groups, name keys)")
do
  -- Mirrors a real song: a non-plugin (ext. MIDI) instrument, then a plugin
  -- instrument nested in an <InstrumentGroup>, with attribute-bearing tags.
  local xml = [[<?xml version="1.0"?>
 <Song>
   <Instrument>
     <Name>MIDI In</Name>
     <InstrumentType>ext. MIDI</InstrumentType>
   </Instrument>
   <InstrumentGroup>
     <Instrument>
       <Name>VST: Kick - Nicky Romero ()</Name>
       <PluginGenerator><PluginDevice>
         <PluginType>VST</PluginType>
         <PluginIdentifier>Kick - Nicky Romero</PluginIdentifier>
         <PluginDisplayName>VST: Sonic Academy: Kick - Nicky Romero</PluginDisplayName>
       </PluginDevice></PluginGenerator>
     </Instrument>
   </InstrumentGroup>
 </Song>]]
  local info = up_song_xml.parse_instruments(xml)
  check(info[1] == nil, "non-plugin (MIDI) instrument skipped")
  check(info[2] and info[2].display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "plugin inside InstrumentGroup still indexed (idx 2)")
  -- Name-keyed lookups must resolve regardless of index alignment.
  check(info["VST: Kick - Nicky Romero ()"]
    and info["VST: Kick - Nicky Romero ()"].display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "recoverable by live instrument name (index-independent)")
  check(info["VST: Sonic Academy: Kick - Nicky Romero"]
    and info["VST: Sonic Academy: Kick - Nicky Romero"].display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "recoverable by plugin display name")
end

section("up_song_xml.parse_instruments treats blank name fields as absent")
do
  -- Empty / self-closing name elements must not defeat the display_name <-> short
  -- fallback, and must never become lookup keys (out[""] would make any blank-name
  -- lookup resolve to an unrelated instrument).
  local xml = [[<?xml version="1.0"?>
 <Song>
   <Instrument><Name></Name><PluginGenerator><PluginDevice>
     <PluginType>AU</PluginType>
     <PluginIdentifier />
     <PluginDisplayName/>
     <PluginShortDisplayName>Reaktor5</PluginShortDisplayName>
   </PluginDevice></PluginGenerator></Instrument>
   <Instrument><Name>Kick NR</Name><PluginGenerator><PluginDevice>
     <PluginType>VST</PluginType>
     <PluginDisplayName>VST: Sonic Academy: Kick - Nicky Romero</PluginDisplayName>
     <PluginShortDisplayName>   </PluginShortDisplayName>
   </PluginDevice></PluginGenerator></Instrument>
 </Song>]]
  local info = up_song_xml.parse_instruments(xml)
  check(info[1] and info[1].display_name == "Reaktor5",
    "empty <PluginDisplayName/> falls back to the short display name")
  check(info[1] and info[1].instrument_name == nil and info[1].identifier == nil,
    "blank <Name> / <PluginIdentifier> are nil, not empty strings")
  check(info[2] and info[2].short_display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "whitespace-only short display name falls back to the display name")
  check(info[""] == nil, "no entry is indexed under an empty-string key")
end

section("up_song_xml.parse_instruments recovers Reaktor ensemble (preset) from chunk")
do
  -- Reaktor/Kontakt embed the loaded ensemble as a base64 "file://.../Name.ext"
  -- inside the opaque ParameterChunk. Renoise exposes that name nowhere on the
  -- live API once the plugin fails to load, so it must be lifted from Song.xml.
  local chunk = "cHJlZml4AGZpbGU6Ly8vVXNlcnMvU2hhcmVkL1Jhem9yL1Jhem9yLnJrcGxyAHN1ZmZpeA=="
  local xml = '<?xml version="1.0"?>\n<Song>\n<Instrument>\n<Name>Dark Dreams 1</Name>\n'
    .. '<PluginGenerator><PluginDevice>\n<PluginType>AU</PluginType>\n'
    .. '<PluginIdentifier>aumu:NiR5:-NI-</PluginIdentifier>\n'
    .. '<PluginDisplayName>AU: Native Instruments: Reaktor5</PluginDisplayName>\n'
    .. '<ParameterChunk><![CDATA[' .. chunk .. ']]></ParameterChunk>\n'
    .. '</PluginDevice></PluginGenerator>\n</Instrument>\n</Song>'
  local info = up_song_xml.parse_instruments(xml)
  check(info[1] and info[1].preset_name == "Razor",
    "loaded Reaktor ensemble recovered from ParameterChunk (Razor)")
  check(info["Dark Dreams 1"] and info["Dark Dreams 1"].preset_name == "Razor",
    "preset recoverable by live instrument name")
end

section("up_song_xml.parse_instruments keeps every instrument inside a group")
do
  -- Regression: <InstrumentGroup> must not swallow the first inner <Instrument>
  -- (the old pattern matched the group as an instrument open and consumed it).
  local xml = [[<?xml version="1.0"?>
 <Song>
   <InstrumentGroup>
     <Instrument>
       <Name>VST: Kick - Nicky Romero ()</Name>
       <PluginGenerator><PluginDevice>
         <PluginType>VST</PluginType>
         <PluginIdentifier>Kick - Nicky Romero</PluginIdentifier>
         <PluginDisplayName>VST: Sonic Academy: Kick - Nicky Romero</PluginDisplayName>
       </PluginDevice></PluginGenerator>
     </Instrument>
     <Instrument>
       <Name>AU: Native Instruments: Reaktor5</Name>
       <PluginGenerator><PluginDevice>
         <PluginType>AU</PluginType>
         <PluginDisplayName>AU: Native Instruments: Reaktor5</PluginDisplayName>
       </PluginDevice></PluginGenerator>
     </Instrument>
   </InstrumentGroup>
   <Instrument>
     <Name>Sampler</Name>
     <InstrumentType>Sampler</InstrumentType>
   </Instrument>
 </Song>]]
  local info = up_song_xml.parse_instruments(xml)
  check(info[1] and info[1].display_name == "VST: Sonic Academy: Kick - Nicky Romero",
    "first grouped instrument kept (idx 1)")
  check(info[2] and info[2].display_name == "AU: Native Instruments: Reaktor5",
    "second grouped instrument kept (idx 2, not dropped)")
  check(info["AU: Native Instruments: Reaktor5"],
    "second grouped instrument found by live instrument name")
end

section("up_song_xml.parse_instruments recovers preset from attributed/indented chunk")
do
  -- Regression: a real ParameterChunk may carry attributes and leading whitespace
  -- before the CDATA, which the strict match previously failed to recover.
  local chunk = "cHJlZml4AGZpbGU6Ly8vVXNlcnMvU2hhcmVkL1Jhem9yL1Jhem9yLnJrcGxyAHN1ZmZpeA=="
  local xml = '<?xml version="1.0"?>\n<Song>\n<Instrument>\n<Name>Dark Dreams 1</Name>\n'
    .. '<PluginGenerator><PluginDevice>\n<PluginType>AU</PluginType>\n'
    .. '<PluginDisplayName>AU: Native Instruments: Reaktor5</PluginDisplayName>\n'
    .. '<ParameterChunk preset="Razor.rkplr">  <![CDATA[' .. chunk .. ']]></ParameterChunk>\n'
    .. '</PluginDevice></PluginGenerator>\n</Instrument>\n</Song>'
  local info = up_song_xml.parse_instruments(xml)
  check(info[1] and info[1].preset_name == "Razor",
    "preset recovered from attributed/indented ParameterChunk")
end

section("coverage: up_song_xml.parse_instruments skips samplers and recover() handles no file")
do
  local xml = [[<?xml version="1.0"?>
 <Song>
   <Instrument><Name>Just a Sampler</Name></Instrument>
   <Instrument><Name>Reaktor Inst</Name><PluginGenerator><PluginDevice>
     <PluginType>AU</PluginType>
     <PluginDisplayName>AU: Native Instruments: Reaktor5</PluginDisplayName>
   </PluginDevice></PluginGenerator></Instrument>
 </Song>]]
  local info = up_song_xml.parse_instruments(xml)
  -- The sampler (no PluginType) is skipped, so the plugin is indexed by its name,
  -- not by the 1-based instrument position (which the sampler occupies).
  check(info["Reaktor Inst"] and info["Reaktor Inst"].display_name == "AU: Native Instruments: Reaktor5",
    "plugin instrument indexed by name; sampler without PluginType skipped")
  -- recover() needs a real song file; with none it yields an empty table.
  local got = up_song_xml.recover({ file_name = "" })
  check(got ~= nil and type(got) == "table", "recover() returns a table even with no song file")

  -- An empty or whitespace-only <PluginType> is not a real protocol: a non-plugin
  -- instrument with such an edge-case element must NOT be misclassified as a plugin.
  for _, pt in ipairs({ "", "   " }) do
    local x = string.format([[<?xml version="1.0"?>
 <Song>
   <Instrument><Name>Edge Case %q</Name><PluginGenerator><PluginDevice>
     <PluginType>%s</PluginType>
     <PluginDisplayName>Edge Case %s</PluginDisplayName>
   </PluginDevice></PluginGenerator></Instrument>
 </Song>]], pt, pt, pt)
    local inf = up_song_xml.parse_instruments(x)
    check(inf["Edge Case " .. pt] == nil,
      "instrument with empty/whitespace PluginType (" .. tostring(pt) .. ") is not treated as a plugin")
  end
end

section("coverage: up_song_xml recover cache + edge inputs")
do
  up_song_xml.invalidate_cache()
  local r1 = up_song_xml.recover({ file_name = fixture })
  local r2 = up_song_xml.recover({ file_name = fixture })
  check(r1 ~= nil and r2 ~= nil, "recover returns parsed identity table from the fixture")
  up_song_xml.invalidate_cache()
  local empty = up_song_xml.recover({ file_name = "" })
  check(empty ~= nil and type(empty) == "table", "recover returns a table when no song file exists")

  -- Whitespace-only fields collapse to nil and a non-plugin (no PluginType) is skipped.
  local xml = [[<?xml version="1.0"?>
 <Song><Instrument><Name>   </Name><PluginType>  </PluginType>
 <PluginDisplayName>x</PluginDisplayName></Instrument></Song>]]
  local info = up_song_xml.parse_instruments(xml)
  check(info[1] == nil, "instrument with blank PluginType is not classified as a plugin")
end
