--- Windows with one creation path and one teardown path: a float, or a
--- vertical split for a surface that must not cover what it is about.
---
--- Geometry is a plain `{ row, col, width, height }` box computed by pure
--- functions, so layout and the scale-in animation are testable without a UI.
local M = {}

local animate = require("epicenter.ui.animate")
local easing = require("epicenter.ui.easing")

local SPLIT_WINHIGHLIGHT = table.concat({
  "Normal:EpicenterNormal",
  "CursorLine:EpicenterSelection",
  "WinBar:EpicenterNormal",
  "WinBarNC:EpicenterNormal",
  "Search:EpicenterMatch",
}, ",")

local WINHIGHLIGHT = table.concat({
  "Normal:EpicenterNormal",
  "NormalFloat:EpicenterNormal",
  "FloatBorder:EpicenterBorder",
  "FloatTitle:EpicenterTitle",
  "FloatFooter:EpicenterHint",
  "CursorLine:EpicenterSelection",
  "Search:EpicenterMatch",
}, ",")

--- @class epicenter.Box
--- @field row integer
--- @field col integer
--- @field width integer
--- @field height integer

local function resolve(value, total, max)
  local n = value <= 1 and math.floor(total * value) or math.floor(value)
  return math.max(1, math.min(n, max or total, total))
end

--- Centered box for the editor grid. Pure.
--- @param opts { width: number, height: number, max_width?: integer,
---   max_height?: integer, columns?: integer, lines?: integer }
--- @return epicenter.Box
function M.box(opts)
  local columns = opts.columns or vim.o.columns
  local lines = opts.lines or (vim.o.lines - vim.o.cmdheight - 1)
  local width = resolve(opts.width, columns, opts.max_width)
  local height = resolve(opts.height, lines, opts.max_height)
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2)),
    col = math.max(0, math.floor((columns - width) / 2)),
  }
end

--- Scales a box about its centre. Pure; used by the open animation.
--- @param box epicenter.Box
--- @param factor number
--- @return epicenter.Box
function M.scale(box, factor)
  local width = math.max(1, math.floor(box.width * factor + 0.5))
  local height = math.max(1, math.floor(box.height * factor + 0.5))
  return {
    width = width,
    height = height,
    row = math.max(0, box.row + math.floor((box.height - height) / 2)),
    col = math.max(0, box.col + math.floor((box.width - width) / 2)),
  }
end

--- Carves a box into left/right panes with a one-column gutter. Pure.
--- @return epicenter.Box, epicenter.Box
function M.split_h(box, left_ratio, gutter)
  gutter = gutter or 2
  local left_width = math.max(1, math.floor((box.width - gutter) * left_ratio))
  local right_width = math.max(1, box.width - gutter - left_width)
  return { row = box.row, col = box.col, width = left_width, height = box.height }, {
    row = box.row,
    col = box.col + left_width + gutter,
    width = right_width,
    height = box.height,
  }
end

--- Stacks a header of `height` rows above the rest. Pure.
--- @return epicenter.Box, epicenter.Box
function M.split_v(box, height, gutter)
  gutter = gutter or 2
  local rest = math.max(1, box.height - height - gutter)
  return { row = box.row, col = box.col, width = box.width, height = height }, {
    row = box.row + height + gutter,
    col = box.col,
    width = box.width,
    height = rest,
  }
end

--- @class epicenter.Window
local Window = {}
Window.__index = Window

--- @param spec { box: epicenter.Box, title?: string, footer?: string,
---   border?: string|table, enter?: boolean, focusable?: boolean, zindex?: integer,
---   winblend?: integer, buf?: integer, filetype?: string, on_close?: fun(),
---   reflow?: fun(): epicenter.Box }
--- @return epicenter.Window
function M.open(spec)
  local cfg = require("epicenter.config").get()
  local box = spec.box
  local border = spec.border or cfg.ui.border

  local owns_buf = spec.buf == nil
  local buf = spec.buf or vim.api.nvim_create_buf(false, true)
  if owns_buf then
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = spec.filetype or "epicenter"
  end

  local config = {
    relative = "editor",
    row = box.row,
    col = box.col,
    width = box.width,
    height = box.height,
    style = "minimal",
    border = border,
    zindex = spec.zindex,
    focusable = spec.focusable ~= false,
    noautocmd = true,
  }
  if border ~= "none" then
    config.title = spec.title
    config.title_pos = spec.title and "center" or nil
    config.footer = spec.footer
    config.footer_pos = spec.footer and "center" or nil
  end

  local win = vim.api.nvim_open_win(buf, spec.enter == true, config)
  vim.wo[win].winhighlight = WINHIGHLIGHT
  vim.wo[win].winblend = spec.winblend or cfg.ui.winblend
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false

  local self = setmetatable({
    buf = buf,
    win = win,
    box = box,
    spec = spec,
    owns_buf = owns_buf,
    closed = false,
    tween = nil,
    reveal_target = nil,
    -- The rows a caller may render into. NOT `box.height` read live: the
    -- reveal tween scales `box` frame by frame, and content that reflowed to
    -- a mid-tween height would settle wrong.
    content = box.height,
  }, Window)

  self.augroup = vim.api.nvim_create_augroup("EpicenterWin" .. win, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(win),
    callback = function()
      self:_cleanup()
    end,
  })
  -- Public UI-kit contract (F4): a caller outside the palette (which owns
  -- its own multi-pane VimResized handler, see Palette:reflow) opts a
  -- standalone float into resize handling by supplying `reflow`.
  if spec.reflow then
    vim.api.nvim_create_autocmd("VimResized", {
      group = self.augroup,
      callback = function()
        -- Reflow in place: a resize never animates.
        self:set_geometry(spec.reflow())
      end,
    })
  end

  return self
