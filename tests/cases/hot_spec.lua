local hot = require("epicenter.features.hot")
local support = require("support")

local function symbol(over)
  return vim.tbl_extend("force", {
    qualified = "M.handle_request",
    name = "handle_request",
    kind = "method",
    file = "app/server.lua",
    uri = "file:///proj/app/server.lua",
    line = 9,
    endLine = 13,
  }, over or {})
end

describe("hot spot rows", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("scales the bar to the busiest symbol in the list", function()
    local busiest = hot.render_hot({ symbol = symbol(), fanIn = 8 }, 8, 8)
    local quiet = hot.render_hot({ symbol = symbol(), fanIn = 2 }, 8, 8)
    expect.matches(busiest.text, "######## 8$")
    expect.matches(quiet.text, "##------ 2$")
  end)

  it("draws an empty bar rather than dividing by zero", function()
    expect.matches(hot.render_hot({ symbol = symbol(), fanIn = 0 }, 0, 4).text, "%-%-%-%- 0$")
  end)

  it("shows the symbol and where it lives", function()
    local rendered = hot.render_hot({ symbol = symbol(), fanIn = 1 }, 4, 4)
    expect.matches(rendered.text, "M%.handle_request")
    expect.matches(rendered.text, "app/server%.lua:9")
  end)

  -- F12: at a narrow width, the file elided to keep the bar/count visible -
  -- the number the panel exists to show - rather than the window edge
  -- silently cutting them off.
  it("elides a long path before it ever loses the bar or the count", function()
    local long = symbol({
      qualified = "OrderService.place",
      file = "py_fastapi/app/services/order_service.py",
    })
    local rendered = hot.render_hot({ symbol = long, fanIn = 7 }, 7, 12, 40)
    expect.truthy(vim.fn.strdisplaywidth(rendered.text) <= 40, "fits: " .. rendered.text)
    expect.matches(rendered.text, "…", "the path was elided")
    expect.matches(rendered.text, "7$", "the count survives")
  end)

  it("renders an unused symbol without a bar", function()
    local rendered = hot.render_unused(symbol())
    expect.matches(rendered.text, "M%.handle_request")
    expect.matches(rendered.text, "app/server%.lua:9$")
  end)

  it("declares its three commands and the hot keymap", function()
    expect.eq(
      vim.tbl_map(function(c)
        return c.name
      end, hot.commands),
      { "hot", "unused", "graph" }
    )
    expect.eq(hot.keymaps[1].suffix, "h")
  end)
end)

