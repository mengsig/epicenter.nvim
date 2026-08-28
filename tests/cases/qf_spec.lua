--- The quickfix / location-list export: the pure entry shape, the `<Tab>`
--- multi-selection, the panel and palette keys that send it, and the
--- `--qf`/`--loc` command flags.
local support = require("support")
local epicenter = require("epicenter")
local qf = require("epicenter.ui.qf")

local function open_fixture(root, relative, line)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
  if line then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
  end
  return vim.api.nvim_get_current_buf()
end

--- The real keypress, in the window that actually holds the panel.
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function close_lists()
  vim.cmd("silent! cclose")
  vim.cmd("silent! lclose")
  vim.fn.setqflist({}, "f")
end

describe("quickfix entries", function()
  it("carries file, 1-based line, 1-based column and the row's own text", function()
    local entries = qf.entries({
      {
        target = { path = "/proj/app/server.lua", line = 9, character = 12 },
        text = "  M.handle ",
      },
      { target = { path = "/proj/app/config.lua", line = 4 }, text = "M.route" },
    })
    expect.eq(entries, {
      { filename = "/proj/app/server.lua", lnum = 9, col = 13, text = "M.handle" },
      { filename = "/proj/app/config.lua", lnum = 4, col = 1, text = "M.route" },
    })
  end)

  it("carries the row's end line where the panel knew one", function()
    expect.eq(
      qf.entries({ { target = { path = "/proj/a.lua", line = 9, end_line = 14 }, text = "x" } })[1],
      { filename = "/proj/a.lua", lnum = 9, end_lnum = 14, col = 1, text = "x" }
    )
  end)

  it("drops a row with no target rather than inventing a location", function()
    expect.eq(qf.entries({ { text = "a heading" } }), {})
  end)

  it("opens nothing for an empty result set", function()
    expect.eq(qf.send({ rows = {}, title = "empty" }), 0)
  end)
end)

