local outline = require("epicenter.features.outline")
local support = require("support")

local function symbol(over)
  return vim.tbl_extend("force", {
    qualified = "RequestHandler",
    name = "RequestHandler",
    kind = "class",
    file = "app/handlers.py",
    uri = "file:///proj/app/handlers.py",
    line = 1,
    endLine = 1,
  }, over or {})
end

describe("outline rows", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("flattens the nesting into indented rows", function()
    local rows = outline.rows_of({
      {
        symbol = symbol(),
        children = {
          {
            symbol = symbol({ qualified = "RequestHandler.close", name = "close", kind = "method" }),
          },
        },
      },
      { symbol = symbol({ qualified = "dispatch", name = "dispatch", kind = "fn" }) },
    })
    expect.eq(
      vim.tbl_map(function(row)
        return ("%d:%s"):format(row.depth, row.symbol.name)
      end, rows),
      { "0:RequestHandler", "1:close", "0:dispatch" }
    )
  end)

  it("shows the bare name, the kind and the line", function()
    local rendered = outline.render_row({ symbol = symbol({ line = 7 }), depth = 1 })
    expect.matches(rendered.text, "RequestHandler")
    expect.matches(rendered.text, "7$")
    expect.matches(rendered.text, "^    ", "depth indents the row")
  end)

  it("picks the innermost symbol containing the cursor line", function()
    local rows = {
      { symbol = symbol({ name = "outer", line = 1, endLine = 20 }), depth = 0 },
      { symbol = symbol({ name = "inner", line = 5, endLine = 9 }), depth = 1 },
    }
    expect.eq(outline.enclosing_index(rows, 7), 2)
    expect.eq(outline.enclosing_index(rows, 15), 1)
    expect.eq(outline.enclosing_index(rows, 40), nil)
  end)

  it("declares the command and its keymap", function()
    expect.eq(outline.commands[1].name, "outline")
    expect.eq(outline.keymaps[1].suffix, "o")
  end)
end)

