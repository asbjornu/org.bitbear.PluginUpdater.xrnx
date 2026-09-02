-- Tests for up_plugin_analysis (plugin name analysis): protocol detection, native-path
-- discrimination, tokenisation, display-name normalisation, and the preset-label
-- extraction used for recovered plugins.

-- 2. up_plugin_analysis ----------------------------------------------------------------
section("up_plugin_analysis.analyze_plugin")
do
  local a = up_plugin_analysis.analyze_plugin(nil, "AU: Native Instruments: Reaktor5")
  check(a.protocol == "AU", "protocol detected from display name (AU)")
  check(a.base:find("reaktor5") ~= nil, "base keeps version (reaktor5)")
  check(up_plugin_analysis.family_base("native instruments: reaktor 6") == "native instruments: reaktor",
    "family_base strips trailing version")

  local a2 = up_plugin_analysis.analyze_plugin(nil, "VST: Sonic Academy: Kick - Nicky Romero")
  check(a2.base:find("kick") ~= nil and a2.base:find("nicky") ~= nil,
    "base includes artist suffix tokens")
end

section("up_plugin_analysis.is_native_path (native namespace, not vendor)")
do
  -- Renoise's built-in devices live under "Native/" (e.g. Audio/Effects/Native/Gainer).
  check(up_plugin_analysis.is_native_path("Audio/Effects/Native/Gainer"), "built-in native device path is native")
  check(up_plugin_analysis.is_native_path("Audio/Instruments/Native/Multi-Sampler"), "native instrument path is native")
  -- The vendor "Native Instruments" must NOT be mistaken for a built-in device,
  -- otherwise every plugin from that vendor (Reaktor, Kontakt, ...) is dropped
  -- from the candidate pool and can never be offered as an upgrade.
  check(not up_plugin_analysis.is_native_path("Native Instruments: Reaktor 6"),
    "vendor 'Native Instruments' is NOT native")
  check(not up_plugin_analysis.is_native_path("/Library/Audio/Plug-Ins/VST/Native Instruments/Reaktor 6.vst"),
    "filesystem path under 'Native Instruments' is NOT native")
  check(not up_plugin_analysis.is_native_path("VST: Native Instruments: Kontakt 7"),
    "display name with 'Native Instruments' is NOT native")
end

section("up_plugin_analysis.token_set / token_subset")
do
  local t1 = up_plugin_analysis.token_set("Sonic Academy: Kick - Nicky Romero")
  check(t1.kick and t1.nicky and t1.romero, "token_set splits significant words (e.g. Kick - Nicky - Romero)")
  local t2 = up_plugin_analysis.token_set("FabFilter Pro-Q 3")
  check(t2["q"], "single-char token 'q' is preserved (Pro-Q)")
  check(up_plugin_analysis.token_subset(up_plugin_analysis.token_set("fabfilter pro mb"),
                             up_plugin_analysis.token_set("fabfilter pro mb")),
    "token_subset: equal sets")
  check(not up_plugin_analysis.token_subset(up_plugin_analysis.token_set("fabfilter pro q"),
                                 up_plugin_analysis.token_set("fabfilter pro mb")),
    "token_subset: Pro-Q not subset of Pro-MB")
end

section("up_plugin_analysis.strip_redundant_prefix")
do
  local a = up_plugin_analysis.analyze_plugin(nil, "AU: Native Instruments: Reaktor5")
  local extra = up_plugin_analysis.strip_redundant_prefix("Reaktor5 Make It Bright", "AU", a)
  check(extra == "Make It Bright", "strips plugin-name tokens, keeps patch name")
end

section("up_plugin_analysis.format_plugin")
do
  check(up_plugin_analysis.format_plugin("VST: Lennardigital Sylenth1", "VST") == "VST: Lennardigital Sylenth1",
    "format_plugin re-emits protocol + name")
end

section("coverage: up_plugin_analysis.instrument_preset_label variants")
do
  local reaktor_a = up_plugin_analysis.analyze_plugin(nil, "VST: Native Instruments: Reaktor5")
  local label = function(name, protocol, analysis)
    return up_plugin_analysis.instrument_preset_label(name, protocol, analysis)
  end
  check(label("VST: Reaktor5 (Make It Bright)", "VST", reaktor_a) == "Make It Bright",
    "label recovered from parenthetical preset")
  check(label("Cinematic Pad 1", "AU", nil) == "Cinematic Pad 1",
    "label is a bare user patch name")
  check(label("Dark Dreams 1", "AU", reaktor_a) == "Dark Dreams 1",
    "label is the user patch when unrelated to the plugin name")
  check(label("VST: Reaktor5", "VST", reaktor_a) == "",
    "empty label when the name is only the plugin itself")

  -- Hyphenated product words (e.g. "Pro-Q") must be recognized as the plugin's own
  -- identity, not leaked as a user preset label.
  local proq = up_plugin_analysis.analyze_plugin(nil, "VST3: FabFilter Pro-Q")
  check(label("VST3: FabFilter Pro-Q", "VST3", proq) == "",
    "hyphenated product name (Pro-Q) is the plugin, not a preset")
  check(label("VST3: FabFilter Pro-Q (My Patch)", "VST3", proq) == "My Patch",
    "preset after a hyphenated plugin name is still carried over")
end
