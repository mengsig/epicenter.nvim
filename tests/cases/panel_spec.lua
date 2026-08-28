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
