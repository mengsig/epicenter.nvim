--- Shared helpers for specs: fixture paths and the fake-server lifecycle.
local M = {}

local repo = _G.EPICENTER_ROOT

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
    "serve",
    "--root",
    root,
  }
end

--- Starts the fake server for the fixture tree and waits until it is usable.
--- @return string root
function M.start_fake()
  local client = require("epicenter.client")
  local root = M.fixture_root()
  local id, err = client.start({ root = root, cmd = M.fake_cmd(root) })
  assert(id, err)
  local ok = vim.wait(15000, function()
    local c = vim.lsp.get_client_by_id(id)
    return c ~= nil and c.initialized == true and client.session_for_root(root) ~= nil
  end, 10)
  assert(ok, "fake navgraph server did not initialize")
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
