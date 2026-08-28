--- F7: the `vim.lsp.enable("navgraph")` route, driven with NO
--- `epicenter.client.start` call anywhere - only what the README tells a
--- 0.11+ user to do (`lsp.auto_start = false` + `vim.lsp.enable("navgraph")`,
--- `lsp/navgraph.lua`:5-8). Before the fix this left every panel answering
--- "navgraph is not running for this project".
---
--- `vim.lsp.enable` does not exist on 0.10; this whole file is a no-op there
--- (0.10 has no such route to prove).
local compat = require("epicenter.compat")
if not compat.HAS_011 then
  return
end

local epicenter = require("epicenter")
local support = require("support")
local client = require("epicenter.client")

describe("real navgraph: the vim.lsp.enable route (F7)", function()
  local buf, opened

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({
      ui = { icons = "ascii" },
      animate = false,
      lsp = { auto_start = false },
      navgraph = { path = support.real_bin() },
    })
    require("epicenter.ui.theme").apply()
    vim.lsp.enable("navgraph")
    vim.cmd.edit(
      vim.fn.fnameescape(vim.fs.joinpath(support.real_root(), "py_fastapi/app/routes/users.py"))
    )
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    vim.lsp.enable("navgraph", false)
    if opened then
      pcall(function()
        opened:close()
      end)
      opened = nil
    end
    for _, c in ipairs(vim.lsp.get_clients({ name = "navgraph" })) do
      compat.lsp_stop(c)
    end
  end)

  it("adopts the client vim.lsp.enable started and answers a real panel", function()
    local ok = vim.wait(20000, function()
      return client.session_for_buf(buf) ~= nil
    end, 20)
    assert(ok, "epicenter never adopted the vim.lsp.enable client")

    opened = epicenter.run("status", {}, buf)
    local text = wait(function()
      local body = table.concat(vim.api.nvim_buf_get_lines(opened.buf, 0, -1, false), "\n")
      return body:match("files") and body or nil
    end, 20000, "the status panel to answer with real index data")
    expect.matches(text, "%d+ files", "real navgraph/status data reached the panel")
  end)
end)
