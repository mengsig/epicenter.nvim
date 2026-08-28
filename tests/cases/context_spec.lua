--- `:Epicenter context` and `:Epicenter where`: the markdown rendering (pure)
--- and both commands end to end against the fake server, which speaks the
--- v1.1 addendum.
local support = require("support")
local epicenter = require("epicenter")
local context = require("epicenter.features.context")

local function symbol(over)
  return vim.tbl_extend("force", {
    id = 1,
    name = "handle",
    qualified = "M.handle",
    kind = "fn",
    file = "app/server.lua",
    uri = "file:///proj/app/server.lua",
    line = 9,
    endLine = 12,
    sig = "function M.handle(method, path)",
    language = "lua",
    callers = 2,
    callees = 1,
    exported = true,
    test = false,
    contentHash = "0123456789abcdef",
  }, over or {})
end

local function bundle(over)
  return vim.tbl_extend("force", {
    symbol = symbol(),
    definition = {
      text = "function M.handle(method, path)\n  return path\nend",
      range = { start = { line = 8, character = 0 }, ["end"] = { line = 11, character = 0 } },
    },
    signature = "function M.handle(method, path)",
    doc = "Handles one request.",
    callers = { symbol({ qualified = "M.start", line = 14 }) },
    callees = { symbol({ qualified = "config.route", file = "app/config.lua", line = 3 }) },
    types = {},
    tests = {},
    truncated = false,
    tokensEstimate = 120,
  }, over or {})
end

