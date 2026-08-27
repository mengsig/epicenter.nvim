--- A titled float carrying a `ui.list` (or a `ui.tree`) plus the keys every
--- graph panel shares: move, jump, peek, yank, close. The palette is the
--- widget for "type and filter"; this is the widget for "here is a result set".
local M = {}

local list_mod = require("epicenter.ui.list")
local preview_mod = require("epicenter.ui.preview")
local tree_mod = require("epicenter.ui.tree")
local window = require("epicenter.ui.window")

local OPEN_COMMAND = { edit = "edit", tab = "tabedit", vsplit = "vsplit", split = "split" }

--- @class epicenter.Target
--- @field path string
--- @field line integer 1-based
--- @field end_line? integer

--- Opens `target` in the window the panel was called from, leaving a jumplist
--- entry behind.
--- @param target epicenter.Target
--- @param action? "edit"|"tab"|"vsplit"|"split"
function M.jump(target, action)
  vim.cmd("normal! m'")
  vim.cmd(("%s %s"):format(OPEN_COMMAND[action] or "edit", vim.fn.fnameescape(target.path)))
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(target.line, last)), 0 })
  vim.cmd("normal! zz")
end

--- Centered box for a panel, from `ui.width`/`ui.height`.
--- @return epicenter.Box
function M.box(scale)
  local cfg = require("epicenter.config").get()
  scale = scale or 1
  return window.box({
    width = cfg.ui.width * scale,
    height = cfg.ui.height * scale,
    max_width = cfg.ui.max_width,
    max_height = cfg.ui.max_height,
  })
end

--- A throwaway float showing the target's source. Any of q/<Esc>/<CR> closes it.
--- @param target epicenter.Target
--- @return epicenter.Window
function M.peek(target)
  local box = M.box(0.7)
  local win = window.open({
    box = box,
    title = (" %s:%d "):format(vim.fn.fnamemodify(target.path, ":~:."), target.line),
    footer = " q close ",
    enter = true,
    zindex = 150,
  })
  preview_mod.new({ buf = win.buf, win = win.win, height = box.height }):show(target)
  win:reveal()
  for _, lhs in ipairs({ "q", "<Esc>", "<CR>" }) do
    vim.keymap.set("n", lhs, function()
      win:close()
    end, { buffer = win.buf, nowait = true, silent = true })
  end
  return win
end

--- @class epicenter.Panel
local Panel = {}
Panel.__index = Panel

--- @param spec { title: string, footer?: string, box?: epicenter.Box, filetype?: string,
---   enter?: boolean, zindex?: integer, reflow?: fun(): epicenter.Box,
---   render_row: fun(row, index): { text: string, spans?: table[] },
---   text_of?: fun(row): string, empty_text?: string,
---   tree?: { key_of: fun(node): string, children_of: fun(node): any[] },
---   target_of?: fun(row): epicenter.Target|nil,
---   keys?: table<string, fun(panel: epicenter.Panel)>, on_close?: fun() }
--- @return epicenter.Panel
function M.open(spec)
  local box = spec.box or M.box()
  local self = setmetatable({ spec = spec, open = true }, Panel)

  self.win = window.open({
    box = box,
    title = spec.title,
    footer = spec.footer,
    filetype = spec.filetype or "epicenter-panel",
    enter = spec.enter ~= false,
    zindex = spec.zindex,
    reflow = spec.reflow,
    on_close = function()
      self.open = false
      if spec.on_close then
        spec.on_close()
      end
    end,
  })

  if spec.tree then
    self.tree = tree_mod.new({
      buf = self.win.buf,
      height = box.height,
      key_of = spec.tree.key_of,
      children_of = spec.tree.children_of,
      render_row = spec.render_row,
      text_of = spec.text_of,
      empty_text = spec.empty_text,
    })
    self.list = self.tree.list
  else
    self.list = list_mod.new({
      buf = self.win.buf,
      height = box.height,
      render_item = spec.render_row,
      text_of = spec.text_of,
      empty_text = spec.empty_text,
    })
  end

  self:_install_keys()
  self.win:reveal()
  return self
end

function Panel:target()
  local row = self.list:current()
  return row and self.spec.target_of and self.spec.target_of(row) or nil
end

function Panel:_install_keys()
  local actions = {}

  if self.spec.target_of then
    for lhs, action in pairs({ ["<CR>"] = "edit", ["<C-v>"] = "vsplit", ["<C-t>"] = "tab" }) do
      actions[lhs] = function()
        local target = self:target()
        if not target then
          return
        end
        self:close()
        -- After close, so the jump lands in the window the user came from.
        vim.schedule(function()
          M.jump(target, action)
        end)
      end
    end
    actions["o"] = function()
      local target = self:target()
      if target then
        M.peek(target)
      end
    end
    actions["y"] = function()
      local target = self:target()
      if not target then
        return
      end
      local text = ("%s:%d"):format(vim.fn.fnamemodify(target.path, ":~:."), target.line)
      vim.fn.setreg(vim.v.register or '"', text)
      require("epicenter").notify("yanked " .. text)
    end
  end

  for _, lhs in ipairs({ "q", "<Esc>" }) do
    actions[lhs] = function()
      self:close()
    end
  end
  for lhs, fn in pairs(self.spec.keys or {}) do
    actions[lhs] = function()
      fn(self)
    end
  end

  self.list:install_keys(self.win.buf, actions)
end

function Panel:valid()
  return self.open and self.win:valid()
end

function Panel:current()
  return self.list:current()
end

--- @param opts? { stagger?: boolean }
function Panel:draw(opts)
  self.list:draw(opts)
end

function Panel:set_items(items, opts)
  self.list:set_items(items)
  self:draw(opts)
end

function Panel:set_roots(roots, opts)
  assert(self.tree, "panel was not opened as a tree")
  self.tree:set_roots(roots, opts)
  self:draw()
end

--- Re-renders the tree after its nodes changed, keeping the selected row.
function Panel:refresh_tree()
  assert(self.tree, "panel was not opened as a tree")
  local index = self.list:index()
  self.tree:refresh()
  self.list:select(index)
  self:draw()
end

function Panel:set_filter(query)
  self.list:set_filter(query)
  self:draw()
end

--- Replaces the rows with a calm one-line message (a failure is not a crash).
function Panel:notice(text)
  self.list.empty_text = text
  self:set_items({})
end

function Panel:set_footer(footer)
  self.win:set_footer(footer)
end

function Panel:set_title(title)
  self.win:set_title(title)
end

function Panel:close()
  if not self.open then
    return
  end
  self.win:close()
end

M.Panel = Panel

return M
