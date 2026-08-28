--- The search palette: fuzzy symbol search and repo-wide grep on the same
--- widget, both live on every keystroke.
--- No config requires at file scope - see `epicenter.registry`.
local M = {}

local OPEN_COMMAND = { edit = "edit", tab = "tabedit", vsplit = "vsplit", split = "split" }

--- Kind filters cycled by <C-k>. `nil` kinds means every kind.
local KIND_CYCLE = {
  { label = nil, kinds = nil },
  { label = "functions", kinds = { "fn", "method" } },
  { label = "types", kinds = { "class", "struct", "type", "enum", "interface" } },
  { label = "values", kinds = { "const", "var", "field" } },
}

--- The three things one palette can be looking at. `<C-space>` cycles them
--- in this order; the source, the rows and the jump all follow the mode, so
--- switching is a keystroke rather than a different command.
local MODES = { "symbols", "grep", "refs" }

local MODE_TITLE = {
  symbols = " search ",
  grep = " grep ",
  refs = " references ",
}

local SHARED_HELP = {
  "  <CR>        jump to the result",
  "  <C-t>       open in a new tab",
  "  <C-v>       open in a vertical split",
  "  <C-x>       open in a split",
  "  <C-n>/<C-p> next / previous result",
  "  <C-space>   symbols -> grep -> references",
  "  <C-y>       yank file:line",
  "  <C-q>/<C-l> send the rows to the quickfix / location list",
  "  ?           toggle this help (normal mode)",
  "  <Esc>       close",
}

local MODE_HELP = {
  symbols = { "  <C-k>       cycle the kind filter" },
  grep = { "  <C-r>       toggle regex" },
  refs = { "  <C-k>       cycle the kind filter" },
}

--- Help for the mode the palette is in. Pure.
--- @return string[]
function M.help_lines(state)
  local lines = { "  keys", "" }
  vim.list_extend(lines, MODE_HELP[state.mode] or {})
  vim.list_extend(lines, SHARED_HELP)
  return lines
end

