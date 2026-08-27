local support = require("support")
local epicenter = require("epicenter")

--- Opens a fixture file so the palette resolves the fixture root.
local function open_fixture(root, relative)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
  return vim.api.nvim_get_current_buf()
end

local function results_lines(p)
  return vim.api.nvim_buf_get_lines(p.results_win.buf, 0, -1, false)
end

describe("search palette against the fake navgraph server", function()
  local root, buf

  before_each(function()
    -- Deterministic editor size: the layout decisions depend on it.
    vim.o.columns = 160
    vim.o.lines = 40
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    buf = open_fixture(root, "app/config.lua")
  end)

  it("opens three panes, focused on the prompt", function()
    local p = epicenter.run("search", {}, buf)
    expect.truthy(p.prompt_win:valid())
    expect.truthy(p.results_win:valid())
    expect.truthy(p.preview_win ~= nil and p.preview_win:valid(), "80+ columns gets a preview pane")
    expect.eq(vim.api.nvim_get_current_win(), p.prompt_win.win)
    p:close()
    expect.falsy(p.prompt_win:valid())
    expect.falsy(p.results_win:valid())
  end)

  it("shows ranked results for a query and highlights the match", function()
    local p = epicenter.run("search", {}, buf)
    p:query("handle_request")
    -- The palette lists everything on open; wait for rows carrying match
    -- indices so this never asserts against the unfiltered list.
    wait(function()
      local item = p.list:current()
      return item ~= nil and #(item.matches or {}) > 0
    end, 10000, "search results")

    expect.eq(p.list:current().symbol.qualified, "M.handle_request")
    local lines = results_lines(p)
    expect.matches(lines[1], "M%.handle_request")
    expect.matches(lines[1], "app/server%.lua:9")

    local marks =
      vim.api.nvim_buf_get_extmarks(p.results_win.buf, p.list.ns, 0, -1, { details = true })
    local match_marks = vim.tbl_filter(function(mark)
      return mark[4].hl_group == "EpicenterMatch"
    end, marks)
    expect.truthy(#match_marks > 0, "matched characters are highlighted")
    p:close()
  end)

  it("drops a result set that a newer keystroke superseded", function()
    local p = epicenter.run("search", {}, buf)
    p:query("h")
    p:query("handle_request")
    wait(function()
      local item = p.list:current()
      return item ~= nil and #(item.matches or {}) > 0
    end, 10000, "search results")
    vim.wait(200)
    expect.eq(p.list:current().symbol.qualified, "M.handle_request")
    p:close()
  end)

  it("jumps to the definition on accept", function()
    local p = epicenter.run("search", {}, buf)
    p:query("handle_request")
    wait(function()
      local item = p.list:current()
      return item ~= nil and #(item.matches or {}) > 0
    end, 10000, "search results")
    local symbol = p.list:current().symbol
    p:accept("edit")

    wait(function()
      return vim.fs.normalize(vim.api.nvim_buf_get_name(0)):match("server%.lua") ~= nil
    end, 5000, "jump to the definition")
    expect.eq(vim.api.nvim_win_get_cursor(0)[1], symbol.line)
    expect.matches(vim.api.nvim_get_current_line(), "function M%.handle_request")
  end)

  it("reports an empty query with no matches instead of an error", function()
    local p = epicenter.run("search", {}, buf)
    p:query("zzzznotasymbol")
    wait(function()
      return p.list:count() == 0 and results_lines(p)[1]:match("no symbols match") ~= nil
    end, 10000, "empty state")
    p:close()
  end)

  it("greps live over the same sources", function()
    local buf2 = open_fixture(root, "app/server.lua")
    local p = epicenter.run("grep", {}, buf2)
    p:query("log_request")
    wait(function()
      return p.list:count() > 0
    end, 10000, "grep results")
    expect.matches(results_lines(p)[1], "app/server%.lua:%d+")
    expect.matches(results_lines(p)[1], "log_request")
    p:close()
  end)

  it("reflows in place on a resize instead of animating", function()
    local p = epicenter.run("search", {}, buf)
    local before = p.results_win:geometry()
    p:reflow()
    expect.eq(p.results_win:geometry(), before, "same editor size, same geometry")
    expect.eq(p.tween, nil, "a reflow never starts a tween")
    p:close()
  end)

  it("announces the planned subcommands instead of failing", function()
    local notices = {}
    local toast = require("epicenter.ui.toast")
    local original = toast.notify
    toast.notify = function(msg, opts)
      table.insert(notices, { msg = msg, opts = opts })
    end
    epicenter.run("blast", {}, buf)
    toast.notify = original
    expect.eq(#notices, 1)
    expect.matches(notices[1].msg, "coming in this release")
    expect.eq(notices[1].opts.level, "info")
  end)
end)
