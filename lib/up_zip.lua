local up_zip = {}

-- Pure-Lua reader for a single entry inside a ZIP archive (e.g. a Renoise
-- `.xrns` song, which is a zip). It locates the entry via the central
-- directory and inflates it with the vendored LibDeflate, so no system
-- `unzip` binary is required. Only the "stored" (0) and "deflate" (8)
-- compression methods are handled, which covers Renoise's `.xrns` files.
--
-- LibDeflate is vendored from https://github.com/SafeteeWoW/LibDeflate and is
-- kept up to date by .github/workflows/luarocks-update.yml.

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
  local minp = math.max(1, #data - 65557)
  for i = minp, #data - 21 do
    if data:byte(i) == 0x50 and data:byte(i + 1) == 0x4b
      and data:byte(i + 2) == 0x05 and data:byte(i + 3) == 0x06 then
      return i
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
  local name_len = u16(data, local_offset + 26)
  local extra_len = u16(data, local_offset + 28)
  local start = local_offset + 30 + name_len + extra_len
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