--- The mode after `<C-space>`. Pure.
--- @return string
function M.next_mode(mode)
  for index, name in ipairs(MODES) do
    if name == mode then
      return MODES[(index % #MODES) + 1]
    end
  end
  return MODES[1]
end

--- Opens `path` at `line` (1-based), leaving the jumplist entry behind.
local function jump(target, action)
  vim.cmd("normal! m'")
  vim.cmd(("%s %s"):format(OPEN_COMMAND[action] or "edit", vim.fn.fnameescape(target.path)))
  local line = math.max(1, math.min(target.line, vim.api.nvim_buf_line_count(0)))
  local line_len = #(vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or "")
  local col = math.max(0, math.min(target.character or 0, line_len))
  vim.api.nvim_win_set_cursor(0, { line, col })
  vim.cmd("normal! zz")
end

--- Row for a `navgraph/search` item: kind icon, qualified name with the
--- matched characters lit, location, fan-in. The file elides before the line
--- number or the fan-in count ever do (F12).
--- @param item { symbol: table, matches: integer[] } matches: 0-based byte
---   indices into symbol.qualified (contract pinned in protocol.md, not row-relative)
--- @param width integer|nil the panel's current width; nil skips fitting
function M.render_symbol(item, _, width)
  local icons = require("epicenter.ui.icons")
  local text_mod = require("epicenter.ui.text")
  local symbol = item.symbol
  local spans = {}
  local prefix = " " .. icons.kind(symbol.kind) .. " "
  local head = prefix .. symbol.qualified

  for _, index in ipairs(item.matches or {}) do
    local from = #prefix + index
    if from < #head then
      table.insert(spans, { hl = "EpicenterMatch", from = from, to = from + 1 })
    end
  end

  -- refs mode: item.lines are the reference's own use-site line(s), not the
  -- enclosing definition's - show where the reference is, not where the
  -- enclosing function starts (F3).
  local line = item.lines and item.lines[1] or symbol.line
  local file = ("  %s"):format(symbol.file)
  local line_tag = (":%d"):format(line)
  local count_tag = (symbol.callers or 0) > 0
      and ("  %s%d"):format(icons.ui("fan_in"), symbol.callers)
    or ""

  local text, shown_file = text_mod.fit(head, file, line_tag .. count_tag, width)
  local at = #head
  table.insert(spans, { hl = "EpicenterMuted", from = at, to = at + #shown_file + #line_tag })
  if count_tag ~= "" then
    local count_at = at + #shown_file + #line_tag
    table.insert(spans, { hl = "EpicenterCount", from = count_at, to = count_at + #count_tag })
  end
  return { text = text, spans = spans }
end

--- Row for a `navgraph/grep` item: location, the line, and the match lit.
--- The file elides before the matched line's own text ever does (F12), down
--- to its basename - past that floor the match text itself elides from the
--- right, rather than the path collapsing to nothing on a long match (D1).
--- @param width integer|nil the panel's current width; nil skips fitting
function M.render_match(item, _, pattern, width)
  local text_mod = require("epicenter.ui.text")
  local head = "  "
  local line_tag = (":%d"):format(item.line)
  local body = vim.trim(item.text)
  local leading = #item.text - #item.text:gsub("^%s+", "")
  local tail = line_tag .. "  " .. body

  local text, shown_file =
    text_mod.fit(head, item.file, tail, width, { min_middle = vim.fn.fnamemodify(item.file, ":t") })
  local spans = {}
  table.insert(spans, { hl = "EpicenterMuted", from = #head, to = #head + #shown_file + #line_tag })

  local body_at = #head + #shown_file + #line_tag + 2
  local from = body_at + math.max(0, item.character - leading)
  if pattern and #pattern > 0 and from < #text then
    table.insert(
      spans,
      { hl = "EpicenterMatch", from = from, to = math.min(#text, from + #pattern) }
    )
  end
  return { text = text, spans = spans }
end

--- Definition target normally; in refs mode `item.lines` are the use-site
--- line(s) inside `symbol`'s file, and the jump/preview must land on the
--- reference, not the enclosing definition (F3). No `end_line`, so the
--- preview highlights just the reference line, not the whole function.
function M.symbol_target(item)
  local symbol = item.symbol
  if item.lines then
    return { path = vim.uri_to_fname(symbol.uri), line = item.lines[1] }
  end
  return { path = vim.uri_to_fname(symbol.uri), line = symbol.line, end_line = symbol.endLine }
end

local function match_target(item)
  return { path = vim.uri_to_fname(item.uri), line = item.line, character = item.character }
end

-- Frecency -----------------------------------------------------------------------

local RECENT_KIND = "search"
--- How many recent picks are remembered and sent as `search.recent`.
local RECENT_MAX = 40

--- The qualified names most recently jumped to in this project, newest
--- first. Empty until something has been picked.
--- @return string[]
function M.recent(root)
  local stored = require("epicenter.store").read(RECENT_KIND, root)
  return type(stored.recent) == "table" and stored.recent or {}
end

--- `qualified` moved to the front, older picks after it, capped. Pure.
--- @return string[]
function M.promote(recent, qualified)
  local out = { qualified }
  for _, name in ipairs(recent) do
    if name ~= qualified and #out < RECENT_MAX then
      table.insert(out, name)
    end
  end
  return out
end

--- Remembers a pick so the server ranks it first next time. A failure to
--- write is a log line, not a toast: the jump itself worked.
local function remember(root, symbol)
  local qualified = symbol and symbol.qualified
  if type(qualified) ~= "string" or qualified == "" then
    return
  end
  local ok, err = require("epicenter.store").write(RECENT_KIND, root, {
    recent = M.promote(M.recent(root), qualified),
  })
  if not ok then
    require("epicenter.log").warn("could not remember the pick: %s", err)
  end
end

-- The palette --------------------------------------------------------------------

local function symbol_source(query, state, cb)
  local cfg = require("epicenter.config").get()
  require("epicenter.client").search({
    query = query,
    refs = state.mode == "refs",
    kinds = KIND_CYCLE[state.kind_index].kinds,
    recent = state.recent,
    limit = cfg.search.limit,
  }, function(err, result)
    if err then
      return cb(err)
    end
    cb(nil, result.items or {}, result.total)
  end, { bufnr = state.bufnr, channel = "search" })
end

local function grep_source(query, state, cb)
  local cfg = require("epicenter.config").get()
  state.pattern = query
  if query == "" then
    return cb(nil, {}, 0)
  end
  require("epicenter.client").grep({
    pattern = query,
    regex = state.regex,
    limit = cfg.grep.limit,
  }, function(err, result)
    if err then
      return cb(err)
    end
    cb(nil, result.items or {}, result.total)
  end, { bufnr = state.bufnr, channel = "grep" })
end

--- One palette for all three modes. `mode` decides where the rows come from,
--- how they draw, and what a jump means - nothing else differs, which is why
--- `<C-space>` can switch between them mid-query.
--- @param ctx { args: string[], bufnr: integer }
--- @param mode "symbols"|"grep"|"refs"
local function open_palette(ctx, mode)
  local cfg = require("epicenter.config").get()
  local palette = require("epicenter.ui.palette")
  local icons = require("epicenter.ui.icons")
  local root = require("epicenter.root").find(ctx.bufnr)

  local state = {
    bufnr = ctx.bufnr,
    mode = mode,
    kind_index = 1,
    regex = false,
    pattern = "",
    root = root,
    recent = M.recent(root),
  }

  return palette.open({
    title = MODE_TITLE[mode],
    prompt_prefix = " " .. icons.ui("search") .. " ",
    debounce_ms = cfg.search.debounce_ms,
    state = state,
    empty_text = "  no matches",
    help_lines = M.help_lines,
    source = function(query, current, cb)
      if current.mode == "grep" then
        return grep_source(query, current, cb)
      end
      return symbol_source(query, current, cb)
    end,
    render_item = function(item, index, width)
      if state.mode == "grep" then
        return M.render_match(item, index, state.pattern, width)
      end
      return M.render_symbol(item, index, width)
    end,
    preview_of = function(item)
      return state.mode == "grep" and match_target(item) or M.symbol_target(item)
    end,
    on_accept = function(item, action)
      if state.mode == "grep" then
        return jump(match_target(item), action)
      end
      remember(state.root, item.symbol)
      jump(M.symbol_target(item), action)
    end,
    mode_label = function(current)
      local parts = { current.mode }
      if current.mode == "grep" and current.regex then
        table.insert(parts, "regex")
      end
      local kind = current.mode ~= "grep" and KIND_CYCLE[current.kind_index].label or nil
      if kind then
        table.insert(parts, kind)
      end
      return table.concat(parts, " · ")
    end,
    keys = {
      -- Terminals disagree on <C-space>: most send NUL, which Neovim spells
      -- <C-@>. Both are mapped so the key works either way.
      ["<C-space>"] = function(self)
        M.cycle_mode(self)
      end,
      ["<C-@>"] = function(self)
        M.cycle_mode(self)
      end,
      ["<C-r>"] = function(self)
        if self.state.mode ~= "grep" then
          return
        end
        self.state.regex = not self.state.regex
        self:refresh()
      end,
      ["<C-k>"] = function(self)
        if self.state.mode == "grep" then
          return
        end
        self.state.kind_index = (self.state.kind_index % #KIND_CYCLE) + 1
        self:refresh()
      end,
    },
  })
end

--- Switches the open palette to the next mode, keeping the query.
--- @param self epicenter.Palette
function M.cycle_mode(self)
  self.state.mode = M.next_mode(self.state.mode)
  self:set_title(MODE_TITLE[self.state.mode])
  self.list:clear_marks()
  self:refresh()
end

-- The module is its own feature spec; the render helpers above stay reachable
-- for tests and for follow-up features that show the same rows.
M.name = "search"
M.summary = "Fuzzy symbol search and repo-wide grep, live as you type"

M.options = {
  search = { debounce_ms = 40, limit = 50 },
  grep = { debounce_ms = 60, limit = 200 },
}

M.commands = {
  {
    name = "search",
    desc = "Fuzzy symbol search across the project",
    run = function(ctx)
      return open_palette(ctx, "symbols")
    end,
    rows = true,
  },
  {
    name = "grep",
    desc = "Repo-wide text search, unsaved edits too",
    run = function(ctx)
      return open_palette(ctx, "grep")
    end,
    rows = true,
  },
}

M.keymaps = {
  { suffix = "s", command = "search", desc = "Epicenter: search symbols" },
  { suffix = "g", command = "grep", desc = "Epicenter: grep" },
}

M.KIND_CYCLE = KIND_CYCLE
M.MODES = MODES

return M
