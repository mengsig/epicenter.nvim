--- The v1.1 area of the fake navgraph server: the custom `navgraph/tests`,
--- `navgraph/types` and `navgraph/impact`, plus the standard LSP call- and
--- type-hierarchy methods the addendum adds.
---
--- Shapes are exactly the addendum's and no others - `tests/contract/schema.lua`
--- checks both directions on the wire, so a feature written against an
--- imagined shape fails at the first call.
local graph = require("fakelib.graph")
local index_lib = require("fakelib.index")

--- LSP `SymbolKind` for the contract's kind strings. Anything else is
--- `Function`, which is what a name-based indexer mostly finds.
local SYMBOL_KIND = {
  fn = 12,
  method = 6,
  class = 5,
  struct = 23,
  interface = 11,
  enum = 10,
  const = 14,
  var = 13,
  field = 8,
}

--- @param code integer JSON-RPC error code the server should answer with
local function fail(code, fmt, ...)
  error({ code = code, message = fmt:format(...) }, 0)
end

local function range_of(symbol)
  return {
    start = { line = symbol.line - 1, character = 0 },
    ["end"] = { line = symbol.endLine - 1, character = 0 },
  }
end

local function selection_of(symbol)
  return {
    start = { line = symbol.line - 1, character = 0 },
    ["end"] = { line = symbol.line - 1, character = #symbol.name },
  }
end

--- @param exact boolean|nil `nil` leaves the flag off, as a prepare does
local function item_of(symbol, exact)
  return {
    name = symbol.name,
    kind = SYMBOL_KIND[symbol.kind] or 12,
    uri = symbol.uri,
    range = range_of(symbol),
    selectionRange = selection_of(symbol),
    data = {
      id = symbol.id,
      qualified = symbol.qualified,
      file = symbol.file,
      exact = exact,
    },
  }
end

--- The definition an item's `data` names. The id is authoritative; the
--- qualified name is the fallback a client that built the item by hand has.
local function symbol_of_item(ctx, item)
  for _, symbol in ipairs(ctx.index.symbols) do
    if symbol.id == item.data.id then
      return symbol
    end
  end
  for _, symbol in ipairs(ctx.index.symbols) do
    if symbol.qualified == item.data.qualified and symbol.file == item.data.file then
      return symbol
    end
  end
  return nil
end

--- The one definition a `{ textDocument, position }` request points at.
local function symbol_at_position(ctx, params)
  local file = ctx.to_relative(params.textDocument.uri)
  local line = (params.position.line or 0) + 1
  local word = index_lib.word_at(ctx.index, file, line, (params.position.character or 0) + 1)
  if not word then
    return index_lib.enclosing(ctx.index, file, line)
  end
  local elsewhere = nil
  for _, symbol in ipairs(ctx.index.symbols) do
    if symbol.name == word or symbol.qualified == word then
      if symbol.file == file then
        return symbol
      end
      elsewhere = elsewhere or symbol
    end
  end
  return elsewhere or index_lib.enclosing(ctx.index, file, line)
end

local function target_symbol(ctx, params, method)
  local found = graph.targets(ctx.index, params, ctx.to_relative, ctx.overlays)
  if #found == 0 then
    fail(-32001, "%s: symbol not found", method)
  end
  return found[1]
end

-- Call hierarchy ---------------------------------------------------------------

--- One direction of the call graph as LSP hierarchy calls. `fromRanges` are
--- the call-site lines, which is what the addendum promises.
local function hierarchy_calls(ctx, item, direction)
  local symbol = symbol_of_item(ctx, item)
  if not symbol then
    return {}
  end
  local edges = graph.edges_of(ctx.index, symbol.id, direction)
  local out = {}
  for _, edge in ipairs(edges) do
    local other = graph.symbol_by_id(ctx.index, edge.other)
    if other then
      local ranges = {}
      for _, line in ipairs(edge.lines) do
        table.insert(ranges, {
          start = { line = line - 1, character = 0 },
          ["end"] = { line = line - 1, character = 0 },
        })
      end
      local entry = { fromRanges = ranges }
      entry[direction == "callees" and "to" or "from"] =
        item_of(graph.symbol(ctx.index, other), edge.exact)
      table.insert(out, entry)
    end
  end
  return out
end

-- Type hierarchy ---------------------------------------------------------------

local function types_of(ctx, symbol)
  local supertypes, subtypes = {}, {}
  for _, name in ipairs(ctx.index.bases[symbol.id] or {}) do
    for _, candidate in ipairs(ctx.index.symbols) do
      if candidate.qualified == name or candidate.name == name then
        table.insert(supertypes, graph.symbol(ctx.index, candidate))
      end
    end
  end
  for _, candidate in ipairs(ctx.index.symbols) do
    for _, name in ipairs(ctx.index.bases[candidate.id] or {}) do
      if name == symbol.name or name == symbol.qualified then
        table.insert(subtypes, graph.symbol(ctx.index, candidate))
      end
    end
  end
  return supertypes, subtypes
end

-- Tests ------------------------------------------------------------------------

--- The `coverage` walk inverted: every test definition from which `symbol` is
--- reachable, breadth-first, with the depth it was reached at.
local function tests_reaching(ctx, symbol, limit)
  local seen, out, truncated = { [symbol.id] = true }, {}, false
  local frontier, via_of = { symbol.id }, {}
  local depth = 0

  while #frontier > 0 and depth < 16 do
    depth = depth + 1
    local next_frontier = {}
    for _, id in ipairs(frontier) do
      for _, edge in ipairs(graph.edges_of(ctx.index, id, "callers")) do
        if not seen[edge.other] then
          seen[edge.other] = true
          table.insert(next_frontier, edge.other)
          via_of[edge.other] = depth == 1 and { edge.other } or vim.deepcopy(via_of[id] or {})
          local caller = graph.symbol_by_id(ctx.index, edge.other)
          if caller and caller.test then
            if #out >= limit then
              truncated = true
            else
              table.insert(out, {
                symbol = graph.symbol(ctx.index, caller),
                depth = depth,
                via = via_of[edge.other],
              })
            end
          end
        end
      end
    end
    frontier = next_frontier
  end
  return out, truncated
end

-- Impact -----------------------------------------------------------------------

--- The fixture has no git, so "the working change" is what the fake already
--- treats as changed: the files the server holds an overlay for. A `range`
--- narrows that to the definitions it covers.
local function changed_roots(ctx, params)
  local roots = graph.changed(ctx.index, ctx.overlays)
  if params.uri then
    local file = ctx.to_relative(params.uri)
    roots = vim.tbl_filter(function(symbol)
      return symbol.file == file
    end, roots)
  end
  if params.range then
    local from = (params.range.start.line or 0) + 1
    local to = (params.range["end"].line or 0) + 1
    roots = vim.tbl_filter(function(symbol)
      return symbol.line <= to and from <= symbol.endLine
    end, roots)
  end
  return roots
end

--- One hunk per changed definition: the fixture's stand-in for a real diff's
--- hunks, which is as much as an overlay-vs-disk comparison can honestly say
--- without a git tree.
local function hunks_of(ctx, roots)
  local by_file, order = {}, {}
  for _, symbol in ipairs(roots) do
    local hunk = by_file[symbol.file]
    if not hunk then
      hunk = {
        uri = symbol.uri,
        range = range_of(symbol),
        roots = {},
        first = symbol.line,
        last = symbol.endLine,
      }
      by_file[symbol.file] = hunk
      table.insert(order, hunk)
    end
    hunk.first = math.min(hunk.first, symbol.line)
    hunk.last = math.max(hunk.last, symbol.endLine)
    hunk.range = {
      start = { line = hunk.first - 1, character = 0 },
      ["end"] = { line = hunk.last - 1, character = 0 },
    }
    table.insert(hunk.roots, graph.symbol(ctx.index, symbol))
  end
  return vim.tbl_map(function(hunk)
    return { uri = hunk.uri, range = hunk.range, roots = hunk.roots }
  end, order)
end

return {
  ["navgraph/tests"] = function(ctx, params)
    local symbol = target_symbol(ctx, params, "navgraph/tests")
    local tests, truncated = tests_reaching(ctx, symbol, params.limit or 100)
    local max_depth = 0
    for _, entry in ipairs(tests) do
      max_depth = math.max(max_depth, entry.depth)
    end
    return {
      symbol = graph.symbol(ctx.index, symbol),
      tests = tests,
      summary = { count = #tests, maxDepth = max_depth },
      truncated = truncated,
    }
  end,

  ["navgraph/types"] = function(ctx, params)
    local symbol = target_symbol(ctx, params, "navgraph/types")
    local supertypes, subtypes = types_of(ctx, symbol)
    return {
      symbol = graph.symbol(ctx.index, symbol),
      supertypes = supertypes,
      subtypes = subtypes,
      -- The fake resolves no interface/protocol members and extracts no
      -- type-use edges; empty is what it has, and the contract says a
      -- language with neither answers with what it has, never an error.
      implementors = {},
      users = {},
      truncated = false,
    }
  end,

  --- An empty change is a routine answer here, never an error.
  ["navgraph/impact"] = function(ctx, params)
    local roots = changed_roots(ctx, params)
    local blast = graph.blast(ctx.index, roots, {
      direction = params.direction,
      depth = params.depth or 1,
      tests = params.tests,
      strict = params.strict,
      limit = params.limit,
    })
    blast.hunks = hunks_of(ctx, roots)
    blast.truncated = blast.summary.truncated
    return blast
  end,

  ["textDocument/prepareCallHierarchy"] = function(ctx, params)
    local symbol = symbol_at_position(ctx, params)
    return symbol and { item_of(graph.symbol(ctx.index, symbol)) } or {}
  end,

  ["callHierarchy/incomingCalls"] = function(ctx, params)
    return hierarchy_calls(ctx, params.item, "callers")
  end,

  ["callHierarchy/outgoingCalls"] = function(ctx, params)
    return hierarchy_calls(ctx, params.item, "callees")
  end,

  ["textDocument/prepareTypeHierarchy"] = function(ctx, params)
    local symbol = symbol_at_position(ctx, params)
    return symbol and { item_of(graph.symbol(ctx.index, symbol)) } or {}
  end,

  ["typeHierarchy/supertypes"] = function(ctx, params)
    local symbol = symbol_of_item(ctx, params.item)
    if not symbol then
      return {}
    end
    local supertypes = types_of(ctx, symbol)
    return vim.tbl_map(item_of, supertypes)
  end,

  ["typeHierarchy/subtypes"] = function(ctx, params)
    local symbol = symbol_of_item(ctx, params.item)
    if not symbol then
      return {}
    end
    local _, subtypes = types_of(ctx, symbol)
    return vim.tbl_map(item_of, subtypes)
  end,

  --- The fixture records no interface/protocol members, so the honest answer
  --- is the definitions that inherit from the type under the cursor.
  ["textDocument/implementation"] = function(ctx, params)
    local symbol = symbol_at_position(ctx, params)
    if not symbol then
      return {}
    end
    local _, subtypes = types_of(ctx, symbol)
    return vim.tbl_map(function(subtype)
      return { uri = subtype.uri, range = range_of(subtype) }
    end, subtypes)
  end,
}
