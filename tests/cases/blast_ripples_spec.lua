local ripples = require("epicenter.features.blast.ripples")
local support = require("support")

local function node(file, line, depth)
  return {
    depth = depth,
    symbol = {
      uri = vim.uri_from_fname(vim.fs.joinpath(support.fixture_root(), file)),
      file = file,
      line = line,
      qualified = ("s%d"):format(line),
    },
  }
end

local function marks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, ripples.namespace, 0, -1, { details = true })
end

describe("inline ripples", function()
  local buf

  before_each(function()
    require("epicenter.config").reset()
    -- No server here: without auto_start the plugin's BufReadPost autocmd
    -- would try to launch a real navgraph for the fixture tree.
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      animate = false,
      lsp = { auto_start = false },
    })
    require("epicenter.ui.theme").apply()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(support.fixture_root(), "app/server.lua")))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    ripples.clear()
  end)

  it("grades the mark by ring and stops grading past the last grade", function()
    ripples.apply({ node("app/server.lua", 5, 1), node("app/server.lua", 9, 2) })
    expect.eq(ripples.ring_at(buf, 5), 1)
    expect.eq(ripples.ring_at(buf, 9), 2)

    ripples.apply({ node("app/server.lua", 14, 7) })
    expect.eq(ripples.ring_at(buf, 14), #ripples.GROUPS, "deep rings share the faintest grade")
  end)

  it("marks the line and the sign column together", function()
    ripples.apply({ node("app/server.lua", 5, 1) })
    local details = marks(buf)[1][4]
    expect.eq(details.line_hl_group, "EpicenterRipple1")
    expect.eq(details.sign_hl_group, "EpicenterRipple1")
    expect.truthy(details.sign_text ~= nil and #details.sign_text > 0)
  end)

  it("keeps the shallowest ring when two nodes share a line", function()
    ripples.apply({ node("app/server.lua", 5, 3), node("app/server.lua", 5, 1) })
    expect.eq(ripples.ring_at(buf, 5), 1)
  end)

  it("ignores a node whose line is past the end of the buffer", function()
    ripples.apply({ node("app/server.lua", 9999, 1) })
    expect.eq(#marks(buf), 0)
  end)

  it("skips departing nodes so a transition never marks a stale line", function()
    ripples.apply({
      node("app/server.lua", 5, 1),
      vim.tbl_extend("force", node("app/server.lua", 9, 1), { state = "removed" }),
    })
    expect.eq(ripples.ring_at(buf, 5), 1)
    expect.eq(ripples.ring_at(buf, 9), nil)
  end)

  it("marks a file opened after the panel already asked for ripples", function()
    ripples.apply({ node("app/config.lua", 3, 1) })
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(support.fixture_root(), "app/config.lua")))
    local opened = vim.api.nvim_get_current_buf()
    expect.eq(ripples.ring_at(opened, 3), 1)
  end)

  it("places nothing when ripples are turned off", function()
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      ripples = false,
      lsp = { auto_start = false },
    })
    ripples.apply({ node("app/server.lua", 5, 1) })
    expect.eq(#marks(buf), 0)
  end)

  it("drops every mark on clear", function()
    ripples.apply({ node("app/server.lua", 5, 1) })
    expect.truthy(#marks(buf) > 0)
    ripples.clear()
    expect.eq(#marks(buf), 0)
  end)
end)
