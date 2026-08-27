--- Exploration area of the fake navgraph server: `navgraph/callers`,
--- `navgraph/calls`, `navgraph/path`, `navgraph/outline`, `navgraph/hot`,
--- `navgraph/unused` and `navgraph/graph`, in the shapes `docs/lsp.md` v1
--- specifies and no others.
---
--- Params are checked against the contract; an unknown key is a `-32602`: a
--- client that drifts from the protocol must fail here, loudly, rather than
--- against a shape the fake invented to be friendly. The call graph is
--- derived from the fixture sources rather than hard-coded, so a fixture edit
--- cannot silently drift from what the specs assert.

--- @param code integer JSON-RPC error code the server should answer with
local function fail(code, fmt, ...)
  error({ code = code, message = fmt:format(...) }, 0)
end

local function check_params(method, params, allowed)
  for key in pairs(params or {}) do
    if not allowed[key] then
      fail(-32602, "%s: unknown param %q", method, tostring(key))
    end
  end
end

local function merged(...)
  return vim.tbl_extend("force", {}, ...)
end

local SCOPE = { strict = true, tests = true }
local TARGET = { uri = true, position = true, symbol = true }

local CALLERS_PARAMS = merged(TARGET, SCOPE, { depth = true, refs = true })
local PATH_PARAMS = { from = true, to = true }
local OUTLINE_PARAMS = merged(SCOPE, { path = true, kinds = true, limit = true })
local HOT_PARAMS = merged(SCOPE, { path = true, limit = true })
local UNUSED_PARAMS = merged(SCOPE, { path = true, noPublic = true, followImports = true, limit = true })
local GRAPH_PARAMS = merged(SCOPE, { path = true })

-- Call graph -------------------------------------------------------------------

--- Words on `line` immediately followed by `(`, skipping control-flow keywords.
local KEYWORDS = {
  ["return"] = true,
  ["if"] = true,
  ["elseif"] = true,
  ["while"] = true,
  ["for"] = true,
  ["and"] = true,
  ["or"] = true,
  ["not"] = true,
  ["in"] = true,
  ["function"] = true,
  ["def"] = true,
  ["class"] = true,
  ["end"] = true,
}

local function called_names(line)
  local names = {}
  for name in line:gmatch("([%a_][%w_]*)%s*%(") do
    if not KEYWORDS[name] then
      table.insert(names, name)
    end
  end
  return names
end

--- One edge per (from,to) pair; `lines` accumulates every call-site line.
local function record(graph, from, to, exact, line)
  local key = ("%d:%d"):format(from.id, to.id)
  local edge = graph.by_key[key]
  if not edge then
    edge = { from = from, to = to, exact = exact, lines = {} }
    graph.by_key[key] = edge
    table.insert(graph.callers[to.id], edge)
    table.insert(graph.callees[from.id], edge)
  end
  table.insert(edge.lines, line)
end

