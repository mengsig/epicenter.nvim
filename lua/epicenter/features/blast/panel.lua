--- The blast panel: depth rings over the impacted symbols, live.
---
--- The panel owns its buffer instead of handing it to `ui.list`, because the
--- header must stay pinned above the body and a realtime update has to change
--- only the rows that actually changed. It still uses the kit's pure layer -
--- `ui.list.render`, `ui.list.scroll` and `ui.animate` - for everything below
--- the header, so scrolling and motion behave exactly as they do elsewhere.
local M = {}

local animate = require("epicenter.ui.animate")
local list = require("epicenter.ui.list")
local model = require("epicenter.features.blast.model")
local prompt = require("epicenter.ui.prompt")
local ripples = require("epicenter.features.blast.ripples")
local window = require("epicenter.ui.window")

--- Title, chips, blank. The body starts below them.
local HEADER_ROWS = 3

--- One channel for every panel request, so a newer query always wins - the
--- symbol lookup and the graph query that follows it included.
local CHANNEL = "blast"

--- The protocol's code for a Target that resolves to nothing.
local TARGET_NOT_FOUND = -32001

--- Anchors a cursor target's line across edits (below), so a realtime
--- re-query resolves the same definition the cursor was on even after a
--- line-shifting edit - without pinning to the symbol's name, which can be
--- ambiguous (overloads, same-named methods across files) (F3).
local PIN_NS = vim.api.nvim_create_namespace("epicenter.blast.pin")

local SPLIT_WINHIGHLIGHT = table.concat({
  "Normal:EpicenterNormal",
  "CursorLine:EpicenterSelection",
}, ",")

--- `<CR>` stays open rather than closing-then-jumping (the kit panel's
--- default): this is a persistent, live-updating widget you keep querying
--- from, the same reasoning the outline sidebar's own override documents
--- (F9). `o` is a toggle rather than a one-shot float for the same reason.
M.HELP = {
  "  keys",
  "",
  "  <CR>       jump to the symbol",
  "  <Tab>      add / remove this row from the selection",
  "  <C-Q>      send the rows to the quickfix list",
  "  <C-L>      send the rows to the location list",
  "  <C-V>      open in a vertical split",
  "  <C-T>      open in a new tab",
  "  o          toggle a peek at it without leaving the panel",
  "  y          yank file:line",
  "  +/-        deeper / shallower (the chip names both depths)",
  "  d          flip callers <-> callees",
  "  t          cycle the tests scope (with/without/only)",
  "  s          toggle strict resolution",
  "  f          follow the cursor",
  "  j/k/gg/G   move",
  "  /          filter by name",
  "  ?          toggle this help",
  "  q, <Esc>   close",
}

-- Surface ----------------------------------------------------------------------

--- A float or a vertical split, behind one interface, so the panel has a
--- single paint path for both layouts.
local Surface = {}
Surface.__index = Surface

local function float_surface(title)
  local surface = setmetatable({ kind = "float" }, Surface)
  local function box()
    local ui = require("epicenter.config").get().ui
    return window.box({
      width = ui.width,
      height = ui.height,
      max_width = ui.max_width,
      max_height = ui.max_height,
    })
  end
  -- Exposed so the panel can size itself down to a message and back (D5);
  -- `box()` alone stays private to the reflow closure below.
  surface.full_box = box
  surface.window = window.open({
    box = box(),
    title = title,
    footer = " ^q quickfix · ? keys · q close ",
    enter = true,
    reflow = function()
      local next_box = box()
      surface.target_height = next_box.height
      return next_box
    end,
    on_close = function()
      surface.closed = true
      if surface.on_close then
        surface.on_close()
      end
    end,
  })
  surface.buf = surface.window.buf
  surface.win = surface.window.win
  surface.target_height = surface.window.box.height
  return surface
end

