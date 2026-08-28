local support = require("support")
local epicenter = require("epicenter")
local model = require("epicenter.features.blast.model")
local panel_module = require("epicenter.features.blast.panel")

--- Opens a fixture file with the cursor on `line`.
local function open_fixture(root, relative, line)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  return vim.api.nvim_get_current_buf()
end

local function lines_of(panel)
  return vim.api.nvim_buf_get_lines(panel.surface.buf, 0, -1, false)
end

local function body(panel)
  return table.concat(lines_of(panel), "\n")
end

local function names(panel)
  return vim.tbl_map(function(node)
    return node.symbol.qualified
  end, panel.nodes)
end

--- Runs `trigger` (if any) and blocks until the panel answers a query.
local function settled(panel, trigger)
  local before = panel.answered
  if trigger then
    trigger()
  end
  wait(function()
    return panel.answered > before
  end, 10000, "blast result")
end

describe("blast panel against the fake navgraph server", function()
  local root, buf, panel

  before_each(function()
    -- Deliberately no `vim.o.columns` change: growing it in a headless
    -- session aborts Neovim in draw_tabline, and nothing here needs the room.
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    buf = open_fixture(root, "app/server.lua", 5)
  end)

  after_each(function()
    if panel then
      panel:close()
      panel = nil
    end
    require("epicenter.events").clear()
  end)

  it("rings the callers of the symbol the cursor sits in", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    expect.eq(names(panel), { "M.handle_request", "M.start" })
    expect.eq(
      vim.tbl_map(function(node)
        return node.depth
      end, panel.nodes),
      { 1, 2 }
    )

    local text = body(panel)
    expect.matches(lines_of(panel)[1], "log_request", "the header names the root")
    expect.matches(lines_of(panel)[2], "2 symbols · 1 file · 0 tests · depth 2")
    expect.matches(text, "ring 1")
    expect.matches(text, "ring 2")
    expect.matches(text, "app/server%.lua:9")
  end)

  it("takes a named symbol from the command line", function()
    panel = epicenter.run("blast", { "M.handle_request" }, buf)
    settled(panel)
    expect.eq(names(panel), { "M.start" })
    expect.matches(lines_of(panel)[1], "M%.handle_request")
  end)

  it("re-queries at the new depth on + and -", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    expect.eq(#panel.nodes, 2)

    settled(panel, function()
      panel:set_depth(-1)
    end)
    expect.eq(panel.state.depth, 1)
    expect.eq(names(panel), { "M.handle_request" })

    settled(panel, function()
      panel:set_depth(1)
    end)
    expect.eq(names(panel), { "M.handle_request", "M.start" })
  end)

  it("flips to callees and marks the name-resolved edge", function()
    panel = epicenter.run("blast", { "M.handle_request" }, buf)
    settled(panel)

    settled(panel, function()
      panel:flip_direction()
    end)
    expect.eq(panel.state.direction, "callees")
    expect.eq(names(panel), { "M.route", "log_request" })
    local inexact = vim.tbl_filter(function(node)
      return not node.exact
    end, panel.nodes)
    expect.eq(#inexact, 1, "the cross-file call is resolved by name only")
    expect.eq(inexact[1].symbol.qualified, "M.route")
    expect.matches(body(panel), "M%.route.*%?")
  end)

  it("drops heuristic edges under strict", function()
    panel = epicenter.run("blast", { "M.handle_request" }, buf)
    settled(panel)
    settled(panel, function()
      panel:flip_direction()
    end)
    expect.eq(#panel.nodes, 2)

    settled(panel, function()
      panel:toggle_strict()
    end)
    expect.eq(panel.state.strict, true)
    expect.eq(names(panel), { "log_request" })
    -- The chip line reflecting "strict" is covered directly, at a width
    -- that guarantees it survives, by blast_model_spec's chips_line specs
    -- (F12: a narrow real panel may legitimately elide the mode indicator).
  end)

  it("cycles the tests scope and sends it with the query", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    settled(panel, function()
      panel:cycle_tests()
    end)
    expect.eq(panel.state.tests, "without")
    expect.eq(#panel.nodes, 2)
    -- The chip line reflecting "tests without" is covered directly, at a
    -- width that guarantees it survives, by blast_model_spec's chips_line
    -- specs (F12: a narrow real panel may legitimately elide it).

    settled(panel, function()
      panel:cycle_tests()
    end)
    expect.eq(panel.state.tests, "only")
    expect.eq(#panel.nodes, 0)
    expect.matches(body(panel), "nothing impacted", "no test touches this fixture")
  end)

  it("says so when the cursor is on nothing", function()
    local empty = open_fixture(root, "app/config.lua", 2)
    panel = epicenter.run("blast", {}, empty)
    settled(panel)
    expect.matches(body(panel), "no symbol under the cursor")
    expect.eq(panel.nodes, {})
  end)

  -- D5: the panel is a stable box while nodes are showing - resizing on
  -- every +/-/d/t/j/k would be jittery - but the SAME box for a one-line
  -- "no symbol" answer sat in a ~28-row float with nothing in it. Re-queries
  -- a position in the SAME buffer, never re-editing a file while the float
  -- is the current window - that would edit the panel's own float buffer.
  it("shrinks to the message once there is nothing to show but one (#D5)", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    local full_height = panel.surface.window.box.height
    expect.truthy(full_height > 10, "the normal box is the full ui.height: " .. full_height)

    settled(panel, function()
      -- app/server.lua:8 is blank - the same "genuinely no symbol" position
      -- the existing spec above already uses.
      panel:set_query(
        "blast",
        { uri = vim.uri_from_bufnr(buf), position = { line = 7, character = 0 } },
        buf
      )
    end)
    expect.matches(body(panel), "no symbol under the cursor")
    expect.eq(panel.surface.window.box.height, 4, "shrunk to header + one message row")

    -- Back to a real answer: the full box returns.
    settled(panel, function()
      panel:set_query(
        "blast",
        { uri = vim.uri_from_bufnr(buf), position = { line = 4, character = 0 } },
        buf
      )
    end)
    expect.eq(panel.surface.window.box.height, full_height, "restored once there is content again")
  end)

  it("jumps to the selected row and yanks its location", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    local target = panel:current_target()
    expect.matches(target.path, "server%.lua$")
    expect.eq(target.line, 9)

    panel:yank()
    expect.matches(vim.fn.getreg('"'), "server%.lua:9$")

    panel:jump()
    expect.matches(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), "server%.lua$")
    expect.eq(vim.api.nvim_win_get_cursor(0)[1], 9)
  end)

  it("opens the jump target in a split or a tab (merge-gate F9)", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    local before_wins = #vim.api.nvim_list_wins()
    panel:jump("vsplit")
    expect.truthy(#vim.api.nvim_list_wins() > before_wins, "the vsplit opened")
    expect.matches(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), "server%.lua$")

    local before_tabs = #vim.api.nvim_list_tabpages()
    panel:jump("tab")
    expect.truthy(#vim.api.nvim_list_tabpages() > before_tabs, "the tab opened")
    expect.matches(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), "server%.lua$")
  end)

  it("/ selects the first row matching the typed text (merge-gate F9)", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    expect.truthy(vim.tbl_contains(names(panel), "M.start"))

    local original_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("start")
    end
    panel:_filter()
    vim.ui.input = original_input

    expect.eq(panel.rows[panel.selected].node.symbol.qualified, "M.start")
  end)

  it("skips headings when moving and toggles the key help", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    expect.eq(panel.rows[panel.selected].kind, "node")
    panel:move(1)
    expect.eq(panel.rows[panel.selected].kind, "node")
    expect.eq(panel.rows[panel.selected].node.symbol.qualified, "M.start")

    panel:toggle_help()
    expect.matches(body(panel), "flip callers")
    panel:toggle_help()
    expect.matches(body(panel), "ring 1")
  end)

  it("documents every key it installs, so `?` never lies (#F10)", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    local help_text = table.concat(panel_module.HELP, "\n")
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.surface.buf, "n")) do
      expect.truthy(
        help_text:find(map.lhs, 1, true) ~= nil,
        "`?` help does not mention " .. map.lhs
      )
    end
  end)

  it("repaints on VimResized (#F11)", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    local calls = 0
    local original = panel._paint
    panel._paint = function(self, ...)
      calls = calls + 1
      return original(self, ...)
    end

    vim.api.nvim_exec_autocmds("VimResized", { modeline = false })

    expect.eq(calls, 1, "a resize must repaint the panel exactly once")
    panel._paint = original
  end)

  it("cleans up its marks and subscriptions on close", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    local surface_buf = panel.surface.buf
    local ripples = require("epicenter.features.blast.ripples")
    expect.eq(ripples.ring_at(buf, 9), 1, "the ring-1 caller is marked in the code")

    local closing = panel
    panel = nil
    closing:close()
    expect.falsy(closing:valid())
    expect.eq(ripples.ring_at(buf, 9), nil)
    expect.falsy(vim.api.nvim_buf_is_valid(surface_buf))
    expect.eq(require("epicenter.features.blast.panel").current(), nil)
  end)

  it("re-targets on the cursor in follow mode, debounced", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    expect.eq(names(panel), { "M.handle_request", "M.start" })

    panel:toggle_follow()
    expect.eq(panel.state.follow, true)
    -- The chip line reflecting "follow" is covered directly, at a width
    -- that guarantees it survives, by blast_model_spec's chips_line specs
    -- (F12: a narrow real panel may legitimately elide the mode indicator).
    expect.ne(
      vim.api.nvim_get_current_win(),
      panel.surface.win,
      "follow hands the cursor back to the code"
    )

    vim.api.nvim_win_set_cursor(0, { 14, 0 })
    panel:on_cursor_moved(buf)
    expect.truthy(panel.follow_debouncer.pending(), "a cursor move waits out the debounce")
    expect.matches(lines_of(panel)[1], "log_request", "and the panel has not moved yet")

    settled(panel, function()
      panel.follow_debouncer.flush()
    end)
    expect.matches(lines_of(panel)[1], "M%.start", "the panel followed to the new definition")
  end)

  -- F10: the fallback for "the cursor is not on a name" used to re-target at
  -- `character = 0`, which is leading whitespace for every indented
  -- definition - the one column the server can never resolve. It now re-asks
  -- by the enclosing definition's disambiguated name.
  it("blasts the enclosing definition from anywhere inside its body", function()
    -- app/server.lua:11 is `  return config.route(method, path)`, indented,
    -- inside M.handle_request and not on any definition's own name.
    buf = open_fixture(root, "app/server.lua", 11)
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    expect.eq(names(panel), { "M.start" }, "the callers of the enclosing definition")
    expect.eq(panel.meta.root.qualified, "M.handle_request")
    expect.eq(panel.message, nil, "no 'no symbol under the cursor'")
  end)

  it("blasts from the leading indentation of a body line too", function()
    -- Column 0 of an indented line: where `<CR>` from any picker parks the
    -- cursor, and where the server resolves nothing at all.
    buf = open_fixture(root, "app/server.lua", 10)
    vim.api.nvim_win_set_cursor(0, { 10, 0 })
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    expect.eq(panel.message, nil, "no 'no symbol under the cursor'")
    expect.eq(panel.meta.root.qualified, "log_request", "the call under the first non-blank column")
  end)

  it("still says so where there is genuinely no symbol", function()
    buf = open_fixture(root, "app/server.lua", 8)
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    expect.matches(body(panel), "no symbol under the cursor")
  end)

  --- F3: the title is built from `self.meta.root`, which the message path did
  --- not clear - so the panel rendered a title naming a symbol, a chip line of
  --- zeros, and a body saying there is none, all at once.
  it("stops naming the previous symbol once the query finds none", function()
    buf = open_fixture(root, "app/server.lua", 5)
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    expect.matches(lines_of(panel)[1], "log_request", "the header names the answered root")

    settled(panel, function()
      panel:set_query(
        "blast",
        { uri = vim.uri_from_bufnr(buf), position = { line = 7, character = 0 } },
        buf
      )
    end)
    expect.matches(body(panel), "no symbol under the cursor")
    expect.falsy(
      lines_of(panel)[1]:find("log_request", 1, true),
      "the header still names a symbol the body says is not there: " .. lines_of(panel)[1]
    )
    expect.matches(lines_of(panel)[1], "blast radius")
  end)

  --- F2: `+`/`-` re-query and repaint. Where the value clamps they change
  --- nothing at all, and silence there is indistinguishable from a dead key.
  it("says so when + or - has nowhere left to go", function()
    buf = open_fixture(root, "app/server.lua", 5)
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    local said = {}
    local original = epicenter.notify
    epicenter.notify = function(message)
      table.insert(said, message)
    end
    local ok = pcall(function()
      local max = require("epicenter.config").get().blast.max_depth
      panel.state.depth = 1
      panel:set_depth(-1)
      expect.eq(panel.state.depth, 1, "clamped, so nothing was re-queried")
      expect.matches(said[#said] or "", "already 1")

      panel.state.depth = max
      panel:set_depth(1)
      expect.eq(panel.state.depth, max)
      expect.matches(said[#said] or "", "already at its maximum")
      expect.eq(#said, 2, "one line per clamped press, and none otherwise")
    end)
    epicenter.notify = original
    assert(ok)
  end)

  it("shows the depth it asked for beside the depth it reached", function()
    buf = open_fixture(root, "app/server.lua", 5)
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    -- log_request has one ring of callers, so any deeper ask falls short.
    settled(panel, function()
      panel:set_depth(2)
    end)
    expect.eq(panel.state.depth, 4)
    expect.matches(lines_of(panel)[2], "depth %d of 4", lines_of(panel)[2])
  end)

  it("ignores cursor movement inside the panel itself", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)
    panel:toggle_follow()
    panel:on_cursor_moved(panel.surface.buf)
    expect.falsy(panel.follow_debouncer.pending())
  end)

  it("peeks at the selected definition and closes the peek again", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    panel:peek()
    expect.truthy(panel.peek_win ~= nil and panel.peek_win:valid())
    local peeked = table.concat(vim.api.nvim_buf_get_lines(panel.peek_win.buf, 0, -1, false), "\n")
    expect.matches(peeked, "function M%.handle_request")

    panel:peek()
    expect.eq(panel.peek_win, nil, "o toggles the peek shut")
  end)

  it("renders the same panel in a vertical split", function()
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      animate = false,
      blast = { layout = "vsplit" },
    })
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    expect.eq(panel.surface.kind, "split")
    expect.eq(
      vim.api.nvim_win_get_config(panel.surface.win).relative,
      "",
      "a real window, not a float"
    )
    expect.matches(table.concat(lines_of(panel), "\n"), "ring 1")
    expect.matches(lines_of(panel)[1], "log_request")
  end)

  it("sends every mode toggle as a query parameter", function()
    local state = { depth = 3, direction = "callees", tests = "only", strict = true }
    expect.eq(model.params(state, { symbol = "x" }), {
      depth = 3,
      direction = "callees",
      tests = "only",
      strict = true,
      symbol = "x",
    })
  end)
end)