--- A call resolved inside the caller's own file is exact; when no definition
--- of that name lives in the file, every same-named definition elsewhere
--- becomes a heuristic edge (mirrors `docs/lsp.md`'s exact/heuristic tiers).
local function build_graph(index)
  local by_name = {}
  local graph = { by_key = {}, callers = {}, callees = {}, ext = {} }
  for _, symbol in ipairs(index.symbols) do
    by_name[symbol.name] = by_name[symbol.name] or {}
    table.insert(by_name[symbol.name], symbol)
    graph.callers[symbol.id] = {}
    graph.callees[symbol.id] = {}
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
local graphs = setmetatable({}, { __mode = "k" })

local function graph_of(index)
  local graph = graphs[index]
  if not graph then
    graph = build_graph(index)
    graphs[index] = graph
  end
  return graph
end

--- The contract's `Symbol`: a copy carrying real edge counts.
local function symbol_of(index, symbol)
  local graph = graph_of(index)
  local out = vim.tbl_extend("force", {}, symbol)
  out.callers = #(graph.callers[symbol.id] or {})
  out.callees = #(graph.callees[symbol.id] or {})
  return out
end

--- @param opts { strict?: boolean, tests?: string }
local function passes(opts, other, exact)
  if opts.strict and not exact then
    return false
  end
  local tests = opts.tests or "with"
  if tests == "without" and other.test then
    return false
  end
  if tests == "only" and not other.test then
    return false
  end
  return true
end

-- Target resolution --------------------------------------------------------------

--- Exact qualified name first, then a bare-name hit.
local function find_named(index, name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  for _, symbol in ipairs(index.symbols) do
    if symbol.qualified == name then
      return symbol
    end
  end
  for _, symbol in ipairs(index.symbols) do
    if symbol.name == name then
      return symbol
    end
  end
  return nil
end

--- Identifiers on `line`, each flagged as a call when a `(` follows it.
local function mentions(line)
  local out, from = {}, 1
  while true do
    local start, stop, word = line:find("([%a_][%w_.:]*)", from)
    if not start then
      return out
    end
    from = stop + 1
    table.insert(out, {
      word = word,
      from = start,
      to = stop,
      call = line:sub(stop + 1):match("^%s*%(") ~= nil,
    })
  end
end

--- Symbol the request points at: an explicit name, else the word under the
--- cursor, else the symbol whose body encloses the cursor.
local function root_symbol(ctx, params)
  if type(params.symbol) == "string" and params.symbol ~= "" then
    return find_named(ctx.index, params.symbol)
  end

  if not params.uri or not params.position then
    return nil
  end
  local file = ctx.to_relative(params.uri)
  local row = (params.position.line or 0) + 1
  local line = (ctx.index.sources[file] or {})[row] or ""
  local col = (params.position.character or 0) + 1

  for _, mention in ipairs(mentions(line)) do
    if col >= mention.from and col <= mention.to + 1 then
      local bare = mention.word:match("[%w_]+$")
      -- Exact qualified name wins, then the definition in this file, then any.
      local same_file, elsewhere = nil, nil
      for _, symbol in ipairs(ctx.index.symbols) do
        if symbol.qualified == mention.word then
          return symbol
        end
        if symbol.name == bare then
          if symbol.file == file then
            same_file = same_file or symbol
          else
            elsewhere = elsewhere or symbol
          end
        end
      end
      if same_file or elsewhere then
        return same_file or elsewhere
      end
    end
  end
  return require("fakelib.index").enclosing(ctx.index, file, row)
end

-- Call trees ---------------------------------------------------------------------

--- The contract's `Node` tree for `navgraph/callers` / `navgraph/calls`.
local function node_for(index, graph, symbol, exact, lines, direction, opts, on_path, level, max_depth)
  local node = {
    symbol = symbol_of(index, symbol),
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
  local edges_of = direction == "callees" and graph.callees or graph.callers
  for _, edge in ipairs(edges_of[symbol.id] or {}) do
    local other = direction == "callees" and edge.to or edge.from
    if passes(opts, other, edge.exact) then
      table.insert(
        node.children,
        node_for(index, graph, other, edge.exact, edge.lines, direction, opts, on_path, level + 1, max_depth)
      )
    end
  end
  on_path[symbol.id] = nil
  return node
end

local function tree_for(ctx, params, direction, method)
  check_params(method, params, CALLERS_PARAMS)
  local root = root_symbol(ctx, params)
  if not root then
    fail(-32001, "%s: symbol not found", method)
  end
  local graph = graph_of(ctx.index)
  local opts = { strict = params.strict == true, tests = params.tests }
  local depth = math.max(1, math.floor(params.depth or 1))
  return { root = node_for(ctx.index, graph, root, true, {}, direction, opts, {}, 0, depth) }
end

--- Shortest call chain from `from` to `to`, breadth-first so the answer is the
--- shortest one and the search cannot loop on a cycle.
local function shortest_path(graph, from, to)
  if from.id == to.id then
    return { from }
  end
  local came_from, queue, seen = {}, { from }, { [from.id] = true }
  local at = 1
  while at <= #queue do
    local node = queue[at]
    at = at + 1
    for _, edge in ipairs(graph.callees[node.id] or {}) do
      local next_symbol = edge.to
      if not seen[next_symbol.id] then
        seen[next_symbol.id] = true
        came_from[next_symbol.id] = node
        if next_symbol.id == to.id then
          local chain, cursor = {}, next_symbol
          while cursor do
            table.insert(chain, 1, cursor)
            cursor = came_from[cursor.id]
          end
          return chain
        end
        table.insert(queue, next_symbol)
      end
    end
  end
  return nil
end

return {
  ["navgraph/callers"] = function(ctx, params)
    return tree_for(ctx, params, "callers", "navgraph/callers")
  end,

  ["navgraph/calls"] = function(ctx, params)
    return tree_for(ctx, params, "callees", "navgraph/calls")
  end,

  ["navgraph/path"] = function(ctx, params)
    check_params("navgraph/path", params, PATH_PARAMS)
    local from, to = find_named(ctx.index, params.from), find_named(ctx.index, params.to)
    if not from or not to then
      return { path = {} }
    end
    local chain = shortest_path(graph_of(ctx.index), from, to)
    if not chain then
      return { path = {} }
    end
    return { path = vim.tbl_map(function(symbol)
      return symbol_of(ctx.index, symbol)
    end, chain) }
  end,

  ["navgraph/outline"] = function(ctx, params)
    check_params("navgraph/outline", params, OUTLINE_PARAMS)
    local limit = params.limit or 300
    local tests = params.tests or "with"
    local files, order, count = {}, {}, 0
    for _, symbol in ipairs(ctx.index.symbols) do
      local matches_path = not params.path or symbol.file:find(params.path, 1, true) ~= nil
      local matches_kind = not params.kinds
        or #params.kinds == 0
        or vim.tbl_contains(params.kinds, symbol.kind)
      local matches_tests = true
      if tests == "without" then
        matches_tests = not symbol.test
      elseif tests == "only" then
        matches_tests = symbol.test == true
      end
      if matches_path and matches_kind and matches_tests and count < limit then
        count = count + 1
        if not files[symbol.file] then
          files[symbol.file] = { file = symbol.file, lang = symbol.language, symbols = {} }
          table.insert(order, files[symbol.file])
        end
        table.insert(files[symbol.file].symbols, symbol_of(ctx.index, symbol))
      end
    end
    return { files = order }
  end,

  ["navgraph/hot"] = function(ctx, params)
    check_params("navgraph/hot", params, HOT_PARAMS)
    local graph = graph_of(ctx.index)
    local items = {}
    for _, symbol in ipairs(ctx.index.symbols) do
      if not params.path or symbol.file == params.path then
        local fan_in, fan_in_exact, fan_in_test = 0, 0, 0
        for _, edge in ipairs(graph.callers[symbol.id] or {}) do
          local n = #edge.lines
          fan_in = fan_in + n
          if edge.exact then
            fan_in_exact = fan_in_exact + n
          end
          if edge.from.test then
            fan_in_test = fan_in_test + n
          end
        end
        local fan_out, fan_out_exact = 0, 0
        for _, edge in ipairs(graph.callees[symbol.id] or {}) do
          local n = #edge.lines
          fan_out = fan_out + n
          if edge.exact then
            fan_out_exact = fan_out_exact + n
          end
        end
        local strict_ok = params.strict ~= true or fan_in_exact > 0 or fan_out_exact > 0
        if fan_in > 0 and strict_ok then
          table.insert(items, {
            symbol = symbol_of(ctx.index, symbol),
            fanIn = fan_in,
            fanInExact = fan_in_exact,
            fanInTest = fan_in_test,
            fanOut = fan_out,
            fanOutExact = fan_out_exact,
          })
        end
      end
    end
    table.sort(items, function(a, b)
      if a.fanIn ~= b.fanIn then
        return a.fanIn > b.fanIn
      end
      return a.symbol.qualified < b.symbol.qualified
    end)
    local limit = params.limit or 25
    return { items = vim.list_slice(items, 1, math.min(#items, limit)) }
  end,

  ["navgraph/unused"] = function(ctx, params)
    check_params("navgraph/unused", params, UNUSED_PARAMS)
    local graph = graph_of(ctx.index)
    local tests = params.tests or "with"
    local items = {}
    for _, symbol in ipairs(ctx.index.symbols) do
      local matches_path = not params.path or symbol.file:find(params.path, 1, true) ~= nil
      if matches_path and not (params.noPublic == true and symbol.exported) then
        local callers = graph.callers[symbol.id] or {}
        local non_test_callers = 0
        for _, edge in ipairs(callers) do
          if not edge.from.test then
            non_test_callers = non_test_callers + 1
          end
        end
        local unreached = #callers == 0
        local test_only = #callers > 0 and non_test_callers == 0
        local include, marked_test_only = false, false
        if tests == "with" then
          include = unreached
        elseif tests == "without" then
          include, marked_test_only = unreached or test_only, test_only
        elseif tests == "only" then
          include, marked_test_only = test_only, test_only
        end
        if include then
          table.insert(items, { symbol = symbol_of(ctx.index, symbol), testOnly = marked_test_only })
        end
      end
    end
    local limit = params.limit or 300
    return { items = vim.list_slice(items, 1, math.min(#items, limit)) }
  end,

  --- Writes a standalone HTML file under `.navgraph/`, content-hashed so a
  --- repeated request for the same view reuses one file. `path` is a filter
  --- over which subgraph to draw - the server always chooses the output path.
  ["navgraph/graph"] = function(ctx, params)
    check_params("navgraph/graph", params, GRAPH_PARAMS)
    local graph = graph_of(ctx.index)
    local edges = {}
    for _, symbol in ipairs(ctx.index.symbols) do
      if not params.path or symbol.file:find(params.path, 1, true) ~= nil then
        for _, edge in ipairs(graph.callees[symbol.id] or {}) do
          table.insert(edges, edge)
        end
      end
    end

    local lines = { "<!doctype html><title>navgraph</title><pre>digraph navgraph {" }
    for _, edge in ipairs(edges) do
      table.insert(lines, ("  %q -> %q;"):format(edge.from.qualified, edge.to.qualified))
    end
    table.insert(lines, "}</pre>")
    local content = table.concat(lines, "\n") .. "\n"

    local navgraph_dir = vim.fs.joinpath(ctx.root, ".navgraph")
    vim.fn.mkdir(navgraph_dir, "p")
    local hash = vim.fn.sha256(content):sub(1, 8)
    local rel = vim.fs.joinpath(".navgraph", ("graph-%s.html"):format(hash))
    local fh = assert(io.open(vim.fs.joinpath(ctx.root, rel), "w"), "fake server could not write graph file")
    fh:write(content)
    fh:close()
    return { path = rel }
  end,
}
