--- Exploration area of the fake navgraph server: the call graph behind
--- callers/calls, and the queries built on it.
---
--- The edges are derived from the fixture sources rather than hard-coded, so a
--- fixture edit cannot silently drift from what the specs assert. Resolution
--- mirrors the real engine's two tiers: an exact qualified-name hit is a solid
--- edge, a trailing-name hit is a heuristic one (`?` in the UI, dropped by
--- `strict`).
local index_mod = require("fakelib.index")

--- Words that end in `(` but are never a call.
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

--- One graph per index build; a reindex builds a fresh index table.
local graphs = setmetatable({}, { __mode = "k" })

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

local function graph_of(index)
  if graphs[index] then
    return graphs[index]
  end

  local by_qualified, by_name = {}, {}
  for _, symbol in ipairs(index.symbols) do
    by_qualified[symbol.qualified] = by_qualified[symbol.qualified] or symbol
    by_name[symbol.name] = by_name[symbol.name] or {}
    table.insert(by_name[symbol.name], symbol)
  end

  local edges, seen = {}, {}
  local function add(from, to, name, kind, heuristic)
    local key = ("%s|%s|%s"):format(tostring(from), tostring(to or name), kind)
    if seen[key] then
      seen[key].count = seen[key].count + 1
      return
    end
    local edge =
      { from = from, to = to, name = name, kind = kind, heuristic = heuristic, count = 1 }
    seen[key] = edge
    table.insert(edges, edge)
  end

  for _, from in ipairs(index.symbols) do
    local lines = index.sources[from.file] or {}
    for i = from.line + 1, math.min(from.endLine, #lines) do
      for _, mention in ipairs(mentions(lines[i])) do
        local bare = mention.word:match("[%w_]+$")
        if not KEYWORDS[bare] then
          local kind = mention.call and "call" or "ref"
          local exact = by_qualified[mention.word]
          if exact then
            add(from, exact, exact.qualified, kind, false)
          else
            local candidates = by_name[bare] or {}
            for _, to in ipairs(candidates) do
              add(from, to, to.qualified, kind, true)
            end
            -- An unresolved *call* is an external edge; an unresolved bare
            -- mention is noise (a string, a parameter) and is dropped.
            if #candidates == 0 and mention.call then
              add(from, nil, mention.word, kind, true)
            end
          end
        end
      end
    end
  end

  graphs[index] = edges
  return edges
end

--- @param opts { refs?: boolean, strict?: boolean, tests?: string }
local function allowed(edge, other, opts)
  if edge.kind == "ref" and not opts.refs then
    return false
  end
  if opts.strict and edge.heuristic then
    return false
  end
  local tests = opts.tests or "with"
  if tests == "without" and other and other.test then
    return false
  end
  if tests == "only" and not (other and other.test) then
    return false
  end
  return true
end

--- Edges leaving `symbol` (callees) or arriving at it (callers).
--- @param direction "callers"|"callees"
local function level(edges, symbol, direction, opts)
  local out = {}
  for _, edge in ipairs(edges) do
    if direction == "callees" and edge.from == symbol and allowed(edge, edge.to, opts) then
      table.insert(out, { node = edge.to, edge = edge })
    elseif direction == "callers" and edge.to == symbol and allowed(edge, edge.from, opts) then
      table.insert(out, { node = edge.from, edge = edge })
    end
  end
  return out
end

--- Symbol the request points at: an explicit name, else the word under the
--- cursor, else the symbol whose body encloses the cursor.
local function root_symbol(ctx, params)
  if type(params.symbol) == "string" and params.symbol ~= "" then
    for _, symbol in ipairs(ctx.index.symbols) do
      if symbol.qualified == params.symbol then
        return symbol
      end
    end
    for _, symbol in ipairs(ctx.index.symbols) do
      if symbol.name == params.symbol then
        return symbol
      end
    end
    return nil
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
  return index_mod.enclosing(ctx.index, file, row)
end

local function opts_of(params)
  return { refs = params.refs == true, strict = params.strict == true, tests = params.tests }
end

local function respond(ctx, params, direction)
  local edges = graph_of(ctx.index)
  local opts = opts_of(params)
  local root = root_symbol(ctx, params)
  if not root then
    return { root = vim.NIL, edges = {} }
  end

  local found = level(edges, root, direction, opts)
  local limit = params.limit or 100
  local items = {}
  for _, entry in ipairs(vim.list_slice(found, 1, math.min(#found, limit))) do
    table.insert(items, {
      symbol = entry.node or nil,
      name = entry.node and entry.node.qualified or entry.edge.name,
      resolved = entry.node ~= nil,
      heuristic = entry.edge.heuristic,
      kind = entry.edge.kind,
      count = entry.edge.count,
      degree = entry.node and #level(edges, entry.node, direction, opts) or 0,
    })
  end

  return {
    root = { symbol = root, degree = #found },
    edges = items,
    truncated = #found > #items,
  }
end

return {
  ["navgraph/callers"] = function(ctx, params)
    return respond(ctx, params, "callers")
  end,

  ["navgraph/calls"] = function(ctx, params)
    return respond(ctx, params, "callees")
  end,
}
