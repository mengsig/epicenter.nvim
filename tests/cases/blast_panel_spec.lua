local support = require("support")
local epicenter = require("epicenter")
local model = require("epicenter.features.blast.model")

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
        return node.ring
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
    local heuristic = vim.tbl_filter(function(node)
      return node.heuristic
    end, panel.nodes)
    expect.eq(#heuristic, 1, "the cross-file call is resolved by name only")
    expect.eq(heuristic[1].symbol.qualified, "M.route")
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
    expect.matches(lines_of(panel)[2], "strict")
  end)

  it("cycles the tests scope and sends it with the query", function()
    panel = epicenter.run("blast", {}, buf)
    settled(panel)

    settled(panel, function()
      panel:cycle_tests()
    end)
    expect.eq(panel.state.tests, "without")
    expect.eq(#panel.nodes, 2)
    expect.matches(lines_of(panel)[2], "tests without")

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
