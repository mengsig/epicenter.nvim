--- Shared helpers for specs: fixture paths and the fake-server lifecycle.
local M = {}

-- Self-locating: the smoke script loads this without the test init.
local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")

function M.fixture_root()
  return vim.fs.normalize(repo .. "/tests/fixtures/proj")
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

--- Starts the fake server for the fixture tree and waits until it is usable.
--- @return string root
function M.start_fake()
  local client = require("epicenter.client")
  local root = M.fixture_root()
  local cmd = M.fake_cmd(root)
  local id, err = client.start({ root = root, cmd = cmd })
  assert(id, err)
  local ok = vim.wait(15000, function()
    local c = vim.lsp.get_client_by_id(id)
    return c ~= nil and c.initialized == true and client.session_for_root(root) ~= nil
  end, 10)
  assert(ok, "fake navgraph server did not initialize")
  -- Hermeticity guard: if a real navgraph on $PATH ever won the race to
  -- attach first, client.start would otherwise adopt it instead of the fake.
  local adopted = vim.lsp.get_client_by_id(id)
  assert(
    adopted and vim.deep_equal(adopted.config.cmd, cmd),
    "start_fake() adopted a non-fake client - the suite is not hermetic"
  )
  return root
end

function M.stop_fake(root)
  require("epicenter.client").stop(root)
end

--- Issues a request against the fake server and blocks for its response.
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
