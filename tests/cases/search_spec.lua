local search = require("epicenter.features.search")

local SYMBOL = {
  qualified = "M.handle_request",
  kind = "method",
  file = "app/server.lua",
  line = 9,
  endLine = 13,
  callers = 3,
  uri = "file:///tmp/proj/app/server.lua",
}

describe("search rows", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("shows the qualified name, the location and the fan-in", function()
    local row = search.render_symbol({ symbol = SYMBOL, matches = {} })
    expect.matches(row.text, "M%.handle_request")
    expect.matches(row.text, "app/server%.lua:9")
    expect.matches(row.text, "3$")
  end)

  it("lights exactly the matched characters", function()
    local row = search.render_symbol({ symbol = SYMBOL, matches = { 0, 2 } })
    local lit = {}
    for _, span in ipairs(row.spans) do
      if span.hl == "EpicenterMatch" then
        table.insert(lit, row.text:sub(span.from + 1, span.to))
      end
    end
    expect.eq(lit, { "M", "h" }, "match indices are relative to the qualified name, not the row")
  end)

  it("omits the fan-in badge when nothing calls the symbol", function()
    local row = search.render_symbol({
      symbol = vim.tbl_extend("force", SYMBOL, { callers = 0 }),
      matches = {},
    })
    expect.falsy(row.text:match("%d$") and row.text:match("0$"))
  end)

  it("ignores a match index past the end of the name", function()
    local row = search.render_symbol({ symbol = SYMBOL, matches = { 999 } })
    for _, span in ipairs(row.spans) do
      expect.truthy(span.to <= #row.text)
    end
  end)

  it("shows the reference's own line in refs mode, not the enclosing definition's (F3)", function()
    -- A refs-mode item carries the enclosing definition as `symbol` but the
    -- actual use-site line(s) in `lines` - the definition's own line (9)
    -- must not appear; the reference's line (10) must.
    local row = search.render_symbol({ symbol = SYMBOL, lines = { 10, 14 } })
    expect.matches(row.text, "app/server%.lua:10")
    expect.falsy(row.text:match("app/server%.lua:9%f[%D]"), "must not show the definition's line")
  end)

  it("jumps to the first use site in refs mode, not the definition (F3)", function()
    local target = search.symbol_target({ symbol = SYMBOL, lines = { 10, 14 } })
    expect.eq(target.path, "/tmp/proj/app/server.lua")
    expect.eq(target.line, 10, "must land on the reference, not the definition line (9)")
    expect.eq(target.end_line, nil, "a reference is a single line, not the whole function")
  end)

  it("jumps to the definition when not in refs mode", function()
    local target = search.symbol_target({ symbol = SYMBOL, matches = {} })
    expect.eq(target.line, 9)
    expect.eq(target.end_line, 13)
  end)

  it("renders a grep hit with the match lit inside the trimmed line", function()
    local row = search.render_match({
      file = "app/server.lua",
      line = 10,
      character = 2,
      text = "  log_request(method, path)",
    }, 1, "log_request")
    expect.matches(row.text, "app/server%.lua:10")
    local lit = nil
    for _, span in ipairs(row.spans) do
      if span.hl == "EpicenterMatch" then
        lit = row.text:sub(span.from + 1, span.to)
      end
    end
    expect.eq(lit, "log_request", "the highlight follows the text after trimming")
  end)

  it("declares both palette commands and their keymaps", function()
    expect.eq(
      vim.tbl_map(function(c)
        return c.name
      end, search.commands),
      { "search", "grep" }
    )
    expect.eq(
      vim.tbl_map(function(k)
        return k.suffix
      end, search.keymaps),
      { "s", "g" }
    )
  end)
end)