describe("the <Tab> multi-selection", function()
  local list_mod = require("epicenter.ui.list")

  local function list_of(items)
    local buf = vim.api.nvim_create_buf(false, true)
    local list = list_mod.new({
      buf = buf,
      height = 10,
      render_item = function(item)
        return { text = item.name }
      end,
      text_of = function(item)
        return item.name
      end,
    })
    list:set_items(items)
    return list
  end

  it("sends every row on screen when nothing is marked", function()
    local list = list_of({ { name = "a" }, { name = "b" } })
    expect.eq(#list:marked_or_all(), 2)
  end)

  it("sends only the marked rows once any row is marked", function()
    local items = { { name = "a" }, { name = "b" }, { name = "c" } }
    local list = list_of(items)
    list:select(2)
    expect.eq(list:toggle_mark(), true)
    expect.eq(list:marked_or_all(), { items[2] })
  end)

  it("marks in view order, not in the order they were toggled", function()
    local items = { { name = "a" }, { name = "b" }, { name = "c" } }
    local list = list_of(items)
    list:select(3)
    list:toggle_mark()
    list:select(1)
    list:toggle_mark()
    expect.eq(list:marked_or_all(), { items[1], items[3] })
  end)

  it("toggles back off, and a new result set forgets the marks", function()
    local items = { { name = "a" }, { name = "b" } }
    local list = list_of(items)
    list:toggle_mark()
    expect.eq(list:toggle_mark(), false)
    expect.eq(#list:marked_or_all(), 2)

    list:toggle_mark()
    list:set_items({ { name = "x" } })
    expect.eq(#list:marked_or_all(), 1, "a fresh answer starts with no selection")
  end)

  it("renders a marked row so it is visible without reading the state", function()
    local items = { { name = "a" }, { name = "b" } }
    local list = list_of(items)
    list:select(2)
    list:toggle_mark()
    local rendered = list_mod.render(list:state())
    expect.eq(rendered.marked_rows, { 1 }, "row indices are 0-based into the painted slice")
  end)
end)

describe("sending rows to a list, against the fake navgraph server", function()
  local root, buf

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    buf = open_fixture(root, "app/server.lua", 9)
    support.attach(root, buf)
    close_lists()
  end)

  after_each(function()
    close_lists()
    require("epicenter.events").clear()
  end)

  it("sends a panel's rows on a real <C-q>, with a title and working :cnext", function()
    local panel = epicenter.run("callers", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 0
    end, 10000, "callers rows")

    vim.api.nvim_set_current_win(panel.win.win)
    press("<C-q>")

    wait(function()
      return #vim.fn.getqflist() > 0
    end, 5000, "the quickfix list to fill")
    local list = vim.fn.getqflist()
    expect.truthy(#list > 0)
    expect.matches(vim.fn.getqflist({ title = 1 }).title, "callers")
    for _, entry in ipairs(list) do
      expect.truthy(entry.bufnr > 0, "every entry names a real file")
      expect.truthy(entry.lnum >= 1)
    end
    expect.falsy(panel:valid(), "the panel closes once its rows are in the list")
  end)

  it("sends only the <Tab> selection", function()
    local panel = epicenter.run("hot", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "hot rows")
    local total = panel.list:count()

    vim.api.nvim_set_current_win(panel.win.win)
    press("<Tab>")
    press("<C-q>")

    wait(function()
      return #vim.fn.getqflist() > 0
    end, 5000, "the quickfix list to fill")
    expect.eq(#vim.fn.getqflist(), 1, ("one marked row of %d"):format(total))
  end)

  it("sends a panel's rows to the location list on <C-l>", function()
    local panel = epicenter.run("hot", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 0
    end, 10000, "hot rows")

    vim.api.nvim_set_current_win(panel.win.win)
    press("<C-l>")

    wait(function()
      return #vim.fn.getloclist(0) > 0
    end, 5000, "the location list to fill")
    expect.eq(#vim.fn.getqflist(), 0, "the quickfix list is left alone")
  end)

  -- L3: this used to call palette:export("quickfix") directly - the real
  -- <C-q>/<C-l>/<Tab> maps at palette.lua:365-373 had no coverage through
  -- the key path at all, which is exactly how M4's <C-v> hijack shipped
  -- untested.
  it("sends a palette's matches on a real <C-q>", function()
    local palette = epicenter.run("search", {}, buf)
    palette:query("handle_request")
    wait(function()
      local item = palette.list:current()
      return item ~= nil and #(item.matches or {}) > 0
    end, 10000, "search results")

    press("<C-q>")
    wait(function()
      return #vim.fn.getqflist() > 0
    end, 5000, "the quickfix list to fill")
    expect.matches(vim.fn.getqflist({ title = 1 }).title, "search")
  end)

  it("--qf on the command line sends the rows the panel would have shown", function()
    epicenter.run("callers", { "--qf" }, buf)
    wait(function()
      return #vim.fn.getqflist() > 0
    end, 10000, "the quickfix list to fill")
    expect.truthy(#vim.fn.getqflist() > 0)
  end)

  it("--qf on a live palette waits for the query the user actually types", function()
    local palette = epicenter.run("grep", { "--qf" }, buf)
    -- The palette opens with an empty-query request of its own; its answer
    -- is not a result set anybody asked for.
    vim.wait(400)
    expect.truthy(palette.open, "the palette is still open before a keystroke")
    expect.eq(#vim.fn.getqflist(), 0, "nothing is exported for a query nobody typed")

    palette:query("handle_request")
    wait(function()
      return palette.list:count() > 0
    end, 10000, "grep matches")
    local matched = palette.list:count()

    palette:accept()
    wait(function()
      return #vim.fn.getqflist() > 0
    end, 5000, "the quickfix list to fill")
    expect.eq(#vim.fn.getqflist(), matched, "the rows the user was looking at")
    expect.falsy(palette.open, "the palette closes once its rows are in the list")
  end)

  it("--loc fills the location list instead", function()
    epicenter.run("callers", { "--loc" }, buf)
    wait(function()
      return #vim.fn.getloclist(0) > 0
    end, 10000, "the location list to fill")
    expect.eq(#vim.fn.getqflist(), 0)
  end)

  it("keeps the flag out of the command's own arguments", function()
    local rest, list = epicenter.split_export_flag({ "M.handle", "--qf" })
    expect.eq(rest, { "M.handle" })
    expect.eq(list, "quickfix")

    local none_rest, none = epicenter.split_export_flag({ "M.handle" })
    expect.eq(none_rest, { "M.handle" })
    expect.eq(none, nil)
  end)

  it("completes the flags on a command that has rows, and not on one that does not", function()
    local with_rows = epicenter.complete("--", ":Epicenter callers --", 0)
    expect.truthy(vim.tbl_contains(with_rows, "--qf"))
    expect.truthy(vim.tbl_contains(with_rows, "--loc"))
    expect.eq(epicenter.complete("--", ":Epicenter restart --", 0), {})
  end)

  it("says so rather than opening an empty list when a command has no rows", function()
    local notices = {}
    local toast = require("epicenter.ui.toast")
    local original = toast.notify
    toast.notify = function(msg)
      table.insert(notices, msg)
    end
    epicenter.run("log", { "--qf" }, buf)
    toast.notify = original

    expect.eq(#notices, 1)
    expect.matches(notices[1], "no rows")
  end)
end)
