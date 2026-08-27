local palette = require("epicenter.ui.palette")
local window = require("epicenter.ui.window")

describe("palette layout", function()
  local box = { row = 2, col = 4, width = 100, height = 20 }

  it("stacks a one-line prompt above the body", function()
    local boxes = palette.layout(box, false)
    expect.eq(boxes.prompt.height, 1)
    expect.eq(boxes.prompt.row, 2)
    expect.truthy(
      boxes.results.row > boxes.prompt.row + boxes.prompt.height,
      "panes must clear each other's border"
    )
    expect.eq(boxes.preview, nil)
  end)

  it("puts the preview beside the results when there is room", function()
    local boxes = palette.layout(box, true)
    expect.truthy(boxes.preview ~= nil)
    expect.eq(boxes.results.row, boxes.preview.row)
    expect.truthy(boxes.preview.col > boxes.results.col + boxes.results.width)
    expect.eq(boxes.results.width + boxes.preview.width + 2, box.width)
  end)

  it("drops the preview rather than squeezing it on a narrow editor", function()
    local narrow = palette.layout({ row = 0, col = 0, width = 60, height = 20 }, true)
    expect.eq(narrow.preview, nil)
    expect.eq(narrow.results.width, 60, "results take the full width instead")
  end)

  it("keeps every pane inside the box", function()
    local boxes = palette.layout(box, true)
    for _, pane in pairs(boxes) do
      expect.truthy(pane.row >= box.row)
      expect.truthy(pane.col >= box.col)
      expect.truthy(pane.col + pane.width <= box.col + box.width)
      expect.truthy(pane.row + pane.height <= box.row + box.height)
    end
  end)

  it("yields a valid box set at every width from 40 to 300 (F2)", function()
    for width = 40, 300 do
      local wide = { row = 0, col = 0, width = width, height = 30 }
      for _, want_preview in ipairs({ false, true }) do
        local boxes = palette.layout(wide, want_preview)
        expect.truthy(boxes.prompt ~= nil and boxes.results ~= nil, ("width %d"):format(width))
        expect.truthy(boxes.prompt.width > 0 and boxes.results.width > 0, ("width %d"):format(width))
        if want_preview and width >= 80 then
          expect.truthy(boxes.preview ~= nil, ("width %d should keep a preview"):format(width))
          expect.truthy(boxes.preview.width > 0, ("width %d"):format(width))
        else
          expect.eq(boxes.preview, nil, ("width %d should drop the preview"):format(width))
        end
      end
    end
  end)
end)

describe("palette query staleness", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ animate = false, ui = { icons = "ascii" } })
  end)

  it("drops a slow response for a query a synchronous later query already replaced", function()
    local pending = nil
    local p = palette.open({
      title = " test ",
      -- Mimics grep's empty-query short-circuit: "" answers synchronously,
      -- anything else stays in flight until the test resolves it.
      source = function(query, _, cb)
        if query == "" then
          cb(nil, {}, 0)
        else
          pending = cb
        end
      end,
      render_item = function(item)
        return { text = tostring(item) }
      end,
      empty_text = "  no matches",
    })

    p:query("a")
    expect.truthy(pending ~= nil, "the query for 'a' must still be in flight")
    p:query("") -- backspace: the empty query answers synchronously, in-place

    -- The stale "a" response arrives after the user already cleared the query.
    pending(nil, { "stale-result" }, 1)
    vim.wait(50)

    expect.eq(p.list:count(), 0, "the stale response must not repaint the cleared query")
    p:close()
  end)

  it("does not leave a stale footer total on the error path (F19)", function()
    local fail_next = false
    local p = palette.open({
      title = " test ",
      source = function(_, _, cb)
        if fail_next then
          return cb({ message = "boom" })
        end
        cb(nil, { "a", "b", "c" }, 3)
      end,
      render_item = function(item)
        return { text = tostring(item) }
      end,
      empty_text = "  no matches",
    })
    vim.wait(50, function()
      return p.total ~= nil
    end)
    expect.eq(p.total, 3)

    fail_next = true
    p:query("x")
    vim.wait(50)

    expect.eq(p.total, 0, "an error must not leave the previous query's total behind")
    p:close()
  end)
