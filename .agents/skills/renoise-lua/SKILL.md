---
name: renoise-lua-constraints
description: Constraints when editing Lua code for this Renoise tool
---
- **Pure-Lua only.** No external packages, no C modules (xml2lua/LuaExpat won't load in the Renoise sandbox). Vendor pure-Lua if a dependency is needed.
- Lua patterns here have **no `|` alternation**; use character classes (e.g. `[%s>]`) instead.
- The test harness errors on reading undeclared globals. Access `utf8` via `pcall(require,"utf8")`, never bare.
- Keep `luacheck` clean; LibDeflate is vendored and excluded from lint.
- Commit messages: terse, no "the user" references.
