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
        expect.truthy(
          boxes.prompt.width > 0 and boxes.results.width > 0,
          ("width %d"):format(width)
        )
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

--- M3: `71235f9`'s <Tab> mark-preservation fix keyed marks by `mark_key(item)`,
--- but only `ui.tree` supplied one - a palette fell back to the item table's
--- own identity, so any re-populate with equal-but-fresh tables (a live
--- source answers fresh every time) dropped every mark silently.
describe("palette <Tab> marks survive a re-populate when mark_key is set (M3)", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ animate = false, ui = { icons = "ascii" } })
  end)

  --- Same three logical rows, a fresh table each time `source` answers -
  --- exactly what a live search does on every keystroke.
  local function three_rows()
    return { { id = "a" }, { id = "b" }, { id = "c" } }
  end

  it("keeps the mark on the same logical row, and drops it on a genuinely new one", function()
    local p = palette.open({
      title = " test ",
      source = function(_, _, cb)
        cb(nil, three_rows(), 3)
      end,
      render_item = function(item)
        return { text = item.id }
      end,
      mark_key = function(item)
        return item.id
      end,
      empty_text = "  no matches",
    })
    p:query("x")
    vim.wait(50, function()
      return p.list:count() == 3
    end)

    p.list:select(1)
    expect.eq(p.list:toggle_mark(), true)
    expect.eq(#p.list:marked_or_all(), 1, "one row marked")

    -- Re-populate with fresh tables carrying the same logical rows (id "a").
    -- The count stays 3 either way, so this waits unconditionally rather
    -- than on a predicate that was already true before the refresh ran.
    p:refresh()
    vim.wait(50)
    expect.eq(#p.list:marked_or_all(), 1, "the mark survives a re-populate of the same rows")
    expect.eq(p.list:marked_or_all()[1].id, "a")

    -- A genuinely different result set carries none of the old keys.
    p.spec.source = function(_, _, cb)
      cb(nil, { { id = "x" }, { id = "y" } }, 2)
    end
    p:refresh()
    vim.wait(50, function()
      return p.list:count() == 2
    end)
    expect.eq(#p.list:marked_or_all(), 2, "a genuinely fresh result set starts unmarked")
    p:close()
  end)
end)

--- M4: an armed --qf/--loc used to hijack every ACTIONS entry (`<CR>`,
--- `<C-t>`, `<C-v>`, `<C-x>`) - `Palette:accept` exported whenever
--- `armed_export` was set, regardless of which key sent it there. Both the
--- footer and the README/vimdoc promise `<CR>` only.
describe("an armed export claims <CR> only (M4)", function()
  local qf = require("epicenter.ui.qf")
  local original_send

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ animate = false, ui = { icons = "ascii" } })
    original_send = qf.send_and_notify
  end)

  after_each(function()
    qf.send_and_notify = original_send
  end)

  local function armed_palette(on_accept)
    local p = palette.open({
      title = " test ",
      source = function(_, _, cb)
        cb(nil, { { id = "a" } }, 1)
      end,
      render_item = function(item)
        return { text = item.id }
      end,
      on_accept = on_accept,
      empty_text = "  no matches",
    })
    p:arm_export("quickfix")
    p:query("x")
    vim.wait(50)
    return p
  end

  it("exports on <CR> (a nil or 'edit' action)", function()
    local sent = 0
    qf.send_and_notify = function()
      sent = sent + 1
    end
    local accepted = 0
    local p = armed_palette(function()
      accepted = accepted + 1
    end)

    p:accept("edit")
    vim.wait(20)

    expect.eq(sent, 1, "the armed export ran")
    expect.eq(accepted, 0, "on_accept must not also run")
  end)

  for _, action in ipairs({ "tab", "vsplit", "split" }) do
    it(("keeps its normal meaning: <%s> still opens the row, not export"):format(action), function()
      local sent = 0
      qf.send_and_notify = function()
        sent = sent + 1
      end
      local accepted, accepted_action = 0, nil
      local p = armed_palette(function(_item, act)
        accepted, accepted_action = accepted + 1, act
      end)

      p:accept(action)
      vim.wait(20)

      expect.eq(sent, 0, "an armed export must not hijack " .. action)
      expect.eq(accepted, 1, "the row still opens")
      expect.eq(accepted_action, action)
    end)
  end
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
    p:close()
  end)

  -- D2: the pane used to stay gone for the rest of the palette's life once
  -- dropped, even after a resize gave it room back.
  it("restores the preview pane once a resize gives it room back (#D2)", function()
    local p = open_wide()
    expect.truthy(p.preview_win ~= nil, "opens wide with a preview pane")

    p.columns = 60
    p:reflow()
    expect.eq(p.preview_win, nil, "dropped below the threshold")

    p.columns = 160
    p:reflow()
    expect.truthy(p.preview_win ~= nil, "the pane returns once there's room again")
    expect.truthy(p.preview ~= nil)
    expect.truthy(p.preview_win:valid())

    -- Back down and up again: a drop/restore cycle must not accumulate
    -- stale windows or break on repetition.
    p.columns = 60
    p:reflow()
    p.columns = 160
    p:reflow()
    expect.truthy(p.preview_win ~= nil and p.preview_win:valid())
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
