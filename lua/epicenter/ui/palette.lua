--- Prompt + results + preview, driven by an async source that is re-queried on
--- every keystroke. The widget owns layout, motion, keys and staleness; the
--- caller owns only where the items come from and what a jump means.
local M = {}

local animate = require("epicenter.ui.animate")
local easing = require("epicenter.ui.easing")
local list_mod = require("epicenter.ui.list")
local preview_mod = require("epicenter.ui.preview")
local prompt_mod = require("epicenter.ui.prompt")
local window = require("epicenter.ui.window")

--- Below this width the preview pane is dropped rather than squeezed.
local MIN_WIDTH_FOR_PREVIEW = 80
local PROMPT_HEIGHT = 1
local GUTTER = 2

--- Splits the palette box into prompt / results / preview. Pure.
--- @return { prompt: epicenter.Box, results: epicenter.Box, preview: epicenter.Box|nil }
function M.layout(box, want_preview)
  local prompt, body = window.split_v(box, PROMPT_HEIGHT, GUTTER)
  if not want_preview or box.width < MIN_WIDTH_FOR_PREVIEW then
    return { prompt = prompt, results = body, preview = nil }
  end
  local results, preview = window.split_h(body, 0.45, GUTTER)
  return { prompt = prompt, results = results, preview = preview }
end

--- @class epicenter.Palette
local Palette = {}
Palette.__index = Palette

local ACTIONS = {
  ["<CR>"] = "edit",
  ["<C-t>"] = "tab",
  ["<C-v>"] = "vsplit",
  ["<C-x>"] = "split",
}