describe("hot spots against the fake navgraph server", function()
  local root, buf, panel

  local function press(lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
      if map.lhs == lhs and map.callback then
        return map.callback()
      end
    end
    error("no mapping for " .. lhs)
  end

  local function names()
    return vim.tbl_map(function(item)
      return (item.symbol or item).qualified
    end, panel.list:items())
  end

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
  end)

  it("ranks this file's symbols by call sites, and b widens to the repo", function()
    panel = require("epicenter").run("hot", {}, buf)
    wait(function()
      return panel.list:count() > 0
    end, 10000, "hot spots")
    expect.eq(names(), { "M.handle_request", "log_request" }, "this buffer only")
    local first = vim.api.nvim_buf_get_lines(panel.win.buf, 0, -1, false)[1]
    expect.matches(first, "#", "the busiest symbol gets a full bar")
    expect.matches(first, "2$", "M.start calls it twice")

    press("b")
    wait(function()
      return panel.list:count() > 2
    end, 10000, "repo-wide hot spots")
    expect.truthy(vim.tbl_contains(names(), "dispatch"), "the python side shows up too")
  end)

  it("filters navgraph/hot's path as a substring, not an exact match (merge-gate F6)", function()
    -- The contract's `path` is a substring filter over the root-relative path
    -- (same as outline/unused/graph) - `hot app` must match `app/server.lua`.
    local err, exact = support.request(root, "navgraph/hot", { path = "app/server.lua" })
    assert(not err, vim.inspect(err))
    local err2, substring = support.request(root, "navgraph/hot", { path = "server" })
    assert(not err2, vim.inspect(err2))
    expect.truthy(#substring.items > 0, "a substring match returns results")
    expect.eq(
      vim.tbl_map(function(item)
        return item.symbol.qualified
      end, substring.items),
      vim.tbl_map(function(item)
        return item.symbol.qualified
      end, exact.items),
      "a substring of the path matches the same set as the full path"
    )
  end)

  it("lists what nothing reaches, and p drops the public ones", function()
    panel = require("epicenter").run("unused", {}, buf)
    wait(function()
      return panel.list:count() > 0
    end, 10000, "unused symbols")
    expect.truthy(vim.tbl_contains(names(), "M.start"), "nothing calls the entry point")
    expect.falsy(vim.tbl_contains(names(), "log_request"), "it has a caller")

    press("p")
    wait(function()
      return panel.list:count() == 0
    end, 10000, "no unreached internals")
  end)

  it("narrows the unused list to the filter argument", function()
    panel = require("epicenter").run("unused", { "load_config" }, buf)
    wait(function()
      return panel.list:count() > 0
    end, 10000, "filtered unused symbols")
    expect.eq(names(), { "M.load_config" })
  end)

  it("draws the requested subgraph without touching the file named as the filter (F6)", function()
    -- {path} is a FILTER, not an output path: the server always chooses
    -- where it writes, under .navgraph/ - the old behaviour destroyed
    -- whatever file this argument named.
    local source = vim.fs.joinpath(root, "app/server.lua")
    local before = table.concat(vim.fn.readfile(source), "\n")

    local opened, notices = nil, {}
    local original_open, toast = vim.ui.open, require("epicenter.ui.toast")
    local original_notify = toast.notify
    vim.ui.open = function(path)
      opened = path
    end
    toast.notify = function(msg)
      table.insert(notices, msg)
    end

    require("epicenter").run("graph", { "app/server.lua" }, buf)
    wait(function()
      return opened ~= nil
    end, 10000, "graph export")
    vim.ui.open, toast.notify = original_open, original_notify

    expect.truthy(opened, "vim.ui.open was called")
    expect.matches(
      opened,
      "%.navgraph[/\\]graph%-%x+%.html$",
      "the server chose the path, not the argument"
    )
    expect.truthy((vim.uv or vim.loop).fs_stat(opened), "the file is really there")
    expect.matches(table.concat(vim.fn.readfile(opened), "\n"), "digraph navgraph")
    expect.truthy(#vim.tbl_filter(function(msg)
      return tostring(msg):match("graph written to") ~= nil
    end, notices) > 0, "the notice names the path")

    local after = table.concat(vim.fn.readfile(source), "\n")
    expect.eq(after, before, "the source file handed as a filter is untouched")
  end)

  -- F14: `vim.ui.open` returns `nil, err` when it finds no handler (a
  -- headless box, no `xdg-open`) - the success toast already fired, so the
  -- graph silently not opening must not be the only thing that happened.
  it("says so when vim.ui.open finds no handler", function()
    local notices = {}
    local original_open, toast = vim.ui.open, require("epicenter.ui.toast")
    local original_notify = toast.notify
    vim.ui.open = function()
      return nil, "no handler found"
    end
    toast.notify = function(msg, opts)
      table.insert(notices, { message = msg, level = opts and opts.level })
    end

    require("epicenter").run("graph", { "app/server.lua" }, buf)
    wait(function()
      return #notices >= 2
    end, 10000, "the open failure to be reported")
    vim.ui.open, toast.notify = original_open, original_notify

    expect.truthy(
      vim.tbl_contains(
        vim.tbl_map(function(n)
          return n.message:match("could not open the graph") ~= nil
        end, notices),
        true
      ),
      "no notice named the failure: " .. vim.inspect(notices)
    )
  end)
end)

describe("hot bar scale", function()
  it("scales to the widest fan-in, not to the first row", function()
    -- The server ranks by connectivity, so a later row can out-fan the first.
    expect.eq(hot.bar_scale({ { fanIn = 3 }, { fanIn = 9 }, { fanIn = 1 } }), 9)
    expect.eq(hot.bar_scale({}), 0)
  end)
end)

--- F9: the panel prints `fanIn` and scales each bar to it, so the order has to
--- be `fanIn` too. The server's own ranking is by connectivity - a real answer
--- put a 7 at the bottom, under four rows of 2, 1, 1, 1 - which drew a bar
--- chart that read as broken and made "ranked by fan-in" untrue.
describe("hot spot ranking (F9)", function()
  local function fan_ins(items)
    return vim.tbl_map(function(item)
      return item.fanIn
    end, hot.rank(items))
  end

  it("puts the longest bar first", function()
    expect.eq(
      fan_ins({
        { fanIn = 2, symbol = { qualified = "place" } },
        { fanIn = 1, symbol = { qualified = "resolve" } },
        { fanIn = 1, symbol = { qualified = "append" } },
        { fanIn = 0, symbol = { qualified = "init" } },
        { fanIn = 7, symbol = { qualified = "get" } },
      }),
      { 7, 2, 1, 1, 0 }
    )
  end)

  it("keeps the server's own order within a tie", function()
    local ranked = hot.rank({
      { fanIn = 1, symbol = { qualified = "second" } },
      { fanIn = 3, symbol = { qualified = "first" } },
      { fanIn = 1, symbol = { qualified = "third" } },
      { fanIn = 1, symbol = { qualified = "fourth" } },
    })
    expect.eq(
      vim.tbl_map(function(item)
        return item.symbol.qualified
      end, ranked),
      { "first", "second", "third", "fourth" }
    )
  end)

  it("treats a missing fanIn as none, and an empty answer as empty", function()
    expect.eq(fan_ins({ { symbol = {} }, { fanIn = 4, symbol = {} } }), { 4, nil })
    expect.eq(hot.rank({}), {})
    expect.eq(hot.rank(nil), {})
  end)

  it("does not mutate the answer it was handed", function()
    local items = { { fanIn = 1 }, { fanIn = 5 } }
    hot.rank(items)
    expect.eq(items[1].fanIn, 1, "the caller's list is left alone")
  end)
end)

