--- Which tests reach the symbol under the cursor - the coverage walk run
--- backwards (`navgraph/tests`) - grouped by file, and a key that runs one.
---
--- The runner is a per-language command template; running one never blocks
--- the editor, and its output lands in a scratch split as it arrives. No
--- config requires at file scope - see `epicenter.registry`.
local M = {}

--- navgraph's short language tags mapped onto the runner table's keys, so a
--- server answering `py` and one answering `python` reach the same command.
local LANGUAGE_ALIAS = {
  py = "python",
  js = "javascript",
  ts = "typescript",
  tsx = "typescript",
  jsx = "javascript",
  rb = "ruby",
  rs = "rust",
  cs = "csharp",
}

--- @param symbol table a protocol Symbol
--- @return string
function M.language_of(symbol)
  local language = symbol.language or ""
  return LANGUAGE_ALIAS[language] or language
end

-- Model ------------------------------------------------------------------------

--- The panel's tree: one node per file, its tests underneath, both in a
--- stable order. Pure, so the grouping is testable without a server.
--- @param entries { symbol: table, depth: integer, via: integer[] }[]
--- @return table[] file nodes
function M.group_by_file(entries)
  local by_file, order = {}, {}
  for _, entry in ipairs(entries or {}) do
    local file = entry.symbol.file
    local node = by_file[file]
    if not node then
      node = { type = "file", key = file, name = file, children = {} }
      by_file[file] = node
      table.insert(order, node)
    end
    table.insert(node.children, {
      type = "test",
      key = ("%s#%s@%d"):format(file, entry.symbol.qualified, entry.symbol.line),
      name = entry.symbol.qualified,
      symbol = entry.symbol,
      depth = entry.depth,
      children = {},
    })
  end
  for _, node in ipairs(order) do
    table.sort(node.children, function(a, b)
      if a.depth ~= b.depth then
        return a.depth < b.depth
      end
      return a.symbol.line < b.symbol.line
    end)
  end
  table.sort(order, function(a, b)
    return a.name < b.name
  end)
  return order
end

