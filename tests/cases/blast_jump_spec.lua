--- Jumping out of a panel or a card with motion ON. With animation off a
--- window closes inside the call that asks for it, which hides the ordering
--- bug entirely: the jump must restore the window it is jumping into BEFORE
--- `:edit`, or it lands in - or fails against - the floating window that is
--- still fading out.
local epicenter = require("epicenter")
local support = require("support")

describe("jumping while a panel is animating", function()
  local root, buf, saved, panel, card

  before_each(function()
    saved = vim.g.epicenter_reduce_motion
    vim.g.epicenter_reduce_motion = nil
    require("epicenter.config").reset()
    -- start_fake() below is the only server this suite needs; auto_start
    -- makes its independence from the host's own navgraph explicit (F2).
    epicenter.setup({ ui = { icons = "ascii" }, animate = true, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    expect.truthy(require("epicenter.config").motion_enabled(), "motion is on for these")

    root = root or support.start_fake()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    -- Column 12 is inside `handle_request` on `function M.handle_request(...)`.
    -- The column matters: navgraph resolves the identifier under it and
    -- nothing off one, so a hover at column 0 ("function") has no symbol.
    vim.api.nvim_win_set_cursor(0, { 9, 12 })
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    for _, open in ipairs({ panel, card }) do
      if open then
        open:close()
      end
    end
    panel, card = nil, nil
    vim.g.epicenter_reduce_motion = saved
    require("epicenter.events").clear()
  end)

  it("lands a panel jump in the code window, not in the float", function()
    panel = epicenter.run("blast", { "M.handle_request" }, buf)
    wait(function()
      return panel.answered > 0 and #panel.nodes > 0
    end, 10000, "the blast result")
    expect.eq(vim.api.nvim_get_current_win(), panel.surface.win, "the panel holds the cursor")

    panel:jump()

    expect.ne(vim.api.nvim_get_current_win(), panel.surface.win)
    expect.eq(vim.api.nvim_win_get_config(0).relative, "", "the jump landed in a real window")
    expect.matches(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), "server%.lua$")
    expect.eq(vim.api.nvim_win_get_cursor(0)[1], 14)
    expect.matches(vim.api.nvim_get_current_line(), "function M%.start")
  end)

  it("lands a hover jump although the card is still fading out", function()
    card = epicenter.run("hover", {}, buf)
    wait(function()
      return card.answered > 0
    end, 10000, "the hover answer")

    -- Step into the card, the way `K` twice does, so the float owns the cursor
    -- when the jump closes it.
    epicenter.run("hover", {}, buf)
    expect.eq(vim.api.nvim_get_current_win(), card.win.win)

    local jumping = card
    card = nil
    jumping:jump()

    wait(function()
      return vim.api.nvim_win_get_cursor(0)[1] == 14
    end, 5000, "the jump to M.start")
    expect.eq(vim.api.nvim_win_get_config(0).relative, "", "the jump landed in a real window")
    expect.matches(vim.api.nvim_get_current_line(), "function M%.start")
  end)
end)
