local animate = require("epicenter.ui.animate")
local epicenter = require("epicenter")
local model = require("epicenter.features.blast.model")
local support = require("support")

local ADDED_LINES = {
  "",
  "function M.default_route()",
  '  return M.route("GET", "/")',
  "end",
}

local function names(panel)
  return vim.tbl_map(function(node)
    return node.symbol.qualified
  end, panel.nodes)
end

local function state_of(panel, qualified)
  for _, node in ipairs(panel.nodes) do
    if node.symbol.qualified == qualified then
      return node.state or "settled"
    end
  end
  return nil
end

local function line_highlights(panel)
  local marks =
    vim.api.nvim_buf_get_extmarks(panel.surface.buf, panel.ns, 0, -1, { details = true })
  return vim.tbl_map(function(mark)
    return mark[4].line_hl_group
  end, marks)
end

describe("the blast panel diffs a realtime update instead of rebuilding", function()
  local root, buf, original, panel, manual, now

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()

    local path = vim.fs.joinpath(root, "app/config.lua")
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 then
      vim.api.nvim_buf_delete(existing, { force = true })
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    original = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    manual, now = animate.manual_driver(), 0
  end)

  after_each(function()
    if panel then
      panel:close()
      panel = nil
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
      vim.bo[buf].modified = false
    end
    require("epicenter.events").clear()
  end)

  --- Hands the panel a tween this test drives by hand, so the transition can
  --- be inspected mid-flight instead of only at its final state.
  local function hand_drive()
    panel.animate_opts = {
      motion = true,
      duration = 100,
      driver = manual.driver,
      clock = function()
        return now
      end,
    }
  end

  local function finish_transition()
    now = now + 1000
    manual.step()
    expect.eq(panel.transition_tween, nil, "the transition tween finished")
  end

  local function answered_after(fn)
    local before = panel.answered
    fn()
    wait(function()
      return panel.answered > before
    end, 10000, "a realtime re-query")
  end

  it("flashes what arrived, dims what left, and settles on the new set", function()
    panel = epicenter.run("blast", { "M.route" }, buf)
    wait(function()
      return #panel.nodes == 2
    end, 10000, "the first result")
    expect.eq(names(panel), { "M.handle_request", "M.start" })
    hand_drive()

    -- An unsaved edit adds a same-file caller of M.route.
    answered_after(function()
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, ADDED_LINES)
    end)

    expect.eq(#panel.last_delta.added, 1)
    expect.eq(#panel.last_delta.removed, 0)
    expect.matches(panel.last_delta.added[1], "M%.default_route$")
    expect.eq(
      state_of(panel, "M.default_route"),
      "added",
      "the new row is flagged while it flashes"
    )
    expect.truthy(
      vim.tbl_contains(line_highlights(panel), "EpicenterRange"),
      "an arriving row is lit with the accent"
    )

    finish_transition()
    expect.eq(state_of(panel, "M.default_route"), "settled")
    expect.eq(#panel.nodes, 3)
    expect.falsy(vim.tbl_contains(line_highlights(panel), "EpicenterRange"))

    -- Take it away again: the row stays in place, dimmed, until the tween ends.
    answered_after(function()
      vim.api.nvim_buf_set_lines(buf, #original, -1, false, {})
    end)

    expect.eq(panel.last_delta.removed, {
      model.node_key({
        uri = vim.uri_from_fname(vim.fs.joinpath(root, "app/config.lua")),
        qualified = "M.default_route",
      }),
    })
    expect.eq(state_of(panel, "M.default_route"), "removed")
    expect.eq(#panel.nodes, 3, "the departing row is still on screen")

    finish_transition()
    expect.eq(state_of(panel, "M.default_route"), nil)
    expect.eq(names(panel), { "M.handle_request", "M.start" })
  end)

  it("ticks the summary chips across the transition", function()
    panel = epicenter.run("blast", { "M.route" }, buf)
    wait(function()
      return #panel.nodes == 2
    end, 10000, "the first result")
    hand_drive()

    answered_after(function()
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, ADDED_LINES)
    end)

    now = now + 50
    manual.step()
    local mid = vim.api.nvim_buf_get_lines(panel.surface.buf, 1, 2, false)[1]
    expect.matches(mid, "%d symbols")

    finish_transition()
    expect.matches(
      vim.api.nvim_buf_get_lines(panel.surface.buf, 1, 2, false)[1],
      "^  3 symbols · 2 files"
    )
  end)

  it("repaints without a transition when the result did not change", function()
    panel = epicenter.run("blast", { "M.route" }, buf)
    wait(function()
      return #panel.nodes == 2
    end, 10000, "the first result")
    hand_drive()

    answered_after(function()
      -- A comment changes the file without changing the graph.
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "-- nothing to see here" })
    end)

    expect.eq(panel.last_delta, { added = {}, removed = {} })
    expect.eq(panel.transition_tween, nil, "an unchanged result never animates")
    expect.eq(names(panel), { "M.handle_request", "M.start" })
  end)
end)

--- <leader>ee's headline entry point: a fixed cursor position, not a named
--- symbol. The re-index that a line-shifting edit triggers is exactly the
--- edit that stops naming the same line (#F2).
describe("the blast panel pins to the resolved symbol on a cursor-target realtime re-query", function()
  local root, buf, panel, original

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()

    local path = vim.fs.joinpath(root, "app/server.lua")
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 then
      vim.api.nvim_buf_delete(existing, { force = true })
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    original = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- `function M.handle_request(...)` - a fixed cursor position, not a
    -- definition's own line number the panel could re-derive.
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
  end)

  after_each(function()
    if panel then
      panel:close()
      panel = nil
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
      vim.bo[buf].modified = false
    end
    require("epicenter.events").clear()
  end)

  it("keeps the root on the resolved symbol after a line-shifting edit", function()
    panel = epicenter.run("blast", {}, buf)
    wait(function()
      return panel.answered > 0 and #panel.nodes > 0
    end, 10000, "the first result")
    expect.eq(panel.meta.root.qualified, "M.handle_request")
    expect.eq(names(panel), { "M.start" })

    local before = panel.answered
    -- Inserted above the root: every definition below shifts down one line,
    -- so the ORIGINAL cursor position now names a different definition
    -- (log_request's range grows to cover it).
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- a line inserted near the top" })
    wait(function()
      return panel.answered > before
    end, 10000, "a realtime re-query")

    expect.eq(panel.meta.root.qualified, "M.handle_request", "the panel must not silently re-root")
    expect.eq(names(panel), { "M.start" })
  end)
end)
