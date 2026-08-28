local toast = require("epicenter.ui.toast")

describe("toast maths", function()
  it("draws a progress bar", function()
    expect.eq(toast.bar(0, 10, "#", "-"), "----------")
    expect.eq(toast.bar(1, 10, "#", "-"), "##########")
    expect.eq(toast.bar(0.5, 10, "#", "-"), "#####-----")
  end)

  it("clamps a bar fraction", function()
    expect.eq(toast.bar(-1, 4, "#", "-"), "----")
    expect.eq(toast.bar(2, 4, "#", "-"), "####")
    expect.eq(toast.bar(nil, 4, "#", "-"), "----")
  end)

  it("stacks upward from the bottom right", function()
    local boxes = toast.layout({ 1, 2 }, 100, 40, 20)
    expect.eq(#boxes, 2)
    expect.eq(boxes[2].col, 78, "flush to the right edge")
    expect.eq(boxes[1].col, 78)
    expect.eq(boxes[2].row, 36, "the newest toast sits lowest")
    expect.eq(boxes[1].row, 33, "older toasts stack above it, clear of its border")
    expect.truthy(boxes[1].row + boxes[1].height + 1 < boxes[2].row, "stacked toasts never overlap")
  end)

  it("never places a toast off screen", function()
    local boxes = toast.layout({ 5, 5, 5, 5, 5, 5, 5, 5 }, 30, 10, 20)
    for _, box in ipairs(boxes) do
      expect.truthy(box.row >= 0)
      expect.truthy(box.col >= 0)
    end
  end)
end)

--- Every live toast's rendered text. Toasts are floats carrying their own
--- filetype, which is the only handle a caller has on their content.
local function toast_text()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "epicenter-toast" then
      table.insert(out, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    end
  end
  return table.concat(out, "\n")
end

describe("toast stack", function()
  before_each(function()
    require("epicenter.config").reset()
    toast.clear()
  end)

  after_each(function()
    toast.clear()
  end)

  it("shows and dismisses a notice", function()
    local handle = toast.notify("indexing finished", { level = "info", timeout = 60000 })
    expect.eq(toast.count(), 1)
    handle.dismiss()
    expect.eq(toast.count(), 0)
  end)

  it("keeps several notices stacked", function()
    toast.notify("one", { timeout = 60000 })
    toast.notify("two", { timeout = 60000 })
    expect.eq(toast.count(), 2)
    toast.clear()
    expect.eq(toast.count(), 0)
  end)

  it("auto-dismisses after the timeout", function()
    toast.notify("brief", { timeout = 10 })
    wait(function()
      return toast.count() == 0
    end, 2000, "auto dismiss")
  end)

  it("names the log file on an error, so the cause is findable", function()
    toast.notify("navgraph stopped after 3 restarts", { level = "error", timeout = 60000 })
    expect.matches(toast_text(), vim.pesc(require("epicenter.log").path()))
  end)

  it("leaves an error that already names the log alone", function()
    local path = require("epicenter.log").path()
    toast.notify("cannot open log " .. path, { level = "error", timeout = 60000 })
    local text = toast_text()
    local _, occurrences = text:gsub(vim.pesc(path), "")
    expect.eq(occurrences, 1, "the log path must not be repeated")
  end)

  it("does not name the log on an ordinary notice", function()
    toast.notify("yanked app/server.lua:9", { timeout = 60000 })
    expect.falsy(toast_text():find(require("epicenter.log").path(), 1, true))
  end)

  it("holds a progress toast open until it finishes", function()
    local p = toast.progress("building navgraph")
    expect.eq(toast.count(), 1)
    p.update(0.5, "compiling")
    expect.eq(toast.count(), 1)
    p.finish()
    expect.eq(toast.count(), 0)
  end)
end)
