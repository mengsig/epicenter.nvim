--- Peek: the definition under the cursor (or under a picker row) in a float
--- that can be read without leaving where you are.
---
--- One component, two callers. From inside a panel the peek TAKES focus - the
--- panel already has it, and `q` there has to reach the float. From the code
--- it must NOT: `gp`-style peek is something you glance at and keep typing
--- past, so its keys live on the buffer you are still in and are handed back
--- when the float goes.
local M = {}

local preview_mod = require("epicenter.ui.preview")
local window = require("epicenter.ui.window")

--- @class epicenter.Peek
local Peek = {}
Peek.__index = Peek

--- The one open peek. A second `gp` replaces it rather than stacking floats.
local active = nil

--- @return epicenter.Peek|nil
function M.current()
  return active and active.win:valid() and active or nil
end

local function box_for()
  local cfg = require("epicenter.config").get()
  return window.box({
    width = 0.6,
    height = 0.4,
    max_width = math.min(cfg.ui.max_width, 100),
    max_height = math.min(cfg.ui.max_height, 20),
  })
end

--- Saves `buf`'s own normal-mode mapping for `lhs`, so closing the peek puts
--- back whatever was there rather than leaving the key unmapped.
--- @return table|nil the maparg dict, or nil when the buffer had none
local function borrow(buf, lhs, fn)
  local existing = vim.fn.maparg(lhs, "n", false, true)
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  return (not vim.tbl_isempty(existing) and existing.buffer == 1) and existing or nil
end

local function give_back(buf, lhs, saved)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- Deleting the peek's own map may legitimately fail (the buffer was
  -- re-mapped meanwhile); losing the user's OWN mapping is a real failure.
  pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  if saved then
    local ok, err = pcall(vim.fn.mapset, saved)
    if not ok then
      require("epicenter").notify(
        ("peek could not put your %s mapping back: %s"):format(lhs, err),
        "warn"
      )
    end
  end
end

--- @param target epicenter.Target
--- @param opts? { focus?: boolean, on_go?: fun(target: epicenter.Target),
---   origin_win?: integer } `origin_win` is where `<CR>` goes; a focused peek
---   opened from a panel must name the window the reader came FROM, since the
---   current window is the panel's own float.
--- @return epicenter.Peek
function M.open(target, opts)
  opts = opts or {}
  if active then
    active:close()
  end

  local focus = opts.focus == true
  local box = box_for()
  local self = setmetatable({
    target = target,
    focus = focus,
    on_go = opts.on_go,
    origin_win = opts.origin_win or vim.api.nvim_get_current_win(),
    origin_buf = vim.api.nvim_get_current_buf(),
    borrowed = {},
    closed = false,
  }, Peek)

  self.win = window.open({
    box = box,
    title = (" %s:%d "):format(vim.fn.fnamemodify(target.path, ":~:."), target.line),
    footer = focus and " <CR> go · q close " or " <CR> go · q dismiss ",
    filetype = "epicenter-peek",
    enter = focus,
    focusable = focus,
    zindex = 200,
    on_close = function()
      self:_cleanup()
    end,
  })
  preview_mod.new({ buf = self.win.buf, win = self.win.win, height = box.height }):show(target)
  self:_install_keys()
  self.win:reveal()

  active = self
  return self
end

function Peek:_install_keys()
  local function go()
    self:go()
  end
  local function dismiss()
    self:close()
  end

  if self.focus then
    for _, lhs in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", lhs, dismiss, { buffer = self.win.buf, nowait = true, silent = true })
    end
    vim.keymap.set("n", "<CR>", go, { buffer = self.win.buf, nowait = true, silent = true })
    return
  end

  -- Unfocused: the keys have to be reachable from the buffer the cursor is
  -- still in, and handed back untouched when the float goes.
  local buf = self.origin_buf
  -- A list, not a map keyed by lhs: `borrow` answers nil for a key the buffer
  -- had no mapping for, and a nil value would drop that key from the table
  -- entirely - so it would never be handed back.
  self.borrowed = {
    { lhs = "<CR>", saved = borrow(buf, "<CR>", go) },
    { lhs = "q", saved = borrow(buf, "q", dismiss) },
  }

  self.augroup = vim.api.nvim_create_augroup("EpicenterPeek" .. self.win.buf, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    group = self.augroup,
    buffer = buf,
    callback = function()
      self:close()
    end,
  })
end

--- Jumps to what the peek is showing, in the window it was opened from.
function Peek:go()
  local target = self.target
  local origin = self.origin_win
  self:close()
  vim.schedule(function()
    if origin and vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
    if self.on_go then
      return self.on_go(target)
    end
    require("epicenter.ui.panel").jump(target, "edit")
  end)
end

function Peek:valid()
  return not self.closed and self.win:valid()
end

function Peek:close()
  if self.closed then
    return
  end
  self.win:close()
  self:_cleanup()
end

--- The single teardown path: reached by `close()` and by the window's own
--- `on_close` (a `WinClosed` from anywhere).
function Peek:_cleanup()
  if self.closed then
    return
  end
  self.closed = true
  if active == self then
    active = nil
  end
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  for _, entry in ipairs(self.borrowed) do
    give_back(self.origin_buf, entry.lhs, entry.saved)
  end
  self.borrowed = {}
end

M.Peek = Peek

return M