describe("outline sidebar against the fake navgraph server", function()
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
    return vim.tbl_map(function(row)
      return row.symbol.name
    end, panel.list:items())
  end

  local function open(relative)
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
    buf = vim.api.nvim_get_current_buf()
    panel = require("epicenter").run("outline", {}, buf)
    wait(function()
      return panel.list:count() > 0
    end, 10000, "outline for " .. relative)
    return panel
  end

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.events").clear()
  end)

  it("nests the methods of a class under it", function()
    open("app/handlers.py")
    expect.eq(names(), { "RequestHandler", "handle_request", "close", "dispatch" })
    local rows = vim.api.nvim_buf_get_lines(panel.win.buf, 0, -1, false)
    expect.matches(rows[1], "RequestHandler")
    expect.matches(rows[2], "^    %S", "a method is indented under its class")
  end)

  it("highlights the symbol the cursor sits in, and follows it", function()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    buf = vim.api.nvim_get_current_buf()
    local source_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(source_win, { 10, 0 })

    panel = require("epicenter").run("outline", {}, buf)
    wait(function()
      return panel.list:count() > 0
    end, 10000, "outline")
    expect.eq(panel:current().symbol.qualified, "M.handle_request")

    vim.api.nvim_win_set_cursor(source_win, { 15, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    wait(function()
      return panel:current().symbol.qualified == "M.start"
    end, 5000, "the sidebar follows the cursor")
  end)

  it("cycles the kind filter on <C-k>, not k (F8)", function()
    open("app/handlers.py")
    press("<C-K>")
    expect.eq(names(), { "handle_request", "close", "dispatch" }, "functions and methods only")
    press("<C-K>")
    expect.eq(names(), { "RequestHandler" }, "types only")
  end)

  it("k moves up instead of cycling the filter (F8)", function()
    open("app/handlers.py")
    panel.list:select(3) -- "close"
    local before = panel:current().symbol.name
    press("k")
    expect.truthy(panel:current().symbol.name ~= before, "the selection actually moved")
    expect.eq(
      names(),
      { "RequestHandler", "handle_request", "close", "dispatch" },
      "k never touches the filter"
    )
  end)

  it("filters by name", function()
    open("app/handlers.py")
    panel:set_filter("close")
    expect.eq(names(), { "close" })
  end)

  it("y, <C-v> and <C-t> come from the panel's target_of (F12)", function()
    open("app/handlers.py")
    local mapped = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
      mapped[map.lhs] = true
    end
    for _, lhs in ipairs({ "y", "<C-V>", "<C-T>", "?", "/" }) do
      expect.truthy(mapped[lhs], "outline maps " .. lhs)
    end
  end)

  it("rebuilds itself when the index changes", function()
    open("app/handlers.py")
    local before = panel.list:count()
    support.request(root, "navgraph/rescan", {})
    wait(function()
      return panel.list:count() == before and names()[1] == "RequestHandler"
    end, 10000, "outline after the reindex")
  end)

  it("coalesces a burst of reindexes into one debounced pass (F5)", function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      animate = false,
      outline = { debounce_ms = 250 },
      -- Isolates the count to the sidebar's own requests: blast's badges
      -- feature also calls `client.outline` on every reindex, independently.
      badges = false,
    })
    open("app/handlers.py")

    local client = require("epicenter.client")
    local calls, original = 0, client.outline
    client.outline = function(...)
      calls = calls + 1
      return original(...)
    end

    local ok = pcall(function()
      for _ = 1, 5 do
        support.request(root, "navgraph/rescan", {})
      end
      wait(function()
        return calls == 1
      end, 10000, "one settled pass for a burst of 5 reindexes, not one pass per reindex")
      -- Confirm it stays at 1: a bug that fires per-reindex would keep growing.
      vim.wait(500)
      expect.eq(calls, 1)
    end)
    client.outline = original
    assert(ok)
  end)

  it("follows a buffer switch", function()
    open("app/handlers.py")
    vim.api.nvim_set_current_win(outline.current().source_win)
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/config.lua")))
    wait(function()
      return vim.deep_equal(names(), { "route", "load_config" })
    end, 10000, "outline for the new buffer")
  end)

  --- F11: wiping the source buffer used to leave `state.source_buf` dangling
  --- whenever `BufEnter` lands somewhere that is not a source buffer (a
  --- scratch buffer, here) - the next reindex then crashed inside
  --- `root.lua`'s `relative()`. The trigger needs no user action: the
  --- server's own watch poll fires `navgraph/indexed` on an ordinary
  --- reindex, reproduced here via `navgraph/rescan`.
  it("survives wiping the source buffer with nowhere to retarget, on the next reindex", function()
    open("app/handlers.py")
    local wiped = buf
    local source_win = outline.current().source_win

    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(source_win, scratch)
    vim.api.nvim_buf_delete(wiped, { force = true })

    local logged = {}
    local original = require("epicenter.log").error
    require("epicenter.log").error = function(fmt, ...)
      table.insert(logged, fmt:format(...))
    end

    -- The watch-poll case: a reindex with no user action in between.
    support.request(root, "navgraph/rescan", {})
    wait(function()
      return panel:valid() and panel.list:count() == 0
    end, 10000, "the sidebar clears rather than crashing")

    require("epicenter.log").error = original
    expect.eq(logged, {}, "no error logged from the reindex after the wipe")
    expect.truthy(panel:valid(), "the sidebar itself survives")
    expect.eq(outline.current().source_buf, nil, "the dangling buffer id was cleared")
  end)

  it("retargets to another visible source buffer when the current one is wiped", function()
    open("app/handlers.py")
    local wiped = buf
    vim.cmd.vsplit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/config.lua")))
    local other_win = vim.api.nvim_get_current_win()

    vim.api.nvim_buf_delete(wiped, { force = true })

    wait(function()
      return vim.deep_equal(names(), { "route", "load_config" })
    end, 10000, "the sidebar retargeted to the other open source buffer")
    expect.eq(outline.current().source_win, other_win)
  end)

  it("opens focused, focuses when it is not, and closes when it is", function()
    open("app/handlers.py")
    expect.eq(vim.api.nvim_get_current_win(), panel.win.win, "the sidebar takes focus on open")

    local source_win = outline.current().source_win
    vim.api.nvim_set_current_win(source_win)
    expect.eq(require("epicenter").run("outline", {}, buf), panel, "from elsewhere it focuses")
    expect.eq(vim.api.nvim_get_current_win(), panel.win.win)

    require("epicenter").run("outline", {}, buf)
    expect.falsy(panel:valid(), "running it from inside closes it")
    expect.eq(outline.current(), nil)
  end)
