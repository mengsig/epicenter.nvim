--- The fake server answers `docs/lsp.md` v1 and nothing else: these assert the
--- exact keys of every payload the blast features read, so a shape invented on
--- the client can never pass by being mirrored in the fake.
local support = require("support")

local function keys_of(value)
  local out = vim.tbl_keys(value)
  table.sort(out)
  return out
end

local function has_keys(value, required, label)
  for _, key in ipairs(required) do
    expect.truthy(value[key] ~= nil, ("%s has no %q"):format(label, key))
  end
end

local SYMBOL_KEYS = {
  "id",
  "name",
  "qualified",
  "kind",
  "file",
  "uri",
  "line",
  "endLine",
  "sig",
  "language",
  "callers",
  "callees",
  "exported",
  "test",
}

describe("the fake server speaks the v1 editor protocol", function()
  local root

  before_each(function()
    require("epicenter.config").reset()
    root = root or support.start_fake()
  end)

  local function ask(method, params)
    local err, result = support.request(root, method, params)
    expect.eq(err, nil, method .. " failed")
    return result
  end

  it("answers navgraph/blast with roots, nodes, edges and a summary", function()
    local result = ask("navgraph/blast", { symbol = "log_request", depth = 2 })
    expect.eq(keys_of(result), { "edges", "nodes", "roots", "summary" })

    has_keys(result.roots[1], SYMBOL_KEYS, "a root Symbol")
    expect.eq(keys_of(result.nodes[1]), { "depth", "exact", "symbol", "via" })
    has_keys(result.nodes[1].symbol, SYMBOL_KEYS, "a node Symbol")
    expect.eq(keys_of(result.edges[1]), { "exact", "from", "lines", "to" })
    expect.eq(
      keys_of(result.summary),
      { "byDepth", "byFile", "files", "maxDepth", "symbols", "tests", "truncated" }
    )
    expect.eq(keys_of(result.summary.byFile[1]), { "count", "file" })
    expect.eq(result.nodes[1].symbol.line, 9, "Symbol.line is 1-based")
  end)

  it("takes every documented Target form for a blast", function()
    expect.truthy(#ask("navgraph/blast", { symbol = "log_request" }).roots == 1)
    expect.truthy(#ask("navgraph/blast", { file = "app/config.lua" }).roots == 2)

    local uri = vim.uri_from_fname(vim.fs.joinpath(root, "app/server.lua"))
    -- LSP positions are 0-based: line 9 in the file is line 8 here.
    local positioned = ask("navgraph/blast", {
      uri = uri,
      position = { line = 8, character = 13 },
    })
    expect.eq(positioned.roots[1].qualified, "M.handle_request")
  end)

  it("answers navgraph/callers with one Node tree", function()
    local result = ask("navgraph/callers", { symbol = "M.handle_request", depth = 1 })
    expect.eq(keys_of(result), { "root" })
    expect.eq(keys_of(result.root), { "children", "exact", "ext", "lines", "recursion", "symbol" })
    has_keys(result.root.symbol, SYMBOL_KEYS, "the root Symbol")
    expect.eq(result.root.children[1].symbol.qualified, "M.start")
    expect.eq(result.root.children[1].lines, { 15, 16 })
  end)

  it("answers navgraph/outline with one entry per file", function()
    local result = ask("navgraph/outline", { path = "app/server.lua" })
    expect.eq(keys_of(result), { "files" })
    expect.eq(keys_of(result.files[1]), { "file", "lang", "symbols" })
    expect.eq(result.files[1].file, "app/server.lua")
    has_keys(result.files[1].symbols[1], SYMBOL_KEYS, "an outline Symbol")
  end)

  it("wraps a blast result in navgraph/diff", function()
    local result = ask("navgraph/diff", { ref = "HEAD" })
    expect.eq(keys_of(result), { "blast", "ref" })
    expect.eq(result.ref, "HEAD")
    expect.eq(keys_of(result.blast), { "edges", "nodes", "roots", "summary" })
  end)

  it("refuses a param the contract does not define", function()
    local err = support.request(root, "navgraph/blast", { symbol = "log_request", ring = 2 })
    expect.eq(err.code, -32602)
    expect.matches(err.message, "unknown param")

    local outline_err = support.request(root, "navgraph/outline", { uri = "file:///x.lua" })
    expect.eq(outline_err.code, -32602, "outline filters by `path`, never by `uri`")

    local callers_err = support.request(root, "navgraph/callers", { symbol = "x", limit = 5 })
    expect.eq(callers_err.code, -32602, "callers has no `limit`; the client caps the list")
  end)

  it("reports a target that resolves to nothing as -32001", function()
    local err = support.request(root, "navgraph/blast", { symbol = "not_a_symbol" })
    expect.eq(err.code, -32001)
    expect.matches(err.message, "symbol not found")
  end)

  it("treats an empty change set as a routine diff answer, not an error", function()
    local err, result = support.request(root, "navgraph/diff", {})
    expect.eq(err, nil)
    expect.eq(#result.blast.roots, 0)
    expect.eq(result.blast.summary.symbols, 0)
  end)
end)
