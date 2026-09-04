local up_matching = {}

local up_plugin_analysis = require("up_plugin_analysis")

-- Read a field from a possibly-opaque object (Renoise DeviceInfo userdata) without
-- throwing, so a probe that isn't supported on a given object degrades gracefully.
local function safe_get_field(object, key)
  local ok, value = pcall(function() return object[key] end)
  if not ok then return nil end
  return value
end

local NAME_KEYS = { "name", "device_name", "display_name", "plugin_name", "product_name", "short_name" }

-- Resolve the human-readable name of a track device from one of its info objects,
-- tolerating both plain string fields and throwing getter functions.
local function track_display_name_of(device_info)
  for _, key in ipairs(NAME_KEYS) do
    local value = safe_get_field(device_info, key)
    if type(value) == "string" and value ~= "" then
      return value
    end
    if type(value) == "function" then
      local ok, result = pcall(value, device_info)
      if ok and type(result) == "string" and result ~= "" then
        return result
      end
    end
  end
  return nil
end

-- Collect the (path, name) pairs for a track's available devices. Renoise exposes
-- available_devices (loadable full paths; VST readable, VST3 opaque UID, AU 4-char
-- code) and available_device_infos (DeviceInfo objects) in parallel; zip them so
-- each pool entry keeps a loadable path AND a readable name -- the only reliable
-- key for matching across protocols (DeviceInfo.device_path is nil in this binding).
local function collect_track_device_infos(track)
  local ok_devices, device_paths = pcall(function() return track.available_devices end)
  local ok_infos, device_infos = pcall(function() return track.available_device_infos end)
  if ok_devices and device_paths and #device_paths > 0 then
    local entries = {}
    for index, device_path in ipairs(device_paths) do
      local device_name
      if ok_infos and device_infos and device_infos[index] then
        device_name = track_display_name_of(device_infos[index])
      end
      entries[#entries + 1] = { device_path = device_path, device_name = device_name }
    end
    return entries
  end
  return nil
end

function up_matching.build_track_pool(song, yield_function, on_progress, fallback_pool)
  local pool = {}
  local seen = {}
  local device_infos = nil
  for track_index = 1, #song.tracks do
    if on_progress then
      on_progress("Indexing track plugins", track_index, #song.tracks)
    end
    if yield_function then
      yield_function()
    end
    if not device_infos then
      local track_entries = collect_track_device_infos(song.tracks[track_index])
      if track_entries and #track_entries > 0 then
        device_infos = track_entries
      end
    else
      break
    end
  end
  if device_infos then
    for index, entry in ipairs(device_infos) do
      local device_path
      if type(entry) == "table" then
        device_path = entry.device_path
      elseif type(entry) == "string" then
        device_path = entry
      end
      local device_name = (type(entry) == "table") and entry.device_name or nil
      if device_path and not up_plugin_analysis.is_native_path(device_path) and not seen[device_path] then
        seen[device_path] = true
        local analysis = up_plugin_analysis.analyze_plugin(device_path, device_name)
        analysis.path = device_path
        analysis.name = device_name
        table.insert(pool, analysis)
      end
      if yield_function and (index % 50 == 0) then
        yield_function()
      end
    end
  end
  if #pool == 0 and fallback_pool then
    for _, analysis in ipairs(fallback_pool) do
      local path = tostring(analysis.path or "")
        :gsub("[Gg]enerators", "Effects")
        :gsub("[Gg]enerator", "Effect")
      if path ~= "" and not up_plugin_analysis.is_native_path(path) and not seen[path] then
        seen[path] = true
        local analysis2 = up_plugin_analysis.analyze_plugin(path, analysis.product or analysis.name)
        analysis2.path = path
        table.insert(pool, analysis2)
      end
    end
  end
  return pool
end

function up_matching.build_instrument_pool(song, yield_function, on_progress)
  local pool = {}
  local seen = {}
  local plugin_infos = nil
  for instrument_index = 1, #song.instruments do
    if on_progress then
      on_progress("Indexing instrument plugins", instrument_index, #song.instruments)
    end
    if yield_function then
      yield_function()
    end
    if not plugin_infos then
      local ok, available_infos = pcall(function()
        return song.instruments[instrument_index].plugin_properties.available_plugin_infos
      end)
      if ok and available_infos and #available_infos > 0 then
        plugin_infos = available_infos
      end
    else
      break
    end
  end
  if plugin_infos then
    for index, plugin_info in ipairs(plugin_infos) do
      -- We got this entry from `available_plugin_infos`, which lists plugins
      -- only, so trust the name rather than gating on the path. For VST3 (and
      -- some AU) instruments `info.path` is an opaque UID / 4-char code with no
      -- protocol token, so `is_plugin_path` would wrongly reject it and the
      -- plugin (e.g. "Kick 2") would vanish from the candidate pool. The name
      -- is the reliable key for matching; `info.path` is still kept because it
      -- is the handle Renoise uses to actually load the plugin.
      local plugin_name = plugin_info.name
      if type(plugin_name) ~= "string" or plugin_name == "" then
        plugin_name = plugin_info.path
      end
      -- available_plugin_infos yields loadable plugin handles, so a usable path
      -- is required: a nil/empty path cannot be loaded and would later blow up
      -- in pp:load_plugin(candidate.path) / track:insert_device_at(candidate.path).
      -- VST3/AU paths are opaque UIDs but are still valid, non-empty string
      -- handles Renoise loads by, so gate on a non-empty string rather than on
      -- path shape.
      if type(plugin_info.path) == "string" and plugin_info.path ~= "" then
        local native_name = up_plugin_analysis.is_native_path(plugin_name)
        if type(plugin_name) == "string" and plugin_name ~= "" and not native_name then
          if not seen[plugin_info.path] then
            seen[plugin_info.path] = true
            local analysis = up_plugin_analysis.analyze_plugin(plugin_info.path, plugin_name)
            analysis.path = plugin_info.path
            analysis.name = plugin_name
            table.insert(pool, analysis)
          end
        end
      end
      if yield_function and (index % 50 == 0) then
        yield_function()
      end
    end
  end
  return pool
end

function up_matching.vendor_ok(candidate, old_analysis)
  if old_analysis.vendor == "" or candidate.vendor == "" then
    return true
  end
  return candidate.vendor == old_analysis.vendor
end

function up_matching.candidate_matches(candidate, old_analysis)
  if not old_analysis then
    return false
  end
  if candidate.path == old_analysis.raw then
    return false
  end
  if candidate.base ~= old_analysis.base then
    return false
  end
  return up_matching.vendor_ok(candidate, old_analysis)
end

-- Best-effort match used for broken/missing plugins, where we can't transfer
-- state and so a newer major version of the same product is an acceptable
-- replacement. A candidate matches when its significant tokens are a subset of
-- the old plugin's (or vice versa), which tolerates vendor-prefix asymmetry
-- ("Native Instruments: Reaktor5" <-> "Reaktor6") and artist suffixes
-- ("Kick - Nicky Romero" <-> "Kick 2"), while still rejecting unrelated plugins.
function up_matching.candidate_matches_loose(candidate, old_analysis)
  if not old_analysis then
    return false
  end
  if candidate.path == old_analysis.raw then
    return false
  end
  local candidate_tokens = up_plugin_analysis.token_set(candidate.base)
  local old_tokens = up_plugin_analysis.token_set(old_analysis.base)
  if not next(candidate_tokens) or not next(old_tokens) then
    return false
  end
  return up_plugin_analysis.token_subset(candidate_tokens, old_tokens)
    or up_plugin_analysis.token_subset(old_tokens, candidate_tokens)
end

-- Last-resort match for plugins we could only identify by their live instrument
-- name (the .xrns couldn't be read, so we lack the vendor-prefixed display
-- name). When the candidate and the old name share a significant token (length
-- >= 4), treat them as the same product. e.g. "Kick - Nicky Romero" and
-- "Kick 2" both carry "kick", so the missing Kick surfaces as a Kick 2 upgrade.
-- Requiring a long shared token keeps unrelated plugins from matching.
function up_matching.candidate_matches_shared(candidate, old_analysis)
  if not old_analysis then
    return false
  end
  if candidate.path == old_analysis.raw then
    return false
  end
  local candidate_tokens = up_plugin_analysis.token_set(candidate.base)
  local old_tokens = up_plugin_analysis.token_set(old_analysis.base)
  if not next(candidate_tokens) or not next(old_tokens) then
    return false
  end
  for token in pairs(candidate_tokens) do
    if #token >= 4 and old_tokens[token] and up_plugin_analysis.is_product_token(token) then
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
  for _, candidate in ipairs(pool) do
    if up_matching.candidate_matches(candidate, old_analysis) then
      if best == nil or up_plugin_analysis.rank(candidate) > best_rank then
        best = candidate
        best_rank = up_plugin_analysis.rank(candidate)
      end
    end
  end
  return best
end

-- old_or_record may be the analysis table or the full inventory record. Exact
-- matches (same product + version, any protocol) are preferred; when none exist
-- we fall back to a version/name-flexible family match. That covers missing
-- plugins recovered from the song, and healthy plugins whose installed equivalent
-- differs in version or branding -- e.g. AU "FabFilter FF Pro MB" -> VST3
-- "FabFilter Pro-MB", or Reaktor5 -> Reaktor6.
-- Same-product match across versions: the candidate shares the old plugin's
-- product family (its base with the trailing version stripped), so e.g. both
-- "Pro-L" and "Pro-L 2" collapse to "fabfilter pro l" and match each other.
-- Unlike candidate_matches (strict same-version) this deliberately spans major
-- versions so an installed newer release is offered as an upgrade. Unlike the
-- loose token match it never crosses into a different product, so "Pro-Q 3" is
-- never offered for "Pro-L".
function up_matching.candidate_matches_family(candidate, old_analysis)
  if not old_analysis then
    return false
  end
  if candidate.path == old_analysis.raw then
    return false
  end
  if up_plugin_analysis.family_base(candidate.base) ~= up_plugin_analysis.family_base(old_analysis.base) then
    return false
  end
  return up_matching.vendor_ok(candidate, old_analysis)
end

function up_matching.find_candidates(pool, old_or_record)
  local old_analysis = old_or_record
  if type(old_or_record) == "table" and old_or_record.analysis then
    old_analysis = old_or_record.analysis
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
  for _, candidate in ipairs(pool) do
    if up_matching.candidate_matches_family(candidate, old_analysis) then
      table.insert(list, candidate)
    end
  end
  if #list == 0 then
    -- Fall back to the version/name-flexible token match for broken/missing
    -- plugins (vendor-prefix or artist-suffix asymmetry, e.g. Reaktor5 ->
    -- Reaktor6, "Kick - Nicky Romero" -> "Kick 2", FF Pro MB -> Pro-MB).
    for _, candidate in ipairs(pool) do
      if up_matching.candidate_matches_loose(candidate, old_analysis) then
        table.insert(list, candidate)
      end
    end
  end
  if #list == 0 then
    -- Last resort: when we could only identify the plugin by its live instrument
    -- name (the .xrns was unreadable and plugin_properties exposed no name), match
    -- on a shared significant token so e.g. "Kick - Nicky Romero" still surfaces
    -- as a "Kick 2" upgrade.
    for _, candidate in ipairs(pool) do
      if up_matching.candidate_matches_shared(candidate, old_analysis) then
        table.insert(list, candidate)
      end
    end
  end
  if #list > 0 then
    table.sort(list, function(a, b)
      local same_protocol_a = (a.protocol == old_analysis.protocol) and 1 or 0
      local same_protocol_b = (b.protocol == old_analysis.protocol) and 1 or 0
      if same_protocol_a ~= same_protocol_b then return same_protocol_a > same_protocol_b end
      return up_plugin_analysis.rank(a) > up_plugin_analysis.rank(b)
    end)
  end
  return list
end

return up_matching
