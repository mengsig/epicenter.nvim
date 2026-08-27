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
