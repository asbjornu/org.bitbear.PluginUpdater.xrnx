# Plugin Updater (org.bitbear.PluginUpdater)

A Renoise tool that scans the current song for **outdated or broken plugin
devices** (track FX chains and instrument plugins), finds the best installed
candidate, and upgrades them while trying to preserve the previous preset/state.

## What it does

1. **Inventory (read-only).** Walks every track device (skipping the mixer
   device at index 1) and every instrument plugin. For each plugin it records
   its location, `device_path`/`name`, whether the API can still read its
   fields (this directly answers the "are broken devices visible?" question),
   and the parsed family (vendor + base name, version stripped).
2. **Candidate matching.** Builds a lookup from Renoise's own resolved
   installed-plugin lists (`track.available_device_infos` and
   `instrument.plugin_properties.available_plugin_infos`). Groups by family and
   ranks by **CLAP > VST3 > VST > AU** and by version.
3. **Swap + state transfer (per device, pcall-guarded).** For each outdated or
   broken device it: captures the old `active_preset_data`, inserts the new
   plugin at the same position, then (a) transplants the old state directly, or
   (b) falls back to matching the old preset **name** against the new plugin's
   presets, or (c) reverts so the song is left exactly as it was. Broken devices
   are replaced by the new plugin loaded at default state (strictly better than
   a missing plugin).
4. **Reporting + safety.** Shows a full per-device report and a status summary.
   **It never saves the song** — you inspect/undo, and Renoise's own undo stack
   covers the device swaps.

## Dry run (default)

The dialog opens with **"Dry run (report only)"** checked. Press **Scan** to get
the upgrade plan without touching anything. Uncheck it (or press **Run
Upgrades**) to perform the swaps.

## Installation

This folder *is* the tool bundle (named after the tool id,
`org.bitbear.PluginUpdater.xrnx`).

- **Easy:** drag the `org.bitbear.PluginUpdater.xrnx` folder into Renoise's
  Tools directory, then restart Renoise (or use *Renoise → Help → Show
  Preferences → Plugins* to locate the folder). Renoise auto-detects tool
  folders.
- **As a package:** zip the folder's contents into
  `org.bitbear.PluginUpdater.xrnx` (the `.xrnx` extension *is* a zip) and
  install it from Renoise's *Tools → Install* browser, or double-click it.

After install you'll find **Tools → Upgrade Outdated Plugins...** in the main
menu (and a global key binding you can assign in the Keyboard preferences).

## Limitations / things to verify in Renoise

- **Broken *instrument* plugins:** when a plugin fails to load,
  `plugin_device` is `nil`, so the original plugin id is not exposed by the API.
  Such instruments cannot be auto-matched (the report notes this). Healthy
  plugin instruments and all track plugins are matched normally.
- **Preset-name fallback** parses the old `active_preset_data` XML for a name;
  this is best-effort and plugin-dependent.
- **State transplant verification** accepts the transplant unless it raises an
  error or yields an empty state; some plugins re-encode preset data, so always
  sanity-check upgraded devices by ear.

## Testing checklist (needs a live Renoise session)

- On a scratch song, include one plugin known to reject cross-version state
  (e.g. FabFilter Saturn 1 → 2) and one that accepts it, and confirm the
  pcall-guarded fallback chain behaves (direct transplant, then named-preset,
  then revert).
- Test against a **copy** of a real project (never the original) to confirm
  broken track devices are visible and repairable, and that up-to-date devices
  are reported as `skipped-up-to-date`.
