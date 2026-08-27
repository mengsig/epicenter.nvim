--- Hover card: what this symbol is, how connected it is, and who calls it -
--- one float, one request.
---
--- Rendering is a pure function over the server's answer, so the card's
--- content is testable without opening a window.
local M = {}

local model = require("epicenter.features.blast.model")
local window = require("epicenter.ui.window")

local append = model.append

--- Treesitter spans for one signature line, offset by `offset` bytes.
--- Best effort: no parser for the language means no colour, never an error.
--- @return table[] spans
function M.signature_spans(sig, path, offset)
  local filetype = vim.filetype.match({ filename = path })
  local lang = filetype and vim.treesitter.language.get_lang(filetype) or nil
  if not lang then
    return {}
  end
  local ok, spans = pcall(function()
    local parser = vim.treesitter.get_string_parser(sig, lang)
    local query = vim.treesitter.query.get(lang, "highlights")
    local tree = parser:parse()[1]
    if not (query and tree) then
      return {}
    end
    local out = {}
    for id, node in query:iter_captures(tree:root(), sig, 0, 1) do
      local _, from, _, to = node:range()
      table.insert(out, { hl = "@" .. query.captures[id], from = offset + from, to = offset + to })
    end
    return out
  end)
  return ok and spans or {}
end

local function counts_line(symbol)
  local icons = require("epicenter.ui.icons")
  local spans, text = {}, ""
  local inbound = model.plural(symbol.callers or 0, "caller")
  local outbound = model.plural(symbol.callees or 0, "callee")
  text = append(text, spans, ("  %s %s"):format(icons.ui("fan_in"), inbound), "EpicenterCount")
  text = append(text, spans, ("   %s %s"):format(icons.ui("fan_out"), outbound), "EpicenterCount")
  local range = symbol.endLine
      and symbol.endLine > symbol.line
      and ("%s:%d-%d"):format(symbol.file, symbol.line, symbol.endLine)
    or ("%s:%d"):format(symbol.file, symbol.line)
  return { text = append(text, spans, "    " .. range, "EpicenterMuted"), spans = spans }
end

