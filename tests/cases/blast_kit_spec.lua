--- `K` under `lsp.fallback_only` (#F11): whether it opens the epicenter card
--- or falls back to `vim.lsp.buf.hover()` is decided at press time, by
--- whether any OTHER attached client already answers hover for the buffer.
local support = require("support")

describe("K under lsp.fallback_only decides the hover provider at press time", function()
  local root, buf

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()

    local path = vim.fs.joinpath(root, "app/server.lua")
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 then
      vim.api.nvim_buf_delete(existing, { force = true })
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    -- Column 12 is inside `handle_request` on `function M.handle_request(...)`.
    -- The column matters: navgraph resolves the identifier under it and
    -- nothing off one, so a hover at column 0 ("function") has no symbol.
    vim.api.nvim_win_set_cursor(0, { 9, 12 })
    wait(function()
      return #vim.lsp.get_clients({ bufnr = buf, name = "navgraph" }) > 0
    end, 10000, "navgraph to attach to the buffer")
  end)

  after_each(function()
    require("epicenter.events").clear()
  end)

  local function press_K()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("K", true, false, true), "x", false)
  end

  it("opens the epicenter card when navgraph is the only hover provider", function()
    local hover = require("epicenter.features.blast.hover")
    press_K()
    wait(function()
      return hover.current() ~= nil
    end, 5000, "the hover card to open")
    hover.current():close()
  end)

  it("falls back to vim.lsp.buf.hover() once another client already answers hover", function()
    -- A synthetic competitor, injected at the `vim.lsp.get_clients` seam the
    -- fallback guard itself queries - no second real LSP client needed.
    local fake_other
    fake_other = {
      id = -999,
      name = "fake-other-lsp",
      -- 0.11 calls this as a method, 0.10 as a plain function: answer both,
      -- the way a real client object does.
      supports_method = function(a, b)
        return (a == fake_other and b or a) == "textDocument/hover"
      end,
    }
    local original_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function(opts)
      local list = original_get_clients(opts)
      if not opts or not opts.name then
        table.insert(list, fake_other)
      end
      return list
    end

    local hover = require("epicenter.features.blast.hover")
    local calls = 0
    local original_hover = vim.lsp.buf.hover
    vim.lsp.buf.hover = function(...)
      calls = calls + 1
    end

    press_K()
    vim.wait(200)

    vim.lsp.buf.hover = original_hover
    vim.lsp.get_clients = original_get_clients
    expect.eq(calls, 1, "K must fall back to the other client's hover")
    expect.eq(hover.current(), nil, "the epicenter card must not open")
  end)
end)