describe("hot graph export message (F2)", function()
  it("reports flat success when the graph was not capped", function()
    local message, level =
      hot.graph_message("/proj/.navgraph/graph-abc.html", { path = "x", truncated = false })
    expect.matches(message, "^graph written to ")
    expect.eq(level, nil)
  end)

  it("names the truncation rather than presenting a capped subgraph as the graph", function()
    local message, level = hot.graph_message(
      "/proj/.navgraph/graph-abc.html",
      { path = "x", truncated = true, nodes = 400, nodesTotal = 612 }
    )
    expect.matches(message, "400 of 612 nodes shown")
    expect.eq(level, "warn")
  end)
end)

--- Exercises `tests/fake/explore.lua`'s `navgraph/unused` handler directly
--- against a synthetic index: no fixture file on disk has "test" in its name,
--- so the shared fixture tree cannot exercise `tests = "only"` on its own.
describe("navgraph/unused fake fidelity (merge-gate F7)", function()
  it("'only' lists unused test helpers, not code merely used only by tests", function()
    -- helper_fn: a test symbol nothing calls - an unused test helper.
    -- worker: a production symbol whose one caller is that test symbol.
    local index = {
      symbols = {
        {
          id = 1,
          name = "helper_fn",
          qualified = "helper_fn",
          kind = "fn",
          file = "app/helper_test.lua",
          uri = "file:///proj/app/helper_test.lua",
          line = 1,
          endLine = 3,
          test = true,
        },
        {
          id = 2,
          name = "worker",
          qualified = "worker",
          kind = "fn",
          file = "app/server.lua",
          uri = "file:///proj/app/server.lua",
          line = 1,
          endLine = 1,
          test = false,
        },
      },
      sources = {
        ["app/helper_test.lua"] = { "function helper_fn()", "  worker()", "end" },
        ["app/server.lua"] = { "function worker()" },
      },
    }
    local handlers = require("fake.explore")
    local ok, result = pcall(handlers["navgraph/unused"], { index = index }, { tests = "only" })
    assert(ok, tostring(result))
    expect.eq(
      vim.tbl_map(function(item)
        return item.symbol.qualified
      end, result.items),
      { "helper_fn" },
      "the unused test helper is listed, not the production symbol tests happen to call"
    )
  end)
end)

--- Exercises `tests/fake/explore.lua`'s `navgraph/graph` handler directly
--- against a synthetic index bigger than its NODE_CAP: no fixture on disk
--- is anywhere near large enough to trip the renderer's node cap on its own.
describe("navgraph/graph fake fidelity (F2)", function()
  it("truncates and reports nodesTotal once the graph exceeds the node cap", function()
    -- A straight call chain w1 -> w2 -> ... -> wN: N-1 edges touch all N
    -- symbols, so nodesTotal is exactly N.
    local N = 450
    local symbols, lines = {}, {}
    for i = 1, N do
      table.insert(symbols, {
        id = i,
        name = "w" .. i,
        qualified = "w" .. i,
        kind = "fn",
        file = "big.lua",
        uri = "file:///proj/big.lua",
        line = (i - 1) * 3 + 1,
        endLine = (i - 1) * 3 + 3,
        test = false,
      })
      table.insert(lines, ("function w%d()"):format(i))
      table.insert(lines, i < N and ("  w%d()"):format(i + 1) or "  -- leaf")
      table.insert(lines, "end")
    end
    local index = { symbols = symbols, sources = { ["big.lua"] = lines } }

    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local handlers = require("fake.explore")
    local ok, result = pcall(handlers["navgraph/graph"], { index = index, root = root }, {})
    assert(ok, tostring(result))

    expect.eq(result.nodesTotal, N)
    expect.eq(result.truncated, true)
    expect.truthy(result.nodes < result.nodesTotal, "fewer nodes shown than the graph has")
  end)

  it("does not truncate a graph under the cap", function()
    local index = {
      symbols = {
        {
          id = 1,
          name = "a",
          qualified = "a",
          kind = "fn",
          file = "small.lua",
          uri = "file:///proj/small.lua",
          line = 1,
          endLine = 3,
          test = false,
        },
        {
          id = 2,
          name = "b",
          qualified = "b",
          kind = "fn",
          file = "small.lua",
          uri = "file:///proj/small.lua",
          line = 4,
          endLine = 6,
          test = false,
        },
      },
      sources = { ["small.lua"] = { "function a()", "  b()", "end", "function b()", "end" } },
    }
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local handlers = require("fake.explore")
    local ok, result = pcall(handlers["navgraph/graph"], { index = index, root = root }, {})
    assert(ok, tostring(result))
    expect.eq(result.truncated, false)
    expect.eq(result.nodes, result.nodesTotal)
  end)
end)
