--- Floating windows with one creation path and one teardown path.
---
--- Geometry is a plain `{ row, col, width, height }` box computed by pure
--- functions, so layout and the scale-in animation are testable without a UI.
local M = {}

local animate = require("epicenter.ui.animate")
local easing = require("epicenter.ui.easing")

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

--- @return epicenter.Box
function Window:geometry()
  return vim.deepcopy(self.box)
end

--- @param box epicenter.Box
function Window:set_geometry(box)
  assert(box ~= nil, "Window:set_geometry: box must not be nil")
  if not self:valid() then
    return
  end
  self.box = box
  vim.api.nvim_win_set_config(self.win, {
    relative = "editor",
    row = box.row,
    col = box.col,
    width = box.width,
    height = box.height,
  })
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

--- Scale-in from `from` (default 0.86) to full size.
function Window:reveal(opts)
  opts = opts or {}
  local cfg = require("epicenter.config").get()
  local target = self.box
  local from = opts.from or 0.86
  self:_stop_tween()
  -- With motion off the tween finishes inside this call, so only keep the
  -- handle when it is still running.
  local running = true
  local handle = animate.tween({
    duration = opts.duration or cfg.animation.open_ms,
    easing = easing.out_cubic,
    motion = opts.motion,
    on_frame = function(eased)
      self:set_geometry(M.scale(target, easing.lerp(from, 1, eased)))
    end,
    on_done = function()
      running = false
      self:set_geometry(target)
      self.tween = nil
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

M.Window = Window

return M
