--- A titled float carrying a `ui.list` (or a `ui.tree`) plus the keys every
--- graph panel shares: move, jump, peek, yank, close. The palette is the
--- widget for "type and filter"; this is the widget for "here is a result set".
local M = {}

local list_mod = require("epicenter.ui.list")
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

--- Copies `file:line` to the register and notifies - the `y` every panel
--- shares (F9).
--- @param target epicenter.Target
function M.yank(target)
  local text = ("%s:%d"):format(vim.fn.fnamemodify(target.path, ":~:."), target.line)
  vim.fn.setreg(vim.v.register or '"', text)
  require("epicenter").notify("yanked " .. text)
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

--- `M.box`, sized to `count` rows instead of `ui.height` - floored at 3, so a
--- small result set (or the empty/loading message) does not sit in a
--- mostly-empty float, and never taller than the panel's own default (F13).
--- @return epicenter.Box
local function box_for_count(count)
  local cfg = require("epicenter.config").get()
  return window.box({
    width = cfg.ui.width,
    height = math.min(math.max(count, 3), M.box().height),
    max_width = cfg.ui.max_width,
    max_height = cfg.ui.max_height,
  })
end

--- The source of `target`, without leaving the panel. One component with the
--- `gp` peek (`ui.peek`); focused here, because the panel holds the cursor
--- and `q` has to reach the float.
--- @param target epicenter.Target
--- @param origin_win? integer where `<CR>` should open the file - the window
---   the reader came from, never the panel's own float.
--- @return epicenter.Peek
function M.peek(target, origin_win)
  return require("epicenter.ui.peek").open(target, { focus = true, origin_win = origin_win })
end

-- Remembered layout -------------------------------------------------------------
-- Terminal/window preference, not project data: one geometry per panel TYPE
-- (`spec.filetype`), independent of which project it was resized in - so
-- `store`'s per-root keying is deliberately not used here.
local LAYOUT_ROOT = "panel-layout"
local MIN_WIDTH, MIN_HEIGHT = 20, 3
local RESIZE_STEP, MOVE_STEP = 4, 1

--- Remembering a geometry is a read-modify-write of a state file, and `+`
--- held at typematic rate is ~30 keypresses a second. Nudges accumulate here
--- and are written once the keys stop - or when the panel closes, or on the
--- way out of Neovim, whichever comes first.
local PERSIST_MS = 250
local pending_layout = {}
local persist_timer = nil
local persist_group = nil

--- A failure to save is a log line, not a toast: the panel still works, it
--- just reopens at the default size next time.
local function flush_layout()
  if persist_timer then
    persist_timer:stop()
  end
  if next(pending_layout) == nil then
    return
  end
  local store = require("epicenter.store")
  local stored = store.read("panel_layout", LAYOUT_ROOT)
  for filetype, box in pairs(pending_layout) do
    stored[filetype] = { width = box.width, height = box.height, row = box.row, col = box.col }
  end
  pending_layout = {}
  local ok, err = store.write("panel_layout", LAYOUT_ROOT, stored)
  if not ok then
    require("epicenter.log").warn("could not remember panel geometry: %s", err)
  end
end

--- The geometry this panel type reopens at: a nudge not yet written out is
--- still the truth about it.
--- @param filetype string
--- @return epicenter.Box|nil
local function remembered_box(filetype)
  local box = pending_layout[filetype]
    or require("epicenter.store").read("panel_layout", LAYOUT_ROOT)[filetype]
  return box and window.clamp(box) or nil
end

