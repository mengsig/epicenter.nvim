--- Blast radius: what breaks if this symbol changes, in depth rings, live.
--- No config requires at file scope - see `epicenter.registry`.
local M = {}

M.name = "blast"
M.summary = "Blast radius of a symbol, in depth rings, live"

M.options = {
  blast = {
    depth = 2,
    --- Upper bound for `+` in the panel.
    max_depth = 6,
    direction = "callers",
    tests = "with",
    strict = false,
    layout = "float",
    follow_debounce_ms = 80,
    realtime_debounce_ms = 150,
  },
  --- Ring-graded marks on the impacted lines while a panel is open.
  ripples = true,
  hover = {
    --- Top callers listed on the card.
    callers = 5,
    max_width = 80,
  },
  --- "cursor" badges the definition the cursor is inside, "all" badges every
  --- definition in the buffer, `false` badges nothing.
  badges = "cursor",
}

M.option_docs = {
  ["badges"] = '"cursor" | "all" | false',
  ["blast.depth"] = "rings requested",
  ["blast.direction"] = '"callers" | "callees"',
  ["blast.layout"] = '"float" | "vsplit"',
  ["blast.max_depth"] = "upper bound for `+` in the panel",
  ["blast.strict"] = "drop name-resolved (heuristic) edges",
  ["blast.tests"] = '"with" | "without" | "only"',
  ["ripples"] = "mark the impacted lines while a panel is open",
}

M.option_rules = {
  variants = {
    ["badges"] = { "string", "boolean" },
  },
  enums = {
    ["badges"] = { "cursor", "all", false },
    ["blast.direction"] = { "callers", "callees" },
    ["blast.tests"] = { "with", "without", "only" },
    ["blast.layout"] = { "float", "vsplit" },
  },
  positive = {
    ["blast.depth"] = true,
    ["blast.max_depth"] = true,
    ["blast.follow_debounce_ms"] = true,
    ["blast.realtime_debounce_ms"] = true,
    ["hover.callers"] = true,
    ["hover.max_width"] = true,
  },
}

