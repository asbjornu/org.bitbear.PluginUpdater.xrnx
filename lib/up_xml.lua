-- Pure-Lua XML parser for Renoise's Song.xml, built on SLAXML.
--
-- Renoise's embedded Lua ships no XML library, and C-based parsers (e.g. LuaExpat)
-- cannot be loaded in its sandbox, so we vendor a pure-Lua parser. SLAXML
-- (https://github.com/Phrogz/SLAXML, MIT) is used as the underlying engine: it is
-- pure Lua, runs on every PUC-Rio Lua 5.1+ (and the harness's Lua 5.5), correctly
-- decodes numeric character references above 255 into UTF-8, and handles CDATA,
-- comments, namespaces and processing instructions.
--
-- This module is a thin tree builder over SLAXML's SAX stream. parse() returns the
-- root element as a table
--
--   { tag = "Song", attrs = { a = "b" }, children = { elem, ... }, text = "...", cdata = "..." }
--
-- Elements appear in `children` in document order. Text and CDATA are captured on
-- the parent element (matching the shape up_songxml expects). Only the subset
-- Renoise emits is needed, but the full parser handles more.

local up_xml = {}

local ok_slaxml, SLAXML = pcall(require, "slaxml")
if not ok_slaxml or not SLAXML then
  error("up_xml requires the vendored SLAXML parser (lib/slaxml.lua). The slaxml rockspec on "
    .. "LuaRocks is broken, so it is committed directly into lib/; restore it from version "
    .. "control with `git checkout -- lib/slaxml.lua`.", 2)
end

-- Parse an XML string into its root element (or nil on empty/garbage input).
function up_xml.parse(xml)
  if type(xml) ~= "string" or xml == "" then return nil end
  local root = nil
  local stack = {}
  local ok = pcall(function()
    local parser = SLAXML:parser{
      startElement = function(name)
        local node = { tag = name, attrs = {}, children = {}, text = "", cdata = "" }
        if #stack > 0 then
          table.insert(stack[#stack].children, node)
        else
          root = node
        end
        table.insert(stack, node)
      end,
      attribute = function(name, value)
        local top = stack[#stack]
        if top then top.attrs[name] = value end
      end,
      text = function(value, cdata)
        local top = stack[#stack]
        if not top then return end
        if cdata then
          top.cdata = top.cdata .. value
        else
          top.text = top.text .. value
        end
      end,
      closeElement = function(name)
        local top = stack[#stack]
        if not top then
          error("unexpected closing tag </" .. name .. ">", 2)
        end
        if top.tag ~= name then
          error("mismatched closing tag </" .. name .. "> (expected </" .. top.tag .. ">)", 2)
        end
        table.remove(stack)
      end,
    }
    parser:parse(xml)
  end)
  if not ok then return nil end
  return root
end

-- Depth-first search for the first descendant (or self) element with the given tag.
function up_xml.find(elem, tag)
  if not elem then return nil end
  if elem.tag == tag then return elem end
  for _, c in ipairs(elem.children) do
    local found = up_xml.find(c, tag)
    if found then return found end
  end
  return nil
end

-- Collect every descendant element (including nested ones) with the given tag.
function up_xml.find_all(elem, tag, acc)
  acc = acc or {}
  if not elem then return acc end
  for _, c in ipairs(elem.children) do
    if c.tag == tag then acc[#acc + 1] = c end
    up_xml.find_all(c, tag, acc)
  end
  return acc
end

-- First child element whose tag matches.
function up_xml.child(elem, tag)
  if not elem then return nil end
  for _, c in ipairs(elem.children) do
    if c.tag == tag then return c end
  end
  return nil
end

-- Trimmed text content of the first child element with the given tag (nil if absent).
function up_xml.child_text(elem, tag)
  local c = up_xml.child(elem, tag)
  if not c then return nil end
  return (c.text or ""):match("^%s*(.-)%s*$") or ""
end

-- CDATA of the first child element with the given tag (nil if absent).
function up_xml.child_cdata(elem, tag)
  local c = up_xml.child(elem, tag)
  if not c then return nil end
  return c.cdata ~= "" and c.cdata or nil
end

-- Trimmed text of the first *descendant* (depth-first) with the given tag. Renoise
-- nests e.g. <PluginType> inside <PluginGenerator><PluginDevice>, so callers usually
-- want the nearest matching descendant, not just a direct child.
function up_xml.descendant_text(elem, tag)
  local e = up_xml.find(elem, tag)
  if not e then return nil end
  return (e.text or ""):match("^%s*(.-)%s*$") or ""
end

-- CDATA of the first *descendant* element with the given tag (nil if absent).
function up_xml.descendant_cdata(elem, tag)
  local e = up_xml.find(elem, tag)
  if not e then return nil end
  return e.cdata ~= "" and e.cdata or nil
end

return up_xml
