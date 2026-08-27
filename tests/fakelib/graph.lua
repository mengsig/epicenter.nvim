--- Call graph over the fixture index: edges, ring walks, outlines and the
--- "what changed" set the diff queries answer.
---
--- Edge resolution mirrors what a real name-based indexer can promise. A call
--- resolved inside the caller's own file is exact; when no definition of that
--- name lives in the file, every same-named definition elsewhere becomes a
--- heuristic edge, which `strict` drops.
---
--- "Changed" has no git here: it is the set of files navgraph holds an overlay
--- for, which is exactly the set of files open in the editor. That keeps the
--- diff panel live against unsaved edits, which is what it is for.
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

local function add_edge(graph, from, to, heuristic)
  local key = ("%d:%d"):format(from.id, to.id)
  if from.id == to.id or graph.seen[key] then
    return
  end
  graph.seen[key] = true
  table.insert(graph.callees[from.id], { symbol = to, heuristic = heuristic })
  table.insert(graph.callers[to.id], { symbol = from, heuristic = heuristic })
end

local function build(index)
  local by_name = {}
  local graph = { callers = {}, callees = {}, seen = {} }
  for _, symbol in ipairs(index.symbols) do
    by_name[symbol.name] = by_name[symbol.name] or {}
    table.insert(by_name[symbol.name], symbol)
    graph.callers[symbol.id] = {}
    graph.callees[symbol.id] = {}
  end

  for _, from in ipairs(index.symbols) do
    local lines = index.sources[from.file] or {}
    for i = from.line + 1, math.min(from.endLine, #lines) do
      for _, name in ipairs(called_names(lines[i])) do
        local same_file, elsewhere = {}, {}
        for _, candidate in ipairs(by_name[name] or {}) do
          table.insert(candidate.file == from.file and same_file or elsewhere, candidate)
        end
        local heuristic = #same_file == 0
        for _, to in ipairs(#same_file > 0 and same_file or elsewhere) do
          add_edge(graph, from, to, heuristic)
        end
      end
    end
  end
  graph.seen = nil
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

--- A copy of `symbol` carrying its true edge counts and its doc comment. The
--- index itself is never mutated - it is shared by every request.
function M.enrich(index, symbol)
  local graph = M.of(index)
  local out = vim.tbl_extend("force", {}, symbol)
  out.callers = #(graph.callers[symbol.id] or {})
  out.callees = #(graph.callees[symbol.id] or {})
  out.doc = doc_above(index, symbol)
  return out
end

--- @param edges { symbol: table, heuristic: boolean }[]
local function keep(edges, opts)
  return vim.tbl_filter(function(edge)
    if opts.strict and edge.heuristic then
      return false
    end
    return not (opts.tests == "without" and edge.symbol.test)
  end, edges)
end

--- Breadth-first ring walk from `roots`.
--- @param roots table[] indexed symbols
--- @param opts { direction?: string, depth?: integer, tests?: string, strict?: boolean }
--- @return { symbol: table, ring: integer, heuristic: boolean }[]
function M.walk(index, roots, opts)
  opts = opts or {}
  local graph = M.of(index)
  local edges_of = opts.direction == "callees" and graph.callees or graph.callers
  local depth = math.max(1, math.floor(opts.depth or 2))
  local tests = opts.tests or "with"

  local seen, nodes = {}, {}
  local frontier = {}
  for _, root in ipairs(roots) do
    seen[root.id] = true
    table.insert(frontier, root)
  end

  for ring = 1, depth do
    local next_frontier = {}
    for _, from in ipairs(frontier) do
      for _, edge in ipairs(keep(edges_of[from.id] or {}, opts)) do
        local to = edge.symbol
        if not seen[to.id] then
          seen[to.id] = true
          table.insert(next_frontier, to)
          if tests ~= "only" or to.test then
            table.insert(nodes, {
              symbol = M.enrich(index, to),
              ring = ring,
              heuristic = edge.heuristic,
            })
          end
        end
      end
    end
    frontier = next_frontier
  end
  return nodes
end

--- Definitions the request points at: a qualified (or bare) name, else the
--- symbol enclosing a position.
--- @param params { symbol?: string, uri?: string, position?: table }
--- @param to_relative fun(uri: string): string
--- @return table[]
function M.roots(index, params, to_relative)
  if params.symbol then
    local exact, loose = {}, {}
    for _, symbol in ipairs(index.symbols) do
      if symbol.qualified == params.symbol then
        table.insert(params.uri and symbol.uri == params.uri and exact or loose, symbol)
      elseif symbol.name == params.symbol then
        table.insert(loose, symbol)
      end
    end
    local found = #exact > 0 and exact or loose
    return found[1] and { found[1] } or {}
  end
  if not (params.uri and params.position) then
    return {}
  end
  local file = to_relative(params.uri)
  local symbol = index_lib.enclosing(index, file, (params.position.line or 0) + 1)
  return symbol and { symbol } or {}
end

--- Definitions of one file, in file order, with their edge counts.
function M.outline(index, file)
  local out = {}
  for _, symbol in ipairs(index.symbols) do
    if symbol.file == file then
      table.insert(out, M.enrich(index, symbol))
    end
  end
  table.sort(out, function(a, b)
    return a.line < b.line
  end)
  return out
end

--- Definitions in the files navgraph currently holds overlays for.
--- @param overlays table<string, string>
function M.changed(index, overlays)
  local out = {}
  for _, symbol in ipairs(index.symbols) do
    if overlays[symbol.file] then
      table.insert(out, M.enrich(index, symbol))
    end
  end
  return out
end

return M