local function split_surface()
  local surface = setmetatable({ kind = "split" }, Surface)
  vim.cmd("vsplit")
  surface.win = vim.api.nvim_get_current_win()
  surface.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(surface.win, surface.buf)
  vim.api.nvim_win_set_width(surface.win, math.max(40, math.floor(vim.o.columns * 0.4)))

  vim.bo[surface.buf].bufhidden = "wipe"
  vim.bo[surface.buf].swapfile = false
  vim.bo[surface.buf].filetype = "epicenter"
  for option, value in pairs({ number = false, relativenumber = false, wrap = false }) do
    vim.wo[surface.win][option] = value
  end
  vim.wo[surface.win].signcolumn = "no"
  vim.wo[surface.win].winhighlight = SPLIT_WINHIGHLIGHT

  surface.augroup = vim.api.nvim_create_augroup("EpicenterBlastSplit", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = surface.augroup,
    pattern = tostring(surface.win),
    callback = function()
      surface:close()
    end,
  })
  return surface
end

function Surface:valid()
  return not self.closed and vim.api.nvim_win_is_valid(self.win)
end

function Surface:height()
  if self.kind == "float" then
    return self.target_height
  end
  return vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_height(self.win) or 1
end

function Surface:width()
  if self.kind == "float" then
    return self.window:content_width()
  end
  return vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_width(self.win) or 1
end

--- Resizes a float in place (D5); a no-op for a split, which keeps whatever
--- height the user gave it (F8) - the same exemption `ui.panel`'s own
--- content-sizing already makes for a split layout.
function Surface:resize(box)
  if self.kind ~= "float" then
    return
  end
  self.window:set_geometry(box)
  self.target_height = box.height
end

function Surface:focus()
  if self:valid() then
    vim.api.nvim_set_current_win(self.win)
  end
end

function Surface:reveal(opts)
  if self.kind == "float" then
    self.window:reveal(opts)
  end
end

function Surface:close()
  if self.closed then
    return
  end
  self.closed = true
  if self.kind == "float" then
    -- The window owns the single teardown path; it calls back into on_close
    -- once its fade is done. The panel already counts as closed.
    self.window:close()
    return
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  if vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  if self.on_close then
    self.on_close()
  end
end

-- Panel ------------------------------------------------------------------------

--- @class epicenter.blast.Panel
local Panel = {}
Panel.__index = Panel

--- At most one panel: the ripples it paints are global to the session.
local current = nil

--- @return epicenter.blast.Panel|nil
function M.current()
  return current and current:valid() and current or nil
end

local function initial_state(cfg)
  return {
    depth = model.clamp_depth(cfg.blast.depth, cfg.blast.max_depth),
    direction = cfg.blast.direction,
    tests = cfg.blast.tests,
    strict = cfg.blast.strict,
    follow = false,
  }
end

--- @param opts { kind: "blast"|"diff"|"impact", target: table, bufnr?: integer }
--- @return epicenter.blast.Panel
function M.open(opts)
  local existing = M.current()
  if existing then
    existing:set_query(opts.kind, opts.target, opts.bufnr)
    existing:focus()
    return existing
  end

  local cfg = require("epicenter.config").get()
  local self = setmetatable({
    kind = opts.kind,
    target = opts.target,
    state = initial_state(cfg),
    origin_win = vim.api.nvim_get_current_win(),
    origin_buf = opts.bufnr or vim.api.nvim_get_current_buf(),
    nodes = {},
    rows = {},
    summary = model.empty_summary(),
    meta = { kind = opts.kind, ref = opts.target.ref },
    selected = 1,
    top = 1,
    --- `<Tab>`-toggled rows, keyed by the row table itself.
    marked = {},
    help_open = false,
    empty_text = "  nothing impacted",
    --- Bumped every time a query is answered - the panel's "settled" signal.
    answered = 0,
    --- Bumped on every query; a callback from an older one is discarded.
    generation = 0,
    --- Test seam: forwarded to every tween this panel starts.
    animate_opts = {},
    ns = vim.api.nvim_create_namespace("epicenter.blast"),
  }, Panel)

  self.surface = cfg.blast.layout == "vsplit" and split_surface() or float_surface(" blast ")
  self.surface.on_close = function()
    self:_cleanup()
  end
  self:_install_keys()
  self:_watch(cfg)
  self:_paint()
  self.surface:reveal(self.animate_opts)

  if opts.target.position then
    self:_anchor(opts.target.position.line, opts.target.position.character)
  end

  current = self
  self:query({ first = true })
  return self
