-- Docs in sync: nvim --headless --clean -u tests/minimal_init.lua -l tests/docs_check.lua [--write]
--
-- The keymap table, the command table and the config reference are generated
-- from `epicenter.registry` and `epicenter.config` (see `epicenter.docs`).
-- This compares them against the marked regions in README.md and
-- doc/epicenter.txt, and checks every committed screenshot is linked (F9).
-- `--write` rewrites the generated regions instead of failing, which is what
-- `make docs-fix` runs. The checks themselves live in docs_check_lib.lua, so
-- a spec can drive them without going through this script's os.exit.
local lib = require("docs_check_lib")

local repo = _G.EPICENTER_ROOT or vim.fn.getcwd()
local write = false
for _, arg in ipairs(_G.arg or {}) do
  write = write or arg == "--write"
end

local ok, problems = lib.run(repo, write)

if not ok then
  io.stderr:write(table.concat(problems, "\n\n") .. "\n\n")
  io.stderr:write("docs are out of date - run `make docs-fix`\n")
  os.exit(1)
end

io.write("docs in sync with the registry\n")