end

function Window:valid()
  return not self.closed and vim.api.nvim_win_is_valid(self.win)
end

--- Rows a caller may render into.
function Window:content_height()
  return self.content
end

--- Columns a caller may render into, so row text can fit itself rather than
--- let the window edge silently clip it (F12).
function Window:content_width()
  return self.box.width
end

--- @return epicenter.Box
function Window:geometry()
  return vim.deepcopy(self.box)
end

local function apply_geometry(self, box)
  self.box = box
  vim.api.nvim_win_set_config(self.win, {
    relative = "editor",
    row = box.row,
    col = box.col,
    width = box.width,
    height = box.height,
  })
end

--- @param box epicenter.Box
function Window:set_geometry(box)
  assert(box ~= nil, "Window:set_geometry: box must not be nil")
  if not self:valid() then
    return
  end
  self.content = box.height
  if self.tween and self.reveal_target then
    -- A reveal tween owns the geometry until it settles (F1): retarget the
    -- running tween instead of jumping the window now, which the tween's
    -- own next frame would immediately undo back to its stale target. The
    -- next frame (or `on_done`, if this lands after the last one) applies it.
    self.reveal_target = box
    return
  end
  apply_geometry(self, box)
end

function Window:set_lines(lines)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
end

function Window:set_footer(footer)
  if not self:valid() or (self.spec.border or "") == "none" then
    return
  end
  vim.api.nvim_win_set_config(
    self.win,
    { footer = footer, footer_pos = footer and "center" or nil }
  )
end

function Window:set_title(title)
  if not self:valid() or (self.spec.border or "") == "none" then
    return
  end
  vim.api.nvim_win_set_config(self.win, { title = title, title_pos = title and "center" or nil })
end

function Window:focus()
  if self:valid() then
    vim.api.nvim_set_current_win(self.win)
  end
end

--- Scale-in from `from` (default 0.86) to full size. `self.reveal_target` is
--- the tween's own live target (F1): `set_geometry` retargets it in place
--- rather than fighting the tween's next frame, so a `paint` that lands new
--- content mid-reveal is not immediately undone by a stale captured target.
function Window:reveal(opts)
  opts = opts or {}
  local cfg = require("epicenter.config").get()
  local from = opts.from or 0.86
  self:_stop_tween()
  self.reveal_target = self.box
  -- With motion off the tween finishes inside this call, so only keep the
  -- handle when it is still running.
  local running = true
  local handle = animate.tween({
    duration = opts.duration or cfg.animation.open_ms,
    easing = easing.out_cubic,
    motion = opts.motion,
    on_frame = function(eased)
      apply_geometry(self, M.scale(self.reveal_target, easing.lerp(from, 1, eased)))
    end,
    on_done = function()
      running = false
      apply_geometry(self, self.reveal_target)
      self.tween = nil
      self.reveal_target = nil
      if opts.on_done then
        opts.on_done()
      end
    end,
  })
  self.tween = running and handle or nil
end

function Window:_stop_tween()
  if self.tween then
    self.tween.cancel()
    self.tween = nil
  end
  self.reveal_target = nil
end

--- Fades out, then closes. Cleanup runs exactly once, from `_cleanup`.
function Window:close(opts)
  opts = opts or {}
  if self.closed or not vim.api.nvim_win_is_valid(self.win) then
    self:_cleanup()
    return
  end
  local cfg = require("epicenter.config").get()
  local base = vim.wo[self.win].winblend
  self:_stop_tween()
  local running = true
  local handle = animate.tween({
    duration = opts.duration or cfg.animation.close_ms,
    easing = easing.linear,
    motion = opts.motion,
    on_frame = function(eased)
      if vim.api.nvim_win_is_valid(self.win) then
        vim.wo[self.win].winblend = math.floor(easing.lerp(base, 100, eased))
      end
    end,
    on_done = function()
      running = false
      self.tween = nil
      if vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_close(self.win, true)
      end
      self:_cleanup()
    end,
  })
  self.tween = running and handle or nil