--- Keys every palette shares. A caller with mode-specific keys (e.g. search's
--- <C-r>/<C-k> vs grep's <C-r>) supplies its own `help_lines` in its spec
--- instead - the shared block used to be shown for both and lied for grep.
local HELP = {
  "  keys",
  "",
  "  <CR>        jump to the result",
  "  <C-t>       open in a new tab",
  "  <C-v>       open in a vertical split",
  "  <C-x>       open in a split",
  "  <C-n>/<C-p> next / previous result",
  "  <C-y>       yank file:line",
  "  ?           toggle this help (normal mode)",
  "  <Esc>       close",
}

function Palette:_box()
  local cfg = require("epicenter.config").get()
  return window.box({
    width = cfg.ui.width,
    height = cfg.ui.height,
    max_width = cfg.ui.max_width,
    max_height = cfg.ui.max_height,
    -- Test-only sizing hook (see `spec.columns`/`spec.lines`): nil defers to
    -- the real editor grid, exactly as before. Specs must never assign
    -- `vim.o.columns` themselves - nvim 0.12 aborts in draw_tabline when it
    -- changes under an open floating window.
    columns = self.columns,
    lines = self.lines,
  })
end

--- `boxes.preview` is nil below MIN_WIDTH_FOR_PREVIEW even when
--- `preview_win` still exists - during the open animation the target box
--- has room but an early scaled-down frame may not. Skip the preview this
--- frame rather than pass nil through; `reflow` drops the pane outright
--- when the *settled* size no longer fits (see `_drop_preview`), and the
--- animation's own `on_done` always re-applies the full, fitting target.
function Palette:_apply_layout(box)
  local boxes = M.layout(box, self.want_preview)
  self.prompt_win:set_geometry(boxes.prompt)
  self.results_win:set_geometry(boxes.results)
  if boxes.preview then
    if self.preview_win then
      self.preview_win:set_geometry(boxes.preview)
    end
    if self.preview then
      self.preview:set_height(boxes.preview.height)
    end
  end
  self.list:set_height(boxes.results.height)
end

--- Closes and forgets the preview pane once its window has no room; unlike
--- the transient dip during the open animation, a settled resize below the
--- threshold means the pane stays gone until the palette is reopened.
function Palette:_drop_preview()
  self.preview_win:close()
  self.preview_win = nil
  self.preview = nil
  self.want_preview = false
end

--- Reflow after a `VimResized`: geometry changes, nothing animates.
function Palette:reflow()
  if not self.open then
    return
  end
  self.box = self:_box()
  if self.preview_win and M.layout(self.box, self.want_preview).preview == nil then
    self:_drop_preview()
  end
  self:_apply_layout(self.box)
  self.list:draw()
end

function Palette:_set_footer()
  local total = self.total or self.list:count()
  local shown = self.list:count()
  local left = shown == total and ("%d"):format(total) or ("%d/%d"):format(shown, total)
  local mode = self.spec.mode_label and self.spec.mode_label(self.state) or nil
  self.results_win:set_footer((" %s%s "):format(left, mode and (" · " .. mode) or ""))
end

function Palette:_update_preview()
  if not self.preview or self.help_open then
    return
  end
  local item = self.list:current()
  local target = item and self.spec.preview_of and self.spec.preview_of(item) or nil
  if not target then
    self.preview:clear("")
    return
  end
  self.preview:show(target)
end

function Palette:_on_results(err, items, total)
  if not self.open then
    return
  end
  if err then
    self.list:set_items({})
    self.list.empty_text = "  " .. (err.message or "the search failed")
    self.total = 0
    self.list:draw()
    self:_set_footer()
    return
  end
  self.list.empty_text = self.spec.empty_text or "  no matches"
  self.total = total or #items
  self.list:set_items(items)
  self.list:draw({ stagger = true })
  self:_set_footer()
  self:_update_preview()
end

function Palette:query(text)
  if not self.open then
    return
  end
  self.query_text = text
  -- The widget owns query identity, not the transport: a source that answers
  -- synchronously (e.g. an empty-query short-circuit) must not race a slower
  -- in-flight request for a query the user already replaced.
  self.generation = self.generation + 1
  local generation = self.generation
  self.spec.source(text, self.state, function(err, items, total)
    vim.schedule(function()
      if generation ~= self.generation then
        return
      end
      self:_on_results(err, items or {}, total)
    end)
  end)
end

--- Re-runs the current query, e.g. after a mode toggle.
function Palette:refresh()
  self:query(self.query_text or "")
end

function Palette:move(delta)
  self.list:move(delta)
  self.list:draw()
  self:_set_footer()
  self:_update_preview()
end

function Palette:toggle_help()
  if not self.preview then
    return
  end
  self.help_open = not self.help_open
  if self.help_open then
    self.preview_win:set_lines(self.spec.help_lines or HELP)
  else
    self.preview.shown = nil
    self:_update_preview()
  end
end

function Palette:accept(action)
  local item = self.list:current()
  if not item then
    return
  end
  -- Instant close: an animated fade would still be on screen when the
  -- scheduled jump below runs, so the edit/cursor/zz happened underneath it.
  self:close({ motion = false })
  -- After close, so the jump lands in the window the user came from.
  vim.schedule(function()
    self.spec.on_accept(item, action or "edit")
  end)
end

--- @param opts? { motion?: boolean } forwarded to each window's close()
function Palette:close(opts)
  if not self.open then
    return
  end
  self.open = false
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if self.tween then
    self.tween.cancel()
    self.tween = nil
  end
  self.prompt:close()
  for _, win in ipairs({ self.prompt_win, self.results_win, self.preview_win }) do
    if win then
      win:close(opts)
    end
  end
  vim.cmd("stopinsert")
  if self.previous_win and vim.api.nvim_win_is_valid(self.previous_win) then
    vim.api.nvim_set_current_win(self.previous_win)
  end
  if self.spec.on_close then
    self.spec.on_close()
  end
end

function Palette:_install_keys()
  local buf = self.prompt_win.buf
  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  for lhs, action in pairs(ACTIONS) do
    map({ "i", "n" }, lhs, function()
      self:accept(action)
    end)
  end
  map({ "i", "n" }, "<C-n>", function()
    self:move(1)
  end)
  map({ "i", "n" }, "<C-p>", function()
    self:move(-1)
  end)
  map({ "i", "n" }, "<Down>", function()
    self:move(1)
  end)
  map({ "i", "n" }, "<Up>", function()
    self:move(-1)
  end)
  map("n", "j", function()
    self:move(1)
  end)
  map("n", "k", function()
    self:move(-1)
  end)
  map({ "i", "n" }, "<C-y>", function()
    local item = self.list:current()
    local target = item and self.spec.preview_of and self.spec.preview_of(item)
    if target then
      local text = ("%s:%d"):format(vim.fn.fnamemodify(target.path, ":~:."), target.line)
      vim.fn.setreg(vim.v.register or '"', text)
      require("epicenter").notify("yanked " .. text)
    end
  end)
  map("n", "?", function()
    self:toggle_help()
  end)
  map({ "i", "n" }, "<Esc>", function()
    self:close()
  end)
  map("n", "q", function()
    self:close()
  end)

  for lhs, fn in pairs(self.spec.keys or {}) do
    map({ "i", "n" }, lhs, function()
      fn(self)
    end)
  end
end

--- @param spec { title: string, prompt_prefix?: string, debounce_ms?: integer,
---   state?: table, source: fun(query: string, state: table, cb: fun(err, items, total)),
---   render_item: fun(item, index): { text: string, spans?: table[] },
---   preview_of?: fun(item): { path: string, line: integer, end_line?: integer }|nil,
---   on_accept: fun(item, action: "edit"|"tab"|"vsplit"|"split"),
---   keys?: table<string, fun(palette: epicenter.Palette)>,
---   mode_label?: fun(state: table): string, empty_text?: string, on_close?: fun(),
---   help_lines?: string[] shown by `?`; defaults to the shared HELP block,
---   columns?: integer, lines?: integer - test-only editor-grid override,
---   see `Palette:_box`; production callers must leave these nil }
--- @return epicenter.Palette
function M.open(spec)
  local cfg = require("epicenter.config").get()
  local self = setmetatable({
    spec = spec,
    state = spec.state or {},
    open = true,
    help_open = false,
    want_preview = cfg.ui.preview and spec.preview_of ~= nil,
    previous_win = vim.api.nvim_get_current_win(),
    query_text = "",
    generation = 0,
    columns = spec.columns,
    lines = spec.lines,
  }, Palette)

  self.box = self:_box()
  local boxes = M.layout(self.box, self.want_preview)

  self.results_win = window.open({
    box = boxes.results,
    title = spec.title,
    focusable = false,
    zindex = 100,
  })
  if boxes.preview then
    self.preview_win = window.open({
      box = boxes.preview,
      focusable = false,
      zindex = 100,
    })
  end
  self.prompt_win = window.open({
    box = boxes.prompt,
    footer = " ↵ jump · ^t/^v/^x open · ^n/^p move · ? help ",
    enter = true,
    zindex = 110,
    on_close = function()
      self:close()
    end,
  })

  -- One autocmd owns the whole palette's resize: the three windows must
  -- reflow together, including the list/preview heights (see Palette:reflow).
  self.augroup = vim.api.nvim_create_augroup("EpicenterPalette" .. self.prompt_win.buf, {
    clear = true,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      self:reflow()
    end,
  })

  self.list = list_mod.new({
    buf = self.results_win.buf,
    height = boxes.results.height,
    render_item = spec.render_item,
    empty_text = spec.empty_text or "  type to search",
  })
  if self.preview_win then
    self.preview = preview_mod.new({
      buf = self.preview_win.buf,
      win = self.preview_win.win,
      height = boxes.preview.height,
    })
  end

  self.prompt = prompt_mod.new({
    buf = self.prompt_win.buf,
    prefix = spec.prompt_prefix or "> ",
    debounce_ms = spec.debounce_ms or 40,
    on_change = function(text)
      self:query(text)
    end,
    on_submit = function()
      self:accept("edit")
    end,
    on_cancel = function()
      self:close()
    end,
  })

  self:_install_keys()
  self.list:draw()
  self:_set_footer()

  -- One tween scales the whole palette in; the panes stay in lockstep.
  local target = self.box
  local running = true
  local handle = animate.tween({
    duration = cfg.animation.open_ms,
    easing = easing.out_cubic,
    on_frame = function(eased)
      if self.open then
        self:_apply_layout(window.scale(target, easing.lerp(0.88, 1, eased)))
      end
    end,
    on_done = function()
      running = false
      self.tween = nil
      if self.open then
        self:_apply_layout(target)
        self.list:draw()
      end
    end,
  })
  self.tween = running and handle or nil

  self.prompt:start_insert()
  self:query("")
  return self
end

M.Palette = Palette
M.HELP = HELP

return M
