---
name: run-tests
description: Run the Renoise Plup Lua test suite and keep it green
---
Run `lua tests/run.lua` (Homebrew `lua` at `/usr/local/bin`; do `export PATH=/usr/local/bin:$PATH` first).

- All tests must print `ALL TESTS PASSED`.
- `luacheck lib/*.lua tests/run.lua` must report 0 warnings (LibDeflate is vendored + excluded).
- The harness sets a **strict metatable on `_G`**: any *undeclared global read* errors. Capture libs via `require`; never reference bare globals like `utf8`.