--- Where the cursor is pointing, as a protocol Target. The column is the
--- cursor's own, snapped out of the leading indentation (F10) - navgraph
--- resolves an identifier under the column and nothing off one.
--- @param bufnr integer
--- @return { uri: string, position: { line: integer, character: integer } }
function M.cursor_target(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or { 1, 0 }
  return {
    uri = vim.uri_from_bufnr(bufnr),
    position = { line = cursor[1] - 1, character = M.column_at(bufnr, cursor[1] - 1, cursor[2]) },
  }
end

--- A doc-comment marker (Python `"""`, Zig `///`, C `/** */`, Lua `---`, ...)
--- resolves to neither a symbol nor an enclosing definition, so a target
--- snapped only past leading whitespace still answers nothing there (D4).
--- Column of the line's first identifier - past whatever marker owns the
--- columns before it - for one retry that recovers the enclosing definition
--- the same way a body line already gets it.
--- @param bufnr integer|nil
--- @param line integer 0-based
--- @param already integer 0-based column already asked
--- @return integer|nil 0-based column, nil when no retry is warranted
local function retry_column(bufnr, line, already)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
  local column = text and require("epicenter.features.blast.model").first_identifier_column(text)
  return column ~= already and column or nil
end

--- Turns a raw cursor target into one the server can resolve: on a name it
--- passes straight through, anywhere else in a body it re-asks by the
--- enclosing definition's disambiguated name (F10) - the fallback every
--- cursor-targeted feature shares (blast, hover, callers/callees), so
--- "works anywhere in a body" holds everywhere the cursor drives a query.
--- A nil answer gets one retry at the line's first identifier column, past
--- a doc-comment marker the snapped column landed on (D4).
--- @param target { uri: string, position: table } from `cursor_target`
--- @param cb fun(err: table|nil, resolved: table|nil) `resolved` is nil, with
---   no error, when the cursor genuinely names nothing
--- @param opts? table request opts (bufnr, channel)
--- @return { cancel: fun() }
function M.resolve_target(target, cb, opts)
  local client = require("epicenter.client")
  local cancelled = false
  local inflight

  --- @param position table the position this specific request asked at
  --- @param allow_retry boolean whether a nil answer here may retry once
  local function ask(position, allow_retry)
    inflight = client.symbol_at({ uri = target.uri, position = position }, function(err, result)
      if cancelled then
        return
      end
      if err then
        return cb(err, nil)
      end
      local resolved = result and result.symbol
      if resolved and resolved ~= vim.NIL then
        return cb(nil, { uri = target.uri, position = position })
      end
      local enclosing = result and result.enclosing
      local name = enclosing ~= vim.NIL and client.symbol_ref(enclosing) or nil
      if name then
        return cb(nil, { symbol = name })
      end
      local retry = allow_retry
        and retry_column(opts and opts.bufnr, position.line, position.character)
      if retry then
        return ask({ line = position.line, character = retry }, false)
      end
      cb(nil, nil)
    end, opts)
  end

  ask(target.position, true)
  return {
    cancel = function()
      cancelled = true
      if inflight then
        inflight.cancel()
      end
    end,
  }
end

--- `model.target_column` against a buffer line, for the callers that hold a
--- (bufnr, line, column) rather than the text.
--- @param line integer 0-based
--- @param column integer 0-based
--- @return integer 0-based column
function M.column_at(bufnr, line, column)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return column
  end
  local text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
  if not text then
    return column
  end
  return require("epicenter.features.blast.model").target_column(text, column)
end

--- True when navgraph is the buffer's hover provider - which, under
--- `lsp.fallback_only`, means no other language server offers one.
local function navgraph_owns_hover(bufnr)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = "navgraph" })) do
    local compat = require("epicenter.compat")
    if compat.lsp_supports_method(client, "textDocument/hover", bufnr) then
      return true
    end
  end
  return false
end

--- `K` shows the card only where navgraph answers hover; anywhere else it
--- stays the language server's key. Decided at press time, because clients
--- attach in any order.
local function install_hover_key(bufnr)
  vim.keymap.set("n", "K", function()
    if navgraph_owns_hover(bufnr) then
      require("epicenter").run("hover", {}, bufnr)
    else
      vim.lsp.buf.hover()
    end
  end, { buffer = bufnr, desc = "Epicenter: hover card", silent = true })
end

--- @param cfg table resolved config
function M.setup(cfg)
  require("epicenter.features.blast.badges").setup(cfg)

  local group = vim.api.nvim_create_augroup("EpicenterBlastFeature", { clear = true })
  if cfg.keymaps == false then
    return
  end
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if client and client.name == "navgraph" then
        install_hover_key(event.buf)
      end
    end,
  })
end

M.commands = {
  {
    name = "blast",
    desc = "Blast radius of the symbol at the cursor",
    run = function(ctx)
      local name = ctx.args[1]
      return require("epicenter.features.blast.panel").open({
        kind = "blast",
        target = name and { symbol = name } or M.cursor_target(ctx.bufnr),
        bufnr = ctx.bufnr,
      })
    end,
  },
  {
    name = "hover",
    desc = "What this symbol is, and who calls it",
    run = function(ctx)
      return require("epicenter.features.blast.hover").open(ctx.bufnr)
    end,
  },
  {
    name = "diff",
    desc = "Impact of the changes since a git ref",
    run = function(ctx)
      return require("epicenter.features.blast.panel").open({
        kind = "diff",
        target = { ref = ctx.args[1] or "HEAD" },
        bufnr = ctx.bufnr,
      })
    end,
  },
}

M.keymaps = {
  { suffix = "e", command = "blast", desc = "Epicenter: blast radius" },
  { suffix = "k", command = "hover", desc = "Epicenter: hover card" },
  { suffix = "d", command = "diff", desc = "Epicenter: diff impact" },
}

return M
