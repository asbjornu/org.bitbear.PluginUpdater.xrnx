local up_util = require("up_util")

local up_matching = {}

local function safeget(obj, k)
  local ok, v = pcall(function() return obj[k] end)
  if not ok then return nil end
  return v
end

local NAME_KEYS = { "name", "device_name", "display_name", "plugin_name", "product_name", "short_name" }


local function track_name_of(info)
  for _, k in ipairs(NAME_KEYS) do
    local v = safeget(info, k)
    if type(v) == "string" and v ~= "" then
      return v
    end
    if type(v) == "function" then
      local ok, r = pcall(v, info)
      if ok and type(r) == "string" and r ~= "" then
        return r
      end
    end
  end
  return nil
end

local function track_infos(track)
  -- available_devices  -> loadable full paths (VST = readable, VST3 = opaque UID,
  --   AU = 4-char code). available_device_infos -> DeviceInfo objects, PARALLEL
  --   to available_devices. Zip them so each pool entry keeps a loadable path AND
  --   a readable name, which is the only reliable key for matching across
  --   protocols (DeviceInfo.device_path is nil in this binding).
  local okD, strs = pcall(function() return track.available_devices end)
  local okI, infos = pcall(function() return track.available_device_infos end)
  if okD and strs and #strs > 0 then
    local out = {}
    for i, p in ipairs(strs) do
      local nm
      if okI and infos and infos[i] then
        nm = track_name_of(infos[i])
      end
      out[#out + 1] = { device_path = p, device_name = nm }
    end
    return out
  end
  return nil
end

-- Structural dump of a track's available_device_infos to discover which field
-- carries the human-readable plugin name. Renoise DeviceInfo is opaque userdata,
-- so we probe a candidate list of property getters and report type/value.

function up_matching.build_track_pool(song, yield_fn, on_progress, fallback_pool)
  local pool = {}
  local seen = {}
  local infos = nil
  for ti = 1, #song.tracks do
    if on_progress then
      on_progress("Indexing track plugins", ti, #song.tracks)
    end
    if yield_fn then
      yield_fn()
    end
    if not infos then
      local t = track_infos(song.tracks[ti])
      if t and #t > 0 then
        infos = t
      end
    else
      break
    end
  end
  if infos then
    for j, info in ipairs(infos) do
      local dp
      if type(info) == "table" then
        dp = info.device_path
      elseif type(info) == "string" then
        dp = info
      end
      local dn = (type(info) == "table") and info.device_name or nil
      if dp and not up_util.is_native_path(dp) and not seen[dp] then
        seen[dp] = true
        local a = up_util.analyze_plugin(dp, dn)
        a.path = dp
        a.name = dn
        table.insert(pool, a)
      end
      if yield_fn and (j % 50 == 0) then
        yield_fn()
      end
    end
  end
  if #pool == 0 and fallback_pool then
    for _, a in ipairs(fallback_pool) do
      local p = tostring(a.path or "")
        :gsub("[Gg]enerators", "Effects")
        :gsub("[Gg]enerator", "Effect")
      if p ~= "" and not up_util.is_native_path(p) and not seen[p] then
        seen[p] = true
        local a2 = up_util.analyze_plugin(p, a.product or a.name)
        a2.path = p
        table.insert(pool, a2)
      end
    end
  end
  return pool
end

function up_matching.build_instrument_pool(song, yield_fn, on_progress)
  local pool = {}
  local seen = {}
  local infos = nil
  for ii = 1, #song.instruments do
    if on_progress then
      on_progress("Indexing instrument plugins", ii, #song.instruments)
    end
    if yield_fn then
      yield_fn()
    end
    if not infos then
      local ok, i = pcall(function()
        return song.instruments[ii].plugin_properties.available_plugin_infos
      end)
      if ok and i and #i > 0 then
        infos = i
      end
    else
      break
    end
  end
  if infos then
    for j, info in ipairs(infos) do
      -- We got this entry from `available_plugin_infos`, which lists plugins
      -- only, so trust the name rather than gating on the path. For VST3 (and
      -- some AU) instruments `info.path` is an opaque UID / 4-char code with no
      -- protocol token, so `is_plugin_path` would wrongly reject it and the
      -- plugin (e.g. "Kick 2") would vanish from the candidate pool. The name
      -- is the reliable key for matching; `info.path` is still kept because it
      -- is the handle Renoise uses to actually load the plugin.
      local nm = info.name
      if type(nm) ~= "string" or nm == "" then
        nm = info.path
      end
      -- available_plugin_infos yields loadable plugin handles, so a usable path
      -- is required: a nil/empty path cannot be loaded and would later blow up
      -- in pp:load_plugin(candidate.path) / track:insert_device_at(candidate.path).
      -- VST3/AU paths are opaque UIDs but are still valid, non-empty string
      -- handles Renoise loads by, so gate on a non-empty string rather than on
      -- path shape.
      if type(info.path) == "string" and info.path ~= "" then
        if type(nm) == "string" and nm ~= "" and not up_util.is_native_path(nm) then
          if not seen[info.path] then
            seen[info.path] = true
            local a = up_util.analyze_plugin(info.path, nm)
            a.path = info.path
            a.name = nm
            table.insert(pool, a)
          end
        end
      end
      if yield_fn and (j % 50 == 0) then
        yield_fn()
      end
    end
  end
  return pool
end

function up_matching.vendor_ok(c, old)
  if old.vendor == "" or c.vendor == "" then
    return true
  end
  return c.vendor == old.vendor
end

function up_matching.candidate_matches(c, old)
  if not old then
    return false
  end
  if c.path == old.raw then
    return false
  end
  if c.base ~= old.base then
    return false
  end
  return up_matching.vendor_ok(c, old)
end

-- Best-effort match used for broken/missing plugins, where we can't transfer
-- state and so a newer major version of the same product is an acceptable
-- replacement. A candidate matches when its significant tokens are a subset of
-- the old plugin's (or vice versa), which tolerates vendor-prefix asymmetry
-- ("Native Instruments: Reaktor5" <-> "Reaktor6") and artist suffixes
-- ("Kick - Nicky Romero" <-> "Kick 2"), while still rejecting unrelated plugins.
function up_matching.candidate_matches_loose(c, old)
  if not old then
    return false
  end
  if c.path == old.raw then
    return false
  end
  local tc = up_util.token_set(c.base)
  local to = up_util.token_set(old.base)
  if not next(tc) or not next(to) then
    return false
  end
  return up_util.token_subset(tc, to) or up_util.token_subset(to, tc)
end

-- Last-resort match for plugins we could only identify by their live instrument
-- name (the .xrns couldn't be read, so we lack the vendor-prefixed display
-- name). When the candidate and the old name share a significant token (length
-- >= 4), treat them as the same product. e.g. "Kick - Nicky Romero" and
-- "Kick 2" both carry "kick", so the missing Kick surfaces as a Kick 2 upgrade.
-- Requiring a long shared token keeps unrelated plugins from matching.
function up_matching.candidate_matches_shared(c, old)
  if not old then
    return false
  end
  if c.path == old.raw then
    return false
  end
  local tc = up_util.token_set(c.base)
  local to = up_util.token_set(old.base)
  if not next(tc) or not next(to) then
    return false
  end
  for k in pairs(tc) do
    if #k >= 4 and to[k] and up_util.is_product_token(k) then
      return true
    end
  end
  return false
end

function up_matching.find_candidate(pool, old_analysis)
  if not old_analysis then
    return nil
  end
  local best = nil
  local best_rank = nil
  for _, c in ipairs(pool) do
    if up_matching.candidate_matches(c, old_analysis) then
      if best == nil or up_util.rank(c) > best_rank then
        best = c
        best_rank = up_util.rank(c)
      end
    end
  end
  return best
end

-- old_or_rec may be the analysis table or the full inventory rec. Exact matches
-- (same product + version, any protocol) are preferred; when none exist we fall
-- back to a version/name-flexible family match. That covers missing plugins
-- recovered from the song, and healthy plugins whose installed equivalent differs
-- in version or branding -- e.g. AU "FabFilter FF Pro MB" -> VST3 "FabFilter
-- Pro-MB", or Reaktor5 -> Reaktor6.
-- Same-product match across versions: the candidate shares the old plugin's
-- product family (its base with the trailing version stripped), so e.g. both
-- "Pro-L" and "Pro-L 2" collapse to "fabfilter pro l" and match each other.
-- Unlike candidate_matches (strict same-version) this deliberately spans major
-- versions so an installed newer release is offered as an upgrade. Unlike the
-- loose token match it never crosses into a different product, so "Pro-Q 3" is
-- never offered for "Pro-L".
function up_matching.candidate_matches_family(c, old)
  if not old then
    return false
  end
  if c.path == old.raw then
    return false
  end
  if up_util.family_base(c.base) ~= up_util.family_base(old.base) then
    return false
  end
  return up_matching.vendor_ok(c, old)
end

function up_matching.find_candidates(pool, old_or_rec)
  local old_analysis = old_or_rec
  if type(old_or_rec) == "table" and old_or_rec.analysis then
    old_analysis = old_or_rec.analysis
  end
  if not old_analysis then
    return {}
  end
  -- Prefer same-product candidates (any version), which subsumes the exact
  -- same-version match: this is what lets "Pro-L" be upgraded to "Pro-L 2" (or
  -- "Kick" to "Kick 2") when both releases are installed, instead of only ever
  -- offering the identical version back. Newest version + best protocol ranks
  -- first, so the auto-selected replacement is the upgrade.
  local list = {}
  for _, c in ipairs(pool) do
    if up_matching.candidate_matches_family(c, old_analysis) then
      table.insert(list, c)
    end
  end
  if #list == 0 then
    -- Fall back to the version/name-flexible token match for broken/missing
    -- plugins (vendor-prefix or artist-suffix asymmetry, e.g. Reaktor5 ->
    -- Reaktor6, "Kick - Nicky Romero" -> "Kick 2", FF Pro MB -> Pro-MB).
    for _, c in ipairs(pool) do
      if up_matching.candidate_matches_loose(c, old_analysis) then
        table.insert(list, c)
      end
    end
  end
  if #list == 0 then
    -- Last resort: when we could only identify the plugin by its live instrument
    -- name (the .xrns was unreadable and plugin_properties exposed no name), match
    -- on a shared significant token so e.g. "Kick - Nicky Romero" still surfaces
    -- as a "Kick 2" upgrade.
    for _, c in ipairs(pool) do
      if up_matching.candidate_matches_shared(c, old_analysis) then
        table.insert(list, c)
      end
    end
  end
  if #list > 0 then
    table.sort(list, function(a, b)
      local sa = (a.protocol == old_analysis.protocol) and 1 or 0
      local sb = (b.protocol == old_analysis.protocol) and 1 or 0
      if sa ~= sb then return sa > sb end
      return up_util.rank(a) > up_util.rank(b)
    end)
  end
  return list
end

return up_matching
