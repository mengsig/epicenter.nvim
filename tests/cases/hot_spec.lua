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
end)
