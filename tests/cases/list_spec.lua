local list = require("epicenter.ui.list")

local function render_item(item)
  return { text = item.name, spans = { { hl = "EpicenterMatch", from = 0, to = 1 } } }
end

local function items(n)
  local out = {}
  for i = 1, n do
    table.insert(out, { name = ("item%02d"):format(i) })
  end
  return out
end

describe("list scrolling", function()
  it("keeps the top at 1 while the selection fits", function()
    expect.eq(list.scroll(100, 10, 1, 1), 1)
    expect.eq(list.scroll(100, 10, 10, 1), 1)
  end)

  it("scrolls down just enough to keep the selection visible", function()
    expect.eq(list.scroll(100, 10, 11, 1), 2)
    expect.eq(list.scroll(100, 10, 50, 1), 41)
  end)

  it("scrolls back up when the selection moves above the viewport", function()
    expect.eq(list.scroll(100, 10, 5, 20), 5)
  end)

  it("never scrolls past the end", function()
    expect.eq(list.scroll(12, 10, 12, 99), 3)
    expect.eq(list.scroll(5, 10, 5, 1), 1, "a short list never scrolls")
  end)

  it("handles an empty list", function()
    expect.eq(list.scroll(0, 10, 1, 1), 1)
  end)
end)

describe("list rendering", function()
  it("renders only the visible slice", function()
    local rendered = list.render({
      items = items(50),
      top = 11,
      height = 3,
      selected = 12,
      render_item = render_item,
    })
    expect.eq(rendered.lines, { "item11", "item12", "item13" })
    expect.eq(rendered.selected_row, 1, "row is relative to the viewport")
  end)

  it("offsets highlight spans to the visible row", function()
    local rendered = list.render({
      items = items(4),
      top = 3,
      height = 2,
      selected = 3,
      render_item = render_item,
    })
    expect.eq(rendered.spans, {
      { row = 0, hl = "EpicenterMatch", from = 0, to = 1 },
      { row = 1, hl = "EpicenterMatch", from = 0, to = 1 },
    })
  end)

  it("reports no selected row when the selection is off screen", function()
    local rendered = list.render({
      items = items(50),
      top = 1,
      height = 3,
      selected = 40,
      render_item = render_item,
    })
    expect.eq(rendered.selected_row, nil)
  end)

  it("shows the empty text for an empty list", function()
    local rendered = list.render({
      items = {},
      top = 1,
      height = 5,
      empty_text = "  nothing",
      render_item = render_item,
    })
    expect.eq(rendered.lines, { "  nothing" })
    expect.eq(rendered.spans, {})
  end)
end)

describe("list object", function()
  local buf, l

  before_each(function()
    require("epicenter.config").reset()
    buf = vim.api.nvim_create_buf(false, true)
    l = list.new({
      buf = buf,
      height = 4,
      render_item = render_item,
      text_of = function(item)
        return item.name
      end,
    })
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("wraps at both ends when moving", function()
    l:set_items(items(3))
    expect.eq(l:index(), 1)
    l:move(-1)
    expect.eq(l:index(), 3, "moving up from the top wraps to the bottom")
    l:move(1)
    expect.eq(l:index(), 1)
  end)

  it("does nothing on an empty list", function()
    l:set_items({})
    l:move(1)
    expect.eq(l:current(), nil)
  end)

  it("filters by substring, case-insensitively", function()
    l:set_items({ { name = "Alpha" }, { name = "beta" }, { name = "gamma" } })
    l:set_filter("AL")
    expect.eq(
      vim.tbl_map(function(i)
        return i.name
      end, l:items()),
      { "Alpha" }
    )
    expect.eq(l:index(), 1, "filtering resets the selection")
    l:set_filter("")
    expect.eq(l:count(), 3)
  end)

  it("clamps the selection when the item list shrinks", function()
    l:set_items(items(10))
    l:select(9)
    l:set_items(items(3))
    expect.truthy(l:index() <= 3)
  end)

  it("writes the visible slice and the selection highlight into the buffer", function()
    l:set_items(items(10))
    l:select(6)
    l:draw()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    expect.eq(#lines, 4, "only the viewport is written")
    expect.eq(lines[#lines], "item06")
    local marks = vim.api.nvim_buf_get_extmarks(buf, l.ns, 0, -1, { details = true })
    local has_selection = false
    for _, mark in ipairs(marks) do
      if mark[4].line_hl_group == "EpicenterSelection" then
        has_selection = true
      end
    end
    expect.eq(has_selection, true)
  end)

  it("stagger-reveals only the first draw, then renders later ones at full height", function()
    local saved_reduce = vim.g.epicenter_reduce_motion
    vim.g.epicenter_reduce_motion = false
    require("epicenter.config").setup({ animate = true })

    l:set_items(items(10))
    l:draw({ stagger = true })
    local first = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    expect.eq(#first, 1, "the first paint starts the reveal at one row")

    local settled = vim.wait(500, function()
      return l.reveal == nil
    end)
    expect.truthy(settled, "the first reveal must finish")

    -- A later result set (a keystroke while the palette is already open)
    -- must not collapse-and-regrow again - that was F8.
    l:set_items(items(10))
    l:draw({ stagger = true })
    local second = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    expect.eq(#second, 4, "a later result set renders at full height immediately")

    vim.g.epicenter_reduce_motion = saved_reduce
  end)
end)
