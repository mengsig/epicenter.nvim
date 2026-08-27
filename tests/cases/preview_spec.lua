local preview = require("epicenter.ui.preview")

describe("preview short-file and out-of-range edges", function()
  local buf, win, path

  before_each(function()
    require("epicenter.config").reset()
    buf = vim.api.nvim_create_buf(false, true)
    win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 10,
      style = "minimal",
      noautocmd = true,
    })
    path = vim.fn.tempname()
  end)

  after_each(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.fn.delete(path)
  end)

  it("clears instead of throwing when the target line is past the end of the file", function()
    vim.fn.writefile({ "line one", "line two" }, path)
    local p = preview.new({ buf = buf, win = win, height = 10 })

    local ok, err = pcall(function()
      p:show({ path = path, line = 200, end_line = 200 })
    end)
    expect.eq(ok, true, err)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    expect.matches(lines[1], "has no line 200")
    expect.eq(p.shown, nil, "an unshowable target must not be recorded as shown")
  end)

  it("clamps the cursor to the last line instead of erroring, on a short trailing slice", function()
    -- The target line is only 1 past EOF, so read_slice still returns a
    -- non-empty (but short) slice - the #lines == 0 guard alone misses this.
    vim.fn.writefile({ "one", "two", "three", "four", "five" }, path)
    local p = preview.new({ buf = buf, win = win, height = 4 })

    local ok, err = pcall(function()
      p:show({ path = path, line = 6, end_line = 6 })
    end)
    expect.eq(ok, true, err)

    local shown_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(win)
    expect.truthy(cursor[1] <= #shown_lines, "the cursor must stay inside the shown slice")
  end)

  it("still shows a normal target with the cursor on the right line", function()
    vim.fn.writefile({ "one", "two", "three", "four", "five" }, path)
    local p = preview.new({ buf = buf, win = win, height = 10 })
    p:show({ path = path, line = 3, end_line = 3 })
    local cursor = vim.api.nvim_win_get_cursor(win)
    local lines = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)
    expect.eq(lines[1], "three")
  end)
end)
