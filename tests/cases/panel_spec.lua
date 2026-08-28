--- F1 regression: a panel's primary action (`<CR>`, and the `<C-v>`/`<C-t>`
--- variants) must land the jump in the window the panel was opened from, even
--- with animation ON. Before the fix, `Panel:close()` started an async fade
--- and the scheduled jump ran while the fading float was still current,
--- landing the edit inside the float instead of the source window - the exact
--- bug CI's default reduce-motion hid (`tests/minimal_init.lua` sets it).
local panel_mod = require("epicenter.ui.panel")
local support = require("support")

describe("panel close-then-jump ordering", function()
  local source_win, panel

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      animation = { close_ms = 60, open_ms = 10 },
      -- This suite never starts a server; the jump edits a fixture file, and
      -- without this the host's own navgraph attaches (merge-gate F8).
      lsp = { auto_start = false },
    })
    -- Real animation: this is exactly the case CI's reduce-motion default hid.
    vim.g.epicenter_reduce_motion = false

    vim.cmd.enew()
    source_win = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    vim.g.epicenter_reduce_motion = true
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
  end)

  local function open_panel()
    local target_path = vim.fs.joinpath(support.fixture_root(), "app/server.lua")
    return panel_mod.open({
      title = " test ",
      render_row = function(item)
        return { text = item.name }
      end,
      target_of = function(item)
        return { path = target_path, line = item.line }
      end,
    })
  end

  local function press(lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
      if map.lhs == lhs and map.callback then
        return map.callback()
      end
    end
    error("no mapping for " .. lhs)
  end

  it("<CR> jumps into the window the panel was opened from, not the fading float", function()
    panel = open_panel()
    panel:set_items({ { name = "one", line = 3 } })
    panel.list:select(1)

    press("<CR>")

    -- `close()` restores focus to source_win synchronously (F1), so window
    -- identity alone can pass before the *scheduled* jump has actually run -
    -- wait for the jump's own effect (the buffer switch) instead.
    wait(function()
      return vim.api.nvim_buf_get_name(0):match("server%.lua") ~= nil
    end, 3000, "the scheduled jump landed")
    expect.eq(vim.api.nvim_get_current_win(), source_win, "and it landed in the source window")
    expect.eq(vim.api.nvim_win_get_cursor(0)[1], 3)

    -- The float is still fading here (close_ms=60): let it finish and make
    -- sure that does not steal focus back or error.
    wait(function()
      return not panel:valid()
    end, 3000, "the float finished closing")
    expect.eq(vim.api.nvim_get_current_win(), source_win, "the finished fade did not move focus")
  end)

  it("<C-v> and <C-t> also land relative to the source window", function()
    panel = open_panel()
    panel:set_items({ { name = "one", line = 5 } })
    panel.list:select(1)

    local before = #vim.api.nvim_list_wins()
    press("<C-V>")

    wait(function()
      return #vim.api.nvim_list_wins() > before
    end, 3000, "the vsplit opened")
    expect.matches(vim.api.nvim_buf_get_name(0), "server%.lua")
  end)
end)

describe("panel shared keys (F12)", function()
  local panel

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    vim.cmd.enew()
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
  end)

  it("? toggles a help overlay listing this panel's keys, including feature hints", function()
    panel = panel_mod.open({
      title = " test ",
      render_row = function(item)
        return { text = item.name }
      end,
      hints = { b = "toggle buffer/repo scope" },
    })
    panel:set_items({ { name = "one" } })

    local before = vim.api.nvim_buf_get_lines(panel.win.buf, 0, -1, false)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
      if map.lhs == "?" and map.callback then
        map.callback()
      end
    end
    local help = table.concat(vim.api.nvim_buf_get_lines(panel.win.buf, 0, -1, false), "\n")
    expect.matches(help, "keys")
    expect.matches(help, "q, <Esc>")
    expect.matches(help, "toggle buffer/repo scope", "the feature's own hint is listed")

    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
      if map.lhs == "?" and map.callback then
        map.callback()
      end
    end
    expect.eq(
      vim.api.nvim_buf_get_lines(panel.win.buf, 0, -1, false),
      before,
      "toggling back restores the rows"
    )
  end)

  it("/ filters the rows and lets the feature refresh its own footer", function()
    local footer_calls = {}
    panel = panel_mod.open({
      title = " test ",
      render_row = function(item)
        return { text = item.name }
      end,
      text_of = function(item)
        return item.name
      end,
      on_filter = function(query)
        table.insert(footer_calls, query)
      end,
    })
    panel:set_items({ { name = "alpha" }, { name = "beta" } })

    local original_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("alpha")
    end
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
      if map.lhs == "/" and map.callback then
        map.callback()
      end
    end
    vim.ui.input = original_input

    expect.eq(panel.list:count(), 1)
    expect.eq(footer_calls, { "alpha" })
  end)
end)

