local window = require("epicenter.ui.window")

describe("window geometry", function()
  it("centres a fractional box on the editor grid", function()
    local box = window.box({ width = 0.5, height = 0.5, columns = 100, lines = 40 })
    expect.eq(box, { width = 50, height = 20, row = 10, col = 25 })
  end)

  it("treats values above 1 as absolute cells", function()
    local box = window.box({ width = 30, height = 10, columns = 100, lines = 40 })
    expect.eq(box.width, 30)
    expect.eq(box.height, 10)
  end)

  it("honours the maximums", function()
    local box = window.box({
      width = 0.9,
      height = 0.9,
      max_width = 40,
      max_height = 12,
      columns = 200,
      lines = 60,
    })
    expect.eq(box.width, 40)
    expect.eq(box.height, 12)
  end)

  it("never produces a box larger than the grid or smaller than one cell", function()
    local box = window.box({ width = 500, height = 500, columns = 20, lines = 10 })
    expect.eq(box.width, 20)
    expect.eq(box.height, 10)
    local tiny = window.box({ width = 0.001, height = 0.001, columns = 20, lines = 10 })
    expect.eq(tiny.width, 1)
    expect.eq(tiny.height, 1)
  end)

  it("scales about the centre", function()
    local box = { row = 10, col = 20, width = 40, height = 20 }
    expect.eq(window.scale(box, 1), box)
    local half = window.scale(box, 0.5)
    expect.eq(half.width, 20)
    expect.eq(half.height, 10)
    expect.eq(half.col, 30, "centre stays put horizontally")
    expect.eq(half.row, 15, "centre stays put vertically")
  end)

  it("keeps a scaled box at least one cell", function()
    local tiny = window.scale({ row = 0, col = 0, width = 4, height = 2 }, 0.01)
    expect.eq(tiny.width, 1)
    expect.eq(tiny.height, 1)
  end)

  it("splits horizontally with a gutter", function()
    local left, right = window.split_h({ row = 1, col = 2, width = 42, height = 10 }, 0.5, 2)
    expect.eq(left, { row = 1, col = 2, width = 20, height = 10 })
    expect.eq(right, { row = 1, col = 24, width = 20, height = 10 })
  end)

  it("splits vertically with a gutter", function()
    local head, body = window.split_v({ row = 1, col = 2, width = 40, height = 20 }, 1, 2)
    expect.eq(head, { row = 1, col = 2, width = 40, height = 1 })
    expect.eq(body, { row = 4, col = 2, width = 40, height = 17 })
  end)
end)

describe("window lifecycle", function()
  before_each(function()
    require("epicenter.config").reset()
  end)

  it("opens, writes lines, and cleans up exactly once", function()
    local closed = 0
    local win = window.open({
      box = window.box({ width = 20, height = 5, columns = 80, lines = 24 }),
      title = " test ",
      on_close = function()
        closed = closed + 1
      end,
    })
    expect.eq(win:valid(), true)
    win:set_lines({ "a", "b" })
    expect.eq(vim.api.nvim_buf_get_lines(win.buf, 0, -1, false), { "a", "b" })
    expect.eq(vim.bo[win.buf].modifiable, false, "panel buffers stay read-only")

    local buf = win.buf
    win:close({ motion = false })
    expect.eq(win:valid(), false)
    expect.eq(closed, 1)
    expect.eq(vim.api.nvim_buf_is_valid(buf), false, "the owned buffer is wiped")

    win:close({ motion = false })
    expect.eq(closed, 1, "cleanup must not run twice")
  end)

  it("routes an external window close through the same cleanup", function()
    local closed = 0
    local win = window.open({
      box = window.box({ width = 20, height = 5, columns = 80, lines = 24 }),
      on_close = function()
        closed = closed + 1
      end,
    })
    vim.api.nvim_win_close(win.win, true)
    expect.eq(closed, 1)
    expect.eq(win:valid(), false)
  end)

  it("reveals to the target geometry with motion off", function()
    local box = window.box({ width = 30, height = 8, columns = 80, lines = 24 })
    local win = window.open({ box = box })
    win:reveal({ motion = false })
    expect.eq(win:geometry(), box)
    local config = vim.api.nvim_win_get_config(win.win)
    expect.eq(config.width, box.width)
    expect.eq(config.height, box.height)
    win:close({ motion = false })
  end)

  it("moves to a new geometry in place", function()
    local win =
      window.open({ box = window.box({ width = 30, height = 8, columns = 80, lines = 24 }) })
    win:set_geometry({ row = 2, col = 3, width = 10, height = 4 })
    local config = vim.api.nvim_win_get_config(win.win)
    expect.eq({ config.width, config.height }, { 10, 4 })
    win:close({ motion = false })
  end)

  it("does nothing on VimResized without spec.reflow", function()
    local win =
      window.open({ box = window.box({ width = 30, height = 8, columns = 80, lines = 24 }) })
    local before = win:geometry()
    vim.api.nvim_exec_autocmds("VimResized", {})
    expect.eq(win:geometry(), before)
    win:close({ motion = false })
  end)

  it("reflows in place on VimResized via spec.reflow, a public UI-kit hook (F4)", function()
    -- `spec.reflow` is the documented contract stacked feature waves build
    -- panels on (README/vimdoc: "epicenter.ui.window is the public contract
    -- for features"); a caller that supplies it must get resize handling.
    local function compute_box()
      return window.box({ width = 20, height = 10, lines = vim.o.lines })
    end
    local win = window.open({ box = compute_box(), reflow = compute_box })
    local before = win:geometry()

    vim.o.lines = 15
    vim.api.nvim_exec_autocmds("VimResized", {})
    local shrunk = compute_box()
    vim.o.lines = 40

    local after = win:geometry()
    expect.ne(after, before, "the window must move to the shrunken geometry")
    expect.eq(after, shrunk, "reflow must be recomputed, not reused stale")
    win:close({ motion = false })
  end)
end)
