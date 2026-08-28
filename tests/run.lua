-- Entry point: nvim --headless --clean -u tests/minimal_init.lua -l tests/run.lua
local root = _G.EPICENTER_ROOT or vim.fn.getcwd()
local harness = require("harness")
harness.install_globals()

local files = vim.fn.glob(root .. "/tests/cases/*_spec.lua", false, true)
table.sort(files)

if #files == 0 then
  io.stderr:write("no spec files found under tests/cases\n")
  os.exit(1)
end

local started = vim.uv.hrtime()
local passed, failed, results = harness.run(files)
local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

os.exit(harness.report(passed, failed, results, #files, elapsed_ms))