end)

--- merge-gate F8: the sidebar was an editor-relative FLOAT pinned at
--- `{row=0,col=0}`, so it painted over the leftmost `outline.width` columns of
--- the file it outlines. Survivable while you read it; not afterwards, because
--- this panel's `<CR>` deliberately stays open - the definition you jumped to
--- came back missing its first 34 columns.
describe("outline geometry", function()
  local root, buf, panel

  local function open(relative)
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
    buf = vim.api.nvim_get_current_buf()
    panel = require("epicenter").run("outline", {}, buf)
    wait(function()
      return panel.list:count() > 0
    end, 10000, "outline for " .. relative)
    return panel
  end

  --- Windows showing a real file, with where they start and how wide they are.
  local function source_windows()
    local out = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local candidate = vim.api.nvim_win_get_buf(win)
      if vim.bo[candidate].buftype == "" and vim.api.nvim_buf_get_name(candidate) ~= "" then
        table.insert(out, {
          win = win,
          col = vim.api.nvim_win_get_position(win)[2],
          width = vim.api.nvim_win_get_width(win),
        })
      end
    end
    return out
  end

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    vim.cmd("silent! only")
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    vim.cmd("silent! only")
    require("epicenter.events").clear()
  end)

  it("takes its own columns instead of covering the source", function()
    local full_width = vim.api.nvim_win_get_width(vim.api.nvim_get_current_win())
    open("app/server.lua")

    local config = vim.api.nvim_win_get_config(panel.win.win)
    expect.eq(config.relative, "", "the sidebar must be a real window, not a float over one")

    local width = require("epicenter.config").get().outline.width
    expect.eq(vim.api.nvim_win_get_width(panel.win.win), width)

    local sources = source_windows()
    expect.eq(#sources, 1, "one source window: " .. vim.inspect(sources))
    expect.truthy(
      sources[1].col > width,
      ("the source starts at column %d, right of the %d-wide sidebar"):format(sources[1].col, width)
    )
    expect.truthy(
      sources[1].width < full_width,
      "the source window gave up the columns rather than being painted over"
    )
    -- Nothing of the file is hidden: sidebar + separator + source == the grid.
    expect.eq(width + 1 + sources[1].width, full_width)
  end)

  it("carries its title and its footer without a border to hang them on", function()
    open("app/server.lua")
    local winbar = vim.wo[panel.win.win].winbar
    expect.matches(winbar, "outline: server%.lua")
    panel:set_footer(" 4 · functions ")
    expect.matches(vim.wo[panel.win.win].winbar, "4 · functions")
  end)

  it("<CR> hands the cursor to the source and leaves the sidebar a sidebar", function()
    open("app/server.lua")
    local source = require("epicenter.features.outline").current().source_win
    panel.list:select(3)
    local target = panel:current().symbol
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
      if map.lhs == "<CR>" and map.callback then
        map.callback()
        break
      end
    end

    expect.truthy(panel:valid(), "the sidebar stays open")
    expect.eq(vim.api.nvim_get_current_win(), source, "and the cursor is in the code")
    expect.eq(vim.api.nvim_win_get_cursor(source)[1], target.line)
    expect.eq(vim.api.nvim_win_get_config(panel.win.win).relative, "")
  end)

  it("the float layout closes on the jump rather than sitting on it", function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      animate = false,
      outline = { layout = "float" },
    })
    open("app/server.lua")
    expect.eq(vim.api.nvim_win_get_config(panel.win.win).relative, "editor")

    panel.list:select(3)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
      if map.lhs == "<CR>" and map.callback then
        map.callback()
        break
      end
    end
    wait(function()
      return not panel:valid()
    end, 5000, "the float to close on the jump")
  end)

  it("resizing the split re-flows the rows it shows", function()
    open("app/server.lua")
    local before = panel.list.height
    vim.api.nvim_win_set_height(panel.win.win, math.max(3, before - 4))
    panel:draw()
    expect.eq(panel.list.height, vim.api.nvim_win_get_height(panel.win.win))
    expect.truthy(panel.list.height ~= before, "the list followed the window")
  end)
end)
