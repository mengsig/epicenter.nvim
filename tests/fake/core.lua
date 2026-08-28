--- Core area of the fake navgraph server: status, symbol lookup, search and
--- grep, plus the standard LSP requests that resolve through the same index.
local index = require("fakelib.index")

--- v1.1: the identifier's own LSP range, for the client that wants to know
--- exactly which characters it resolved.
--- @return table|nil
local function identifier_range(ctx, file, line, column)
  local from, to = index.word_span(ctx.index, file, line, column)
  if not from then
    return nil
  end
  return {
    start = { line = line - 1, character = from - 1 },
    ["end"] = { line = line - 1, character = to },
  }
end

--- v1.1: the enclosing chain, outermost -> innermost, for winbar breadcrumbs.
local function breadcrumbs_of(ctx, file, line)
  local chain = {}
  for _, symbol in ipairs(ctx.index.symbols) do
    if symbol.file == file and symbol.line <= line and line <= symbol.endLine then
      table.insert(chain, symbol)
    end
  end
  table.sort(chain, function(a, b)
    return a.line < b.line
  end)
  return chain
end

--- @param ctx { root: string, index: table, overlays: table }
local function symbol_at(ctx, params)
  local file = ctx.to_relative(params.uri)
  local line = (params.position.line or 0) + 1
  local column = (params.position.character or 0) + 1
  local word = index.word_at(ctx.index, file, line, column)
  local crumbs = breadcrumbs_of(ctx, file, line)

  -- Off an identifier the real server has nothing to report - not even the
  -- enclosing definition (F11). Reporting one here is what let a blast target
  -- at `character = 0` pass the fake lane and fail against the real server.
  if not word then
    return {
      word = "",
      symbol = vim.NIL,
      enclosing = vim.NIL,
      candidates = {},
      range = vim.NIL,
      breadcrumbs = crumbs,
    }
  end

  -- Same-file definitions win; the rest come back as ambiguity candidates.
  local candidates = {}
  for _, symbol in ipairs(ctx.index.symbols) do
    if symbol.name == word then
      table.insert(candidates, symbol)
    end
  end
  table.sort(candidates, function(a, b)
    local a_local, b_local = a.file == file, b.file == file
    if a_local ~= b_local then
      return a_local
    end
    return a.id < b.id
  end)

  return {
    word = word,
    symbol = candidates[1] or vim.NIL,
    enclosing = index.enclosing(ctx.index, file, line) or vim.NIL,
    candidates = vim.list_slice(candidates, 2, #candidates),
    range = identifier_range(ctx, file, line, column) or vim.NIL,
    breadcrumbs = crumbs,
  }
end

local function status(ctx)
  -- languages:{<lang>:files} per the contract, so key by the CLI's short
  -- language tag (already on every symbol), not the file extension.
  local lang_of_file = {}
  for _, symbol in ipairs(ctx.index.symbols) do
    lang_of_file[symbol.file] = lang_of_file[symbol.file] or symbol.language
  end
  local languages = {}
  for _, file in ipairs(ctx.index.files) do
    local lang = lang_of_file[file]
    if lang then
      languages[lang] = (languages[lang] or 0) + 1
    end
  end
  local backend_languages = {}
  for lang in pairs(languages) do
    backend_languages[lang] = "heuristic"
  end

  return {
    root = ctx.root,
    protocolVersion = 1,
    protocolMinor = 1,
    backend = { default = "auto", languages = backend_languages },
    version = "fake-0.1.0",
    files = #ctx.index.files,
    symbols = #ctx.index.symbols,
    edges = 0,
    languages = languages,
    overlays = vim.tbl_count(ctx.overlays),
    indexedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    lastIndexMs = ctx.index.ms,
    cache = false,
  }
end

return {
  ["navgraph/status"] = status,

  ["navgraph/symbolAt"] = symbol_at,

  ["navgraph/search"] = function(ctx, params)
    local opts = {
      query = params.query or "",
      kinds = params.kinds,
      limit = params.limit,
      recent = params.recent,
    }
    if params.refs then
      return index.search_refs(ctx.index, opts)
    end
    return index.search(ctx.index, opts)
  end,

  ["navgraph/grep"] = function(ctx, params)
    return index.grep(ctx.index, {
      pattern = params.pattern or "",
      regex = params.regex,
      caseSensitive = params.caseSensitive,
      limit = params.limit,
    })
  end,

  --- The contract answers a rescan with the `navgraph/status` shape, whole.
  ["navgraph/rescan"] = function(ctx)
    ctx.reindex("rescan")
    return status(ctx)
  end,

  ["textDocument/definition"] = function(ctx, params)
    local found = symbol_at(ctx, params)
    local symbol = found.symbol
    if symbol == vim.NIL then
      return {}
    end
    return {
      {
        uri = symbol.uri,
        range = {
          start = { line = symbol.line - 1, character = 0 },
          ["end"] = { line = symbol.endLine - 1, character = 0 },
        },
      },
    }
  end,

  ["textDocument/documentSymbol"] = function(ctx, params)
    local file = ctx.to_relative(params.textDocument.uri)
    local out = {}
    for _, symbol in ipairs(ctx.index.symbols) do
      if symbol.file == file then
        table.insert(out, {
          name = symbol.qualified,
          kind = 12,
          range = {
            start = { line = symbol.line - 1, character = 0 },
            ["end"] = { line = symbol.endLine - 1, character = 0 },
          },
          selectionRange = {
            start = { line = symbol.line - 1, character = 0 },
            ["end"] = { line = symbol.line - 1, character = 0 },
          },
        })
      end
    end
    return out
  end,
}
