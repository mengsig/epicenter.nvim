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

local SEARCH_HELP = {
  "  keys",
  "",
  "  <CR>        jump to the symbol",
  "  <C-t>       open in a new tab",
  "  <C-v>       open in a vertical split",
  "  <C-x>       open in a split",
  "  <C-n>/<C-p> next / previous result",
  "  <C-r>       toggle reference mode",
  "  <C-k>       cycle the kind filter",
  "  <C-y>       yank file:line",
  "  ?           toggle this help (normal mode)",
  "  <Esc>       close",
}

local GREP_HELP = {
  "  keys",
  "",
  "  <CR>        jump to the match",
  "  <C-t>       open in a new tab",
  "  <C-v>       open in a vertical split",
  "  <C-x>       open in a split",
  "  <C-n>/<C-p> next / previous result",
  "  <C-r>       toggle regex",
  "  <C-y>       yank file:line",
  "  ?           toggle this help (normal mode)",
  "  <Esc>       close",
}
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

local function open_symbol_palette(ctx)
  local client = require("epicenter.client")
  local cfg = require("epicenter.config").get()
  local palette = require("epicenter.ui.palette")
  local icons = require("epicenter.ui.icons")

  return palette.open({
    title = " search ",
    prompt_prefix = " " .. icons.ui("search") .. " ",
    debounce_ms = cfg.search.debounce_ms,
    state = { bufnr = ctx.bufnr, refs = false, kind_index = 1 },
    empty_text = "  no symbols match",
    help_lines = SEARCH_HELP,
    source = function(query, state, cb)
      client.search({
        query = query,
        refs = state.refs,
        kinds = KIND_CYCLE[state.kind_index].kinds,
        limit = cfg.search.limit,
      }, function(err, result)
        if err then
          return cb(err)
        end
        cb(nil, result.items or {}, result.total)
      end, { bufnr = state.bufnr, channel = "search" })
    end,
    render_item = M.render_symbol,
    preview_of = M.symbol_target,
    on_accept = function(item, action)
      jump(M.symbol_target(item), action)
    end,
    mode_label = function(state)
      local parts = {}
      if state.refs then
        table.insert(parts, "refs")
      end
      local kind = KIND_CYCLE[state.kind_index].label
      if kind then
        table.insert(parts, kind)
      end
      return #parts > 0 and table.concat(parts, " · ") or nil
    end,
    keys = {
      ["<C-r>"] = function(self)
        self.state.refs = not self.state.refs
        self:refresh()
      end,
      ["<C-k>"] = function(self)
        self.state.kind_index = (self.state.kind_index % #KIND_CYCLE) + 1
        self:refresh()
      end,
    },
  })
end

local function open_grep_palette(ctx)
  local client = require("epicenter.client")
  local cfg = require("epicenter.config").get()
  local palette = require("epicenter.ui.palette")
  local icons = require("epicenter.ui.icons")

  local state = { bufnr = ctx.bufnr, pattern = "", regex = false }
  return palette.open({
    title = " grep ",
    prompt_prefix = " " .. icons.ui("prompt") .. " ",
    debounce_ms = cfg.grep.debounce_ms,
    state = state,
    empty_text = "  no lines match",
    help_lines = GREP_HELP,
    source = function(query, current, cb)
      current.pattern = query
      if query == "" then
        return cb(nil, {}, 0)
      end
      client.grep({
        pattern = query,
        regex = current.regex,
        limit = cfg.grep.limit,
      }, function(err, result)
        if err then
          return cb(err)
        end
        cb(nil, result.items or {}, result.total)
      end, { bufnr = current.bufnr, channel = "grep" })
    end,
    render_item = function(item, index, width)
      return M.render_match(item, index, state.pattern, width)
    end,
    preview_of = match_target,
    on_accept = function(item, action)
      jump(match_target(item), action)
    end,
    mode_label = function(current)
      return current.regex and "regex" or nil
    end,
    keys = {
      ["<C-r>"] = function(self)
        self.state.regex = not self.state.regex
        self:refresh()
      end,
    },
  })
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
    run = open_symbol_palette,
    rows = true,
  },
  {
    name = "grep",
    desc = "Repo-wide text search, unsaved edits too",
    run = open_grep_palette,
    rows = true,
  },
}

M.keymaps = {
  { suffix = "s", command = "search", desc = "Epicenter: search symbols" },
  { suffix = "g", command = "grep", desc = "Epicenter: grep" },
}

M.KIND_CYCLE = KIND_CYCLE

return M
