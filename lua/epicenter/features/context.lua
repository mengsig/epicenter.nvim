--- One symbol, packaged for an LLM: `navgraph/context`'s bundle rendered as
--- compact markdown on the clipboard, and `:Epicenter where` for the reverse
--- question - which definition is this line inside of.
---
--- The rendering is pure (`M.markdown`), so what lands on the clipboard is
--- testable without a server. No config requires at file scope - see
--- `epicenter.registry`.
local M = {}

--- @param symbol table a protocol Symbol
--- @return string
local function location_of(symbol)
  return ("%s:%d"):format(symbol.file, symbol.line)
end

--- One bullet per neighbour, with the file:line that finds it again.
local function bullets(symbols)
  local out = {}
  for _, symbol in ipairs(symbols or {}) do
    table.insert(out, ("- `%s` — %s"):format(symbol.qualified, location_of(symbol)))
  end
  return out
end

local function section(lines, title, symbols)
  if #(symbols or {}) == 0 then
    return
  end
  table.insert(lines, "")
  table.insert(lines, ("**%s** (%d)"):format(title, #symbols))
  vim.list_extend(lines, bullets(symbols))
end

--- The bundle as markdown a model can read without further explanation.
--- Pure.
--- @param bundle table a `navgraph/context` result
--- @return string
function M.markdown(bundle)
  local symbol = bundle.symbol
  local lines = {
    ("## `%s` — %s"):format(symbol.qualified, location_of(symbol)),
    "",
    ("%s · %s · %d callers · %d callees"):format(
      symbol.kind,
      symbol.language,
      symbol.callers,
      symbol.callees
    ),
  }

  if bundle.signature ~= "" then
    table.insert(lines, "")
    table.insert(lines, ("`%s`"):format(bundle.signature))
  end

  local doc = bundle.doc
  if type(doc) == "string" and doc ~= "" then
    table.insert(lines, "")
    for _, line in ipairs(vim.split(doc, "\n", { plain = true })) do
      table.insert(lines, "> " .. line)
    end
  end

  local body = bundle.definition and bundle.definition.text or ""
  if body ~= "" then
    table.insert(lines, "")
    table.insert(lines, "```" .. symbol.language)
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
    table.insert(lines, "```")
  end

  section(lines, "callers", bundle.callers)
  section(lines, "callees", bundle.callees)
  section(lines, "types", bundle.types)
  section(lines, "tests", bundle.tests)

  if bundle.truncated then
    table.insert(lines, "")
    table.insert(lines, "_trimmed to fit the token budget_")
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The bundle's members as quickfix rows: everything the markdown named,
--- so `--qf` walks the same set the clipboard holds. Pure.
--- @return epicenter.qf.Row[]
function M.qf_rows(bundle)
  local rows = {}
  local function add(symbol, label)
    rows[#rows + 1] = {
      target = { path = vim.uri_to_fname(symbol.uri), line = symbol.line },
      text = ("%s  %s"):format(label, symbol.qualified),
    }
  end
  add(bundle.symbol, "symbol")
  for _, group in ipairs({ "callers", "callees", "types", "tests" }) do
    for _, symbol in ipairs(bundle[group] or {}) do
      add(symbol, group:sub(1, #group - 1))
    end
  end
  return rows
end

--- `--budget N` off the argument list. The rest is the optional symbol name.
--- Pure.
--- @param args string[]
--- @return string[] rest, integer|nil budget, string|nil err
function M.split_budget(args)
  local rest, budget, err = {}, nil, nil
  local i = 1
  while i <= #(args or {}) do
    local arg = args[i]
    local inline = arg:match("^%-%-budget=(.*)$")
    if arg == "--budget" or inline then
      local value = inline or args[i + 1]
      budget = tonumber(value)
      if not budget or budget <= 0 or budget ~= math.floor(budget) then
        err = ("--budget wants a positive whole number of tokens, got %s"):format(tostring(value))
      end
      i = i + (inline and 1 or 2)
    else
      table.insert(rest, arg)
      i = i + 1
    end
  end
  return rest, budget, err
end

--- The handle `epicenter.run` needs to honour `--qf`/`--loc` on a command
--- that yanks rather than opening a panel: the rows only exist once the
--- server has answered, so they are filled in later.
local function deferred_rows(title)
  return {
    title = title,
    hooks = {},
    rows = {},
    on_populate = function(self, fn)
      table.insert(self.hooks, fn)
    end,
    export = function(self, list)
      require("epicenter.ui.qf").send_and_notify({
        rows = self.rows,
        list = list,
        title = self.title,
      })
    end,
    fill = function(self, rows)
      self.rows = rows
      for _, fn in ipairs(self.hooks) do
        fn(self)
      end
    end,
  }
end

--- Where the yanked bundle goes. `+` is the system clipboard; without one
--- (a bare TTY, a headless run) Neovim's unnamed register is the honest
--- fallback rather than a silently dropped yank.
--- @return string register, string|nil warning
function M.target_register()
  if vim.fn.has("clipboard") == 1 then
    return "+", nil
  end
  return '"', "no system clipboard - yanked to the unnamed register instead"
end

local function run_context(ctx)
  local epicenter = require("epicenter")
  local client = require("epicenter.client")
  local handle = deferred_rows("epicenter context")

  local rest, budget, err = M.split_budget(ctx.args)
  if err then
    epicenter.notify(err, "error")
    return handle
  end

  local reason = client.unsupported_reason(ctx.bufnr, "navgraph/context", "context")
  if reason then
    epicenter.notify(reason, "warn")
    return handle
  end

  local function ask(target)
    local params = vim.tbl_extend("force", target, budget and { budget = budget } or {})
    client.context(params, function(request_err, bundle)
      if request_err then
        return epicenter.notify(request_err.message or "navgraph did not answer", "error")
      end
      local register, warning = M.target_register()
      vim.fn.setreg(register, M.markdown(bundle))
      handle:fill(M.qf_rows(bundle))
      local note = ("context for %s yanked · ~%d tokens%s"):format(
        bundle.symbol.qualified,
        bundle.tokensEstimate,
        bundle.truncated and " (trimmed)" or ""
      )
      epicenter.notify(note)
      if warning then
        epicenter.notify(warning, "warn")
      end
    end, { bufnr = ctx.bufnr, channel = "context" })
  end

  local name = rest[1]
  if name then
    ask({ symbol = name })
    return handle
  end

  local blast = require("epicenter.features.blast")
  blast.resolve_target(blast.cursor_target(ctx.bufnr), function(resolve_err, resolved)
    if resolve_err then
      return epicenter.notify(resolve_err.message or "navgraph did not answer", "error")
    end
    if not resolved then
      return epicenter.notify("no symbol under the cursor", "warn")
    end
    ask(resolved)
  end, { bufnr = ctx.bufnr, channel = "context:resolve" })

  return handle
end

-- where ------------------------------------------------------------------------

--- `file:line`, as a stack trace or a diff header writes it. A bare number is
--- a line in the current buffer. Pure.
--- @return string|nil path, integer|nil line
function M.split_location(arg)
  if not arg then
    return nil, nil
  end
  local bare = arg:match("^(%d+)$")
  if bare then
    return nil, tonumber(bare)
  end
  -- `file:line:col` first: a greedy `(.*)` would otherwise read the COLUMN
  -- as the line and leave `file:line` as the path.
  local path, line = arg:match("^(.+):(%d+):%d+:?.*$")
  if not path then
    path, line = arg:match("^(.+):(%d+)$")
  end
  if not path then
    return nil, nil
  end
  return path, tonumber(line)
end

--- The breadcrumb line `:Epicenter where` reports. Pure.
--- @param result table a `navgraph/where` answer
--- @return string
function M.trail(result)
  local chain = result.breadcrumbs or {}
  local crumbs = {}
  for i, symbol in ipairs(chain) do
    -- The innermost crumb answers "which definition is this?", so it carries
    -- the qualified name; the ancestors are only the path to it.
    table.insert(crumbs, i == #chain and symbol.qualified or symbol.name)
  end
  local enclosing = result.enclosing
  if #crumbs == 0 then
    return ("%s is not inside a definition"):format(result.file)
  end
  local separator = require("epicenter.config").get().crumbs.separator
  local trail = table.concat(crumbs, separator)
  if enclosing and enclosing ~= vim.NIL then
    return ("%s  ·  %s"):format(trail, location_of(enclosing))
  end
  return trail
end

local function run_where(ctx)
  local epicenter = require("epicenter")
  local client = require("epicenter.client")

  local reason = client.unsupported_reason(ctx.bufnr, "navgraph/where", "where")
  if reason then
    return epicenter.notify(reason, "warn")
  end

  local path, line = M.split_location(ctx.args[1])
  if ctx.args[1] and not line then
    return epicenter.notify(("could not read %q as file:line"):format(ctx.args[1]), "error")
  end

  local uri = vim.uri_from_bufnr(ctx.bufnr)
  if path then
    local root = require("epicenter.root").find(ctx.bufnr)
    local absolute = vim.fn.filereadable(path) == 1 and path or vim.fs.joinpath(root, path)
    uri = vim.uri_from_fname(vim.fn.fnamemodify(absolute, ":p"))
  end
  if not line then
    local win = vim.fn.bufwinid(ctx.bufnr)
    line = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 1
  end

  client.where({ uri = uri, line = line - 1 }, function(err, result)
    if err then
      return epicenter.notify(err.message or "navgraph did not answer", "error")
    end
    epicenter.notify(M.trail(result))
  end, { bufnr = ctx.bufnr, channel = "where" })
end

M.name = "context"
M.summary = "One symbol packaged for an LLM, and what encloses a line"

M.commands = {
  {
    name = "context",
    desc = "Yank a symbol's context bundle",
    rows = true,
    run = run_context,
    complete = function(lead)
      return vim.startswith("--budget", lead) and { "--budget" } or {}
    end,
  },
  {
    name = "where",
    desc = "What encloses this line",
    run = run_where,
  },
}

M.keymaps = {
  { suffix = "y", command = "context", desc = "Epicenter: yank LLM context" },
}

return M