end

--- The single teardown path: reached by `close()` and by `WinClosed`.
function Window:_cleanup()
  if self.closed then
    return
  end
  self.closed = true
  self:_stop_tween()
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if self.owns_buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  if self.spec.on_close then
    self.spec.on_close()
  end
end

--- @class epicenter.Split
--- A window that TAKES space rather than covering it: Vim narrows the source
--- window itself, so nothing is painted over the code (F8). Same surface as
--- `Window` - the panel kit drives either without knowing which it has.
local Split = {}
Split.__index = Split

--- Elides the RIGHT end of `text` down to `width` display columns, keeping
--- its start - the opposite direction from `ui.text.fit`'s path elision,
--- because a winbar title's own left-anchored name (e.g. "outline") is the
--- part worth keeping, not whatever varies after it.
local function elide_right(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local ellipsis = "…"
  local budget = width - vim.fn.strdisplaywidth(ellipsis)
  if budget <= 0 then
    return ""
  end
  local kept = text
  while vim.fn.strdisplaywidth(kept) > budget do
    kept = vim.fn.strcharpart(kept, 0, vim.fn.strchars(kept) - 1)
  end
  return kept .. ellipsis
end

--- A split has no border to hang a title and a footer on; the winbar carries
--- both, title left and footer right. Neovim's own winbar truncation - eaten
--- from the left when the string overflows the window, with no `%<` marker
--- to steer it - used to chew through the title's own fixed name once the
--- footer pushed the combined string over width (D6); `width` lets the
--- title elide itself first instead, keeping its name intact.
--- @param width integer|nil the split's current column width; nil skips fitting
local function winbar_of(title, footer, width)
  local function chunk(text, group)
    if not text or text == "" then
      return ""
    end
    return ("%%#%s#%s%%*"):format(group, (text:gsub("%%", "%%%%")))
  end
  if width then
    local budget = width - vim.fn.strdisplaywidth(footer or "")
    title = elide_right(title or "", math.max(0, budget))
  end
  return chunk(title, "EpicenterTitle") .. "%=" .. chunk(footer, "EpicenterHint")
end

--- @param spec { width: integer, title?: string, footer?: string, filetype?: string,
---   enter?: boolean, on_close?: fun() }
--- @return epicenter.Split
function M.open_split(spec)
  local previous = vim.api.nvim_get_current_win()
  vim.cmd("noautocmd topleft vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, math.max(12, math.min(spec.width, vim.o.columns - 8)))

  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = spec.filetype or "epicenter"
  for option, value in pairs({
    number = false,
    relativenumber = false,
    wrap = false,
    cursorline = false,
    -- Vim keeps the sidebar's width when another window opens or closes.
    winfixwidth = true,
  }) do
    vim.wo[win][option] = value
  end
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winhighlight = SPLIT_WINHIGHLIGHT

  local self = setmetatable({
    buf = buf,
    win = win,
    spec = spec,
    title = spec.title,
    footer = spec.footer,
    closed = false,
  }, Split)
  vim.wo[win].winbar = winbar_of(self.title, self.footer, vim.api.nvim_win_get_width(win))

  self.augroup = vim.api.nvim_create_augroup("EpicenterSplit" .. win, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(win),
    callback = function()
      self:_cleanup()
    end,
  })

  if spec.enter == false and vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  return self
end

function Split:valid()
  return not self.closed and vim.api.nvim_win_is_valid(self.win)
end

function Split:content_height()
  if not self:valid() then
    return 1
  end
  return math.max(1, vim.api.nvim_win_get_height(self.win))
end

function Split:content_width()
  if not self:valid() then
    return 1
  end
  return math.max(1, vim.api.nvim_win_get_width(self.win))
end

Split.set_lines = Window.set_lines
Split.focus = Window.focus

function Split:_paint_winbar()
  if self:valid() then
    vim.wo[self.win].winbar =
      winbar_of(self.title, self.footer, vim.api.nvim_win_get_width(self.win))
  end
end

function Split:set_title(title)
  self.title = title
  self:_paint_winbar()
end

function Split:set_footer(footer)
  self.footer = footer
  self:_paint_winbar()
end

--- A split is already where it belongs the moment it exists; there is nothing
--- to scale in, and animating a real window's width shoves the source text
--- sideways for the whole tween.
function Split:reveal() end

function Split:close()
  if self.closed or not vim.api.nvim_win_is_valid(self.win) then
    return self:_cleanup()
  end
  pcall(vim.api.nvim_win_close, self.win, true)
  self:_cleanup()
end

--- The single teardown path: reached by `close()` and by `WinClosed`.
function Split:_cleanup()
  if self.closed then
    return
  end
  self.closed = true
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  if self.spec.on_close then
    self.spec.on_close()
  end
end

M.Window = Window
M.Split = Split

return M
