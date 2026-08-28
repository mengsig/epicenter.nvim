--- Shared helpers for specs: fixture paths and the server lifecycle, for both
--- lanes - the fake server (`make test`) and the real binary (`make test-real`).
local M = {}

-- Self-locating: the smoke script loads this without the test init.
local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")

function M.fixture_root()
  return vim.fs.normalize(repo .. "/tests/fixtures/proj")
end

--- The multi-language tree the real lane indexes. Separate from the fake
--- lane's fixture: this one must survive a real parser, the other is shaped
--- around the fake's own scanner.
function M.real_root()
  return vim.fs.normalize(repo .. "/tests/fixtures/real")
end

--- The binary under test in the real lane. `navgraph` on `$PATH` by default.
function M.real_bin()
  local bin = os.getenv("NAVGRAPH_BIN")
  if bin == nil or bin == "" then
    return "navgraph"
  end
  return bin
end

--- Command line that runs the fake navgraph server over stdio.
function M.fake_cmd(root)
  return {
    vim.v.progpath,
    "--headless",
    "--clean",
    "-l",
    repo .. "/tests/fake_navgraph.lua",
    "lsp",
    "--root",
    root,
  }
end

--- Command line that runs the REAL navgraph server over stdio.
function M.real_cmd(root)
  return { M.real_bin(), "lsp", "--root", root }
end

--- Starts `cmd` for `root` and waits until the session is usable.
--- @param what string names the lane in an assertion message
local function start(root, cmd, what)
  local client = require("epicenter.client")
  local id, err = client.start({ root = root, cmd = cmd })
  assert(id, err)
  local ok = vim.wait(30000, function()
    local c = vim.lsp.get_client_by_id(id)
    return c ~= nil and c.initialized == true and client.session_for_root(root) ~= nil
  end, 10)
  assert(ok, what .. " navgraph server did not initialize")
  -- Hermeticity guard: if another navgraph on $PATH ever won the race to
  -- attach first, client.start would otherwise adopt it instead of ours.
  local adopted = vim.lsp.get_client_by_id(id)
  assert(
    adopted and vim.deep_equal(adopted.config.cmd, cmd),
    "start_" .. what .. "() adopted a different client - the suite is not hermetic"
  )
  return root
end

--- Starts the fake server for the fixture tree and waits until it is usable.
--- @return string root
function M.start_fake()
  local root = M.fixture_root()
  return start(root, M.fake_cmd(root), "fake")
end

--- Starts the REAL navgraph binary over the real fixture tree.
--- @return string root
function M.start_real()
  local root = M.real_root()
  return start(root, M.real_cmd(root), "real")
end

--- Attaches a buffer to the server already running for `root`, so its text
--- reaches the server as an overlay. Explicit, because both lanes run with
--- `lsp.auto_start = false`: an automatic attach would resolve a binary of its
--- own for any buffer outside the fixture, and adopt whatever is on $PATH.
--- @param root string
--- @param bufnr integer
function M.attach(root, bufnr)
  local client = require("epicenter.client")
  assert(client.session_for_root(root), "no server running for " .. root)
  local id, err = client.start({ root = root, bufnr = bufnr })
  assert(id, err)
  local ok = vim.wait(10000, function()
    return #vim.lsp.get_clients({ bufnr = bufnr, name = "navgraph" }) > 0
  end, 10)
  assert(ok, "buffer did not attach to navgraph")
end

--- Skips the running test when the server for `root` does not announce
--- `method` - the honest answer for a v1.1 spec against a server that does
--- not speak v1.1 yet, rather than a failure or a silent pass.
--- @param what string names the surface under test, for the skip line
function M.require_method(root, method, what)
  if require("epicenter.client").supports(method, { root = root }) then
    return
  end
  require("harness").skip(
    ("%s: this navgraph does not announce %s (protocol 1.1)"):format(what, method)
  )
end

--- Skips the running test when the server for `root` reports a `serverInfo`
--- build older than `min`. For cases pinned to a RESOLVER ACCURACY fix rather
--- than a new method - `M.require_method` has nothing to gate on since the
--- method (e.g. `path`) already exists pre-1.1, only its answer changed.
--- @param root string
--- @param min string minimum build, e.g. "1.1.0"
--- @param what string names the case under test, for the skip line
function M.require_navgraph_version(root, min, what)
  local client_id = require("epicenter.client").info(root).client_id
  local client = client_id and vim.lsp.get_client_by_id(client_id)
  local version = client and client.server_info and client.server_info.version
  local function parts(v)
    local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)")
    return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
  end
  if version then
    local va, vb, vc = parts(version)
    local ma, mb, mc = parts(min)
    if va > ma or (va == ma and (vb > mb or (vb == mb and vc >= mc))) then
      return
    end
  end
  require("harness").skip(
    ("%s: this navgraph (%s) is older than %s"):format(what, tostring(version), min)
  )
end

function M.stop_fake(root)
  require("epicenter.client").stop(root)
end

--- Binaries a spec built for itself, under its own temp directory. The
--- hermeticity guard accepts these: a shim the suite wrote is not "whatever
--- happens to be on $PATH", which is the only thing that guard exists to
--- catch. Global, because the guard runs in another spec file.
_G.EPICENTER_TEST_OWNED_BINARIES = _G.EPICENTER_TEST_OWNED_BINARIES or {}

--- @param path string
--- @return string path
function M.own_binary(path)
  _G.EPICENTER_TEST_OWNED_BINARIES[path] = true
  return path
end

--- Announces a crash a spec is about to cause on purpose. Neovim prints its
--- own "Client navgraph quit with exit code N" for it, in the exact shape a
--- real regression has, and a release is cut on that output - so say which
--- ones were asked for (F5).
--- @param why string
function M.expect_exit_notice(why)
  io.stderr:write(("note: %s - the LSP exit notice(s) below are expected\n"):format(why))
end

--- Issues a request against the running server and blocks for its response.
--- @return table|nil err, any result
function M.request(root, method, params, timeout_ms)
  local client = require("epicenter.client")
  local done, captured = false, nil
  client.request(method, params or vim.empty_dict(), function(err, result)
    captured = { err = err, result = result }
    done = true
  end, { root = root })
  local ok = vim.wait(timeout_ms or 10000, function()
    return done
  end, 5)
  assert(ok, "timed out waiting for " .. method)
  return captured.err, captured.result
end

return M