describe("the context bundle as markdown", function()
  it("leads with the qualified name and where it lives", function()
    expect.matches(context.markdown(bundle()), "^## `M%.handle` — app/server%.lua:9")
  end)

  it("carries the signature, the doc and the body in a fenced block", function()
    local text = context.markdown(bundle())
    expect.matches(text, "`function M%.handle%(method, path%)`")
    expect.matches(text, "> Handles one request%.")
    expect.matches(text, "```lua\nfunction M%.handle")
  end)

  it("names each neighbour with the file:line that finds it", function()
    local text = context.markdown(bundle())
    expect.matches(text, "%*%*callers%*%* %(1%)")
    expect.matches(text, "%- `M%.start` — app/server%.lua:14")
    expect.matches(text, "%- `config%.route` — app/config%.lua:3")
  end)

  it("omits a section the bundle has nothing for", function()
    expect.falsy(context.markdown(bundle()):find("**tests**", 1, true))
  end)

  it("says so when the server trimmed the bundle", function()
    expect.matches(context.markdown(bundle({ truncated = true })), "trimmed to fit")
  end)

  it("lists every member as a quickfix row, the symbol first", function()
    local rows = context.qf_rows(bundle())
    expect.eq(#rows, 3)
    expect.matches(rows[1].text, "^symbol")
    expect.matches(rows[2].text, "^caller  M%.start")
    expect.eq(rows[3].target.line, 3)
  end)
end)

describe("the context argument list", function()
  it("takes --budget in both spellings and keeps the rest", function()
    local rest, budget, err = context.split_budget({ "M.handle", "--budget", "500" })
    expect.eq(rest, { "M.handle" })
    expect.eq(budget, 500)
    expect.eq(err, nil)

    local _, inline = context.split_budget({ "--budget=800" })
    expect.eq(inline, 800)
  end)

  it("refuses a budget that is not a positive whole number", function()
    local _, budget, err = context.split_budget({ "--budget", "nope" })
    expect.eq(budget, nil)
    expect.matches(err or "", "positive whole number")
    expect.matches(select(3, context.split_budget({ "--budget", "-4" })) or "", "positive whole")
  end)

  it("reads file:line, a bare line, and neither", function()
    expect.eq({ context.split_location("app/server.lua:12") }, { "app/server.lua", 12 })
    expect.eq({ context.split_location("app/server.lua:12:4") }, { "app/server.lua", 12 })
    expect.eq({ context.split_location("31") }, { nil, 31 })
    expect.eq({ context.split_location("nonsense") }, {})
  end)
end)

describe("the where trail", function()
  it("joins the chain and pins the enclosing definition", function()
    local text = context.trail({
      enclosing = symbol(),
      breadcrumbs = { symbol({ name = "M" }), symbol() },
      file = "app/server.lua",
    })
    expect.matches(text, "M.*M%.handle", "ancestors by name, the innermost qualified")
    expect.matches(text, "app/server%.lua:9")
  end)

  it("says a line is inside nothing rather than inventing a chain", function()
    expect.matches(
      context.trail({ enclosing = vim.NIL, breadcrumbs = {}, file = "app/server.lua" }),
      "not inside a definition"
    )
  end)
end)

describe("context and where against the fake navgraph server", function()
  local root, buf, notices

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    buf = vim.api.nvim_get_current_buf()
    -- Column 12 is inside `handle_request` on its own definition line.
    vim.api.nvim_win_set_cursor(0, { 9, 12 })
    support.attach(root, buf)

    notices = {}
    epicenter.notify = function(msg)
      table.insert(notices, msg)
    end
    vim.fn.setreg(context.target_register(), "")
  end)

  after_each(function()
    require("epicenter.events").clear()
  end)

  local function yanked()
    return vim.fn.getreg(context.target_register())
  end

  it("yanks the cursor's symbol as markdown and reports the token estimate", function()
    epicenter.run("context", {}, buf)
    wait(function()
      return yanked() ~= ""
    end, 10000, "the yanked bundle")

    expect.matches(yanked(), "## `M%.handle_request`")
    expect.matches(yanked(), "```lua")
    expect.matches(yanked(), "%*%*callers%*%*")
    expect.matches(table.concat(notices, "\n"), "~%d+ tokens")
  end)

  it("takes a named symbol instead of the cursor", function()
    epicenter.run("context", { "M.start" }, buf)
    wait(function()
      return yanked():find("M.start", 1, true) ~= nil
    end, 10000, "the named bundle")
    expect.matches(yanked(), "## `M%.start`")
  end)

  it("drops the body first under a tight budget, and says it was trimmed", function()
    epicenter.run("context", { "M.handle_request", "--budget", "1" }, buf)
    wait(function()
      return yanked() ~= ""
    end, 10000, "the trimmed bundle")

    expect.falsy(yanked():find("```", 1, true), "the body is the first thing dropped")
    expect.matches(yanked(), "trimmed to fit")
    expect.matches(table.concat(notices, "\n"), "trimmed")
  end)

  it("refuses a malformed budget without asking the server", function()
    epicenter.run("context", { "--budget", "half" }, buf)
    expect.matches(table.concat(notices, "\n"), "positive whole number")
    expect.eq(yanked(), "")
  end)

  it("names what encloses the cursor's line", function()
    epicenter.run("where", {}, buf)
    wait(function()
      return #notices > 0
    end, 10000, "the where answer")
    expect.matches(notices[1], "handle_request")
  end)

  it("takes a file:line argument, as pasted off a stack trace", function()
    epicenter.run("where", { "app/server.lua:15" }, buf)
    wait(function()
      return #notices > 0
    end, 10000, "the where answer")
    expect.matches(notices[1], "M%.start")
  end)

  it("says what it could not read rather than guessing a line", function()
    epicenter.run("where", { "app/server.lua" }, buf)
    expect.matches(table.concat(notices, "\n"), "could not read")
  end)
end)

describe("context against a v1.0 server", function()
  local root, buf, notices, temp

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    -- Its OWN root: register_session overwrites whatever record a root holds,
    -- and clobbering the shared fixture's live server strands its process.
    temp = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(vim.fs.joinpath(temp, ".navgraph"), "p")
    local path = vim.fs.joinpath(temp, "only.lua")
    vim.fn.writefile({ "local M = {}", "return M" }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()

    local sent = {}
    require("epicenter.client").register_session(root or temp, {
      request = function(_, method)
        table.insert(sent, method)
        return { cancel = function() end }
      end,
      dropped_count = function()
        return 0
      end,
    }, { experimental = { navgraph = { protocolVersion = 1, methods = {} } } })
    root = temp
    _G.EPICENTER_SENT = sent

    notices = {}
    epicenter.notify = function(msg)
      table.insert(notices, msg)
    end
  end)

  after_each(function()
    require("epicenter.client").stop(temp)
    _G.EPICENTER_SENT = nil
  end)

  it("says the server is too old and sends nothing", function()
    epicenter.run("context", {}, buf)
    epicenter.run("where", {}, buf)
    expect.matches(table.concat(notices, "\n"), "protocol 1%.1")
    expect.eq(_G.EPICENTER_SENT, {}, "a v1.0 server must never be sent a v1.1 method")
  end)
end)