--- @param filetype string
--- @param box epicenter.Box
local function remember_box(filetype, box)
  pending_layout[filetype] = box
  persist_timer = persist_timer or (vim.uv or vim.loop).new_timer()
  persist_timer:stop()
  persist_timer:start(PERSIST_MS, 0, vim.schedule_wrap(flush_layout))
  if not persist_group then
    persist_group = vim.api.nvim_create_augroup("EpicenterPanelLayout", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", { group = persist_group, callback = flush_layout })
  end
end

--- @class epicenter.Panel
local Panel = {}
Panel.__index = Panel

--- @param spec { title: string, footer?: string, box?: epicenter.Box, filetype?: string,
---   layout?: "float"|"vsplit", width?: integer,
---   enter?: boolean, zindex?: integer, reflow?: fun(): epicenter.Box,
---   render_row: fun(row, index): { text: string, spans?: table[] },
---   text_of?: fun(row): string, empty_text?: string,
---   mark_key?: fun(row): any what a `<Tab>` mark survives a re-populate under;
---     a tree panel keys off its own row instead (see `tree.lua`), so this is
---     read only when `tree` is nil,
---   tree?: { key_of: fun(node): string, children_of: fun(node): any[],
---     identity_of?: fun(node): string },
---   target_of?: fun(row): epicenter.Target|nil, hints?: table<string, string>,
---   keys?: table<string, fun(panel: epicenter.Panel)>, on_close?: fun(),
---   on_filter?: fun(query: string) }
--- @return epicenter.Panel
function M.open(spec)
  -- A split already takes only the height the user left it at (F8); an
  -- explicit box is the caller's own choice (e.g. a fixed dashboard) -
  -- neither resizes/moves interactively or remembers a geometry.
  local resizable = spec.layout ~= "vsplit" and not spec.box
  local remembered = resizable and remembered_box(spec.filetype)
  local box = spec.box or remembered or M.box()
  local self = setmetatable({
    spec = spec,
    open = true,
    help_open = false,
    previous_win = vim.api.nvim_get_current_win(),
    resizable = resizable,
    -- A remembered size is the user's own explicit choice - it must not be
    -- overridden by the next redraw's content-fit (F13's default behaviour,
    -- kept for any panel the user has never resized).
    size_to_content = resizable and not remembered,
  }, Panel)

  local function on_close()
    self.open = false
    flush_layout()
    if spec.on_close then
      spec.on_close()
    end
  end

  if spec.layout == "vsplit" then
    -- A persistent surface takes its own space instead of covering the source
    -- (F8); a transient one floats, since it is gone the moment you act.
    self.win = window.open_split({
      width = spec.width or box.width,
      title = spec.title,
      footer = spec.footer,
      filetype = spec.filetype or "epicenter-panel",
      enter = spec.enter ~= false,
      on_close = on_close,
    })
  else
    self.win = window.open({
      box = box,
      title = spec.title,
      footer = spec.footer,
      filetype = spec.filetype or "epicenter-panel",
      enter = spec.enter ~= false,
      zindex = spec.zindex,
      reflow = spec.reflow,
      on_close = on_close,
    })
  end

  local height, width = self.win:content_height(), self.win:content_width()
  if spec.tree then
    self.tree = tree_mod.new({
      buf = self.win.buf,
      height = height,
      width = width,
      key_of = spec.tree.key_of,
      identity_of = spec.tree.identity_of,
      children_of = spec.tree.children_of,
      render_row = spec.render_row,
      text_of = spec.text_of,
      empty_text = spec.empty_text,
    })
    self.list = self.tree.list
  else
    self.list = list_mod.new({
      buf = self.win.buf,
      height = height,
      width = width,
      render_item = spec.render_row,
      text_of = spec.text_of,
      empty_text = spec.empty_text,
      mark_key = spec.mark_key,
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

--- The rows an export sends: the `<Tab>` multi-selection, or everything on
--- screen. Each carries the target it jumps to and the text it shows, so the
--- quickfix list reads exactly like the panel did.
--- @return epicenter.qf.Row[]
function Panel:export_rows()
  if not self.spec.target_of then
    return {}
  end
  local out = {}
  for index, row in ipairs(self.list:marked_or_all()) do
    local target = self.spec.target_of(row)
    if target then
      table.insert(out, { target = target, text = self.spec.render_row(row, index).text })
    end
  end
  return out
end

--- Sends the rows to the quickfix or location list and closes: the panel has
--- done its job once the result set is somewhere `:cnext` can walk it.
--- @param list "quickfix"|"loclist"
function Panel:export(list)
  local rows = self:export_rows()
  local title = vim.trim(self.spec.title or "epicenter")
  self:close()
  vim.schedule(function()
    require("epicenter.ui.qf").send_and_notify({ rows = rows, list = list, title = title })
  end)
end

--- SETTLED: the panel has rows, or it has said there are none. A bare
--- `set_items({})` is a reload clearing the old answer, not an answer.
function Panel:settled()
  return self.list:count() > 0 or self.noticed == true
end

--- Registers a callback for each result set the panel receives. Used by the
--- `--qf`/`--loc` command flags, which have to act on rows that only arrive
--- once the server answers.
---
--- A panel that filled itself synchronously has already settled by the time
--- the flag registers, so `fn` runs now: waiting would skip the answer the
--- user asked for and then fire on whatever a later reindex repainted.
--- @param fn fun(panel: epicenter.Panel)
function Panel:on_populate(fn)
  if self:settled() then
    return fn(self)
  end
  self.populate_hooks = self.populate_hooks or {}
  table.insert(self.populate_hooks, fn)
end

function Panel:_populated()
  if not self:settled() then
    return
  end
  for _, fn in ipairs(self.populate_hooks or {}) do
    fn(self)
  end
end

--- Lines for the `?` overlay: every key this panel actually answers to, so
--- the doc claim ("`?` in normal mode shows them inside the panel") is true
--- everywhere a panel is used, not just the palette (F12/F13).
function Panel:_help_lines()
  local lines, seen = { "  keys", "" }, {}
  local function add(lhs, desc)
    if seen[lhs] then
      return
    end
    seen[lhs] = true
    table.insert(lines, ("  %-14s%s"):format(lhs, desc))
  end
  if self.spec.target_of then
    add("<CR>", "jump to the target")
    add("<C-v>", "open in a vertical split")
    add("<C-t>", "open in a new tab")
    add("o", "peek without leaving the panel")
    add("y", "yank file:line")
    add("<Tab>", "add / remove this row from the selection")
    add("<C-q>", "send the rows to the quickfix list")
    add("<C-l>", "send the rows to the location list")
  end
  add("j, k", "next / previous row")
  if self.tree then
    add("l, h", "expand / collapse")
  end
  add("gg, G", "top / bottom")
  add("/", "filter by name")
  if self.resizable then
    add("+, -", "grow / shrink")
    add("<, >", "narrower / wider")
    add("<C-arrow>", "move")
  end
  for lhs, hint in pairs(self.spec.hints or {}) do
    add(lhs, hint)
  end
  add("?", "toggle this help")
  add("q, <Esc>", "close")
  table.insert(lines, "")
  return lines
end

function Panel:_toggle_help()
  self.help_open = not self.help_open
  if self.help_open then
    self.win:set_lines(self:_help_lines())
  else
    self:draw()
  end
end

--- Resizes/moves a resizable float, clamped to the editor grid, and
--- remembers the result under its panel type - the user's own explicit
--- choice, so a later redraw stops fitting height to content (F13's default
--- only holds until the panel has actually been touched).
--- @param delta { width?: integer, height?: integer, row?: integer, col?: integer }
function Panel:_nudge(delta)
  if not self.resizable or not self:valid() then
    return
  end
  local box = self.win:geometry()
  local next_box = window.clamp({
    width = math.max(MIN_WIDTH, box.width + (delta.width or 0)),
    height = math.max(MIN_HEIGHT, box.height + (delta.height or 0)),
    row = box.row + (delta.row or 0),
    col = box.col + (delta.col or 0),
  })
  self.size_to_content = false
  self.win:set_geometry(next_box)
  self:draw()
  if self.spec.filetype then
    remember_box(self.spec.filetype, next_box)
  end
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
        M.peek(target, self.previous_win)
      end
    end
    actions["y"] = function()
      local target = self:target()
      if target then
        M.yank(target)
      end
    end
    actions["<Tab>"] = function()
      self.list:toggle_mark()
      self.list:move(1)
      self:draw()
    end
    actions["<C-q>"] = function()
      self:export("quickfix")
    end
    actions["<C-l>"] = function()
      self:export("loclist")
    end
  end

  if self.resizable then
    actions["+"] = function()
      self:_nudge({ height = RESIZE_STEP })
    end
    actions["-"] = function()
      self:_nudge({ height = -RESIZE_STEP })
    end
    actions[">"] = function()
      self:_nudge({ width = RESIZE_STEP })
    end
    -- A literal `<` must be spelled `<lt>` as a mapping lhs, or Neovim reads
    -- it as the start of a special-key sequence.
    actions["<lt>"] = function()
      self:_nudge({ width = -RESIZE_STEP })
    end
    actions["<C-Up>"] = function()
      self:_nudge({ row = -MOVE_STEP })
    end
    actions["<C-Down>"] = function()
      self:_nudge({ row = MOVE_STEP })
    end
    actions["<C-Left>"] = function()
      self:_nudge({ col = -MOVE_STEP })
    end
    actions["<C-Right>"] = function()
      self:_nudge({ col = MOVE_STEP })
    end
  end

  actions["?"] = function()
    self:_toggle_help()
  end
  actions["/"] = function()
    vim.ui.input({ prompt = "filter: " }, function(text)
      if text ~= nil and self.open then
        self:set_filter(text)
        if self.spec.on_filter then
          self.spec.on_filter(text)
        end
      end
    end)
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
  if self.size_to_content then
    local box = box_for_count(self.list:count())
    if box.height ~= self.win.box.height then
      self.win:set_geometry(box)
    end
  end
  -- A split is whatever height/width the user has left it at, so both are
  -- read here rather than fixed at open. A float's are its own box, unchanged
  -- outside a reflow (F12: row text needs the live width to fit itself).
  local height, width = self.win:content_height(), self.win:content_width()
  if height ~= self.list.height then
    self.list:set_height(height)
  end
  if width ~= self.list.width then
    self.list:set_width(width)
  end
  self.list:draw(opts)
end

function Panel:set_items(items, opts)
  if items and #items > 0 then
    self.noticed = false
  end
  self.list:set_items(items)
  self:draw(opts)
  self:_populated()
end

function Panel:set_roots(roots, opts)
  assert(self.tree, "panel was not opened as a tree")
  self.tree:set_roots(roots, opts)
  self:draw()
  self:_populated()
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
  self.noticed = true
  self:set_items({})
end

function Panel:set_footer(footer)
  self.win:set_footer(footer)
end

function Panel:set_title(title)
  self.win:set_title(title)
end

--- Restores focus to the window the panel was opened from BEFORE the float's
--- close fade completes, so a scheduled jump (F1) lands there and not in the
--- fading float - the palette already does this, the same three lines.
function Panel:close()
  if not self.open then
    return
  end
  self.win:close()
  if self.previous_win and vim.api.nvim_win_is_valid(self.previous_win) then
    vim.api.nvim_set_current_win(self.previous_win)
  end
end

M.Panel = Panel

return M
