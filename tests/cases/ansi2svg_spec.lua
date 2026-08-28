--- The screenshot converter, driven the way `make screenshots` drives it.
---
--- It is a script, not a module, so the test sets `arg` and runs it - which is
--- also the only entry point it has.
local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")
local converter = vim.fs.joinpath(repo, "scripts", "ansi2svg.lua")

local ESC = "\27["

--- Runs the converter over `lines` and returns the SVG it wrote.
local function convert(lines, fg, bg)
  local source, target = vim.fn.tempname(), vim.fn.tempname()
  vim.fn.writefile(lines, source)
  local saved = _G.arg
  _G.arg = { source, target, fg, bg }
  local ok, err = pcall(dofile, converter)
  _G.arg = saved
  assert(ok, err)
  local svg = table.concat(vim.fn.readfile(target), "\n")
  vim.fn.delete(source)
  vim.fn.delete(target)
  return svg
end

describe("ansi2svg", function()
  it("keeps the grid for both renderers: every glyph placed, every space unbreakable", function()
    local svg = convert({ " ab  cd " })
    -- Trimmed to its ink, so the first x is a real glyph's - librsvg uses only
    -- that one - and every glyph carries its own, which Chromium uses.
    expect.matches(svg, 'x="9 18 27 36 45 54"')
    expect.matches(svg, ">ab&#160;&#160;cd</text>")
    expect.falsy(
      svg:find("> ", 1, true),
      "a plain space in text content is whitespace a renderer may collapse"
    )
  end)

  it("sizes the page from the widest row", function()
    local svg = convert({ "abc", "abcdef" })
    expect.matches(svg, 'width="54"', "6 columns of 9px")
    expect.matches(svg, 'height="40"', "2 rows of 20px")
  end)

  it("reads a 24-bit foreground", function()
    expect.matches(convert({ ESC .. "38;2;255;128;0mhot" }), 'fill="#ff8000"')
  end)

  it("reads a 256-colour foreground from each band of the palette", function()
    expect.matches(convert({ ESC .. "38;5;1mx" }), 'fill="#cc5555"', "the 16 base colours")
    expect.matches(convert({ ESC .. "38;5;196mx" }), 'fill="#ff0000"', "the 6x6x6 cube")
    expect.matches(convert({ ESC .. "38;5;244mx" }), 'fill="#808080"', "the grey ramp")
  end)

  it("paints a background run as a rect, and the default background only once", function()
    local svg = convert({ ESC .. "48;2;20;30;40mx" }, "#ffffff", "#000000")

    expect.matches(svg, '<rect x="0" y="0" width="9" height="20" fill="#141e28"/>')
    local _, page_rects = svg:gsub('<rect width="', "")
    expect.eq(page_rects, 1, "the page background is one rect")
  end)

  it("falls back to the defaults it was handed", function()
    local svg = convert({ "plain" }, "#abcdef", "#123456")
    expect.matches(svg, 'fill="#abcdef"')
    expect.matches(svg, '<rect width="45" height="20" fill="#123456"/>')
  end)

  it("swaps the pair under reverse video", function()
    local svg = convert({ ESC .. "7mx" }, "#abcdef", "#123456")
    expect.matches(svg, 'fill="#123456"', "the foreground becomes the background")
    expect.matches(svg, '<rect x="0" y="0" width="9" height="20" fill="#abcdef"/>')
  end)

  it("resets every attribute on SGR 0", function()
    local svg = convert({ ESC .. "1;38;2;255;0;0mred" .. ESC .. "0mplain" }, "#abcdef", "#000000")
    expect.matches(svg, 'font%-weight="bold"')
    expect.matches(svg, 'fill="#abcdef">plain')
  end)

  it("escapes what would otherwise be markup", function()
    local svg = convert({ "a<b>&c" })
    expect.matches(svg, ">a&lt;b&gt;&amp;c</text>")
    expect.falsy(svg:find(">a<b>", 1, true))
  end)

  it("draws no text for a run that is only whitespace", function()
    local svg = convert({ "   " })
    expect.falsy(svg:find("<text", 1, true), "blank cells are the page background")
  end)

  it("still paints the background of a blank run", function()
    local svg = convert({ ESC .. "48;5;1m   " }, "#ffffff", "#000000")
    expect.matches(svg, '<rect x="0" y="0" width="27" height="20" fill="#cc5555"/>')
    expect.falsy(svg:find("<text", 1, true))
  end)

  it("drops an escape sequence it does not interpret", function()
    local svg = convert({ ESC .. "?25l" .. "visible" })
    expect.matches(svg, ">visible</text>")
    expect.falsy(svg:find("25l", 1, true), "an uninterpreted sequence must not reach the SVG")
  end)

  it("refuses an empty capture instead of writing an empty page", function()
    local source, target = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.writefile({}, source)
    local saved = _G.arg
    _G.arg = { source, target }
    local ok = pcall(dofile, converter)
    _G.arg = saved
    vim.fn.delete(source)
    vim.fn.delete(target)
    expect.falsy(ok, "an empty capture is a failed screenshot, not a blank asset")
  end)
end)
