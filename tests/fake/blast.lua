--- Blast-radius area of the fake navgraph server: `navgraph/blast` and
--- `navgraph/diff`, in the shapes `docs/lsp.md` v1 specifies and no others.
--- `navgraph/callers` and `navgraph/outline` are also on this wire, but the
--- explore area owns both (its Target resolution handles a cursor mid-call,
--- which this hover card also needs; see `tests/fake/explore.lua`).
---
--- Params are checked against the contract and a key that is not in it is a
--- `-32602`: a client that drifts from the protocol must fail here, loudly,
--- rather than against a shape the fake invented to be friendly.
local graph = require("fakelib.graph")

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

--- The fixture has no git of its own ("Changed has no git here", above), so
--- this stands in for what a real repository's refs would resolve - a ref
--- git rejects is a `-32002`, never silently a clean tree.
local KNOWN_REFS = { HEAD = true, ["origin/main"] = true }

local SCOPE = { strict = true, tests = true }
local TARGET = { uri = true, position = true, symbol = true, file = true, ref = true }

local function merged(...)
  return vim.tbl_extend("force", {}, ...)
end

local BLAST_PARAMS = merged(TARGET, SCOPE, { depth = true, direction = true, limit = true })
local DIFF_PARAMS = merged(SCOPE, { ref = true, depth = true, direction = true, limit = true })

local function walk_opts(params)
  return {
    direction = params.direction,
    depth = params.depth,
    tests = params.tests,
    strict = params.strict,
    limit = params.limit,
  }
end

local function blast_for(ctx, params)
  local roots = graph.targets(ctx.index, params, ctx.to_relative, ctx.overlays)
  if #roots == 0 then
    fail(-32001, "navgraph/blast: symbol not found")
  end
  return graph.blast(ctx.index, roots, walk_opts(params))
end

return {
  ["navgraph/blast"] = function(ctx, params)
    check_params("navgraph/blast", params, BLAST_PARAMS)
    return blast_for(ctx, params)
  end,

  --- Unlike a `{ ref }` blast, an empty change set is a routine answer here.
  ["navgraph/diff"] = function(ctx, params)
    check_params("navgraph/diff", params, DIFF_PARAMS)
    local ref = params.ref or "HEAD"
    if not KNOWN_REFS[ref] then
      fail(-32002, "fatal: bad revision '%s'", ref)
    end
    local roots = graph.changed(ctx.index, ctx.overlays)
    return {
      ref = ref,
      blast = graph.blast(
        ctx.index,
        roots,
        merged(walk_opts(params), { depth = params.depth or 1 })
      ),
    }
  end,
}
