--- Turns a `tmux capture-pane -p -e` grid into one standalone SVG.
---
---   nvim -l scripts/ansi2svg.lua <capture.ans> <out.svg> [fg] [bg]
---
--- `fg`/`bg` are the terminal's default colours (what SGR 39/49 mean), which
--- the capture itself does not carry - `scripts/screenshots.sh` reads them
--- from the colourscheme's Normal group.
---
--- Only the SGR subset tmux emits is interpreted. Any other escape sequence is
--- dropped rather than passed through, so nothing unhandled reaches the SVG.

-- Whole numbers: every glyph carries its own x, and integers keep those lists
-- short. 15px monospace advances ~9px, so the grid matches the natural font.
local CELL_W, CELL_H = 9, 20
local FONT_SIZE, BASELINE = 15, 15
local FONT = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'DejaVu Sans Mono', monospace"

--- The 16 ANSI colours, as a terminal with a dark palette renders them.
local ANSI16 = {
  "#1c1c1c",
  "#cc5555",
  "#5faf5f",
  "#d7af5f",
  "#5f87d7",
  "#af87d7",
  "#5fafaf",
  "#c7c7c7",
  "#767676",
  "#e57373",
  "#87d787",
  "#ffd787",
  "#87afff",
  "#d7afff",
  "#87d7d7",
  "#eeeeee",
}

local CUBE = { 0, 95, 135, 175, 215, 255 }

--- xterm-256 index to `#rrggbb`.
local function xterm(n)
  if n < 16 then
    return ANSI16[n + 1]
  end
  if n < 232 then
    local i = n - 16
    return ("#%02x%02x%02x"):format(
      CUBE[math.floor(i / 36) % 6 + 1],
      CUBE[math.floor(i / 6) % 6 + 1],
      CUBE[i % 6 + 1]
    )
  end
  local grey = 8 + (n - 232) * 10
  return ("#%02x%02x%02x"):format(grey, grey, grey)
end

--- Applies one SGR parameter list to `style`, in place.
local function apply_sgr(style, params)
  local codes = {}
  for code in params:gmatch("[^;]+") do
    table.insert(codes, tonumber(code) or 0)
  end
  if #codes == 0 then
    codes = { 0 }
  end

  local i = 1
  while i <= #codes do
    local code = codes[i]
    if code == 0 then
      style.fg, style.bg, style.bold, style.italic, style.underline, style.reverse =
        nil, nil, false, false, false, false
    elseif code == 1 then
      style.bold = true
    elseif code == 3 then
      style.italic = true
    elseif code == 4 then
      style.underline = true
    elseif code == 7 then
      style.reverse = true
    elseif code == 22 then
      style.bold = false
    elseif code == 23 then
      style.italic = false
    elseif code == 24 then
      style.underline = false
    elseif code == 27 then
      style.reverse = false
    elseif code >= 30 and code <= 37 then
      style.fg = ANSI16[code - 30 + 1]
    elseif code == 39 then
      style.fg = nil
    elseif code >= 40 and code <= 47 then
      style.bg = ANSI16[code - 40 + 1]
    elseif code == 49 then
      style.bg = nil
    elseif code >= 90 and code <= 97 then
      style.fg = ANSI16[code - 90 + 9]
    elseif code >= 100 and code <= 107 then
      style.bg = ANSI16[code - 100 + 9]
    elseif code == 38 or code == 48 then
      local key = code == 38 and "fg" or "bg"
      if codes[i + 1] == 5 then
        style[key] = xterm(codes[i + 2] or 0)
        i = i + 2
      elseif codes[i + 1] == 2 then
        style[key] = ("#%02x%02x%02x"):format(
          codes[i + 2] or 0,
          codes[i + 3] or 0,
          codes[i + 4] or 0
        )
        i = i + 4
      end
    end
    i = i + 1
  end
end

