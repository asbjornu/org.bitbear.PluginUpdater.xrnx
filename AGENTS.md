# AGENTS.md — org.bitbear.PluginUpdater

Renoise Lua tool that inventories outdated/broken plugins and upgrades
them.

## Environment

- Lua 5.4/5.5 (Renoise embedded). **Pure-Lua only — no external or C
  modules.** Vendor pure-Lua if a dependency is needed (xml2lua/LuaExpat
  won't load in the sandbox).
- Run the suite with `lua tests/run.lua` (Homebrew `lua` at
  `/usr/local/bin`; `export PATH=/usr/local/bin:$PATH`). CI uses `lua5.1`.
- The test harness installs a **strict metatable on `_G`**: reading an
  *undeclared global* errors. Always `require` libs; never read bare
  globals like `utf8` — capture via `pcall(require,"utf8")`.
- Lua patterns here have **no `|` alternation**; use character classes
  (`[%s>]`).

## Workflow

- Work in the `renoise/3.5.4` Git worktree, which points to the path
  within Renoise this tool is installed into.
- Never change existing branches to point to a worktree. If you need a
  worktree, create a new branch.
- `main` should always point to the canonical repository location, not the
  installation path of the tool or any other worktree directory.
- Commit before considering the task done.
- Group commits logically by feature or fix.
- If the a fix applies to code added previously in the same branch,
  squash the fix into the original commit.
- Add tests for all new features to ensure correctness and high coverage.
- Commit messages: terse, no "the user" references. Keep the header at
  maximum 50 characters, repeat it in the body if truncation is necessary.
  Wrap the body at 72 characters.
- Keep `luacheck` clean on `lib/*.lua` and `tests/run.lua` (LibDeflate is
  vendored + excluded).

## Layout

- `main.lua` entry → loads `up_ui`; `lib/up_*.lua` are modules;
  `tests/run.lua` is the headless suite (mocked Renoise).
- Flow: `up_inventory` scans the song → `up_matching` finds candidates →
  `up_swap` swaps + transfers state → `up_core` orchestrates → `up_ui`
  dialog.
- `up_songxml` + `up_xml` parse `Song.xml` (the `.xrns` is a zip, read by
  `up_zip`). `up_preset` decodes preset/ensemble names from opaque chunk
  data (with a base64 "looks-like-binary" guard). `up_util` holds
  name/token analysis.

## XML parsing

- `lib/up_xml.lua` is a thin **pure-Lua tree builder over the vendored SLAXML
  engine** (`lib/slaxml.lua`, MIT, committed directly into `lib/` because the
  LuaRocks rockspec is broken). `up_songxml.parse_instruments` uses
  `find_all(root,"Instrument")` so `<InstrumentGroup>` nesting and
  attribute-bearing tags are handled structurally.
