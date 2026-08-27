--- Virtual-scroll list. The layout maths and the row rendering are pure
--- functions over a plain state table; the object below only writes the result
--- into a buffer, so rendering is tested without a UI.
local M = {}

local animate = require("epicenter.ui.animate")

--- Keeps `selected` inside the viewport. Pure.
--- @return integer new top (1-based item index)
function M.scroll(total, height, selected, top)
  if total <= 0 or height <= 0 then
    return 1
  end
  local max_top = math.max(1, total - height + 1)
  top = math.max(1, math.min(top or 1, max_top))
  if selected < top then
    top = selected
  elseif selected > top + height - 1 then
    top = selected - height + 1
  end
  return math.max(1, math.min(top, max_top))
end

--- @class epicenter.ListState
--- @field items any[]
--- @field top integer 1-based index of the first visible item
--- @field height integer visible rows
--- @field selected integer|nil 1-based
--- @field render_item fun(item: any, index: integer): { text: string, spans?: table[] }
--- @field empty_text? string

--- Renders the visible slice. Pure.
--- @param state epicenter.ListState
--- @return { lines: string[], spans: table[], selected_row: integer|nil }
function M.render(state)
  local total = #state.items
  if total == 0 then
    return { lines = { state.empty_text or "" }, spans = {}, selected_row = nil }
  end

  local lines, spans = {}, {}
  local last = math.min(total, state.top + state.height - 1)
  for i = state.top, last do
    local row = i - state.top
    local rendered = state.render_item(state.items[i], i)
    table.insert(lines, rendered.text)
    for _, span in ipairs(rendered.spans or {}) do
      table.insert(spans, { row = row, hl = span.hl, from = span.from, to = span.to })
    end
  end

  local selected_row = nil
  if state.selected and state.selected >= state.top and state.selected <= last then
    selected_row = state.selected - state.top
  end
  return { lines = lines, spans = spans, selected_row = selected_row }
end

--- @class epicenter.List
local List = {}
List.__index = List

--- @param opts { buf: integer, height: integer,
---   render_item: fun(item, index): { text: string, spans?: table[] },
---   text_of?: fun(item): string, empty_text?: string, on_select?: fun(item, index) }
function M.new(opts)
  return setmetatable({
    buf = opts.buf,
    ns = vim.api.nvim_create_namespace("epicenter.list"),
    height = opts.height,
    render_item = opts.render_item,
    text_of = opts.text_of or tostring,
    empty_text = opts.empty_text or "  no results",
    on_select = opts.on_select,
    all = {},
    view = {},
    filter = "",
    selected = 1,
    top = 1,
    reveal = nil,
    revealed = false,
  }, List)
end

local function apply_filter(self)
  if self.filter == "" then
    self.view = self.all
    return
  end
  local needle = self.filter:lower()
  self.view = vim.tbl_filter(function(item)
    return self.text_of(item):lower():find(needle, 1, true) ~= nil
  end, self.all)
end

function List:set_items(items)
  self.all = items or {}
  apply_filter(self)
  self.selected = math.min(math.max(1, self.selected), math.max(1, #self.view))
  self.top = M.scroll(#self.view, self.height, self.selected, 1)
end

function List:set_filter(query)
  self.filter = query or ""
  apply_filter(self)
  self.selected = 1
  self.top = 1
end

function List:set_height(height)
  self.height = math.max(1, height)
  self.top = M.scroll(#self.view, self.height, self.selected, self.top)
end

function List:items()
  return self.view
end

function List:count()
  return #self.view
end

function List:index()
  return self.selected
end

function List:current()
  return self.view[self.selected]
end

function List:select(index)
  if #self.view == 0 then
    return
  end
  self.selected = math.max(1, math.min(index, #self.view))
  self.top = M.scroll(#self.view, self.height, self.selected, self.top)
  if self.on_select then
    self.on_select(self:current(), self.selected)
  end
end

--- Moves by `delta`, wrapping at both ends (a palette should never dead-end).
function List:move(delta)
  local total = #self.view
  if total == 0 then
    return
  end
  local next_index = ((self.selected - 1 + delta) % total) + 1
  self:select(next_index)
end

function List:state()
  return {
    items = self.view,
    top = self.top,
    height = self.height,
    selected = self.selected,
    render_item = self.render_item,
    empty_text = self.empty_text,
  }
end

local function paint(self, rendered, rows)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local lines = rows and vim.list_slice(rendered.lines, 1, rows) or rendered.lines
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
  for _, span in ipairs(rendered.spans) do
    if span.row < #lines then
      pcall(vim.api.nvim_buf_set_extmark, self.buf, self.ns, span.row, span.from, {
        end_col = span.to,
        hl_group = span.hl,
        strict = false,
      })
    end
  end
  if rendered.selected_row and rendered.selected_row < #lines then
    vim.api.nvim_buf_set_extmark(self.buf, self.ns, rendered.selected_row, 0, {
      line_hl_group = "EpicenterSelection",
    })
  end
end

--- Writes the visible slice into the buffer. A stagger reveal is right for
--- the first result set after the list opens, and wrong for every refresh
--- after that (it would collapse-and-regrow on every keystroke) - so it
--- fires at most once per list, on whichever draw asks for it first.
--- @param opts? { stagger?: boolean }
function List:draw(opts)
  opts = opts or {}
  local rendered = M.render(self:state())

  if self.reveal then
    self.reveal.cancel()
    self.reveal = nil
  end

  local stagger = opts.stagger and not self.revealed
  if opts.stagger then
    self.revealed = true
  end

  if not stagger or #rendered.lines <= 1 then
    paint(self, rendered)
    return
  end

  local cfg = require("epicenter.config").get()
  local count = #rendered.lines
  paint(self, rendered, 1)
  local running = true
  local handle = animate.tween({
    duration = math.min(cfg.animation.open_ms, cfg.animation.stagger_ms * count),
    on_frame = function(eased)
      paint(self, rendered, math.max(1, math.ceil(eased * count)))
    end,
    on_done = function(completed)
      running = false
      self.reveal = nil
      -- A cancelled reveal is about to be replaced by a fresh draw() call;
      -- painting the old content here would be a wasted, briefly-stale frame.
      if completed then
        paint(self, rendered)
      end
    end,
  })
  self.reveal = running and handle or nil
end

--- Installs the shared panel keys on a list buffer: j/k move, <CR> selects.
--- Panels add their own on top; this keeps movement identical everywhere.
function List:install_keys(buf, actions)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("j", function()
    self:move(1)
    self:draw()
  end)
  map("k", function()
    self:move(-1)
    self:draw()
  end)
  map("gg", function()
    self:select(1)
    self:draw()
  end)
  map("G", function()
    self:select(self:count())
    self:draw()
  end)
  for lhs, fn in pairs(actions or {}) do
    map(lhs, fn)
  end
end

M.List = List

return M
