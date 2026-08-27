--- Blast-radius area of the fake navgraph server: ring walks, the hover
--- card's caller list, per-file outlines and diff impact. The graph itself
--- lives in `fakelib.graph`.
local graph = require("fakelib.graph")

local function walk_opts(params)
  return {
    direction = params.direction,
    depth = params.depth,
    tests = params.tests,
    strict = params.strict,
  }
end

local function answer(ctx, roots, params)
  return {
    roots = vim.tbl_map(function(symbol)
      return graph.enrich(ctx.index, symbol)
    end, roots),
    nodes = graph.walk(ctx.index, roots, walk_opts(params)),
    direction = params.direction or "callers",
    depth = params.depth or 2,
    tests = params.tests or "with",
    strict = params.strict == true,
  }
end

return {
  ["navgraph/blast"] = function(ctx, params)
    return answer(ctx, graph.roots(ctx.index, params, ctx.to_relative), params)
  end,

  ["navgraph/callers"] = function(ctx, params)
    local roots = graph.roots(ctx.index, params, ctx.to_relative)
    if #roots == 0 then
      return { symbol = vim.NIL, items = {}, total = 0 }
    end
    local items = graph.walk(ctx.index, roots, {
      direction = params.direction or "callers",
      depth = params.depth or 1,
      tests = params.tests,
      strict = params.strict,
    })
    local limit = params.limit or #items
    return {
      symbol = graph.enrich(ctx.index, roots[1]),
      items = vim.list_slice(items, 1, math.min(#items, limit)),
      total = #items,
    }
  end,

  ["navgraph/outline"] = function(ctx, params)
    local file = ctx.to_relative(params.uri)
    return { uri = params.uri, file = file, symbols = graph.outline(ctx.index, file) }
  end,

  ["navgraph/diff"] = function(ctx, params)
    local roots = graph.changed(ctx.index, ctx.overlays)
    local result = answer(ctx, roots, params)
    result.ref = params.ref or "HEAD"
    return result
  end,
}
