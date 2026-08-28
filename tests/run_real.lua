-- Real-server lane: nvim --headless --clean -u tests/minimal_init.lua -l tests/run_real.lua
--
-- Same harness as `tests/run.lua`, but the specs under `tests/real/` talk to
-- the REAL `navgraph lsp` binary (`$NAVGRAPH_BIN`, else `navgraph` on `$PATH`)
-- over `tests/fixtures/real`. The fake lane proves the plugin against the
-- protocol as this repo reads it; this lane proves it against the protocol as
-- NavGraph actually speaks it.
local root = _G.EPICENTER_ROOT or vim.fn.getcwd()
local harness = require("harness")
local support = require("support")
harness.install_globals()

--- One `initialize` exchange over a pipe, before any spec runs, so a missing
--- or too-old binary is one clear line instead of a wall of timeouts.
--- @return string|nil error
local function preflight(bin, fixture)
  if vim.fn.executable(bin) == 0 then
    return ("%q is not executable (set NAVGRAPH_BIN to the binary to test)"):format(bin)
  end

  local request = vim.json.encode({
    jsonrpc = "2.0",
    id = 1,
    method = "initialize",
    params = { rootUri = vim.uri_from_fname(fixture), capabilities = vim.empty_dict() },
  })
  -- stdin closes after this frame; per the contract the server answers, then
  -- exits 0 on EOF - so this never leaves a process behind.
  local done = vim
    .system({ bin, "lsp", "--root", fixture }, {
      stdin = ("Content-Length: %d\r\n\r\n%s"):format(#request, request),
      text = true,
    })
    :wait(30000)

  local body = (done.stdout or ""):match("Content%-Length:%s*%d+\r?\n\r?\n(.*)$")
  if not body then
    return ("`%s lsp` did not speak the editor protocol (exit %s): %s"):format(
      bin,
      tostring(done.code),
      vim.trim((done.stdout or "") .. (done.stderr or "")):sub(1, 200)
    )
  end

  local ok, decoded = pcall(vim.json.decode, body)
  local version = ok
    and vim.tbl_get(
      decoded or {},
      "result",
      "capabilities",
      "experimental",
      "navgraph",
      "protocolVersion"
    )
  if version ~= 1 then
    return ("`%s lsp` speaks protocol %s, this lane needs 1"):format(bin, tostring(version))
  end
  return nil
end

local bin, fixture = support.real_bin(), support.real_root()
local err = preflight(bin, fixture)
if err then
  io.stderr:write("test-real: " .. err .. "\n")
  os.exit(1)
end

local files = vim.fn.glob(root .. "/tests/real/*_spec.lua", false, true)
table.sort(files)
if #files == 0 then
  io.stderr:write("no spec files found under tests/real\n")
  os.exit(1)
end

io.write(("navgraph: %s over %s\n"):format(bin, vim.fn.fnamemodify(fixture, ":~")))
local started = vim.uv.hrtime()
local passed, failed, results = harness.run(files)
local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

os.exit(harness.report(passed, failed, results, #files, elapsed_ms))