--- @param payload { symbol: table, items: table[], total: integer }
--- @return { lines: string[], spans: table[], targets: table<integer, table>, rows: integer[] }
function M.render(payload)
  local icons = require("epicenter.ui.icons")
  local symbol = payload.symbol
  local lines, spans, targets, rows = {}, {}, {}, {}

  local function put(rendered)
    for _, span in ipairs(rendered.spans or {}) do
      table.insert(spans, { row = #lines, hl = span.hl, from = span.from, to = span.to })
    end
    table.insert(lines, rendered.text)
  end

  local head, head_spans = "", {}
  head = append(head, head_spans, "  " .. icons.kind(symbol.kind) .. " ", "EpicenterAccent")
  head = append(head, head_spans, symbol.qualified or symbol.name or "?", "EpicenterTitle")
  put({ text = head, spans = head_spans })

  local sig = vim.trim(symbol.sig or "")
  if sig ~= "" then
    local path = symbol.uri and vim.uri_to_fname(symbol.uri) or symbol.file
    put({ text = "  " .. sig, spans = M.signature_spans(sig, path, 2) })
  end

  put({ text = "" })
  put(counts_line(symbol))

  if symbol.doc and symbol.doc ~= "" then
    put({ text = "" })
    for _, line in ipairs(vim.split(symbol.doc, "\n", { plain = true })) do
      put({ text = "  " .. line, spans = { { hl = "EpicenterMuted", from = 0, to = #line + 2 } } })
    end
  end

  if #(payload.items or {}) > 0 then
    put({ text = "" })
    local total = payload.total or #payload.items
    local heading = #payload.items < total
        and ("  top callers  %d of %d"):format(#payload.items, total)
      or "  top callers"
    put({ text = heading, spans = { { hl = "EpicenterMuted", from = 0, to = #heading } } })
    for _, item in ipairs(payload.items) do
      local caller = item.symbol
      local text, row_spans = "", {}
      text = append(text, row_spans, "    " .. icons.kind(caller.kind) .. " ", "EpicenterMuted")
      text = append(text, row_spans, caller.qualified or caller.name or "?", "EpicenterNormal")
      text = append(text, row_spans, ("  %s:%d"):format(caller.file, caller.line), "EpicenterMuted")
      table.insert(rows, #lines)
      targets[#lines] = {
        path = vim.uri_to_fname(caller.uri),
        line = caller.line,
        end_line = caller.endLine,
      }
      put({ text = text, spans = row_spans })
    end
  end

  return { lines = lines, spans = spans, targets = targets, rows = rows }
end

-- The card -----------------------------------------------------------------------

--- @class epicenter.blast.Card
local Card = {}
Card.__index = Card

local current = nil

--- @return epicenter.blast.Card|nil
function M.current()
  return current and current:valid() and current or nil
end

--- Box anchored under the cursor, flipped above when there is no room below.
local function anchor_box(width, height)
  local editor_lines = vim.o.lines - vim.o.cmdheight - 1
  width = math.max(20, math.min(width, vim.o.columns - 4))
  height = math.max(1, math.min(height, editor_lines - 4))

  local cursor = vim.api.nvim_win_get_cursor(0)
  local screen = vim.fn.screenpos(0, cursor[1], cursor[2] + 1)
  if screen.row == 0 then
    return window.box({ width = width, height = height })
  end
  local below, above = screen.row + 1, screen.row - height - 3
  local row = (below + height + 2 <= editor_lines) and below or math.max(0, above)
  return {
    row = row,
    col = math.max(0, math.min(screen.col - 1, vim.o.columns - width - 2)),
    width = width,
    height = height,
  }
end

--- @param bufnr integer buffer whose cursor the card describes
--- @return epicenter.blast.Card
function M.open(bufnr)
  local existing = M.current()
  if existing then
    existing:focus()
    return existing
  end

  local cfg = require("epicenter.config").get()
  local client = require("epicenter.client")
  local blast = require("epicenter.features.blast")
  local target = blast.cursor_target(bufnr)

  local self = setmetatable({
    origin_buf = bufnr,
    origin_win = vim.api.nvim_get_current_win(),
    selected = 1,
    ns = vim.api.nvim_create_namespace("epicenter.hover"),
    answered = 0,
  }, Card)
  current = self

  self.pending = client.callers({
    uri = target.uri,
    position = target.position,
    depth = 1,
    limit = cfg.hover.callers,
  }, function(err, result)
    vim.schedule(function()
      self:_show(err, result)
    end)
  end, { bufnr = bufnr, channel = "hover" })

  return self
end

function Card:valid()
  return not self.closed and self.win ~= nil and self.win:valid()
end

function Card:focus()
  if self:valid() then
    self.win:focus()
  end
end

function Card:_show(err, result)
  self.answered = self.answered + 1
  self.pending = nil
  if self.closed then
    return
  end
  local symbol = result and result.symbol
  if err or not symbol or symbol == vim.NIL then
    self.closed = true
    current = nil
    require("epicenter").notify(
      err and (err.message or "navgraph did not answer") or "no symbol under the cursor",
      err and "error" or "info"
    )
    return
  end

  self.card = M.render({
    symbol = symbol,
    items = result.items or {},
    total = result.total or #(result.items or {}),
  })

  local width = 0
  for _, line in ipairs(self.card.lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
  end
  local cfg = require("epicenter.config").get()
  self.win = window.open({
    box = anchor_box(math.min(width, cfg.hover.max_width), #self.card.lines),
    title = " hover ",
    zindex = 150,
    on_close = function()
      self:_cleanup()
    end,
  })
  self:_paint()
  self.win:reveal()
  self:_install_keys()
  self:_watch()
end

function Card:_paint()
  if not self:valid() then
    return
  end
  self.win:set_lines(self.card.lines)
  local buf = self.win.buf
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  for _, span in ipairs(self.card.spans) do
    pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, span.row, span.from, {
      end_col = span.to,
      hl_group = span.hl,
      strict = false,
    })
  end
  local row = self.card.rows[self.selected]
  if row then
    vim.api.nvim_buf_set_extmark(buf, self.ns, row, 0, { line_hl_group = "EpicenterSelection" })
  end
end

function Card:move(delta)
  local total = #self.card.rows
  if total == 0 then
    return
  end
  self.selected = ((self.selected - 1 + delta) % total) + 1
  self:_paint()
end

function Card:jump()
  local target = self.card.targets[self.card.rows[self.selected] or -1]
  if not target then
    return
  end
  self:close()
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(self.origin_win) then
      vim.api.nvim_set_current_win(self.origin_win)
    end
    vim.cmd("normal! m'")
    vim.cmd("edit " .. vim.fn.fnameescape(target.path))
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(target.line, last)), 0 })
    vim.cmd("normal! zz")
  end)
end

function Card:_install_keys()
  local buf = self.win.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("j", function()
    self:move(1)
  end)
  map("k", function()
    self:move(-1)
  end)
  map("<CR>", function()
    self:jump()
  end)
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    map(lhs, function()
      self:close()
    end)
  end
end

--- Dismissed by moving on, like any hover - but stepping INTO the card is not
--- moving on, and closing a window from inside a window-change event is not
--- allowed, so the close is guarded and deferred.
function Card:_watch()
  self.augroup = vim.api.nvim_create_augroup("EpicenterHover", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    group = self.augroup,
    buffer = self.origin_buf,
    callback = function()
      if not self:valid() or vim.api.nvim_get_current_win() == self.win.win then
        return
      end
      vim.schedule(function()
        self:close()
      end)
    end,
  })
end

function Card:close()
  if self.win then
    self.win:close()
    return
  end
  self:_cleanup()
end

function Card:_cleanup()
  if self.closed then
    return
  end
  self.closed = true
  if self.pending then
    self.pending.cancel()
    self.pending = nil
  end
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  if current == self then
    current = nil
  end
end

M.Card = Card

return M
