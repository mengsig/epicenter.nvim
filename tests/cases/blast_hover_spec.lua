local hover = require("epicenter.features.blast.hover")
local support = require("support")

local SYMBOL = {
  kind = "method",
  name = "handle_request",
  qualified = "M.handle_request",
  file = "app/server.lua",
  uri = "file:///proj/app/server.lua",
  line = 9,
  endLine = 13,
  sig = "function M.handle_request(method, path)",
  callers = 1,
  callees = 2,
  doc = "Routes one request.\nReturns the response.",
}

local CALLER = {
  kind = "fn",
  name = "start",
  qualified = "M.start",
  file = "app/server.lua",
  uri = "file:///proj/app/server.lua",
  line = 14,
  endLine = 18,
}

describe("hover card contents", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, lsp = { auto_start = false } })
  end)

  it("shows the kind, signature, counts, range, doc and top callers", function()
    local card = hover.render({
      symbol = SYMBOL,
      items = { { ring = 1, symbol = CALLER } },
      total = 3,
    })
    local text = table.concat(card.lines, "\n")

    expect.matches(card.lines[1], "M%.handle_request")
    expect.eq(card.lines[2], "  function M.handle_request(method, path)")
    expect.matches(text, "1 caller[^s]")
    expect.matches(text, "2 callees")
    expect.matches(text, "app/server%.lua:9%-13")
    expect.matches(text, "Routes one request%.")
    expect.matches(text, "Returns the response%.")
    expect.matches(text, "top callers  1 of 3")
    expect.matches(text, "M%.start  app/server%.lua:14")
  end)

  it("points <CR> on a caller row at that caller", function()
    local card = hover.render({ symbol = SYMBOL, items = { { ring = 1, symbol = CALLER } } })
    expect.eq(#card.rows, 1)
    expect.eq(card.targets[card.rows[1]], {
      path = "/proj/app/server.lua",
      line = 14,
      end_line = 18,
    })
  end)

  it("drops the caller section and the doc when there are none", function()
    local bare = vim.deepcopy(SYMBOL)
    bare.doc = nil
    local card = hover.render({ symbol = bare, items = {}, total = 0 })
    local text = table.concat(card.lines, "\n")
    expect.falsy(text:find("top callers", 1, true))
    expect.falsy(text:find("Routes one request", 1, true))
    expect.eq(card.rows, {})
  end)

  it("says `N of M` only when the list is capped", function()
    local card =
      hover.render({ symbol = SYMBOL, items = { { ring = 1, symbol = CALLER } }, total = 1 })
    expect.matches(table.concat(card.lines, "\n"), "top callers\n")
  end)

  it("colours the signature where a parser exists, and never errors without one", function()
    expect.eq(hover.signature_spans("function f() end", "/tmp/nothing.zzz", 2), {})
    local spans = hover.signature_spans("local x = 1", "/tmp/a.lua", 2)
    for _, span in ipairs(spans) do
      expect.truthy(span.from >= 2, "spans are offset into the rendered line")
      expect.matches(span.hl, "^@")
    end
  end)
end)

describe("hover card against the fake navgraph server", function()
  local root, buf, card

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if card then
      card:close()
      card = nil
    end
  end)

  local function opened(bufnr)
    local it_card = require("epicenter").run("hover", {}, bufnr or buf)
    wait(function()
      return it_card.answered > 0
    end, 10000, "hover answer")
    return it_card
  end

  it("describes the definition the cursor sits in without taking focus", function()
    local before = vim.api.nvim_get_current_win()
    card = opened()
    expect.truthy(card:valid())
    expect.eq(vim.api.nvim_get_current_win(), before, "the card never steals the cursor")

    local text = table.concat(vim.api.nvim_buf_get_lines(card.win.buf, 0, -1, false), "\n")
    expect.matches(text, "M%.handle_request")
    expect.matches(text, "1 caller[^s]")
    expect.matches(text, "2 callees")
    expect.matches(text, "top callers")
    expect.matches(text, "M%.start")
  end)

  it("focuses the card on a second hover", function()
    card = opened()
    local same = require("epicenter").run("hover", {}, buf)
    expect.eq(same, card, "a second hover reuses the open card")
    expect.eq(vim.api.nvim_get_current_win(), card.win.win)
    vim.api.nvim_set_current_win(card.origin_win)
  end)

  it("jumps to the caller under <CR>", function()
    card = opened()
    local jumping = card
    card = nil
    jumping:jump()
    wait(function()
      return vim.api.nvim_win_get_cursor(0)[1] == 14
    end, 5000, "jump to M.start")
    expect.matches(vim.api.nvim_get_current_line(), "function M%.start")
  end)

  it("says so when there is no definition under the cursor", function()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/config.lua")))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local notices = {}
    local toast = require("epicenter.ui.toast")
    local original = toast.notify
    toast.notify = function(msg)
      table.insert(notices, msg)
    end

    local empty = opened(vim.api.nvim_get_current_buf())
    toast.notify = original
    expect.falsy(empty:valid())
    expect.eq(#notices, 1)
    expect.matches(notices[1], "no symbol under the cursor")
  end)
end)
