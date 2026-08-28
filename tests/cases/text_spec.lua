local text = require("epicenter.ui.text")

describe("row text fitting (F12)", function()
  it("returns the row unchanged when it already fits", function()
    local shown, middle = text.fit("me place ", "  app/order.py:17", "  2", 40)
    expect.eq(shown, "me place   app/order.py:17  2")
    expect.eq(middle, "  app/order.py:17")
  end)

  it("skips fitting entirely with no width", function()
    local shown = text.fit("head", "middle", "tail", nil)
    expect.eq(shown, "headmiddletail")
  end)

  it("elides the middle from the front, keeping the tail whole", function()
    local head, tail = "me OrderService.place  ", "  ############ 2"
    local middle = "  py_fastapi/app/services/order_service.py:17"
    local shown, shown_middle = text.fit(head, middle, tail, 40)

    expect.truthy(vim.fn.strdisplaywidth(shown) <= 40, "still fits: " .. shown)
    expect.matches(shown, "…", "elided with an ellipsis")
    expect.eq(shown:sub(-#tail), tail, "the trailing field survives whole")
    expect.truthy(vim.startswith(shown_middle, "…"))
  end)

  it("keeps the path's filename over its leading directories", function()
    local shown = text.fit("", "a/b/c/d/order_service.py", "", 20)
    expect.matches(shown, "order_service%.py$", "the filename is what's kept")
  end)

  it("drops the middle entirely rather than going negative on width", function()
    local shown = text.fit("0123456789", "irrelevant/path.py", "  9", 12)
    expect.eq(shown, "0123456789…  9")
  end)
end)