end

function Panel:valid()
  return not self.closed and self.surface:valid()
end

function Panel:focus()
  self.surface:focus()
end

-- Query ------------------------------------------------------------------------

function Panel:_cancel_pending()
  if self.pending then
    self.pending.cancel()
    self.pending = nil
  end
end

--- Deletes the anchor extmark, if any, and forgets it.
function Panel:_clear_anchor()
  if self.pin_mark and self.pin_buf and vim.api.nvim_buf_is_valid(self.pin_buf) then
    pcall(vim.api.nvim_buf_del_extmark, self.pin_buf, PIN_NS, self.pin_mark)
  end
  self.pin_buf, self.pin_mark, self.pin_col = nil, nil, nil
end

--- Anchors `self.origin_buf`'s `line` (0-based) via an extmark, replacing
--- any earlier anchor - `nvim` keeps it on the right line as edits land.
--- Follow mode can change `origin_buf` between anchors, so a mark left in a
--- buffer we have since moved off never gets picked up again - delete it.
function Panel:_anchor(line, character)
  if self.pin_buf and self.pin_buf ~= self.origin_buf then
    self:_clear_anchor()
  end
  if not vim.api.nvim_buf_is_valid(self.origin_buf) then
    self:_clear_anchor()
    return
  end
  self.pin_mark = vim.api.nvim_buf_set_extmark(self.origin_buf, PIN_NS, line, 0, {
    id = self.pin_mark,
  })
  self.pin_buf = self.origin_buf
  self.pin_col = character or 0
end

--- The anchor's current position, or nil once it and its buffer are gone.
function Panel:_anchored_target()
  if not (self.pin_mark and self.pin_buf and vim.api.nvim_buf_is_valid(self.pin_buf)) then
    return nil
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(self.pin_buf, PIN_NS, self.pin_mark, {})
  if not mark[1] then
    return nil
  end
  -- Re-snap the column here, not at anchor time: the extmark follows the line
  -- across edits, and an edit can change that line's indentation under it.
  local column =
    require("epicenter.features.blast").column_at(self.pin_buf, mark[1], self.pin_col or 0)
  return {
    uri = vim.uri_from_bufnr(self.pin_buf),
    position = { line = mark[1], character = column },
  }
end

--- Points the panel at a new target (a new cursor position, a named symbol, a
--- diff ref) and re-queries.
function Panel:set_query(kind, target, bufnr)
  self.kind = kind
  self.target = target
  self.meta = { kind = kind, ref = target.ref, root = self.meta and self.meta.root or nil }
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    self.origin_buf = bufnr
  end
  if target.position then
    self:_anchor(target.position.line, target.position.character)
  else
    self:_clear_anchor()
  end
  self:query({})
end

--- @param opts? { first?: boolean, realtime?: boolean }
function Panel:query(opts)
  opts = opts or {}
  if not self:valid() then
    return
  end
  self:_cancel_pending()
  self.generation = self.generation + 1
  local generation = self.generation

  if self.kind == "diff" then
    local params = model.params(self.state, { ref = self.target.ref or "HEAD" })
    return self:_request("diff", params, opts, generation)
  end
  -- The working change has no target at all: the hunks ARE the roots.
  if self.kind == "impact" then
    return self:_request("impact", model.params(self.state, {}), opts, generation)
  end
  if self.target.symbol then
    return self:_request("blast", model.params(self.state, self.target), opts, generation)
  end
  -- Re-derive the position from the anchor (if one exists) rather than
  -- trusting a stale `self.target.position` a line-shifting edit invalidated.
  self.target = self:_anchored_target() or self.target
  self:_resolve_cursor(opts, generation)
end

--- A response for a query the panel has already replaced. The transport drops
--- these too, but only up to the moment it hands one over - the callback runs
--- a scheduler tick later, by which time a key may have re-queried.
function Panel:_superseded(generation)
  return not self:valid() or generation ~= self.generation
end

