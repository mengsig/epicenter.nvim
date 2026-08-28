--- F7 regression: the fake must answer with EXACTLY the shapes `docs/lsp.md`
--- v1 specifies - no invented fields, no missing ones - and must reject a
--- param the contract does not define. Before this fix the fake mirrored the
--- client's invented shapes (`result.edges`, `{found,steps}`, `result.nodes`,
--- `{items:Symbol[]}` for hot, an output `path` for graph); every assertion
--- below would have failed against that fake.
local support = require("support")

local function keys_of(t)
  local out = {}
  for k in pairs(t) do
    table.insert(out, k)
  end
  table.sort(out)
  return out
end

describe("the fake answers the real navgraph/* shapes", function()
  local root

  before_each(function()
    require("epicenter.config").reset()
    root = root or support.start_fake()
  end)

  it("navgraph/callers returns only {root}, a Node with no invented fields", function()
    local err, result = support.request(root, "navgraph/callers", { symbol = "log_request" })
    expect.eq(err, nil)
    expect.eq(keys_of(result), { "root" })
    local node = result.root
    expect.eq(
      keys_of(node),
      { "children", "exact", "ext", "lines", "recursion", "symbol" },
      "a Node carries exactly the contract's fields, no degree/edges"
    )
    expect.eq(type(node.symbol.callers), "number")
    expect.eq(type(node.symbol.callees), "number")
  end)

  it("navgraph/calls children are also plain Nodes", function()
    local err, result = support.request(root, "navgraph/calls", { symbol = "M.handle_request" })
    expect.eq(err, nil)
    expect.truthy(#result.root.children > 0)
    expect.eq(
      keys_of(result.root.children[1]),
      { "children", "exact", "ext", "lines", "recursion", "symbol" }
    )
  end)

  it("navgraph/callers rejects a param the contract does not define", function()
    local err = support.request(root, "navgraph/callers", { symbol = "log_request", limit = 5 })
    expect.truthy(err, "an invented param must fail loudly")
    expect.eq(err.code, -32602)
  end)

  it("navgraph/path returns {path,ambiguousFrom,ambiguousTo}, path a flat Symbol[]", function()
    local err, result =
      support.request(root, "navgraph/path", { from = "M.start", to = "log_request" })
    expect.eq(err, nil)
    expect.eq(keys_of(result), { "ambiguousFrom", "ambiguousTo", "path" })
    expect.truthy(#result.path > 0)
    expect.eq(result.ambiguousFrom, {})
    expect.eq(result.ambiguousTo, {})
    expect.eq(
      type(result.path[1].qualified),
      "string",
      "steps are Symbols directly, not {symbol=...} wrappers"
    )
  end)

  it("navgraph/outline returns {files:[{file,lang,symbols}]}, symbols flat", function()
    local err, result = support.request(root, "navgraph/outline", { path = "app/server.lua" })
    expect.eq(err, nil)
    expect.eq(keys_of(result), { "files" })
    expect.eq(#result.files, 1)
    expect.eq(keys_of(result.files[1]), { "file", "lang", "symbols" })
    expect.eq(result.files[1].lang, "lua")
    expect.eq(
      type(result.files[1].symbols[1].qualified),
      "string",
      "symbols is Symbol[], no children"
    )
  end)

  it("navgraph/hot items carry the contract's fan-in/out fields, not a bare Symbol", function()
    local err, result = support.request(root, "navgraph/hot", { path = "app/server.lua" })
    expect.eq(err, nil)
    expect.eq(keys_of(result), { "items" })
    expect.eq(
      keys_of(result.items[1]),
      { "fanIn", "fanInExact", "fanInTest", "fanOut", "fanOutExact", "symbol" }
    )
  end)

  it("navgraph/unused items are {symbol,testOnly}, not a flat Symbol", function()
    local err, result = support.request(root, "navgraph/unused", {})
    expect.eq(err, nil)
    expect.eq(keys_of(result), { "items" })
    expect.eq(keys_of(result.items[1]), { "symbol", "testOnly" })
  end)

  it(
    "navgraph/graph returns a server-chosen {path,nodes,nodesTotal,truncated}, under .navgraph/",
    function()
      local err, result = support.request(root, "navgraph/graph", {})
      expect.eq(err, nil)
      expect.eq(keys_of(result), { "nodes", "nodesTotal", "path", "truncated" })
      expect.matches(result.path, "^%.navgraph/graph%-%x+%.html$")
      expect.truthy((vim.uv or vim.loop).fs_stat(vim.fs.joinpath(root, result.path)))
      expect.eq(result.truncated, false, "this fixture is nowhere near the node cap")
      expect.eq(result.nodes, result.nodesTotal)
    end
  )

  it("navgraph/status keys languages by language tag, not file extension", function()
    local err, result = support.request(root, "navgraph/status", {})
    expect.eq(err, nil)
    expect.truthy(result.languages.lua, "keyed 'lua', not '.lua'")
    expect.truthy(result.languages.python, "keyed 'python', not '.py'")
  end)

  it("navgraph/status carries exactly the contract's fields, no invented pid (F2)", function()
    local err, result = support.request(root, "navgraph/status", {})
    expect.eq(err, nil)
    expect.eq(keys_of(result), {
      "cache",
      "edges",
      "files",
      "indexedAt",
      "languages",
      "lastIndexMs",
      "overlays",
      "protocolVersion",
      "root",
      "symbols",
      "version",
    })
  end)
end)
