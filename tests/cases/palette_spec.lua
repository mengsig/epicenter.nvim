local palette = require("epicenter.ui.palette")

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
end)
