--- The panels that read the graph rather than walk it: the call path, the
--- outline sidebar, hot spots, unused symbols, the graph export, and the
--- status dashboard.
local epicenter = require("epicenter")
local support = require("support")

describe("real navgraph: navigation panels", function()
  local root, buf, opened

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_real()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "py_fastapi/app/routes/users.py")))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if opened then
      pcall(function()
        opened:close()
      end)
      opened = nil
    end
  end)

  it("draws the real call chain between two symbols", function()
    local handle = epicenter.run("path", { "get_user", "UserService._query" }, buf)
    local win = wait(function()
      return handle.win
    end, 20000, "the path window")
    opened = win
    local text = table.concat(vim.api.nvim_buf_get_lines(win.buf, 0, -1, false), "\n")
    expect.matches(text, "get_user")
    expect.matches(text, "fetch", "the chain runs through UserService.fetch")
    expect.matches(text, "_query")
  end)

  it("says so, rather than inventing a chain, when none exists", function()
    local handle = epicenter.run("path", { "get_user", "Vec.add" }, buf)
    local win = wait(function()
      return handle.win
    end, 20000, "the path window")
    opened = win
    local text = table.concat(vim.api.nvim_buf_get_lines(win.buf, 0, -1, false), "\n")
    expect.matches(text, "no call path")
  end)

  --- F1: `get` is ambiguous between OrderService.get and ItemService.get in
  --- this fixture - the exact case the review found answered as a confident
  --- "no call path" even though OrderService.place -> OrderService.get is a
  --- real edge.
  it("F1: an ambiguous endpoint offers a candidate picker against the real server", function()
    local handle = epicenter.run("path", { "fetch", "get" }, buf)
    local win = wait(function()
      return handle.win
    end, 20000, "the ambiguity candidate picker")
    opened = win
    wait(function()
      return win.list:count() > 0
    end, 20000, "candidates listed")
    local qualified = vim.tbl_map(function(item)
      return item.symbol.qualified
    end, win.list:items())
    table.sort(qualified)
    expect.eq(qualified, { "ItemService.get", "OrderService.get" })
  end)

  it("outlines the current buffer from the real index", function()
    local panel = epicenter.run("outline", {}, buf)
    opened = panel
    local listed = wait(function()
      if panel.list:count() == 0 then
        return nil
      end
      return vim.tbl_map(function(row)
        return row.symbol.name
      end, panel.list:items())
    end, 20000, "outline rows")
    for _, name in ipairs({ "list_users", "get_user", "create_user" }) do
      expect.truthy(vim.tbl_contains(listed, name), name .. " missing: " .. vim.inspect(listed))
    end
  end)

  it("ranks hot spots by real fan-in", function()
    local panel = epicenter.run("hot", { "py_fastapi" }, buf)
    opened = panel
    local items = wait(function()
      return panel.list:count() > 0 and panel.list:items() or nil
    end, 20000, "hot rows")
    expect.truthy(items[1].fanIn > 0, "the busiest symbol has callers")
    -- The contract ranks by connectivity, and `fanInExact` (heuristic edges
    -- excluded) is the key the real server actually orders on - the panel's
    -- bar scale must therefore not assume items[1] is the widest.
    for index = 2, #items do
      expect.truthy(
        items[index - 1].fanInExact >= items[index].fanInExact,
        "hot spots arrive ranked by exact fan-in"
      )
    end
    expect.eq(
      require("epicenter.features.hot").bar_scale(items),
      math.max(unpack(vim.tbl_map(function(item)
        return item.fanIn
      end, items))),
      "the bars scale to the real maximum, not to items[1]"
    )
  end)

  it("lists real zero-caller definitions as removal candidates", function()
    local panel = epicenter.run("unused", {}, buf)
    opened = panel
    local names = wait(function()
      if panel.list:count() == 0 then
        return nil
      end
      return vim.tbl_map(function(item)
        return item.symbol.qualified
      end, panel.list:items())
    end, 20000, "unused rows")
    expect.truthy(
      vim.tbl_contains(names, "Vec.lensq"),
      "the fixture's documented dead helper is missing: " .. vim.inspect(names)
    )
  end)

  it("writes the graph export where the server says it did", function()
    local written = nil
    local original = vim.ui.open
    vim.ui.open = function(path)
      written = path
      return nil, nil
    end
    local ok, err = pcall(function()
      epicenter.run("graph", {}, buf)
      wait(function()
        return written
      end, 30000, "the graph export path")
    end)
    vim.ui.open = original
    assert(ok, tostring(err))

    expect.matches(written, "%.navgraph/graph%-.*%.html$")
    expect.truthy(vim.uv.fs_stat(written) ~= nil, "the server wrote " .. tostring(written))
  end)

  it("reports the real index on the status dashboard", function()
    local win = epicenter.run("status", {}, buf)
    opened = win
    local lines = wait(function()
      local text = vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)
      for _, line in ipairs(text) do
        if line:match("files") then
          return text
        end
      end
      return nil
    end, 20000, "dashboard content")

    local joined = table.concat(lines, "\n")
    expect.matches(joined, "%d+ files")
    expect.matches(joined, "%d+ symbols")
    expect.matches(joined, "running")
    expect.matches(joined, "protocol 1")
  end)
end)
