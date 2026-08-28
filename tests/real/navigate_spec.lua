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

  --- merge-gate F1: `qualified` is not unique. `get_item` is two definitions
  --- of that exact qualified name in this fixture, `router` is four, and
  --- `main` is two inside ONE file. Re-asking with the picked candidate's
  --- bare `qualified` sends the identical request, gets the identical
  --- ambiguity back, and reopens the identical picker, forever.
  local function pick(handle, match)
    local win = wait(function()
      return handle.win
    end, 20000, "the ambiguity candidate picker")
    wait(function()
      return win.list:count() > 0
    end, 20000, "candidates listed")
    local index
    for i, item in ipairs(win.list:items()) do
      if match(item.symbol) then
        index = i
      end
    end
    assert(index, "no candidate matched: " .. vim.inspect(win.list:items()))
    win.list:select(index)
    win:accept("edit")
    return win
  end

  --- The `epicenter-path` window the pick produced - an answer, not another
  --- picker. Consumes it, so a later case starts clean.
  local function answer_text()
    local found
    wait(function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local candidate = vim.api.nvim_win_get_buf(win)
        if vim.bo[candidate].filetype == "epicenter-path" then
          found = candidate
          return true
        end
      end
      return false
    end, 20000, "the answer, rather than the picker again")
    local text = table.concat(vim.api.nvim_buf_get_lines(found, 0, -1, false), "\n")
    vim.api.nvim_buf_delete(found, { force = true })
    return text
  end

  it("F1: resolves a pick whose candidates all share one qualified name", function()
    -- Both `get_item` definitions reach OrderService.get, so only the file on
    -- the first rung says which one the pick actually resolved.
    local handle = epicenter.run("path", { "get_item", "OrderService.get" }, buf)
    local picker = pick(handle, function(symbol)
      return symbol.file == "py_fastapi/app/db.py"
    end)
    expect.eq(#picker.list:items(), 2, "both same-qualified definitions were offered")

    local text = answer_text()
    expect.matches(text, "py_fastapi/app/db%.py:22", "the ladder starts at the PICKED get_item")
    expect.matches(text, "OrderService%.get")
  end)

  it("F1: resolves the four-way `router` collision the fixture ships", function()
    local handle = epicenter.run("path", { "router", "list_users" }, buf)
    local picker = pick(handle, function(symbol)
      return symbol.file == "py_fastapi/app/routes/users.py"
    end)
    expect.eq(#picker.list:items(), 4, "all four routers were offered")
    -- Every row carries file:line - the only thing telling them apart.
    for _, item in ipairs(picker.list:items()) do
      expect.matches(
        require("epicenter.features.search").render_symbol(item).text,
        item.symbol.file:gsub("%p", "%%%0") .. ":%d"
      )
    end
    -- `router` has no callees, so the honest answer is that there is no
    -- chain - the point is that the question got ANSWERED, once.
    expect.matches(answer_text(), "no call path from router to list_users")
  end)

  it("F1: says so when even the file cannot separate two candidates", function()
    -- `main` is a package and a function in go_service/main.go, so `name@path`
    -- narrows the four-way case to one and this one to two.
    local handle = epicenter.run("path", { "main", "OrderService.get" }, buf)
    pick(handle, function(symbol)
      return symbol.kind == "fn"
    end)
    local text = answer_text()
    expect.matches(text, "2 definitions of main share go_service/main%.go")
    expect.matches(text, "cannot be told apart")
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

  --- F9: the panel prints `fanIn` on every row and scales every bar to it, so
  --- the rows have to be ordered by it. The real server ranks by connectivity
  --- instead, which is a different key - so this asserts both halves: the
  --- server's own order is NOT fan-in order (or the case proves nothing), and
  --- the panel's is.
  it("ranks hot spots by the fan-in it prints, whatever order the server sent", function()
    local hot = require("epicenter.features.hot")
    local _, answer = support.request(root, "navgraph/hot", { path = "py_fastapi", limit = 30 })
    local sent = vim.tbl_map(function(item)
      return item.fanIn
    end, answer.items)
    local server_ranked_by_fan_in = true
    for index = 2, #sent do
      server_ranked_by_fan_in = server_ranked_by_fan_in and sent[index - 1] >= sent[index]
    end
    expect.eq(
      server_ranked_by_fan_in,
      false,
      "the server already ranks by fan-in here, so this case proves nothing: " .. vim.inspect(sent)
    )

    local panel = epicenter.run("hot", { "py_fastapi" }, buf)
    opened = panel
    local items = wait(function()
      return panel.list:count() > 0 and panel.list:items() or nil
    end, 20000, "hot rows")
    expect.truthy(items[1].fanIn > 0, "the busiest symbol has callers")

    local shown = vim.tbl_map(function(item)
      return item.fanIn
    end, items)
    for index = 2, #shown do
      expect.truthy(
        shown[index - 1] >= shown[index],
        "the longest bar must be first: " .. vim.inspect(shown)
      )
    end
    expect.eq(hot.bar_scale(items), shown[1], "the bars scale to the row at the top")
    -- Same set of rows, only reordered.
    table.sort(sent, function(a, b)
      return a > b
    end)
    expect.eq(shown, sent, "ranking must not drop or invent a row")
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