--- One display row. Pure.
--- @param row { node: table, depth: integer, expandable: boolean, expanded: boolean }
function M.render_row(row)
  local icons = require("epicenter.ui.icons")
  local node, spans = row.node, {}
  local indent = ("  "):rep(row.depth)

  local function append(text, chunk, hl)
    if chunk == "" then
      return text
    end
    table.insert(spans, { hl = hl, from = #text, to = #text + #chunk })
    return text .. chunk
  end

  if node.type == "file" then
    local text = indent .. icons.ui(row.expanded and "expanded" or "collapsed") .. " "
    return {
      text = append(text, ("%s (%d)"):format(node.name, #node.children), "EpicenterTitle"),
      spans = spans,
    }
  end

  local text = indent .. "  " .. icons.kind("test") .. " " .. node.name
  text = append(text, ("  %s:%d"):format(node.symbol.file, node.symbol.line), "EpicenterMuted")
  -- Depth 1 is a direct test; anything deeper reached the target through
  -- other definitions, which is worth seeing before trusting the coverage.
  text = append(text, ("  d%d"):format(node.depth), "EpicenterCount")
  return { text = text, spans = spans }
end

--- Whether the server capped the list. The addendum promises the flag but
--- not where it sits: navgraph reports it inside the summary. Pure.
--- @return boolean
function M.truncated(result)
  return result.truncated == true or (result.summary or {}).truncated == true
end

-- The runner ---------------------------------------------------------------------

--- The shell command for one test, or nil plus the reason there is none.
--- `%f` is the test's file (absolute), `%s` its own name. Both are
--- shell-escaped as they are substituted - a project under `~/my project/`
--- would otherwise be split into two arguments, and a name carrying a shell
--- metacharacter would be EXECUTED. Templates must not quote them again.
--- Pure.
--- @param symbol table a protocol Symbol
--- @param runners table<string, string> `tests.runner`
--- @return string|nil command, string|nil reason
function M.command_for(symbol, runners)
  local language = M.language_of(symbol)
  local template = runners[language]
  if not template then
    return nil,
      ("no test runner for %s - set tests.runner.%s"):format(
        language == "" and "this language" or language,
        language == "" and "<language>" or language
      )
  end
  local path = vim.uri_to_fname(symbol.uri)
  -- gsub's replacement string treats `%` specially, so substitute one
  -- placeholder at a time with a function.
  return (
    template:gsub("%%[fs]", function(token)
      return vim.fn.shellescape(token == "%f" and path or symbol.name)
    end)
  )
end

--- A scratch split that shows a command's output as it arrives. Owns its own
--- buffer; nothing else writes to it.
local function output_window(command)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "epicenter-test-output"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "$ " .. command, "" })

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.min(15, math.floor(vim.o.lines / 3)))
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "no"

  local function append(chunk)
    if not vim.api.nvim_buf_is_valid(buf) or chunk == nil or chunk == "" then
      return
    end
    local lines = vim.split(chunk:gsub("\r\n", "\n"), "\n", { plain = true })
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    vim.bo[buf].modifiable = false
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end

  vim.bo[buf].modifiable = false
  return { buf = buf, win = win, append = append }
end

--- Runs `command` in the user's shell, streaming into a scratch split. Never
--- blocks: the editor is usable while the suite runs.
--- @return table output the scratch window, for tests
function M.run_command(command, cwd)
  local output = output_window(command)
  local function stream(_, data)
    vim.schedule(function()
      output.append(data)
    end)
  end

  local ok, err = pcall(vim.system, { vim.o.shell, vim.o.shellcmdflag, command }, {
    cwd = cwd,
    text = true,
    stdout = stream,
    stderr = stream,
  }, function(done)
    vim.schedule(function()
      output.append(("\n[exit %d]"):format(done.code))
      require("epicenter").notify(
        done.code == 0 and "tests passed" or ("tests exited %d"):format(done.code),
        done.code == 0 and "info" or "warn"
      )
    end)
  end)
  if not ok then
    output.append("could not start the runner: " .. tostring(err))
  end
  return output
end

-- The panel ------------------------------------------------------------------------

local function target_of(row)
  local symbol = row.node.symbol
  if not symbol then
    return nil
  end
  return { path = vim.uri_to_fname(symbol.uri), line = symbol.line, end_line = symbol.endLine }
end

local function run_row(panel, ctx)
  local row = panel:current()
  local symbol = row and row.node.symbol
  if not symbol then
    return require("epicenter").notify("put the cursor on a test row first", "warn")
  end
  local command, reason = M.command_for(symbol, require("epicenter.config").get().tests.runner)
  if not command then
    return require("epicenter").notify(reason, "warn")
  end
  local cwd = require("epicenter.root").find(ctx.bufnr)
  panel:close()
  vim.schedule(function()
    M.run_command(command, cwd)
  end)
end

local function open_tests(ctx)
  local client = require("epicenter.client")
  local panel_mod = require("epicenter.ui.panel")
  local blast = require("epicenter.features.blast")
  local view = { bufnr = ctx.bufnr }

  view.panel = panel_mod.open({
    title = " tests ",
    footer = " loading... ",
    filetype = "epicenter-tests",
    empty_text = "  loading...",
    tree = {
      key_of = function(node)
        return node.key
      end,
      children_of = function(node)
        return node.children
      end,
    },
    render_row = M.render_row,
    text_of = function(row)
      return row.node.name or ""
    end,
    target_of = target_of,
    hints = { r = "run this test", l = "expand", h = "collapse" },
    keys = {
      r = function(panel)
        run_row(panel, ctx)
      end,
      l = function(panel)
        panel.tree:set_open(true)
        panel:draw()
      end,
      h = function(panel)
        panel.tree:set_open(false)
        panel:draw()
      end,
    },
  })

  if client.gate(ctx.bufnr, "navgraph/tests", "the tests panel", view.panel) then
    return view.panel
  end

  local function ask(target)
    local cfg = require("epicenter.config").get()
    client.tests(vim.tbl_extend("force", target, { limit = cfg.tests.limit }), function(err, result)
      if not view.panel:valid() then
        return
      end
      if err then
        return view.panel:notice("  " .. (err.message or "navgraph did not answer"))
      end
      -- A bare `null` is an ordinary LSP answer, and the addendum is loose
      -- about where the summary sits (see `M.truncated`). Neither may leave
      -- the panel reading "loading..." forever.
      if type(result) ~= "table" or type(result.tests) ~= "table" then
        return view.panel:notice("  navgraph sent no test list for this symbol")
      end
      local name = vim.tbl_get(result, "symbol", "qualified") or "this symbol"
      local files = M.group_by_file(result.tests)
      if #files == 0 then
        return view.panel:notice(("  no test reaches %s"):format(name))
      end
      local summary = result.summary or {}
      local count = type(summary.count) == "number" and summary.count or #result.tests
      local depth = type(summary.maxDepth) == "number"
          and (" · max depth %d"):format(summary.maxDepth)
        or ""
      view.panel:set_roots(files, { expand_roots = true })
      view.panel:set_title((" tests · %s "):format(name))
      view.panel:set_footer(
        (" %d%s%s · r run "):format(count, M.truncated(result) and "+" or "", depth)
      )
    end, { bufnr = ctx.bufnr, channel = "tests" })
  end

  local name = ctx.args[1]
  if name then
    ask({ symbol = name })
    return view.panel
  end

  blast.resolve_target(blast.cursor_target(ctx.bufnr), function(err, resolved)
    if not view.panel:valid() then
      return
    end
    if err then
      return view.panel:notice("  " .. (err.message or "navgraph did not answer"))
    end
    if not resolved then
      return view.panel:notice("  no symbol under the cursor")
    end
    ask(resolved)
  end, { bufnr = ctx.bufnr, channel = "tests:resolve" })

  return view.panel
end

M.name = "tests"
M.summary = "The tests that reach the symbol under the cursor, and a key to run one"

M.options = {
  tests = {
    limit = 100,
    --- Per language, the command `r` runs. `%f` is the test's file, `%s` its
    --- own name. Add a language by naming it here.
    runner = {
      python = "pytest %f::%s",
      lua = "busted %f",
      zig = "zig test %f",
      go = "go test -run %s ./...",
      rust = "cargo test %s",
      javascript = "npx vitest run %f -t %s",
      typescript = "npx vitest run %f -t %s",
    },
  },
}

M.option_docs = {
  ["tests.limit"] = "most tests asked for",
  ["tests.runner"] = "per language: %f is the file, %s the test's name",
}

M.option_rules = {
  positive = { ["tests.limit"] = true },
  extensible = { ["tests.runner"] = true },
}

M.commands = {
  {
    name = "tests",
    desc = "Tests that reach this symbol",
    rows = true,
    run = open_tests,
  },
}

M.keymaps = {
  { suffix = "t", command = "tests", desc = "Epicenter: tests reaching this symbol" },
}

return M
