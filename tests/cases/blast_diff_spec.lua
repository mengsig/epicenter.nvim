local epicenter = require("epicenter")
local support = require("support")

local function lines_of(panel)
  return vim.api.nvim_buf_get_lines(panel.surface.buf, 0, -1, false)
end

local function names(panel)
  return vim.tbl_map(function(node)
    return node.symbol.qualified
  end, panel.nodes)
end

describe("diff blast against the fake navgraph server", function()
  local root, buf, original, panel

  local function reopen(relative)
    local path = vim.fs.joinpath(root, relative)
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 then
      vim.api.nvim_buf_delete(existing, { force = true })
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
  end

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    buf = reopen("app/config.lua")
    original = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end)

  after_each(function()
    if panel then
      panel:close()
      panel = nil
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
      vim.bo[buf].modified = false
    end
    require("epicenter.events").clear()
  end)

  --- The changed set is the files navgraph holds overlays for, and the overlay
  --- for a freshly opened buffer arrives on its own schedule - so wait for the
  --- panel to see it rather than assuming the first answer already has it.
  local function opened(args)
    local it_panel = epicenter.run("diff", args or {}, buf)
    wait(function()
      return (it_panel.summary.changed or 0) > 0
    end, 10000, "changed symbols")
    return it_panel
  end

  it("roots the panel on the changed symbols and names the ref", function()
    panel = opened()
    expect.matches(lines_of(panel)[1], "changes vs HEAD")
    expect.matches(lines_of(panel)[2], "^  2 changed · ")
    expect.eq(panel.summary.changed, 2, "both definitions in the open file changed")
    expect.eq(names(panel), { "M.handle_request", "M.start" })
    expect.matches(table.concat(lines_of(panel), "\n"), "ring 2")
  end)

  it("takes the ref from the command line", function()
    panel = opened({ "origin/main" })
    expect.matches(lines_of(panel)[1], "changes vs origin/main")
  end)

  it("counts an unsaved edit without waiting for a save", function()
    panel = opened()
    expect.eq(panel.summary.changed, 2)

    vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
      "",
      "function M.default_route()",
      '  return M.route("GET", "/")',
      "end",
    })

    wait(function()
      return panel.summary.changed == 3
    end, 10000, "the new definition reaches the panel")
    expect.matches(lines_of(panel)[2], "^  3 changed · ")
  end)

  it("reuses the open panel rather than stacking a second one", function()
    panel = opened()
    local again = epicenter.run("diff", {}, buf)
    expect.eq(again, panel)
    expect.eq(require("epicenter.features.blast.panel").current(), panel)
  end)
end)