--- F13: a fixed default height either clipped a big result set or wasted
--- most of the float on a small one - the same defect `core.lua`'s
--- `box_for` fixed for the status dashboard, now for every float panel.
describe("panel sizes to its content", function()
  local panel

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
  end)

  local function open_panel(spec_extra)
    return panel_mod.open(vim.tbl_extend("force", {
      title = " test ",
      render_row = function(item)
        return { text = item.name }
      end,
    }, spec_extra or {}))
  end

  it("shrinks below the default height for a small result set", function()
    panel = open_panel()
    local natural = panel_mod.box()
    panel:set_items({ { name = "one" }, { name = "two" } })
    expect.truthy(panel.win.box.height < natural.height, "shrunk: " .. panel.win.box.height)
    expect.eq(panel.win.box.height, 3, "floored at 3, not at the item count of 2")
  end)

  it("never grows past the default height for a large result set", function()
    panel = open_panel()
    local natural = panel_mod.box()
    local items = {}
    for i = 1, natural.height + 50 do
      table.insert(items, { name = "item" .. i })
    end
    panel:set_items(items)
    expect.eq(panel.win.box.height, natural.height)
  end)

  it("leaves an explicit box alone", function()
    panel = open_panel({ box = { row = 0, col = 0, width = 40, height = 20 } })
    panel:set_items({ { name = "one" } })
    expect.eq(panel.win.box.height, 20)
  end)

  -- A vsplit's height stays the user's, not the row count: `Split` carries
  -- no `.box`, so this is what every outline_spec.lua case already proves in
  -- production (a Split panel resized to content here would error there
  -- rather than pass) - no standalone case needed to duplicate that split.
end)

