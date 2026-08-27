local index = require("fakelib.index")
local support = require("support")

local built = index.build(support.fixture_root(), {})

local function by_qualified(name)
  for _, symbol in ipairs(built.symbols) do
    if symbol.qualified == name then
      return symbol
    end
  end
end

describe("fake index", function()
  it("scans every fixture source", function()
    expect.eq(built.files, { "app/config.lua", "app/handlers.py", "app/server.lua" })
  end)

  it("qualifies lua and python definitions", function()
    expect.truthy(by_qualified("M.handle_request"))
    expect.truthy(by_qualified("log_request"))
    expect.truthy(by_qualified("RequestHandler"))
    expect.truthy(by_qualified("RequestHandler.handle_request"))
    expect.truthy(by_qualified("dispatch"), "a top-level def is not nested under the class")
  end)

  it("records the real line of each definition", function()
    local symbol = by_qualified("M.handle_request")
    local lines = built.sources["app/server.lua"]
    expect.matches(lines[symbol.line], "function M%.handle_request")
    expect.truthy(symbol.endLine >= symbol.line)
  end)

  it("counts call sites as fan-in", function()
    expect.eq(by_qualified("log_request").callers, 1)
    expect.eq(by_qualified("M.handle_request").callers, 3)
    expect.eq(by_qualified("RequestHandler.close").callers, 0)
  end)

  it("finds the symbol enclosing a line", function()
    local symbol = by_qualified("M.handle_request")
    expect.eq(index.enclosing(built, "app/server.lua", symbol.line).qualified, "M.handle_request")
    expect.eq(index.enclosing(built, "app/server.lua", 1), nil)
  end)

  it("matches a subsequence and reports the matched indices", function()
    expect.eq(index.fuzzy("handle_request", "hreq"), { 0, 7, 8, 9 })
    expect.eq(index.fuzzy("handle_request", "HRQ"), { 0, 7, 9 }, "matching is case-insensitive")
    expect.eq(index.fuzzy("handle", "xyz"), nil)
  end)
end)

describe("fake search ranking", function()
  it("ranks exact above prefix above word boundary above subsequence", function()
    local exact = index.search(built, { query = "dispatch" })
    expect.eq(exact.items[1].symbol.qualified, "dispatch")
    expect.eq(exact.items[1].score, 1000)

    local boundary = index.search(built, { query = "handle_request" })
    expect.eq(boundary.items[1].symbol.qualified, "M.handle_request")
    expect.eq(boundary.items[1].score, 600, "a match right after a dot is a word boundary")
  end)

  it("breaks ties by fan-in", function()
    local result = index.search(built, { query = "handle_request" })
    for i = 2, #result.items do
      local a, b = result.items[i - 1], result.items[i]
      expect.truthy(
        a.score > b.score or a.symbol.callers >= b.symbol.callers,
        "results are not ordered by score then fan-in"
      )
    end
  end)

  it("filters by kind", function()
    local result = index.search(built, { query = "handle", kinds = { "class" } })
    for _, item in ipairs(result.items) do
      expect.eq(item.symbol.kind, "class")
    end
  end)

  it("returns nothing for a query that matches nothing", function()
    local result = index.search(built, { query = "zzzqqq" })
    expect.eq(result.items, {})
    expect.eq(result.total, 0)
  end)

  it("caps items at the limit but reports the true total", function()
    local result = index.search(built, { query = "e", limit = 1 })
    expect.eq(#result.items, 1)
    expect.truthy(result.total > 1)
  end)
end)

describe("fake grep", function()
  it("finds a literal across files with 1-based lines", function()
    local result = index.grep(built, { pattern = "handle_request" })
    expect.truthy(result.total >= 4)
    for _, item in ipairs(result.items) do
      expect.matches(built.sources[item.file][item.line], "handle_request")
      expect.eq(item.text:sub(item.character + 1, item.character + 14), "handle_request")
    end
  end)

  it("is case-insensitive by default and case-sensitive on request", function()
    expect.truthy(index.grep(built, { pattern = "REQUESTHANDLER" }).total > 0)
    expect.eq(index.grep(built, { pattern = "REQUESTHANDLER", caseSensitive = true }).total, 0)
  end)

  it("attaches the enclosing symbol", function()
    local result = index.grep(built, { pattern = "config.route" })
    expect.eq(result.items[1].enclosing.qualified, "M.handle_request")
  end)

  it("marks a truncated result", function()
    local result = index.grep(built, { pattern = "e", limit = 2 })
    expect.eq(#result.items, 2)
    expect.eq(result.truncated, true)
  end)
end)

describe("fake overlays", function()
  it("indexes unsaved text in place of the file on disk", function()
    local overlaid = index.build(support.fixture_root(), {
      ["app/config.lua"] = "local M = {}\n\nfunction M.brand_new_symbol()\n  return 1\nend\n\nreturn M\n",
    })
    local names = vim.tbl_map(function(s)
      return s.qualified
    end, overlaid.symbols)
    expect.truthy(vim.tbl_contains(names, "M.brand_new_symbol"))
    expect.falsy(vim.tbl_contains(names, "M.route"), "the disk copy is replaced, not merged")
  end)
end)
