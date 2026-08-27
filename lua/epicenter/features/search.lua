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

local function short(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

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
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(target.line, last)), 0 })
  vim.cmd("normal! zz")
end

local function append(text, spans, chunk, hl)
  if chunk == "" then
    return text
  end
  table.insert(spans, { hl = hl, from = #text, to = #text + #chunk })
  return text .. chunk
end

--- Row for a `navgraph/search` item: kind icon, qualified name with the
--- matched characters lit, location, fan-in.
--- @param item { symbol: table, matches: integer[] }
function M.render_symbol(item)
  local icons = require("epicenter.ui.icons")
  local symbol = item.symbol
  local spans = {}
  local prefix = " " .. icons.kind(symbol.kind) .. " "
  local text = prefix .. symbol.qualified

  for _, index in ipairs(item.matches or {}) do
    local from = #prefix + index
    if from < #text then
      table.insert(spans, { hl = "EpicenterMatch", from = from, to = from + 1 })
    end
  end

  text = append(text, spans, ("  %s:%d"):format(symbol.file, symbol.line), "EpicenterMuted")
  if (symbol.callers or 0) > 0 then
    text =
      append(text, spans, ("  %s%d"):format(icons.ui("fan_in"), symbol.callers), "EpicenterCount")
  end
  return { text = text, spans = spans }
end

--- Row for a `navgraph/grep` item: location, the line, and the match lit.
function M.render_match(item, _, pattern)
  local spans = {}
  local text = ""
  text = append(text, spans, ("  %s:%d"):format(item.file, item.line), "EpicenterMuted")
  text = text .. "  "

  local body_at = #text
  text = text .. vim.trim(item.text)
  local leading = #item.text - #item.text:gsub("^%s+", "")
  local from = body_at + math.max(0, item.character - leading)
  if pattern and #pattern > 0 and from < #text then
    table.insert(
      spans,
      { hl = "EpicenterMatch", from = from, to = math.min(#text, from + #pattern) }
    )
  end
  return { text = text, spans = spans }
end

local function symbol_target(item)
  local symbol = item.symbol
  return { path = vim.uri_to_fname(symbol.uri), line = symbol.line, end_line = symbol.endLine }
end

local function match_target(item)
  return { path = vim.uri_to_fname(item.uri), line = item.line }
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
    preview_of = symbol_target,
    on_accept = function(item, action)
      jump(symbol_target(item), action)
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
    render_item = function(item, index)
      return M.render_match(item, index, state.pattern)
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
  { name = "search", desc = "Fuzzy symbol search across the project", run = open_symbol_palette },
  {
    name = "grep",
    desc = "Repo-wide text search, unsaved edits included",
    run = open_grep_palette,
  },
}

M.keymaps = {
  { suffix = "s", command = "search", desc = "Epicenter: search symbols" },
  { suffix = "g", command = "grep", desc = "Epicenter: grep" },
}

M.KIND_CYCLE = KIND_CYCLE

return M