--- Turns a cursor position into a symbol before querying, so the header can
--- name the root and a position with no definition says so. Shared with the
--- hover card and the callers/callees explorer (F10 parity).
function Panel:_resolve_cursor(opts, generation)
  local blast = require("epicenter.features.blast")
  self.pending = blast.resolve_target(self.target, function(err, target)
    self.pending = nil
    vim.schedule(function()
      if self:_superseded(generation) then
        return
      end
      if err then
        return self:_show_message(err.message or "navgraph did not answer")
      end
      if not target then
        return self:_show_message("no symbol under the cursor")
      end
      self:_request("blast", model.params(self.state, target), opts, generation)
    end)
  end, { bufnr = self.origin_buf, channel = CHANNEL })
end

function Panel:_request(method, params, opts, generation)
  local client = require("epicenter.client")
  self.pending = client[method](params, function(err, result)
    self.pending = nil
    vim.schedule(function()
      if self:_superseded(generation) then
        return
      end
      self:_on_result(err, result, opts)
    end)
  end, { bufnr = self.origin_buf, channel = CHANNEL })
end

--- `navgraph/diff` wraps a blast result; `navgraph/blast` is one.
--- @return table blast payload, integer|nil changed-symbol count
local function unwrap(kind, result)
  -- An impact answer IS a blast result (plus hunks); its roots are the
  -- changed definitions, exactly as a diff's are.
  if kind == "impact" then
    return result, #(result.roots or {})
  end
  if kind ~= "diff" then
    return result, nil
  end
  local blast = result.blast or { nodes = {}, roots = {}, summary = model.empty_summary() }
  -- The changed set IS the roots the walk started from.
  return blast, #(blast.roots or {})
end

function Panel:_on_result(err, result, opts)
  if not self:valid() then
    return
  end
  if err then
    if err.code == TARGET_NOT_FOUND then
      local named = self.target.symbol
      return self:_show_message(
        named and ("no symbol named " .. named) or "no symbol under the cursor"
      )
    end
    return self:_show_message(err.message or "the query failed")
  end

  self.answered = self.answered + 1
  self.message = nil
  local blast, changed = unwrap(self.kind, result)
  local roots = blast.roots or {}
  self.meta = {
    kind = self.kind,
    root = roots[1],
    ref = result.ref or self.target.ref,
    hunks = result.hunks and #result.hunks or nil,
  }

  local summary = vim.tbl_extend("force", model.empty_summary(), blast.summary or {})
  summary.changed = changed

  local nodes = model.nodes(blast)
  if opts.realtime and #self.nodes > 0 then
    self:_transition(nodes, summary)
  else
    self:_set_nodes(nodes, summary)
    self:_paint({ stagger = not opts.realtime })
  end
  ripples.apply(self.nodes)
  self:_populated()
end

function Panel:_show_message(message)
  self.answered = self.answered + 1
  self.message = "  " .. message
  -- The header names `self.meta.root`. Leaving the PREVIOUS answer's root
  -- there renders a title naming a symbol, a chip line of zeros, and a body
  -- saying there is none - three lines contradicting each other (F3).
  self.meta = { kind = self.kind, ref = self.target.ref }
  self:_set_nodes({}, model.empty_summary())
  self:_paint()
  ripples.apply({})
  self:_populated()
end

--- @param summary table the server's blast summary for `nodes`
function Panel:_set_nodes(nodes, summary)
  self.nodes = nodes
  self.rows = model.rows(nodes)
  -- Fresh row tables: a mark kept here would point at rows that are gone.
  self.marked = {}
  self.summary = summary or self.summary
  self:_clamp_selection()
end

