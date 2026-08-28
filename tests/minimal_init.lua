-- Minimal runtimepath for headless tests: this repo only, no user config.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.resolve(this), ":p:h:h")

vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. root .. "/tests/?/init.lua;" .. package.path

vim.g.epicenter_reduce_motion = true
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.more = false
vim.opt.termguicolors = true

_G.EPICENTER_ROOT = root

-- F5: pins the fallback resolve() path to a binary that cannot exist, so a
-- spec that forgets `lsp.auto_start = false` (and so lets setup()'s attach
-- sweep reach a buffer with no server already running for its root) still
-- cannot spawn a real $PATH or managed-install navgraph. `install.resolve()`
-- only honors this when the caller uses the real prober, so it never affects
-- `tests/cases/install_spec.lua`'s own coverage of the fallback contract
-- (which always injects a fake probe), and the real lane never resolves
-- through here at all (every real-lane spec passes an explicit `cmd`).
vim.g.epicenter_test_navgraph_path_pin = root .. "/tests/fixtures/navgraph-must-not-resolve"

-- F5 hermeticity guard: records every cmd an LSP client actually spawned,
-- across the whole run (module reload between spec files never touches _G).
-- `vim.lsp.rpc.start` is the one spawn point both `vim.lsp.start` (0.11+)
-- and `vim.lsp.start_client` (0.10) converge on inside `client.lua`, so this
-- catches a spawn regardless of which compat path a spec exercises.
_G.EPICENTER_TEST_NAVGRAPH_SPAWNS = {}
local rpc = require("vim.lsp.rpc")
local original_rpc_start = rpc.start
rpc.start = function(cmd, dispatchers, extra_spawn_params)
  if type(cmd) == "table" then
    table.insert(_G.EPICENTER_TEST_NAVGRAPH_SPAWNS, cmd)
  end
  return original_rpc_start(cmd, dispatchers, extra_spawn_params)
end
