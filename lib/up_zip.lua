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
-- global, and also probes `_G.arg` for its CLI harness. Renoise has neither and
-- runs Lua under strict mode, which errors on those undeclared reads. Declare
-- both as a benign `false` via rawset so the reads are permitted and LibDeflate
-- simply skips its registration/CLI harness. This keeps lib/LibDeflate.lua
-- pristine so the scheduled auto-update can replace it unchanged.
rawset(_G, "LibStub", false)
rawset(_G, "arg", false)

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

local function find_eocd(tail, base, size)
  -- `tail` holds the final bytes of the archive (starting at absolute 1-based
  -- offset `base`); the End Of Central Directory record sits at the very end
  -- (optionally followed by a comment). Scan backwards so we find the *last*
  -- occurrence of the signature; a forward scan could match the same 4 bytes
  -- inside compressed data or inside the trailing comment. Validate the comment
  -- length so a coincidental match inside the comment is rejected.
  local maxp = #tail - 21
  local minp = math.max(1, #tail - 65557)
  for i = maxp, minp, -1 do
    if tail:byte(i) == 0x50 and tail:byte(i + 1) == 0x4b
      and tail:byte(i + 2) == 0x05 and tail:byte(i + 3) == 0x06 then
      local comment_len = u16(tail, i + 20)
      if (base + i - 1) + 21 + comment_len == size then
        return base + i - 1
      end
    end
  end
  return nil
end
function up_zip.extract(zip_path, entry_name)
  local file_handle = io.open(zip_path, "rb")
  if not file_handle then return nil end
  local size = file_handle:seek("end")
  if not size or size < 22 then file_handle:close(); return nil end

  -- Seek-based reader: only the EOCD tail, the central directory, the matching
  -- local header, and the (small) target entry are read -- never the whole
  -- archive. Renoise `.xrns` files can embed large samples, so loading the
  -- entire zip into memory would waste RAM and could stall the UI.
  local function read_at(pos, n)
    file_handle:seek("set", pos - 1)
    return file_handle:read(n)
  end

  local tail_len = math.min(size, 65557)
  local base = size - tail_len + 1
  file_handle:seek("set", base - 1)
  local tail = file_handle:read(tail_len)
  local eocd = find_eocd(tail, base, size)
  if not eocd then file_handle:close(); return nil end

  local rel = eocd - base + 1
  local cd_offset = u32(tail, rel + 16) + 1
  -- The central directory sits just before the EOCD signature; the bytes
  -- between it and the signature are the (ignorable) comment.
  if cd_offset < 1 or cd_offset >= eocd then file_handle:close(); return nil end
  local central_directory = read_at(cd_offset, eocd - cd_offset)
  if not central_directory then file_handle:close(); return nil end

  local p = 1
  local method, comp_size, local_offset
  while p + 46 <= #central_directory do
    if central_directory:byte(p) ~= 0x50 or central_directory:byte(p + 1) ~= 0x4b
      or central_directory:byte(p + 2) ~= 0x01 or central_directory:byte(p + 3) ~= 0x02 then
      break
    end
    local name_len = u16(central_directory, p + 28)
    local extra_len = u16(central_directory, p + 30)
    local comment_len = u16(central_directory, p + 32)
    local name = central_directory:sub(p + 46, p + 45 + name_len)
    if name == entry_name then
      method = u16(central_directory, p + 10)
      comp_size = u32(central_directory, p + 20)
      local_offset = u32(central_directory, p + 42) + 1
      break
    end
    p = p + 46 + name_len + extra_len + comment_len
  end
  if not method then file_handle:close(); return nil end

  -- Read just the local header to locate the compressed-data window precisely.
  local local_header = read_at(local_offset, 30)
  if not local_header or #local_header < 30 or local_header:byte(1) ~= 0x50 or local_header:byte(2) ~= 0x4b
    or local_header:byte(3) ~= 0x03 or local_header:byte(4) ~= 0x04 then
    file_handle:close(); return nil
  end
  local name_len = u16(local_header, 27)
  local extra_len = u16(local_header, 29)
  local start = local_offset + 30 + name_len + extra_len
  if start > size or start + comp_size - 1 > size then file_handle:close(); return nil end
  local compressed_data = read_at(start, comp_size)
  file_handle:close()
  if not compressed_data then return nil end
  if method == 0 then
    return compressed_data
  elseif method == 8 then
    local ok, output = pcall(LibDeflate.DecompressDeflate, LibDeflate, compressed_data)
    if ok and output then return output end
    return nil
  end
  return nil
end

return up_zip
