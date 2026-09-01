---
name: repo-layout
description: Module map for org.bitbear.PluginUpdater
---
- `main.lua` loads `up_ui`; `lib/up_*.lua` are the logic modules; `tests/run.lua` is the full headless suite (mocked Renoise).
- `up_inventory` scans the song → `up_matching` finds replacement candidates → `up_swap` performs the swap + state transfer → `up_core` orchestrates → `up_ui` is the dialog.
- `up_songxml` uses `up_xml` (hand-written pure-Lua tree parser) to read `Song.xml` inside the `.xrns` (zip, via `up_zip`).
- `up_preset` decodes preset/ensemble names from opaque chunk data (with a base64 "looks-like-binary" guard before decoding).
- `up_util` holds plugin-name / token analysis.
- PR is `fixes` → `main`; keep `renoise/3.5.4` and `fixes` synced. `fixes` is checked out in another worktree, so use `git update-ref refs/heads/fixes <sha>` then `git push --force origin fixes`.
