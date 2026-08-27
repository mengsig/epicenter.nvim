--- Call graph over the fixture index, shaped exactly as `docs/lsp.md` v1
--- specifies: `Symbol`, `Node`, `Edge`, and the `navgraph/blast` payload.
---
--- Edge confidence mirrors what a name-based indexer can promise. A call
--- resolved inside the caller's own file is `exact`; when no definition of that
--- name lives in the file, every same-named definition elsewhere becomes an
--- inexact edge, which `strict` drops.
---
--- "Changed" has no git here: it is the set of files navgraph holds an overlay
--- for, which is the contract's "every definition in a file whose unsaved
--- buffer differs from the copy on disk", narrowed to what a fixture can know.
local M = {}

local index_lib = require("fakelib.index")

--- Identifiers used as a call on one line. `config.route(x)` calls `route`.
local function called_names(line)
  local names = {}
  for name in line:gmatch("([%a_][%w_]*)%s*%(") do
    table.insert(names, name)
  end
  return names
end

local function record(edges, from, to, exact, line)
  local key = ("%d:%d"):format(from.id, to.id)
  local edge = edges.by_key[key]
  if not edge then
    edge = { from = from.id, to = to.id, exact = exact, lines = {} }
    edges.by_key[key] = edge
    table.insert(edges.list, edge)
    table.insert(edges.callees[from.id], edge)
    table.insert(edges.callers[to.id], edge)
  end
  table.insert(edge.lines, line)
end