function Panel:_clamp_selection()
  if #self.rows == 0 then
    self.selected, self.top = 1, 1
    return
  end
  self.selected = math.max(1, math.min(self.selected, #self.rows))
  if self.rows[self.selected].kind ~= "node" then
    for i, row in ipairs(self.rows) do
      if row.kind == "node" then
        self.selected = i
        return
      end
    end
  end
end

-- Realtime ----------------------------------------------------------------------

local COUNTED = { "symbols", "files", "tests", "maxDepth", "changed" }

local function tick(from, to, eased)
  local out = vim.tbl_extend("force", {}, to)
  for _, key in ipairs(COUNTED) do
    if to[key] then
      out[key] = math.floor((from[key] or 0) + ((to[key] - (from[key] or 0)) * eased) + 0.5)
    end
  end
  return out
end

--- Plays the change instead of rebuilding: the rows that left stay in place,
--- dimmed, the rows that arrived flash the accent, the chips count across.
function Panel:_transition(next_nodes, summary)
  local delta = model.diff(self.nodes, next_nodes)
  self.last_delta = delta
  if #delta.added == 0 and #delta.removed == 0 then
    self:_set_nodes(next_nodes, summary)
    self:_paint()
    return
  end

  -- Paint the union first - the chips already read the new summary - then
  -- count them up to it from the old one.
  local from, to = self.summary, summary
  self:_set_nodes(model.transition(self.nodes, next_nodes), summary)
  self:_paint()

  local cfg = require("epicenter.config").get()
  if self.transition_tween then
    self.transition_tween.cancel()
  end
  self.transition_tween = animate.tween(vim.tbl_extend("force", {
    duration = cfg.animation.open_ms * 2,
    on_frame = function(eased)
      self:_paint_chips(tick(from, to, eased))
    end,
    on_done = function()
      self.transition_tween = nil
      if not self:valid() then
        return
      end
      self:_set_nodes(next_nodes, summary)
      self:_paint()
      ripples.apply(self.nodes)
    end,
  }, self.animate_opts))
end

-- Painting ----------------------------------------------------------------------

--- Shrinks the float to a message-sized box while there is nothing to show
--- but a one-line answer, and restores the full box the moment there is
--- more (D5). A stable box is right while nodes are showing - +/-/d/t/j/k
--- must never resize the panel out from under the cursor - but the same box
--- for "no symbol under the cursor" sits mostly empty; help always gets the
--- full box back, since its own line count needs it.
function Panel:_resize_for_state()
  if not self.surface.full_box then
    return
  end
  local full = self.surface.full_box()
  local target = (self.message and not self.help_open)
      and window.box({
        width = full.width,
        height = HEADER_ROWS + 1,
        max_width = full.width,
        max_height = full.height,
      })
    or full
  if
    target.height ~= self.surface.window.box.height
    or target.width ~= self.surface.window.box.width
  then
    self.surface:resize(target)
  end
end

function Panel:_body_height()
  return math.max(1, self.surface:height() - HEADER_ROWS)
end

function Panel:_header(summary)
  local width = self.surface:width()
  local title = model.title_line(self.meta, width)
  local chips = model.chips_line(summary or self.summary, self.state, width)
  local spans = {}
  for row, rendered in ipairs({ title, chips }) do
    for _, span in ipairs(rendered.spans) do
      table.insert(spans, { row = row - 1, hl = span.hl, from = span.from, to = span.to })
    end
  end
  return { lines = { title.text, chips.text }, spans = spans }
end

function Panel:_mark(row, span)
  pcall(vim.api.nvim_buf_set_extmark, self.surface.buf, self.ns, row, span.from, {
    end_col = span.to,
    hl_group = span.hl,
    strict = false,
  })
end

--- Writes the header plus the first `shown` body rows. The single place that
--- touches the buffer.
function Panel:_write(header, rendered, shown)
  local buf = self.surface.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local body = vim.list_slice(rendered.lines, 1, shown)
  local lines = { header.lines[1], header.lines[2], "" }
  vim.list_extend(lines, body)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  for _, span in ipairs(header.spans) do
    self:_mark(span.row, span)
  end
  for _, span in ipairs(rendered.spans) do
    if span.row < #body then
      self:_mark(HEADER_ROWS + span.row, span)
    end
  end
  if rendered.selected_row and rendered.selected_row < #body then
    vim.api.nvim_buf_set_extmark(buf, self.ns, HEADER_ROWS + rendered.selected_row, 0, {
      line_hl_group = "EpicenterSelection",
    })
  end
  for offset = 0, #body - 1 do
    local row = not self.help_open and self.rows[self.top + offset] or nil
    if row and row.kind == "node" and row.node.state == "added" then
      vim.api.nvim_buf_set_extmark(buf, self.ns, HEADER_ROWS + offset, 0, {
        line_hl_group = "EpicenterRange",
      })
    end
  end
  local glyph = require("epicenter.ui.icons").ui("marked")
  for _, offset in ipairs(rendered.marked_rows or {}) do
    if offset < #body then
      pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, HEADER_ROWS + offset, 0, {
        virt_text = { { glyph, "EpicenterAccent" } },
        virt_text_pos = "overlay",
        strict = false,
      })
    end
  end
end

--- @param opts? { stagger?: boolean }
function Panel:_paint(opts)
  opts = opts or {}
  if not self:valid() then
    return
  end
  self:_resize_for_state()
  local header = self:_header()
  if self.help_open then
    self:_write(header, { lines = M.HELP, spans = {} }, #M.HELP)
    return
  end

  local height = self:_body_height()
  self.top = list.scroll(#self.rows, height, self.selected, self.top)
  local rendered = list.render({
    items = self.rows,
    top = self.top,
    height = height,
    selected = self.selected,
    render_item = model.render_row,
    empty_text = self.message or self.empty_text,
    marked = self.marked,
  })

  if self.reveal_tween then
    self.reveal_tween.cancel()
    self.reveal_tween = nil
  end
  local count = #rendered.lines
  if not opts.stagger or count <= 1 then
    self:_write(header, rendered, count)
    return
  end

  local cfg = require("epicenter.config").get()
  self:_write(header, rendered, 1)
  self.reveal_tween = animate.tween(vim.tbl_extend("force", {
    duration = math.min(cfg.animation.open_ms, cfg.animation.stagger_ms * count),
    on_frame = function(eased)
      self:_write(header, rendered, math.max(1, math.ceil(eased * count)))
    end,
    on_done = function()
      self.reveal_tween = nil
      self:_write(header, rendered, count)
    end,
  }, self.animate_opts))
end

--- Rewrites only the chips line, so the counts can tick during a transition
--- without disturbing the rows underneath.
function Panel:_paint_chips(summary)
  local buf = self.surface.buf
  if not self:valid() or not vim.api.nvim_buf_is_valid(buf) or self.help_open then
    return
  end
  local chips = model.chips_line(summary, self.state, self.surface:width())
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { chips.text })
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 1, 2)
  for _, span in ipairs(chips.spans) do
    self:_mark(1, span)
  end
end

-- Actions -----------------------------------------------------------------------

function Panel:move(delta)
  local total = #self.rows
  if total == 0 then
    return
  end
  local index = self.selected
  for _ = 1, total do
    index = ((index - 1 + delta) % total) + 1
    if self.rows[index].kind == "node" then
      break
    end
  end
  self.selected = index
  self:_paint()
end

function Panel:current_target()
  return model.target(self.rows[self.selected])
end

--- Selects the first row whose name contains the typed text (F9): this
--- panel paints its own selection and ignores real cursor movement inside
--- its own buffer (see `on_cursor_moved`), so leaving `/` unbound let Vim's
--- own search move the cursor without moving the selection it acts on.
function Panel:_filter()
  vim.ui.input({ prompt = "filter: " }, function(text)
    if not text or text == "" or not self:valid() then
      return
    end
    local query = text:lower()
    for index, row in ipairs(self.rows) do
      local symbol = row.kind == "node" and row.node.symbol
      local name = symbol and (symbol.qualified or symbol.name)
      if name and name:lower():find(query, 1, true) then
        self.selected = index
        self:_paint()
        return
      end
    end
    require("epicenter").notify("no match for " .. text, "warn")
  end)
end

--- Window to jump into: the one the panel was opened from, else any window
--- that is not the panel itself.
function Panel:_jump_win()
  if vim.api.nvim_win_is_valid(self.origin_win) and self.origin_win ~= self.surface.win then
    return self.origin_win
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= self.surface.win and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  return nil
end

--- @param action? "edit"|"tab"|"vsplit"|"split" - see `ui.panel.jump` (F9):
---   the mechanics (jumplist mark, open command, cursor, zz) are shared with
---   every other panel; only finding the window to jump into is blast's own,
---   since this panel stays open rather than closing into `previous_win`.
function Panel:jump(action)
  local target = self:current_target()
  if not target then
    return
  end
  local win = self:_jump_win()
  if not win then
    return require("epicenter").notify("no window to jump into", "warn")
  end
  vim.api.nvim_set_current_win(win)
  require("epicenter.ui.panel").jump(target, action)
  -- A split/tab action leaves a NEW window current, not `win` - track
  -- wherever the jump actually landed.
  self.origin_win = vim.api.nvim_get_current_win()
  self.origin_buf = vim.api.nvim_get_current_buf()
end

function Panel:_close_peek()
  if self.peek_win then
    self.peek_win:close()
    self.peek_win = nil
  end
end

--- Shows the selected definition without leaving the panel.
function Panel:peek()
  if self.peek_win then
    return self:_close_peek()
  end
  local target = self:current_target()
  if not target then
    return
  end
  local preview = require("epicenter.ui.preview")
  local box = window.box({ width = 0.6, height = 0.4, max_width = 100, max_height = 20 })
  self.peek_win = window.open({
    box = box,
    title = (" %s "):format(vim.fn.fnamemodify(target.path, ":~:.")),
    focusable = false,
    zindex = 200,
  })
  -- The preview paints into the window's buffer here and is not needed again;
  -- keeping it on `self` would shadow this very method.
  preview
    .new({ buf = self.peek_win.buf, win = self.peek_win.win, height = box.height })
    :show(target)
  self.peek_win:reveal(self.animate_opts)
end

function Panel:yank()
  local target = self:current_target()
  if target then
    require("epicenter.ui.panel").yank(target)
  end
end

--- Toggles the current row's `<Tab>` mark and steps on, so a selection is
--- built by holding one key.
function Panel:toggle_mark()
  local row = self.rows[self.selected]
  if not row or row.kind ~= "node" then
    return
  end
  self.marked[row] = not self.marked[row] or nil
  self:move(1)
end

--- The rows an export sends: the `<Tab>` selection, or every impacted symbol.
--- @return epicenter.qf.Row[]
function Panel:export_rows()
  local chosen = {}
  for _, row in ipairs(self.rows) do
    if row.kind == "node" and (next(self.marked) == nil or self.marked[row]) then
      table.insert(chosen, row)
    end
  end
  local out = {}
  for index, row in ipairs(chosen) do
    local target = model.target(row)
    if target then
      table.insert(out, { target = target, text = model.render_row(row, index).text })
    end
  end
  return out
end

--- @param list_kind "quickfix"|"loclist"
function Panel:export(list_kind)
  local rows = self:export_rows()
  local title = ("epicenter %s"):format(self.kind)
  self:close()
  vim.schedule(function()
    require("epicenter.ui.qf").send_and_notify({ rows = rows, list = list_kind, title = title })
  end)
end

--- Registers a callback for each answered query, for the `--qf`/`--loc`
--- command flags: the rows only exist once the server has answered.
--- @param fn fun(panel: epicenter.blast.Panel)
function Panel:on_populate(fn)
  self.populate_hooks = self.populate_hooks or {}
  table.insert(self.populate_hooks, fn)
end

function Panel:_populated()
  for _, fn in ipairs(self.populate_hooks or {}) do
    fn(self)
  end
end

function Panel:set_depth(delta)
  local max = require("epicenter.config").get().blast.max_depth
  local next_depth = model.clamp_depth(self.state.depth + delta, max)
  if next_depth == self.state.depth then
    -- Silence here is indistinguishable from a dead key (F2).
    return require("epicenter").notify(
      delta > 0 and ("depth is already at its maximum, %d"):format(max) or "depth is already 1"
    )
  end
  self.state.depth = next_depth
  self:query({})
end

function Panel:flip_direction()
  self.state.direction = model.flip_direction(self.state.direction)
  self:query({})
end

function Panel:cycle_tests()
  self.state.tests = model.cycle_tests(self.state.tests)
  self:query({})
end

function Panel:toggle_strict()
  self.state.strict = not self.state.strict
  self:query({})
end

--- Follow hands focus back to the code: the panel re-targets as the cursor
--- moves, so it cannot also hold the cursor.
function Panel:toggle_follow()
  self.state.follow = not self.state.follow
  if self.state.follow then
    local win = self:_jump_win()
    if win then
      vim.api.nvim_set_current_win(win)
    end
  end
  self:_paint()
end

function Panel:toggle_help()
  self.help_open = not self.help_open
  self:_paint()
end

-- Wiring ------------------------------------------------------------------------

function Panel:_install_keys()
  local buf = self.surface.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  map("j", function()
    self:move(1)
  end)
  map("k", function()
    self:move(-1)
  end)
  map("gg", function()
    self.selected = 1
    self:_clamp_selection()
    self:_paint()
  end)
  map("G", function()
    self.selected = #self.rows
    self:_clamp_selection()
    self:_paint()
  end)
  map("<CR>", function()
    self:jump()
  end)
  map("<C-v>", function()
    self:jump("vsplit")
  end)
  map("<C-t>", function()
    self:jump("tab")
  end)
  map("o", function()
    self:peek()
  end)
  map("y", function()
    self:yank()
  end)
  map("<Tab>", function()
    self:toggle_mark()
  end)
  map("<C-q>", function()
    self:export("quickfix")
  end)
  map("<C-l>", function()
    self:export("loclist")
  end)
  map("/", function()
    self:_filter()
  end)
  map("+", function()
    self:set_depth(1)
  end)
  map("-", function()
    self:set_depth(-1)
  end)
  map("d", function()
    self:flip_direction()
  end)
  map("t", function()
    self:cycle_tests()
  end)
  map("s", function()
    self:toggle_strict()
  end)
  map("f", function()
    self:toggle_follow()
  end)
  map("?", function()
    self:toggle_help()
  end)
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    map(lhs, function()
      self:close()
    end)
  end
end

--- Re-queries on a reindex (debounced) and, in follow mode, as the cursor
--- moves in any other window.
function Panel:_watch(cfg)
  local events = require("epicenter.events")

  self.realtime = prompt.debounce(cfg.blast.realtime_debounce_ms, function()
    if self:valid() then
      self:query({ realtime = true })
    end
  end)
  self.unsubscribe = events.on(events.INDEXED, function()
    self.realtime.call()
  end)

  self.follow_debouncer = prompt.debounce(cfg.blast.follow_debounce_ms, function(bufnr, position)
    if not self:valid() or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    self:set_query("blast", {
      uri = vim.uri_from_bufnr(bufnr),
      position = position,
    }, bufnr)
  end)

  self.augroup = vim.api.nvim_create_augroup("EpicenterBlastPanel", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = self.augroup,
    callback = function(event)
      self:on_cursor_moved(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      self:_paint()
    end,
  })
end

--- @param bufnr integer buffer the cursor moved in
function Panel:on_cursor_moved(bufnr)
  if not self.state.follow or not self:valid() or bufnr == self.surface.buf then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if win == self.surface.win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  self.follow_debouncer.call(bufnr, { line = cursor[1] - 1, character = cursor[2] })
end

function Panel:close()
  self:_close_peek()
  self.surface:close()
end

--- Single teardown path: reached by `close()` and by the window closing.
function Panel:_cleanup()
  if self.closed then
    return
  end
  self.closed = true
  self:_cancel_pending()
  for _, field in ipairs({ "reveal_tween", "transition_tween" }) do
    if self[field] then
      self[field].cancel()
      self[field] = nil
    end
  end
  for _, field in ipairs({ "realtime", "follow_debouncer" }) do
    if self[field] then
      self[field].close()
      self[field] = nil
    end
  end
  if self.unsubscribe then
    self.unsubscribe()
    self.unsubscribe = nil
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  self:_clear_anchor()
  self:_close_peek()
  ripples.clear()
  if current == self then
    current = nil
  end
end

M.Panel = Panel
M.HEADER_ROWS = HEADER_ROWS

return M
