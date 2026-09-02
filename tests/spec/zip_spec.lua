-- Tests for up_zip: the pure-Lua reader that inflates a single entry (the saved
-- Song.xml) out of a Renoise .xrns zip without any system `unzip` dependency.

section("up_zip.extract (pure-Lua zip reader)")
do
  local xml = up_zip.extract(fixture, "Song.xml")
  check(xml ~= nil and xml ~= "", "extracts Song.xml from the .xrns fixture")
  check(xml and xml:find("<Song>") ~= nil, "extracted Song.xml is well-formed XML")
  check(xml and xml:find("PluginDisplayName") ~= nil, "extracted Song.xml has plugin identities")
  local missing = up_zip.extract(fixture, "no-such-entry.xml")
  check(missing == nil, "missing entry returns nil")
end