local function build(index)
  local by_name = {}
  local graph = { list = {}, by_key = {}, callers = {}, callees = {}, by_id = {}, ext = {} }
  for _, symbol in ipairs(index.symbols) do
    by_name[symbol.name] = by_name[symbol.name] or {}
    table.insert(by_name[symbol.name], symbol)
    graph.callers[symbol.id] = {}
    graph.callees[symbol.id] = {}
    graph.by_id[symbol.id] = symbol
    graph.ext[symbol.id] = {}
  end

  for _, from in ipairs(index.symbols) do
    local lines = index.sources[from.file] or {}
    for i = from.line + 1, math.min(from.endLine, #lines) do
      for _, name in ipairs(called_names(lines[i])) do
        local same_file, elsewhere = {}, {}
        for _, candidate in ipairs(by_name[name] or {}) do
          table.insert(candidate.file == from.file and same_file or elsewhere, candidate)
        end
        local targets = #same_file > 0 and same_file or elsewhere
        if #targets == 0 then
          if not vim.tbl_contains(graph.ext[from.id], name) then
            table.insert(graph.ext[from.id], name)
          end
        end
        for _, to in ipairs(targets) do
          if to.id ~= from.id then
            record(graph, from, to, #same_file > 0, i)
          end
        end
      end
    end
  end
  return graph
end

--- Cached per index build; a reindex produces a new table and a new graph.
local cache = setmetatable({}, { __mode = "k" })

function M.of(index)
  local graph = cache[index]
  if not graph then
    graph = build(index)
    cache[index] = graph
  end
  return graph
end

--- Contiguous comment lines directly above a definition.
--- @return string|nil
local function doc_above(index, symbol)
  local lines = index.sources[symbol.file] or {}
  local out = {}
  for i = symbol.line - 1, 1, -1 do
    local text = lines[i]
    local comment = text and (text:match("^%s*%-%-+%s?(.*)$") or text:match("^%s*#+%s?(.*)$"))
    if not comment then
      break
    end
    table.insert(out, 1, comment)
  end
  return #out > 0 and table.concat(out, "\n") or nil
end

--- The contract's `Symbol`: a copy carrying real edge counts and its doc
--- comment. The index itself is never mutated - every request shares it.
function M.symbol(index, symbol)
  local graph = M.of(index)
  local out = vim.tbl_extend("force", {}, symbol)
  out.callers = #(graph.callers[symbol.id] or {})
  out.callees = #(graph.callees[symbol.id] or {})
  out.doc = doc_above(index, symbol)
  return out
end

--- @param edges Edge[]
--- @param opts { strict?: boolean, tests?: string }
local function passes(graph, edge, other_id, opts)
  if opts.strict and not edge.exact then
    return false
  end
  return not (opts.tests == "without" and graph.by_id[other_id].test)
end

-- Blast -------------------------------------------------------------------------

local function summarize(nodes, truncated)
  local files, counts, tests, max_depth = {}, {}, 0, 0
  local order = {}
  for _, node in ipairs(nodes) do
    max_depth = math.max(max_depth, node.depth)
    counts[node.depth] = (counts[node.depth] or 0) + 1
    local file = node.symbol.file
    if files[file] == nil then
      files[file] = 0
      table.insert(order, file)
    end
    files[file] = files[file] + 1
    if node.symbol.test then
      tests = tests + 1
    end
  end

  local by_depth = {}
  for depth = 1, max_depth do
    table.insert(by_depth, counts[depth] or 0)
  end
  local by_file = vim.tbl_map(function(file)
    return { file = file, count = files[file] }
  end, order)
  table.sort(by_file, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.file < b.file
  end)

  return {
    symbols = #nodes,
    files = #order,
    tests = tests,
    maxDepth = max_depth,
    truncated = truncated,
    byDepth = by_depth,
    byFile = by_file,
  }
end

--- Breadth-first walk from `roots`, in the `navgraph/blast` response shape.
--- @param roots table[] indexed symbols
--- @param opts { direction?: string, depth?: integer, tests?: string, strict?: boolean, limit?: integer }
function M.blast(index, roots, opts)
  opts = opts or {}
  local graph = M.of(index)
  local edges_of = opts.direction == "callees" and graph.callees or graph.callers
  local depth = math.max(1, math.floor(opts.depth or 2))
  local limit = opts.limit or 500
  local tests = opts.tests or "with"

  local seen, nodes, used_edges, truncated = {}, {}, {}, false
  local frontier, via_of = {}, {}
  for _, root in ipairs(roots) do
    seen[root.id] = true
    table.insert(frontier, root)
  end

  for ring = 1, depth do
    local next_frontier = {}
    for _, from in ipairs(frontier) do
      for _, edge in ipairs(edges_of[from.id] or {}) do
        local to_id = edge.from == from.id and edge.to or edge.from
        if not seen[to_id] and passes(graph, edge, to_id, opts) then
          if #nodes >= limit then
            truncated = true
            break
          end
          seen[to_id] = true
          local to = graph.by_id[to_id]
          table.insert(next_frontier, to)
          table.insert(used_edges, edge)
          -- `via` names the depth-1 neighbours a node was reached through.
          via_of[to_id] = ring == 1 and { to_id } or vim.deepcopy(via_of[from.id] or {})
          if tests ~= "only" or to.test then
            table.insert(nodes, {
              symbol = M.symbol(index, to),
              depth = ring,
              via = via_of[to_id],
              exact = edge.exact,
            })
          end
        end
      end
    end
    frontier = next_frontier
  end

  --- Edges are always written caller->callee, whichever way the walk ran.
  local out_edges = vim.tbl_map(function(edge)
    return { from = edge.from, to = edge.to, exact = edge.exact, lines = edge.lines }
  end, used_edges)

  return {
    roots = vim.tbl_map(function(root)
      return M.symbol(index, root)
    end, roots),
    nodes = nodes,
    edges = out_edges,
    summary = summarize(nodes, truncated),
  }
end

-- Call trees ---------------------------------------------------------------------

--- The contract's `Node` tree for `navgraph/callers` / `navgraph/calls`.
--- @param opts { direction?: string, depth?: integer, tests?: string, strict?: boolean }
--- @return table root node
function M.tree(index, root, opts)
  opts = opts or {}
  local graph = M.of(index)
  local edges_of = opts.direction == "callees" and graph.callees or graph.callers
  local max_depth = math.max(1, math.floor(opts.depth or 1))

  local function node_for(symbol, exact, lines, on_path, level)
    local node = {
      symbol = M.symbol(index, symbol),
      exact = exact,
      lines = lines,
      children = {},
      ext = graph.ext[symbol.id] or {},
      recursion = on_path[symbol.id] == true,
    }
    if node.recursion or level >= max_depth then
      return node
    end
    on_path[symbol.id] = true
    for _, edge in ipairs(edges_of[symbol.id] or {}) do
      local other_id = edge.from == symbol.id and edge.to or edge.from
      if passes(graph, edge, other_id, opts) then
        table.insert(
          node.children,
          node_for(graph.by_id[other_id], edge.exact, edge.lines, on_path, level + 1)
        )
      end
    end
    on_path[symbol.id] = nil
    return node
  end

  return node_for(root, true, {}, {}, 0)
end

-- Targets and files ----------------------------------------------------------------

--- The definitions a Target names: `{ symbol }`, `{ uri, position }`,
--- `{ file }` or `{ ref }`. Empty when nothing resolves.
--- @param to_relative fun(uri: string): string
--- @return table[]
function M.targets(index, params, to_relative, overlays)
  if params.symbol then
    local exact, loose = {}, {}
    for _, symbol in ipairs(index.symbols) do
      if symbol.qualified == params.symbol then
        table.insert(exact, symbol)
      elseif symbol.name == params.symbol then
        table.insert(loose, symbol)
      end
    end
    local found = #exact > 0 and exact or loose
    return found[1] and { found[1] } or {}
  end

  if params.file then
    return vim.tbl_filter(function(symbol)
      return symbol.file == params.file
    end, index.symbols)
  end

  if params.ref then
    return M.changed(index, overlays or {})
  end

  if not (params.uri and params.position) then
    return {}
  end
  local file = to_relative(params.uri)
  local symbol = index_lib.enclosing(index, file, (params.position.line or 0) + 1)
  return symbol and { symbol } or {}
end

--- `navgraph/outline`: every definition per file, in indexing order.
--- @param opts { path?: string, kinds?: string[], limit?: integer, tests?: string }
function M.outline(index, opts)
  opts = opts or {}
  local limit = opts.limit or 300
  local files, order, count = {}, {}, 0

  for _, symbol in ipairs(index.symbols) do
    local matches_path = not opts.path or symbol.file:find(opts.path, 1, true) ~= nil
    local matches_kind = not opts.kinds
      or #opts.kinds == 0
      or vim.tbl_contains(opts.kinds, symbol.kind)
    local matches_tests = opts.tests ~= "without" and true or not symbol.test
    if opts.tests == "only" then
      matches_tests = symbol.test == true
    end
    if matches_path and matches_kind and matches_tests and count < limit then
      count = count + 1
      if not files[symbol.file] then
        files[symbol.file] = { file = symbol.file, lang = symbol.language, symbols = {} }
        table.insert(order, files[symbol.file])
      end
      table.insert(files[symbol.file].symbols, M.symbol(index, symbol))
    end
  end

  return { files = order }
end

--- Definitions in the files navgraph currently holds overlays for - the
--- fixture's stand-in for "changed since the ref".
--- @param overlays table<string, string>
function M.changed(index, overlays)
  return vim.tbl_filter(function(symbol)
    return overlays[symbol.file] ~= nil
  end, index.symbols)
end

return M
