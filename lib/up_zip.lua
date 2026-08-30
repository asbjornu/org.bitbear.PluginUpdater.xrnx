local up_zip = {}

-- Pure-Lua reader for a single entry inside a ZIP archive (e.g. a Renoise
-- `.xrns` song, which is a zip). It locates the entry via the central
-- directory and inflates it with the vendored LibDeflate, so no system
-- `unzip` binary is required. Only the "stored" (0) and "deflate" (8)
-- compression methods are handled, which covers Renoise's `.xrns` files.
--
-- LibDeflate is vendored from https://github.com/SafeteeWoW/LibDeflate and is
-- kept up to date by .github/workflows/luarocks-update.yml.

-- LibDeflate optionally registers itself with the World of Warcraft "LibStub"
-- global. Renoise has no such global and runs Lua under strict mode, which
-- errors when LibDeflate.lua reads the undeclared global. Declare "LibStub"
-- (as nil) before loading so the read is permitted; when it is nil LibDeflate
-- simply skips the registration. This keeps lib/LibDeflate.lua pristine so the
-- scheduled auto-update can replace it unchanged.
do
  local ok, mt = pcall(debug.getmetatable, _G)
  if ok and mt and mt.__declared then
    mt.__declared["LibStub"] = true
  end
  rawset(_G, "LibStub", rawget(_G, "LibStub"))
end

local LibDeflate = require("LibDeflate")

local function u16(s, i)
  return s:byte(i) + s:byte(i + 1) * 256
end

local function u32(s, i)
  return s:byte(i)
    + s:byte(i + 1) * 256
    + s:byte(i + 2) * 65536
    + s:byte(i + 3) * 16777216
end

local function find_eocd(data)
  -- The End Of Central Directory record sits at the very end of the archive
  -- (optionally followed by a comment). Scan backwards from the end so we find
  -- the *last* occurrence of the signature; a naive forward scan could match the
  -- same 4 bytes inside compressed file data or inside the trailing comment.
  -- Validate the comment length so a coincidental match inside the comment is
  -- rejected (the record must end exactly at the last byte of the file).
  local maxp = #data - 21
  local minp = math.max(1, #data - 65557)
  for i = maxp, minp, -1 do
    if data:byte(i) == 0x50 and data:byte(i + 1) == 0x4b
      and data:byte(i + 2) == 0x05 and data:byte(i + 3) == 0x06 then
      local comment_len = u16(data, i + 20)
      if i + 21 + comment_len == #data then
        return i
      end
    end
  end
  return nil
end

-- Extract `entry_name` from the zip archive at `zip_path` and return its
-- contents as a string, or nil if the entry cannot be read.
function up_zip.extract(zip_path, entry_name)
  local f = io.open(zip_path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if not data or #data == 0 then return nil end

  local eocd = find_eocd(data)
  if not eocd then return nil end
  local cd_offset = u32(data, eocd + 16) + 1

  local p = cd_offset
  local method, comp_size, local_offset
  while p + 46 <= #data do
    if data:byte(p) ~= 0x50 or data:byte(p + 1) ~= 0x4b
      or data:byte(p + 2) ~= 0x01 or data:byte(p + 3) ~= 0x02 then
      break
    end
    local name_len = u16(data, p + 28)
    local extra_len = u16(data, p + 30)
    local comment_len = u16(data, p + 32)
    local name = data:sub(p + 46, p + 45 + name_len)
    if name == entry_name then
      method = u16(data, p + 10)
      comp_size = u32(data, p + 20)
      local_offset = u32(data, p + 42) + 1
      break
    end
    p = p + 46 + name_len + extra_len + comment_len
  end
  if not method then return nil end

  if data:byte(local_offset) ~= 0x50 or data:byte(local_offset + 1) ~= 0x4b
    or data:byte(local_offset + 2) ~= 0x03 or data:byte(local_offset + 3) ~= 0x04 then
    return nil
  end
  -- Guard against a truncated/corrupt archive: the local-header fields we read
  -- below and the compressed-data window must lie fully inside the file,
  -- otherwise the byte reads would receive nil and throw instead of returning
  -- nil (which is what callers expect for an unreadable archive).
  if local_offset + 30 > #data then return nil end
  local name_len = u16(data, local_offset + 26)
  local extra_len = u16(data, local_offset + 28)
  local start = local_offset + 30 + name_len + extra_len
  if start > #data or start + comp_size - 1 > #data then return nil end
  local comp = data:sub(start, start + comp_size - 1)
  if method == 0 then
    return comp
  elseif method == 8 then
    local ok, out = pcall(LibDeflate.DecompressDeflate, LibDeflate, comp)
    if ok and out then return out end
    return nil
  end
  return nil
end

return up_zip
