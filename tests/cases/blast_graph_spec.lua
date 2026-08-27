local graph = require("fakelib.graph")
local index_lib = require("fakelib.index")
local support = require("support")

local built = index_lib.build(support.fixture_root(), {})

local function symbol(qualified)
  for _, candidate in ipairs(built.symbols) do
    if candidate.qualified == qualified then
      return candidate
    end
  end
  error("no fixture symbol named " .. qualified)
end

local function names(nodes)
  return vim.tbl_map(function(node)
    return node.symbol.qualified
  end, nodes)
end

describe("fake call graph", function()
  it("resolves a same-file call exactly and a cross-file one by name", function()
    local nodes = graph.walk(built, { symbol("M.handle_request") }, {
      direction = "callees",
      depth = 1,
    })
    expect.eq(names(nodes), { "log_request", "M.route" })

    local by_name = {}
    for _, node in ipairs(nodes) do
      by_name[node.symbol.qualified] = node.heuristic
    end
    expect.eq(by_name["log_request"], false, "the call and the definition share a file")
    expect.eq(by_name["M.route"], true, "config.route resolves to another file by name alone")
  end)

  it("drops heuristic edges under strict", function()
    local nodes = graph.walk(built, { symbol("M.handle_request") }, {
      direction = "callees",
      depth = 1,
      strict = true,
    })
    expect.eq(names(nodes), { "log_request" })
  end)

  it("rings callers breadth-first and stops at the requested depth", function()
    local root = { symbol("log_request") }
    expect.eq(names(graph.walk(built, root, { depth = 1 })), { "M.handle_request" })

    local two = graph.walk(built, root, { depth = 2 })
    expect.eq(names(two), { "M.handle_request", "M.start" })
    expect.eq(
      vim.tbl_map(function(node)
        return node.ring
      end, two),
      { 1, 2 }
    )
  end)

  it("keeps the shallowest ring for a symbol two paths reach", function()
    local nodes = graph.walk(built, { symbol("dispatch") }, { depth = 3 })
    local seen = {}
    for _, node in ipairs(nodes) do
      expect.eq(seen[node.symbol.qualified], nil, "a symbol is emitted once")
      seen[node.symbol.qualified] = node.ring
    end
    expect.eq(seen["RequestHandler.handle_request"], 1)
  end)

  it("counts real edges rather than name occurrences", function()
    local enriched = graph.enrich(built, symbol("M.handle_request"))
    expect.eq(enriched.callers, 1, "only M.start calls it")
    expect.eq(enriched.callees, 2, "log_request and, by name, M.route")
    expect.eq(symbol("M.handle_request").callees, 0, "the index itself is left alone")
  end)

  it("reads the comment block above a definition as its doc", function()
    local overlaid = index_lib.build(support.fixture_root(), {
      ["app/config.lua"] = table.concat({
        "local M = {}",
        "",
        "--- Builds the route key.",
        "-- Two lines of it.",
        "function M.route(method, path)",
        "  return method",
        "end",
        "",
        "return M",
      }, "\n"),
    })
    local documented = nil
    for _, candidate in ipairs(overlaid.symbols) do
      if candidate.qualified == "M.route" then
        documented = graph.enrich(overlaid, candidate)
      end
    end
    expect.eq(documented.doc, "Builds the route key.\nTwo lines of it.")
  end)

  it("outlines a file in definition order with its counts", function()
    local outline = graph.outline(built, "app/server.lua")
    expect.eq(
      vim.tbl_map(function(s)
        return s.qualified
      end, outline),
      { "log_request", "M.handle_request", "M.start" }
    )
    expect.eq(outline[2].callers, 1)
    expect.eq(outline[2].callees, 2)
  end)

  it("treats the files navgraph holds overlays for as the changed set", function()
    expect.eq(graph.changed(built, {}), {})
    local changed = graph.changed(built, { ["app/config.lua"] = "" })
    expect.eq(
      vim.tbl_map(function(s)
        return s.qualified
      end, changed),
      { "M.route", "M.load_config" }
    )
  end)

  it("targets a named symbol, else the definition around a position", function()
    local uri = vim.uri_from_fname(vim.fs.joinpath(support.fixture_root(), "app/server.lua"))
    local to_relative = function()
      return "app/server.lua"
    end

    local named = graph.roots(built, { symbol = "M.start" }, to_relative)
    expect.eq(named[1].qualified, "M.start")

    -- Line 10 (0-based 9) is inside M.handle_request's body.
    local positioned =
      graph.roots(built, { uri = uri, position = { line = 9, character = 4 } }, to_relative)
    expect.eq(positioned[1].qualified, "M.handle_request")

    expect.eq(graph.roots(built, { symbol = "nope" }, to_relative), {})
    expect.eq(graph.roots(built, {}, to_relative), {})
  end)
end)