end)

describe("palette resize across the preview threshold (F2)", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ animate = false, ui = { icons = "ascii" } })
  end)

  local function open_wide()
    -- `columns`/`lines` are the test-only sizing hook `_box` reads instead
    -- of `vim.o.columns` - nvim 0.12 aborts in draw_tabline if a spec
    -- assigns that option while a float is open.
    return palette.open({
      title = " test ",
      columns = 160,
      lines = 40,
      source = function(_, _, cb)
        cb(nil, {}, 0)
      end,
      render_item = function(item)
        return { text = tostring(item) }
      end,
      preview_of = function()
        return nil
      end,
      empty_text = "  no matches",
    })
  end

  it("never crashes reflowing across every width from 40 to 300", function()
    local p = open_wide()
    expect.truthy(p.preview_win ~= nil, "opens wide with a preview pane")

    for width = 300, 40, -1 do
      p.columns = width
      local ok, err = pcall(function()
        p:reflow()
      end)
      expect.truthy(ok, ("reflow crashed at width %d: %s"):format(width, tostring(err)))
    end

    expect.eq(p.preview_win, nil, "settled below the threshold, the pane is dropped")
    expect.eq(p.want_preview, false)
    p:close()
  end)

  it("drops the preview pane, not just its geometry, once it no longer fits", function()
    local p = open_wide()
    local preview_win = p.preview_win
    expect.truthy(preview_win ~= nil)

    p.columns = 60
    p:reflow()

    expect.eq(p.preview_win, nil)
    expect.eq(p.preview, nil)
    expect.falsy(preview_win:valid(), "the dropped window must actually close, not leak")
    p:close()
  end)

  it("skips a transient sub-threshold frame mid open-animation instead of crashing", function()
    local p = open_wide()
    local target = p.box
    expect.truthy(p.preview_win ~= nil)

    -- Mimics an early open-animation frame (palette.lua scales from 0.88):
    -- narrower than the settled target, briefly below the threshold even
    -- though the animation is headed for a size that fits.
    local shrunk = window.scale(target, 0.5)
    local ok, err = pcall(function()
      p:_apply_layout(shrunk)
    end)
    expect.truthy(ok, "a transient sub-threshold frame must not crash: " .. tostring(err))
    expect.truthy(p.preview_win ~= nil, "a transient dip must not drop the pane outright")

    -- The animation always finishes by re-applying the full, fitting target.
    p:_apply_layout(target)
    local boxes = palette.layout(target, p.want_preview)
    expect.eq(p.preview_win:geometry(), boxes.preview)
    expect.truthy(p.preview_win:valid())
    p:close()
  end)
end)

describe("palette replaces the open one instead of stacking (F13)", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ animate = false, ui = { icons = "ascii" } })
  end)

  local function open_test_palette()
    return palette.open({
      title = " test ",
      source = function(_, _, cb)
        cb(nil, {}, 0)
      end,
      render_item = function(item)
        return { text = tostring(item) }
      end,
      empty_text = "  no matches",
    })
  end

  it("closes the first palette on a second open instead of stacking floats", function()
    local wins_before = #vim.api.nvim_list_wins()
    local p1 = open_test_palette()
    local wins_with_one = #vim.api.nvim_list_wins()
    expect.truthy(wins_with_one > wins_before, "opening a palette must add floats")

    -- Mimics a double keypress on the same keymap (F13): a real Palette
    -- object still alive from the previous open.
    local p2 = open_test_palette()

    expect.falsy(p1.open, "the first palette must close, not stay stacked underneath")
    expect.falsy(p1.prompt_win:valid())
    expect.falsy(p1.results_win:valid())
    expect.truthy(p2.open)

    expect.eq(
      #vim.api.nvim_list_wins(),
      wins_with_one,
      "a second open must replace the float count, not add to it"
    )
    p2:close()
    expect.eq(#vim.api.nvim_list_wins(), wins_before, "no floats leak behind")
  end)
end)
