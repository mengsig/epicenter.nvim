local support = require("support")
local epicenter = require("epicenter")
local search = require("epicenter.features.search")

--- Opens a fixture file so the palette resolves the fixture root.
local function open_fixture(root, relative)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
  return vim.api.nvim_get_current_buf()
end

local function results_lines(p)
  return vim.api.nvim_buf_get_lines(p.results_win.buf, 0, -1, false)
end

local function preview_lines(p)
  return vim.api.nvim_buf_get_lines(p.preview_win.buf, 0, -1, false)
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
      return p.list:count() == 0 and results_lines(p)[1]:match("no matches") ~= nil
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
    -- F12: the file may elide at a narrow palette width, keeping its
    -- filename over its leading directories - the line number and the
    -- matched text are what the row guarantees.
    expect.matches(results_lines(p)[1], "%.lua:%d+")
    expect.matches(results_lines(p)[1], "log_request")
    p:close()
  end)

  it("jumps to the match column on accept, not always column 0", function()
    local buf2 = open_fixture(root, "app/server.lua")
    local p = epicenter.run("grep", {}, buf2)
    p:query("log_request")
    wait(function()
      return p.list:count() > 0
    end, 10000, "grep results")
    local expected = p.list:current()
    expect.truthy(expected.character > 0, "the fixture match is not at column 0")
    p:accept("edit")

    -- buf2 already showed server.lua before accept, so waiting on the buffer
    -- name alone would race the scheduled jump - wait for the line instead.
    wait(function()
      return vim.api.nvim_win_get_cursor(0)[1] == expected.line
    end, 5000, "jump to the match")
    expect.eq(vim.api.nvim_win_get_cursor(0)[2], expected.character)
  end)

  it("jumps to the use site in refs mode, not the enclosing definition (F3)", function()
    local p = epicenter.run("search", {}, buf)
    p.state.mode = "refs"
    p:query("log_request")
    wait(function()
      return p.list:count() > 0
    end, 10000, "refs results")

    local item = p.list:current()
    expect.eq(item.symbol.qualified, "M.handle_request", "refs mode groups by the referencer")
    expect.truthy(item.lines ~= nil, "a refs item must carry use-site lines")
    expect.matches(results_lines(p)[1], "app/server%.lua:10", "the row must show the use site")
    expect.falsy(
      results_lines(p)[1]:match("app/server%.lua:9%f[%D]"),
      "the row must not show the enclosing definition's own line"
    )

    p:accept("edit")
    wait(function()
      return vim.api.nvim_win_get_cursor(0)[1] == 10
    end, 5000, "jump to the use site")
    expect.matches(vim.api.nvim_get_current_line(), "log_request%(method, path%)")
  end)

  it("shows the keys of the mode it is in, not the other modes'", function()
    local p = epicenter.run("search", {}, buf)
    p:toggle_help()
    local search_help = table.concat(preview_lines(p), "\n")
    expect.matches(search_help, "cycle the kind filter")
    expect.matches(search_help, "symbols %-> grep %-> references")
    expect.falsy(search_help:match("toggle regex"), "symbols mode has no <C-r>")
    p:close()

    local buf2 = open_fixture(root, "app/server.lua")
    local p2 = epicenter.run("grep", {}, buf2)
    p2:toggle_help()
    local grep_help = table.concat(preview_lines(p2), "\n")
    expect.matches(grep_help, "toggle regex")
    expect.falsy(
      grep_help:match("cycle the kind filter"),
      "grep has no <C-k>, its help must not claim one"
    )
    p2:close()
  end)

  it("cycles symbols -> grep -> references on <C-space>, keeping the query", function()
    local p = epicenter.run("search", {}, buf)
    p:query("log_request")
    wait(function()
      return p.list:count() > 0
    end, 10000, "symbol results")

    search.cycle_mode(p)
    expect.eq(p.state.mode, "grep")
    wait(function()
      return p.list:count() > 0 and results_lines(p)[1]:match("%.lua:%d+") ~= nil
    end, 10000, "grep results for the same query")
    expect.matches(vim.api.nvim_win_get_config(p.results_win.win).title[1][1], "grep")

    search.cycle_mode(p)
    expect.eq(p.state.mode, "refs")
    wait(function()
      return p.list:count() > 0 and p.list:current().lines ~= nil
    end, 10000, "reference results for the same query")

    search.cycle_mode(p)
    expect.eq(p.state.mode, "symbols", "three modes, then back round")
    p:close()
  end)

  it("ranks a recently picked symbol first, and remembers it across a restart", function()
    local state_dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(state_dir, "p")
    require("epicenter.store").set_root(state_dir)

    expect.eq(search.recent(root), {}, "nothing picked yet")
    expect.eq(search.promote({ "b", "c" }, "a"), { "a", "b", "c" })
    expect.eq(search.promote({ "a", "b" }, "b"), { "b", "a" }, "a repeat pick moves to the front")

    local p = epicenter.run("search", {}, buf)
    p:query("request")
    wait(function()
      return p.list:count() > 1
    end, 10000, "symbol results")
    -- Pick the SECOND row, so ranking it first next time is a real change.
    local second = p.list:items()[2].symbol.qualified
    p.list:select(2)
    p:accept("edit")
    wait(function()
      return vim.tbl_contains(search.recent(root), second)
    end, 5000, "the remembered pick")

    local p2 = epicenter.run("search", {}, buf)
    p2:query("request")
    wait(function()
      return p2.list:count() > 1
    end, 10000, "symbol results again")
    expect.eq(p2.list:items()[1].symbol.qualified, second, "the recent pick ranks first")
    p2:close()
    require("epicenter.store").set_root(nil)
  end)

  -- F15: the prompt opens in insert mode, and <Esc> used to close outright -
  -- so every normal-mode key the footer advertises (?, j, k, q) had no way
  -- to be reached at all. One <Esc> now drops to normal mode, like anywhere
  -- else in Neovim; a second closes.
  it("reaches ? and q through <Esc>, rather than <Esc> closing outright", function()
    -- A headless session cannot actually enter insert mode (no UI attached
    -- for `:startinsert` to hand control to), so this drives the prompt's
    -- own per-mode key callbacks directly, the same way blast/explore's
    -- specs drive a panel's keys - the real regression, and the real fix,
    -- are which callback fires for which mode, not the mode transition
    -- itself.
    local p = epicenter.run("search", {}, buf)

    local function press(mode, lhs)
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(p.prompt_win.buf, mode)) do
        if map.lhs == lhs and map.callback then
          return map.callback()
        end
      end
      error(("no %s-mode mapping for %s"):format(mode, lhs))
    end

    -- The prompt opens in insert mode: this is the key <Esc> actually fires
    -- first. It used to close the palette outright, which left every
    -- normal-mode key below unreachable from the prompt's own start state.
    press("i", "<Esc>")
    expect.truthy(p.open, "the first <Esc> drops to normal mode, it does not close")

    press("n", "?")
    expect.truthy(p.help_open, "? is now reachable")
    press("n", "?")

    press("n", "q")
    expect.falsy(p.open, "q closes from normal mode")
  end)

  it("reflows the whole palette, list height included, on a real VimResized", function()
    local p = epicenter.run("search", {}, buf)
    local before_box = p.results_win:geometry()
    expect.eq(p.list.height, before_box.height, "list height starts in sync with the box")

    vim.o.lines = 20
    -- The real path: production never calls Palette:reflow() directly, only
    -- the autocmd does (that gap is exactly what let the list desync, F4).
    vim.api.nvim_exec_autocmds("VimResized", {})
    vim.o.lines = 40

    local after_box = p.results_win:geometry()
    expect.truthy(after_box.height < before_box.height, "the resize must shrink the box")
    expect.eq(p.list.height, after_box.height, "the list height must track the shrunken box")
    expect.eq(p.tween, nil, "a reflow never starts a tween")

    local painted = vim.api.nvim_buf_get_lines(p.results_win.buf, 0, -1, false)
    expect.truthy(
      #painted <= after_box.height,
      "no more rows may be painted than the shrunken window can show"
    )
    p:close()
  end)

  it("announces a planned subcommand instead of failing", function()
    -- Whichever subcommand is still announced-but-unshipped; the list shrinks
    -- as features land, and the branch disappears with the last of them.
    local planned = vim.tbl_filter(function(cmd)
      return cmd.status == "planned"
    end, require("epicenter.registry").commands())[1]
    if not planned then
      return
    end

    local notices = {}
    local toast = require("epicenter.ui.toast")
    local original = toast.notify
    toast.notify = function(msg, opts)
      table.insert(notices, { msg = msg, opts = opts })
    end
    epicenter.run(planned.name, {}, buf)
    toast.notify = original
    expect.eq(#notices, 1)
    expect.matches(notices[1].msg, "coming in a later release")
    expect.eq(notices[1].opts.level, "info")
  end)
end)
