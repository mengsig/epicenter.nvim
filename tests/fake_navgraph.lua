-- Fake navgraph LSP server. Speaks the editor protocol (contract v1) over
-- stdio against a fixture tree, so the integration tests need no zig build.
--
--   nvim --headless --clean -l tests/fake_navgraph.lua serve [--root <dir>]
local this = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(vim.fn.resolve(this), ":p:h:h")
package.path = repo .. "/tests/?.lua;" .. repo .. "/tests/?/init.lua;" .. package.path

local args = _G.arg or {}
local root = nil
for i, value in ipairs(args) do
  if value == "--root" then
    root = args[i + 1]
  end
end

require("fakelib.server").serve({ root = root and vim.fs.normalize(root) or nil })
