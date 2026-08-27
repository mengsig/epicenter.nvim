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

local function walked(roots, opts)
  return graph.blast(built, roots, opts).nodes
end

describe("fake call graph", function()
  it("resolves a same-file call exactly and a cross-file one by name", function()
    local nodes = walked({ symbol("M.handle_request") }, { direction = "callees", depth = 1 })
    expect.eq(names(nodes), { "log_request", "M.route" })

    local by_name = {}
    for _, node in ipairs(nodes) do
      by_name[node.symbol.qualified] = node.exact
    end
    expect.eq(by_name["log_request"], true, "the call and the definition share a file")
    expect.eq(by_name["M.route"], false, "config.route resolves to another file by name alone")
  end)

  it("drops heuristic edges under strict", function()
    local nodes = walked({ symbol("M.handle_request") }, {
      direction = "callees",
      depth = 1,
      strict = true,
    })
    expect.eq(names(nodes), { "log_request" })
  end)

  it("rings callers breadth-first and stops at the requested depth", function()
    local root = { symbol("log_request") }
    expect.eq(names(walked(root, { depth = 1 })), { "M.handle_request" })

    local two = walked(root, { depth = 2 })
    expect.eq(names(two), { "M.handle_request", "M.start" })
    expect.eq(
      vim.tbl_map(function(node)
        return node.depth
      end, two),
      { 1, 2 }
    )
  end)

  it("keeps the shallowest ring for a symbol two paths reach", function()
    local nodes = walked({ symbol("dispatch") }, { depth = 3 })
    local seen = {}
    for _, node in ipairs(nodes) do
      expect.eq(seen[node.symbol.qualified], nil, "a symbol is emitted once")
      seen[node.symbol.qualified] = node.depth
    end
    expect.eq(seen["RequestHandler.handle_request"], 1)
  end)

  it("counts real edges rather than name occurrences", function()
    local enriched = graph.symbol(built, symbol("M.handle_request"))
    expect.eq(enriched.callers, 1, "only M.start calls it")
    expect.eq(enriched.callees, 2, "log_request and, by name, M.route")
    expect.eq(symbol("M.handle_request").callees, 0, "the index itself is left alone")
  end)

  it("summarises the walk the way the protocol specifies", function()
    local answer = graph.blast(built, { symbol("log_request") }, { depth = 2 })
    expect.eq(answer.summary, {
      symbols = 2,
      files = 1,
      tests = 0,
      maxDepth = 2,
      truncated = false,
      byDepth = { 1, 1 },
      byFile = { { file = "app/server.lua", count = 2 } },
    })
    expect.eq(
      vim.tbl_map(function(s)
        return s.qualified
      end, answer.roots),
      { "log_request" }
    )
    for _, edge in ipairs(answer.edges) do
      expect.eq(type(edge.from), "number")
      expect.eq(type(edge.to), "number")
      expect.truthy(#edge.lines > 0, "an edge names its call-site lines")
    end
  end)

  it("marks the walk truncated when the limit stops it", function()
    local answer = graph.blast(built, { symbol("log_request") }, { depth = 2, limit = 1 })
    expect.eq(#answer.nodes, 1)
    expect.eq(answer.summary.truncated, true)
  end)

  it("names the depth-1 neighbours a node was reached through", function()
    local answer = graph.blast(built, { symbol("log_request") }, { depth = 2 })
    local first, second = answer.nodes[1], answer.nodes[2]
    expect.eq(first.via, { first.symbol.id })
    expect.eq(second.via, { first.symbol.id }, "M.start was reached through M.handle_request")
  end)

  it("answers navgraph/callers as a Node tree", function()
    local root = graph.tree(built, symbol("M.handle_request"), { depth = 1 })
    expect.eq(root.symbol.qualified, "M.handle_request")
    expect.eq(root.exact, true)
    expect.eq(root.recursion, false)
    expect.eq(type(root.ext), "table")
    expect.eq(
      vim.tbl_map(function(child)
        return child.symbol.qualified
      end, root.children),
      { "M.start" }
    )
    expect.eq(root.children[1].lines, { 15, 16 }, "both call sites are named")
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
        documented = graph.symbol(overlaid, candidate)
      end
    end
    expect.eq(documented.doc, "Builds the route key.\nTwo lines of it.")
  end)

  it("outlines each matching file in indexing order with its counts", function()
    local outline = graph.outline(built, { path = "app/server.lua" })
    expect.eq(#outline.files, 1)
    expect.eq(outline.files[1].file, "app/server.lua")
    expect.eq(
      vim.tbl_map(function(s)
        return s.qualified
      end, outline.files[1].symbols),
      { "log_request", "M.handle_request", "M.start" }
    )
    expect.eq(outline.files[1].symbols[2].callers, 1)
    expect.eq(outline.files[1].symbols[2].callees, 2)
    expect.eq(#graph.outline(built, {}).files, 3, "no path filter outlines every file")
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

    local named = graph.targets(built, { symbol = "M.start" }, to_relative)
    expect.eq(named[1].qualified, "M.start")

    -- Line 10 (0-based 9) is inside M.handle_request's body.
    local positioned =
      graph.targets(built, { uri = uri, position = { line = 9, character = 4 } }, to_relative)
    expect.eq(positioned[1].qualified, "M.handle_request")

    local whole_file = graph.targets(built, { file = "app/config.lua" }, to_relative)
    expect.eq(#whole_file, 2, "{ file } unions every definition in that file")

    local since_ref = graph.targets(
      built,
      { ref = "HEAD" },
      to_relative,
      { ["app/config.lua"] = "" }
    )
    expect.eq(#since_ref, 2, "{ ref } is the changed set")

    expect.eq(graph.targets(built, { symbol = "nope" }, to_relative), {})
    expect.eq(graph.targets(built, {}, to_relative), {})
  end)
end)