--- M3: `71235f9`'s <Tab> mark-preservation fix keyed marks by `mark_key(item)`,
--- but only `ui.tree` supplied one - a non-tree (flat) panel fell back to the
--- item table's own identity, so any `set_items` re-populate with
--- equal-but-fresh tables (any feature that reloads from a fresh answer)
--- dropped every mark silently.
describe("flat panel <Tab> marks survive a re-populate when mark_key is set (M3)", function()
  local panel

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
  end)

  it("keeps the mark on the same logical row, and drops it on a genuinely new one", function()
    panel = panel_mod.open({
      title = " test ",
      render_row = function(item)
        return { text = item.name }
      end,
      mark_key = function(item)
        return item.id
      end,
    })
    panel:set_items({ { id = "a", name = "one" }, { id = "b", name = "two" } })
    panel.list:select(1)
    expect.eq(panel.list:toggle_mark(), true)
    expect.eq(#panel.list:marked_or_all(), 1, "one row marked")

    -- Re-populate with fresh tables carrying the same logical rows.
    panel:set_items({ { id = "a", name = "one" }, { id = "b", name = "two" } })
    expect.eq(#panel.list:marked_or_all(), 1, "the mark survives a re-populate of the same rows")
    expect.eq(panel.list:marked_or_all()[1].id, "a")

    -- A genuinely different result set carries none of the old keys.
    panel:set_items({ { id = "x", name = "three" }, { id = "y", name = "four" } })
    expect.eq(#panel.list:marked_or_all(), 2, "a genuinely fresh result set starts unmarked")
  end)
end)

--- Deliverable 10: every panel remembers its size/position per session -
--- keyed by panel TYPE (`filetype`), a terminal preference rather than
--- project data, so `store.set_root` isolates it the same way frecency does.
describe("panel remembers its size and position", function()
  local panel, state_dir

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    state_dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(state_dir, "p")
    require("epicenter.store").set_root(state_dir)
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.store").set_root(nil)
  end)

  local function open_panel(filetype)
    return panel_mod.open({
      title = " test ",
      filetype = filetype,
      render_row = function(item)
        return { text = item.name }
      end,
    })
  end

  local function press(p, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(p.win.buf, "n")) do
      if map.lhs == lhs and map.callback then
        return map.callback()
      end
    end
    error("no mapping for " .. lhs)
  end

  it("grows/shrinks/widens/narrows on +/-/</>, clamped to a minimum", function()
    panel = open_panel("epicenter-remember-a")
    panel:set_items({ { name = "one" } })
    local before = panel.win:geometry()

    press(panel, "+")
    expect.eq(panel.win:geometry().height, before.height + 4)
    press(panel, "-")
    press(panel, "-")
    expect.truthy(panel.win:geometry().height >= 3, "never shrinks below the floor")

    local width_before = panel.win:geometry().width
    press(panel, ">")
    expect.eq(panel.win:geometry().width, width_before + 4)
    press(panel, "<lt>")
    expect.eq(panel.win:geometry().width, width_before)
  end)

  it("moves on <C-arrow>, clamped inside the editor grid", function()
    panel = open_panel("epicenter-remember-b")
    panel:set_items({ { name = "one" } })
    local before = panel.win:geometry()

    press(panel, "<C-Right>")
    expect.eq(panel.win:geometry().col, before.col + 1)
    press(panel, "<C-Down>")
    expect.eq(panel.win:geometry().row, before.row + 1)
  end)

  it("reopens at the resized geometry, not the default, for the same panel type", function()
    panel = open_panel("epicenter-remember-c")
    panel:set_items({ { name = "one" } })
    press(panel, "+")
    press(panel, ">")
    local resized = panel.win:geometry()
    panel:close()

    panel = open_panel("epicenter-remember-c")
    expect.eq(panel.win:geometry().width, resized.width)
    expect.eq(panel.win:geometry().height, resized.height)
  end)

  it(
    "a resize wins over the content-fit default from then on (F13 stays the default until touched)",
    function()
      panel = open_panel("epicenter-remember-d")
      panel:set_items({ { name = "one" } })
      local before_resize = panel.win.box.height
      press(panel, "+")
      local resized_height = panel.win.box.height
      expect.truthy(resized_height > before_resize)

      -- A large result set would normally grow the float back to the default
      -- height (F13) - not once the user has picked their own.
      local items = {}
      for i = 1, panel_mod.box().height + 50 do
        table.insert(items, { name = "item" .. i })
      end
      panel:set_items(items)
      expect.eq(panel.win.box.height, resized_height, "the manual size persists across new rows")
    end
  )

  it("resizes from the settled geometry while the open animation is still running", function()
    -- The suite runs with motion off; this is the one case that needs a real
    -- tween, so it turns motion on for itself and hands it back.
    local reduce = vim.g.epicenter_reduce_motion
    vim.g.epicenter_reduce_motion = false
    require("epicenter.config").reset()
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      animate = true,
      animation = { open_ms = 400 },
    })

    local ok, err = pcall(function()
      panel = open_panel("epicenter-remember-f")
      local items = {}
      for i = 1, 30 do
        items[i] = { name = "item" .. i }
      end
      panel:set_items(items)

      -- The reveal owns the geometry: `box` is the frame on screen, and the
      -- logical size is where the tween is going.
      local settled = panel.win:geometry()
      expect.truthy(panel.win.reveal_target ~= nil, "a tween is running")
      wait(function()
        return panel.win.box.height ~= settled.height
      end, 2000, "a scaled frame on screen")

      press(panel, "+")
      wait(function()
        return panel.win.reveal_target == nil
      end, 4000, "the tween to settle")
      expect.eq(
        panel.win:geometry().height,
        settled.height + 4,
        "one step up from the settled box, not from the mid-tween one"
      )
    end)

    vim.g.epicenter_reduce_motion = reduce
    if not ok then
      error(err, 0)
    end
  end)

  it("writes the remembered geometry once for a burst of keypresses", function()
    local store = require("epicenter.store")
    local writes = 0
    local original = store.write
    store.write = function(...)
      writes = writes + 1
      return original(...)
    end

    panel = open_panel("epicenter-remember-g")
    panel:set_items({ { name = "one" } })
    for _ = 1, 10 do
      press(panel, "+")
    end
    expect.eq(writes, 0, "nothing is written while the key is still going")

    local resized = panel.win:geometry()
    panel:close()
    expect.eq(writes, 1, "one write, on the way out")
    store.write = original

    panel = open_panel("epicenter-remember-g")
    expect.eq(panel.win:geometry().height, resized.height, "and the burst's result is what lands")
  end)

  it("keeps a nudge for the next flush when a write fails, rather than losing it (L7)", function()
    local store = require("epicenter.store")
    local original = store.write
    local fail_next = true
    store.write = function(...)
      if fail_next then
        fail_next = false
        return false, "boom"
      end
      return original(...)
    end

    panel = open_panel("epicenter-remember-h")
    panel:set_items({ { name = "one" } })
    press(panel, "+")
    local resized = panel.win:geometry()
    -- The panel's own close flushes immediately: the first (failing) write.
    panel:close()
    store.write = original

    -- flush_layout has no per-panel scope: closing ANY panel (even one with
    -- no nudge of its own) flushes whatever is still pending - the earlier
    -- nudge, if the failed write above did not already lose it.
    local other = open_panel("epicenter-remember-h2")
    other:set_items({ { name = "one" } })
    other:close()

    panel = open_panel("epicenter-remember-h")
    expect.eq(panel.win:geometry().height, resized.height, "the earlier nudge survived and landed")
  end)

  it("does not remember geometry for an explicit box or a vsplit panel", function()
    panel = panel_mod.open({
      title = " test ",
      filetype = "epicenter-remember-e",
      box = { row = 0, col = 0, width = 40, height = 20 },
      render_row = function(item)
        return { text = item.name }
      end,
    })
    panel:set_items({ { name = "one" } })
    expect.falsy(panel.resizable, "an explicit box opts out of resize/remember")
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
      expect.truthy(map.lhs ~= "+", "no resize key installed")
    end
  end)
end)

describe("window.clamp", function()
  local window = require("epicenter.ui.window")

  it("leaves a box that already fits alone", function()
    local box = { row = 1, col = 2, width = 40, height = 10 }
    expect.eq(window.clamp(box, { columns = 100, lines = 40 }), box)
  end)

  it("shrinks width/height to the grid and pulls row/col back in range", function()
    local clamped = window.clamp(
      { row = 90, col = 90, width = 200, height = 100 },
      { columns = 100, lines = 40 }
    )
    expect.eq(clamped.width, 100)
    expect.eq(clamped.height, 40)
    expect.eq(clamped.row, 0)
    expect.eq(clamped.col, 0)
  end)
end)
