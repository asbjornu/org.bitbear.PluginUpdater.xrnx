-- Tests for up_xml: the pure-Lua tree parser built on SLAXML. Covers nested
-- elements, attributes, CDATA, the vendored-parser error message, high
-- codepoints, inner-quote attributes, and malformed-input rejection.

section("up_xml.parse (pure-Lua XML tree)")
do
  -- Validates the tree parser used by up_songxml: nested elements, attributes,
  -- <InstrumentGroup> handling, descendant text, and CDATA.
  local xml = [==[<?xml version="1.0"?>
 <Song>
   <InstrumentGroup>
     <Instrument name="a"><PluginType>VST</PluginType><Name>Kick A</Name></Instrument>
     <Instrument name="b"><PluginType>AU</PluginType><Name>Reaktor B</Name></Instrument>
   </InstrumentGroup>
   <Instrument foo="bar"><Name>VST C</Name><PluginType>VST3</PluginType>
     <ParameterChunk preset="x">  <![CDATA[hello]]></ParameterChunk>
   </Instrument>
 </Song>]==]
  local doc = up_xml.parse(xml)
  check(doc and doc.tag == "Song", "root element is Song")
  local insts = up_xml.find_all(doc, "Instrument")
  check(#insts == 3, "all <Instrument> found at any depth (group + plain + attributed)")
  check(insts[3].attrs.foo == "bar", "attribute parsed from tag")
  check(insts[1].attrs.name == "a", "attribute parsed (first grouped instrument)")
  check(up_xml.descendant_text(insts[1], "Name") == "Kick A", "descendant text extracted")
  check(up_xml.descendant_cdata(insts[3], "ParameterChunk") == "hello",
    "CDATA extracted despite surrounding whitespace")

  -- Direct-child accessors (child / child_text / child_cdata) and their nil
  -- branches.
  local doc2 = up_xml.parse("<Root><A>hi</A><B><![CDATA[x]]></B></Root>")
  check(up_xml.child(doc2, "A") ~= nil, "child finds a direct child element")
  check(up_xml.child(doc2, "Z") == nil, "child returns nil when absent")
  check(up_xml.child_text(doc2, "A") == "hi", "child_text returns trimmed text")
  check(up_xml.child_text(doc2, "Z") == nil, "child_text returns nil when absent")
  check(up_xml.child_cdata(doc2, "B") == "x", "child_cdata returns CDATA")
  check(up_xml.child_cdata(doc2, "Z") == nil, "child_cdata returns nil when absent")
  check(up_xml.child(nil, "A") == nil, "child is nil-safe on a nil element")
end

section("up_xml require fails clearly when slaxml is missing (vendored, not LuaRocks)")
do
  -- up_xml requires the vendored lib/slaxml.lua at load time. When it cannot be
  -- required (missing file / wrong package.path), the error must point at the
  -- vendored copy and must NOT tell users to `luarocks install slaxml`.
  local prev_xml = package.loaded["up_xml"]
  local prev_slax = package.loaded["slaxml"]
  package.loaded["up_xml"] = nil
  package.loaded["slaxml"] = nil
  package.preload["slaxml"] = function() error("forced slaxml load failure", 0) end
  local ok, err = pcall(require, "up_xml")
  package.preload["slaxml"] = nil
  package.loaded["slaxml"] = prev_slax
  package.loaded["up_xml"] = prev_xml
  check(not ok, "require('up_xml') raises when slaxml is unavailable")
  check(not ok and tostring(err):find("vendored SLAXML") ~= nil
    and tostring(err):find("luarocks install slaxml") == nil,
    "error references the vendored parser and not a LuaRocks install")
end

section("up_xml.parse handles high codepoints and inner-quote attribute values")
do
  -- &#8217; is a curly apostrophe (U+2019), a codepoint > 255 that string.char() would
  -- reject; it must decode to UTF-8 without raising and without aborting the parse.
  local xml = [==[<Song><Name>Don&#8217;t</Name>
    <Instrument name='a "quoted" value'><PluginType>VST</PluginType></Instrument>
  </Song>]==]
  local doc = up_xml.parse(xml)
  check(doc ~= nil, "parses despite a high codepoint entity")
  local name = up_xml.descendant_text(doc, "Name")
  check(name and name:find("&#8217;") == nil and name:find("Don") and name:find("t"),
    "high codepoint entity decoded to UTF-8 (not left raw)")
  local inst = up_xml.find_all(doc, "Instrument")[1]
  check(inst.attrs.name == 'a "quoted" value',
    "attribute value containing the other quote is parsed correctly")
end

section("up_xml.parse rejects malformed (mismatched) closing tags")
do
  -- Malformed XML with a mismatched or unopened closing tag must be rejected
  -- (fail the parse) rather than silently producing an incorrect tree.
  check(up_xml.parse("<Root><A></B></Root>") == nil,
    "mismatched closing tag fails the parse")
  check(up_xml.parse("<Root><A></Root>") == nil,
    "closing tag without an open element fails the parse")
end
