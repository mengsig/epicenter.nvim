--- The callers/callees tree fetching real levels one at a time.
local epicenter = require("epicenter")
local support = require("support")

local function rows(panel)
  return vim.tbl_map(function(row)
    return row.node.qualified or row.node.name
  end, panel.list:items())
end

describe("real navgraph: the explorer", function()
  local root, buf, panel

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_real()
    vim.cmd.edit(
      vim.fn.fnameescape(vim.fs.joinpath(root, "py_fastapi/app/services/order_service.py"))
    )
    buf = vim.api.nvim_get_current_buf()
    -- OrderService.place: one level of real callees, several of them.
    vim.api.nvim_win_set_cursor(vim.fn.bufwinid(buf), { 17, 14 })
  end)

  after_each(function()
    if panel then
      panel:close()
      panel = nil
    end
  end)

  local function loaded(target)
    return wait(function()
      return target.list:count() > 0 and rows(target) or nil
    end, 20000, "explorer rows")
  end

  it("opens the callees of the symbol under the cursor", function()
    panel = epicenter.run("callees", {}, buf)
    local listed = loaded(panel)
    expect.eq(listed[1], "OrderService.place", vim.inspect(listed))
    expect.truthy(
      vim.tbl_contains(listed, "OrderService._append_line"),
      "a real callee is missing: " .. vim.inspect(listed)
    )
  end)

  it("fetches a deeper level only when the row is expanded", function()
    panel = epicenter.run("callees", {}, buf)
    loaded(panel)
    local before = panel.list:count()

    local target
    for index, name in ipairs(rows(panel)) do
      if name == "OrderService._append_line" then
        target = index
      end
    end
    expect.truthy(target ~= nil, "the row to expand: " .. vim.inspect(rows(panel)))

    panel.list:select(target)
    vim.api.nvim_win_set_cursor(panel.win.win, { target, 0 })
    vim.api.nvim_buf_call(panel.win.buf, function()
      vim.cmd("normal l")
    end)

    -- `l` opens the row against a placeholder child first; the real level
    -- replaces it when the request lands, so wait for the callee itself.
    -- `_append_line` calls `self.items.get(item_id)`, i.e. `ItemService.get`
    -- (self.items is an ItemService) - not OrderService's own `get`.
    wait(function()
      return vim.tbl_contains(rows(panel), "ItemService.get")
    end, 20000, "the fetched level under the expanded row")
    expect.truthy(panel.list:count() > before, "the level added rows")
  end)

  it("opens the callers side from the same cursor", function()
    panel = epicenter.run("callers", {}, buf)
    local listed = loaded(panel)
    expect.eq(listed[1], "OrderService.place", vim.inspect(listed))
    expect.truthy(#listed > 1, "place has real callers: " .. vim.inspect(listed))
  end)
end)
