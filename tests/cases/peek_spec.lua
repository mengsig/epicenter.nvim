--- Peek: one preview component, two focus rules. From the code the float must
--- not take focus and must hand back the keys it borrowed; from a panel it
--- must, because the panel already holds the cursor.
local support = require("support")
local epicenter = require("epicenter")
local peek = require("epicenter.ui.peek")

local function open_fixture(root, relative, line, column)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
  vim.api.nvim_win_set_cursor(0, { line, column or 0 })
  return vim.api.nvim_get_current_buf()
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function floats()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      table.insert(out, win)
    end
  end
  return out
end

describe("the peek target", function()
  local function symbol(over)
    return vim.tbl_extend("force", {
      uri = "file:///proj/app/server.lua",
      line = 9,
      endLine = 12,
    }, over or {})
  end

  it("prefers the symbol under the cursor", function()
    local target = require("epicenter.features.peek").target_of({
      symbol = symbol(),
      enclosing = symbol({ line = 1 }),
    })
    expect.eq(target.line, 9)
    expect.eq(target.path, "/proj/app/server.lua")
  end)

  it("falls back to the definition the cursor sits inside", function()
    local target = require("epicenter.features.peek").target_of({
      symbol = vim.NIL,
      enclosing = symbol({ line = 3 }),
    })
    expect.eq(target.line, 3)
  end)

  it("resolves nothing when the cursor names nothing", function()
    expect.eq(
      require("epicenter.features.peek").target_of({ symbol = vim.NIL, enclosing = vim.NIL }),
      nil
    )
  end)
end)

describe("peek against the fake navgraph server", function()
  local root, buf

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    -- Column 12 is inside `handle_request` on its own definition line.
    buf = open_fixture(root, "app/server.lua", 9, 12)
    support.attach(root, buf)
  end)

  after_each(function()
    local open = peek.current()
    if open then
      open:close()
    end
    require("epicenter.events").clear()
  end)

  it("opens a float without taking focus, and shows the definition", function()
    local before = vim.api.nvim_get_current_win()
    epicenter.run("peek", {}, buf)
    local card = wait(function()
      return peek.current()
    end, 10000, "the peek float")

    expect.eq(vim.api.nvim_get_current_win(), before, "the cursor stays where it was")
    expect.matches(
      table.concat(vim.api.nvim_buf_get_lines(card.win.buf, 0, -1, false), "\n"),
      "handle_request"
    )
  end)

  it("borrows q from the buffer underneath and dismisses on a real press", function()
    epicenter.run("peek", {}, buf)
    wait(function()
      return peek.current()
    end, 10000, "the peek float")

    expect.truthy(
      vim.fn.maparg("q", "n", false, true).buffer == 1,
      "q is mapped on the source buffer while the peek is up"
    )
    press("q")

    wait(function()
      return peek.current() == nil
    end, 5000, "the peek to dismiss")
    expect.truthy(
      vim.tbl_isempty(vim.fn.maparg("q", "n", false, true)),
      "q is handed back when the float goes"
    )
  end)

  it("gives back a buffer-local mapping it displaced, rather than deleting it", function()
    local hit = 0
    vim.keymap.set("n", "q", function()
      hit = hit + 1
    end, { buffer = buf, desc = "the user's own q" })

    epicenter.run("peek", {}, buf)
    wait(function()
      return peek.current()
    end, 10000, "the peek float")
    peek.current():close()

    expect.eq(vim.fn.maparg("q", "n", false, true).desc, "the user's own q")
    vim.keymap.del("n", "q", { buffer = buf })
  end)

  it("goes to the definition on <CR>, in the window it was opened from", function()
    local origin = vim.api.nvim_get_current_win()
    open_fixture(root, "app/config.lua", 1)
    local other = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_win(origin)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 10, 6 })

    epicenter.run("peek", {}, buf)
    local card = wait(function()
      return peek.current()
    end, 10000, "the peek float")
    local line = card.target.line
    press("<CR>")

    wait(function()
      return peek.current() == nil and vim.api.nvim_win_get_cursor(0)[1] == line
    end, 5000, "the jump")
    expect.eq(vim.api.nvim_get_current_win(), origin)
    expect.truthy(other ~= nil)
  end)

  it("dismisses itself when the cursor moves on", function()
    epicenter.run("peek", {}, buf)
    wait(function()
      return peek.current()
    end, 10000, "the peek float")

    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf, modeline = false })
    wait(function()
      return peek.current() == nil
    end, 5000, "the peek to dismiss")
  end)

  it("replaces an open peek rather than stacking floats", function()
    epicenter.run("peek", {}, buf)
    wait(function()
      return peek.current()
    end, 10000, "the first peek")
    local before = #floats()

    peek.open({ path = vim.fs.joinpath(root, "app/config.lua"), line = 4 }, { focus = false })
    expect.eq(#floats(), before, "a second peek replaces the first")
  end)

  it("takes focus when a panel opens it, so q reaches the float", function()
    local panel = epicenter.run("callers", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 0
    end, 10000, "callers rows")

    local card = require("epicenter.ui.panel").peek(panel:target())
    expect.eq(vim.api.nvim_get_current_win(), card.win.win, "a panel peek is entered")
    card:close()
    panel:close()
  end)

  it("opens the file in the reader's window on <CR>, not inside the panel", function()
    local source_win = vim.api.nvim_get_current_win()
    local panel = epicenter.run("callers", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 0
    end, 10000, "callers rows")
    local panel_win = panel.win.win
    local target = panel:target()

    -- A real `o` inside the panel: the peek is opened by the panel itself.
    vim.api.nvim_set_current_win(panel_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("o", true, false, true), "x", false)
    local card = wait(function()
      return peek.current()
    end, 5000, "the panel's peek")

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    wait(function()
      return not card:valid() and vim.api.nvim_get_current_win() == source_win
    end, 5000, "the jump landing in the reader's own window")
    expect.eq(
      vim.api.nvim_win_get_buf(source_win),
      vim.fn.bufnr(target.path),
      "the file opened where the reader was, not in the panel's float"
    )
    expect.falsy(
      vim.api.nvim_win_is_valid(panel_win)
        and vim.api.nvim_win_get_buf(panel_win) == vim.fn.bufnr(target.path),
      "and never inside the panel's own window"
    )
    if panel:valid() then
      panel:close()
    end
  end)

  it("drops an unfocused peek whose answer arrives after the reader moved on", function()
    local other = vim.api.nvim_create_buf(true, false)
    local before = #floats()
    epicenter.run("peek", {}, buf)
    -- Before the answer lands: the reader is somewhere else entirely.
    vim.api.nvim_set_current_buf(other)
    vim.wait(500)
    expect.eq(peek.current(), nil, "no float over a buffer nobody asked about")
    expect.eq(#floats(), before)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_delete(other, { force = true })
  end)
end)