--- One cell per display column, so a run's x position is its column.
--- Wide characters occupy one cell here; the grid tmux captured already
--- accounts for their width by leaving the next column empty.
local function cells_of(line)
  local cells = {}
  local style = { bold = false, italic = false, underline = false, reverse = false }
  local i = 1
  while i <= #line do
    local escape_start, escape_end, params = line:find("\27%[([0-9;]*)m", i)
    if escape_start == i then
      apply_sgr(style, params)
      i = escape_end + 1
    else
      local other_start, other_end = line:find("\27%[[0-9;?]*[A-Za-z]", i)
      if other_start == i then
        i = other_end + 1
      else
        local next_escape = escape_start or other_start
        local chunk = line:sub(i, (next_escape and next_escape - 1) or #line)
        for _, char in ipairs(vim.fn.split(chunk, "\\zs")) do
          table.insert(cells, {
            char = char,
            fg = style.fg,
            bg = style.bg,
            bold = style.bold,
            italic = style.italic,
            underline = style.underline,
            reverse = style.reverse,
          })
        end
        i = i + #chunk
      end
    end
  end
  return cells
end

local function same_style(a, b)
  return a.fg == b.fg
    and a.bg == b.bg
    and a.bold == b.bold
    and a.italic == b.italic
    and a.underline == b.underline
    and a.reverse == b.reverse
end

--- Splits a row of cells into maximal same-style runs.
local function runs_of(cells)
  local runs = {}
  for column, cell in ipairs(cells) do
    local last = runs[#runs]
    if last and same_style(last.style, cell) and last.column + #last.chars == column then
      table.insert(last.chars, cell.char)
    else
      table.insert(runs, { column = column, chars = { cell.char }, style = cell })
    end
  end
  return runs
end

local ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }

local function xml_escape(text)
  return (text:gsub("[&<>]", ESCAPES))
end

local function svg(rows, defaults)
  local columns = 0
  for _, cells in ipairs(rows) do
    columns = math.max(columns, #cells)
  end
  local width = math.max(columns, 1) * CELL_W
  local height = #rows * CELL_H

  local out = {
    -- xml:space="preserve": without it XML collapses the runs of spaces the
    -- grid is made of, and every glyph after one lands a column short.
    ('<svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" viewBox="0 0 %d %d" width="%d" height="%d" font-family="%s" font-size="%d">'):format(
      width,
      height,
      width,
      height,
      FONT,
      FONT_SIZE
    ),
    ('<rect width="%d" height="%d" fill="%s"/>'):format(width, height, defaults.bg),
  }

  for index, cells in ipairs(rows) do
    local y = (index - 1) * CELL_H
    for _, run in ipairs(runs_of(cells)) do
      local style = run.style
      local fg = style.fg or defaults.fg
      local bg = style.bg or defaults.bg
      if style.reverse then
        fg, bg = bg, fg
      end
      local x = (run.column - 1) * CELL_W
      local run_width = #run.chars * CELL_W
      local text = table.concat(run.chars)

      if bg ~= defaults.bg then
        table.insert(
          out,
          ('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>'):format(
            x,
            y,
            run_width,
            CELL_H,
            bg
          )
        )
      end
      if text:match("^%s*$") == nil then
        -- One x per glyph, rather than one per run plus a textLength: the grid
        -- then survives a renderer whose monospace advance is not CELL_W, and
        -- librsvg does not honour textLength at all.
        local xs = {}
        for column = run.column, run.column + #run.chars - 1 do
          table.insert(xs, tostring((column - 1) * CELL_W))
        end
        local attrs = ('x="%s" y="%d" fill="%s"'):format(table.concat(xs, " "), y + BASELINE, fg)
        if style.bold then
          attrs = attrs .. ' font-weight="bold"'
        end
        if style.italic then
          attrs = attrs .. ' font-style="italic"'
        end
        if style.underline then
          attrs = attrs .. ' text-decoration="underline"'
        end
        table.insert(out, ("<text %s>%s</text>"):format(attrs, xml_escape(text)))
      end
    end
  end

  table.insert(out, "</svg>")
  return table.concat(out, "\n") .. "\n"
end

local args = _G.arg or {}
local source = assert(args[1], "usage: ansi2svg.lua <capture.ans> <out.svg> [fg] [bg]")
local target = assert(args[2], "usage: ansi2svg.lua <capture.ans> <out.svg> [fg] [bg]")
local defaults = { fg = args[3] or "#d0d0d0", bg = args[4] or "#1c1c1c" }

local input = assert(io.open(source, "r"), "cannot read " .. source)
local rows = {}
for line in input:lines() do
  table.insert(rows, cells_of((line:gsub("\r$", ""))))
end
input:close()
assert(#rows > 0, source .. " is empty")

local output = assert(io.open(target, "w"), "cannot write " .. target)
output:write(svg(rows, defaults))
output:close()
