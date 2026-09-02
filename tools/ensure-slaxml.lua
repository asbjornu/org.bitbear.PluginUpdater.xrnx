#!/usr/bin/env lua
-------------------------------------------------------------------------------
-- Ensure lib/slaxml.lua exists.
--
-- SLAXML (MIT) is vendored directly into lib/slaxml.lua and committed to the
-- repository, so Renoise's sandbox can require it without a LuaRocks install.
-- This script is kept as a lightweight guard that confirms the vendored file is
-- present; it no longer relies on `luarocks`, whose slaxml rockspec points at a
-- git tag that no longer exists upstream.
-------------------------------------------------------------------------------

local dest = "lib/slaxml.lua"

local f = io.open(dest, "r")
if not f then
  io.stderr:write(
    "lib/slaxml.lua is missing. It should be vendored in the repository; " ..
    "restore it from version control (e.g. `git checkout -- lib/slaxml.lua`).\n")
  os.exit(1)
end
f:close()

print("slaxml present (vendored): " .. dest)
os.exit(0)
