-- Entry point: nvim --headless --clean -u tests/minimal_init.lua -l tests/run.lua [pattern]
local root = _G.EPICENTER_ROOT or vim.fn.getcwd()
local harness = require("harness")
harness.install_globals()

local pattern = ...

local files = vim.fn.glob(root .. "/tests/cases/*_spec.lua", false, true)
table.sort(files)
if pattern then
  files = vim.tbl_filter(function(f)
    return f:match(pattern) ~= nil
  end, files)
end

if #files == 0 then
  io.stderr:write("no spec files matched\n")
  os.exit(1)
end

local started = vim.uv.hrtime()
local passed, failed, results = harness.run(files)
local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

local out = {}
local function w(fmt, ...)
  table.insert(out, select("#", ...) > 0 and fmt:format(...) or fmt)
end

for _, case in ipairs(results) do
  if not case.ok then
    w("FAIL  %s", case.name)
    for _, line in ipairs(vim.split(tostring(case.err), "\n", { plain = true })) do
      w("      %s", line)
    end
    w("")
  end
end

w("%d passed, %d failed  (%d files, %.0fms)", passed, failed, #files, elapsed_ms)

io.write(table.concat(out, "\n"), "\n")
io.stdout:flush()
os.exit(failed == 0 and 0 or 1)
