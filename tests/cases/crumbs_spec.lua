--- Breadcrumbs and the fan-in/out statusline component: what they render, and
--- what they cost. Both are read on every redraw, so the cost contract is the
--- interesting half - at most one request per line the cursor reaches, and
--- none at all with no server for the buffer's project.
local support = require("support")
local epicenter = require("epicenter")
local crumbs = require("epicenter.features.crumbs")

local function open_fixture(root, relative, line)
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  return vim.api.nvim_get_current_buf()
end

--- Counts every `navgraph/*` the plugin sends, at the transport seam.
local function watch_requests(root)
  local session = assert(require("epicenter.client").session_for_root(root))
  local base = session.rpc.request
  local sent = {}
  session.rpc.request = function(method, params, handler)
    table.insert(sent, method)
    return base(method, params, handler)
  end
  return {
    sent = function()
      return sent
    end,
    reset = function()
      sent = {}
    end,
    restore = function()
      session.rpc.request = base
    end,
  }
end

local function settle(ms)
  vim.wait(ms or 400, function()
    return false
  end, 10)
end

describe("the crumbs shapes", function()
  local function symbol(over)
    return vim.tbl_extend("force", { name = "handle", callers = 3, callees = 2 }, over or {})
  end

  it("reads the chain outermost first when the server sends one", function()
    expect.eq(
      crumbs.chain_of({ breadcrumbs = { symbol({ name = "M" }), symbol({ name = "handle" }) } }),
      { "M", "handle" }
    )
  end)

  it("falls back to the enclosing definition against a v1.0 server", function()
    expect.eq(crumbs.chain_of({ enclosing = symbol({ name = "start" }) }), { "start" })
    expect.eq(crumbs.chain_of({ breadcrumbs = {}, enclosing = symbol() }), { "handle" })
  end)

  it("has nothing to say where the cursor is inside nothing", function()
    expect.eq(crumbs.chain_of({ symbol = vim.NIL, enclosing = vim.NIL }), {})
    expect.eq(crumbs.chain_of(nil), {})
  end)

  it("takes the fan from the symbol, else the innermost crumb, else enclosing", function()
    expect.eq(crumbs.fan_of({ symbol = symbol() }), { ["in"] = 3, out = 2 })
    expect.eq(
      crumbs.fan_of({
        symbol = vim.NIL,
        enclosing = vim.NIL,
        breadcrumbs = { symbol({ callers = 1 }), symbol({ callers = 7, callees = 0 }) },
      }),
      { ["in"] = 7, out = 0 },
      "off an identifier only the chain survives, and its innermost is the one"
    )
    expect.eq(
      crumbs.fan_of({ symbol = vim.NIL, enclosing = symbol({ callers = 5, callees = 1 }) }),
      { ["in"] = 5, out = 1 }
    )
    expect.eq(crumbs.fan_of({ symbol = vim.NIL, enclosing = vim.NIL }), nil)
  end)

  it("renders both directions, and nothing at all without a symbol", function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
    expect.eq(crumbs.fan_text({ ["in"] = 12, out = 4 }), "! 12 <- · 4 ->")
    expect.eq(crumbs.fan_text(nil), "")
  end)
end)

describe("crumbs against the fake navgraph server", function()
  local root, buf, requests

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    buf = open_fixture(root, "app/server.lua", 10)
    support.attach(root, buf)
    requests = watch_requests(root)
  end)

  after_each(function()
    requests.restore()
    crumbs.reset()
    require("epicenter.events").clear()
  end)

  it("names the definition the cursor is inside", function()
    expect.eq(epicenter.breadcrumbs(buf), "", "empty until the first answer lands")
    wait(function()
      return epicenter.breadcrumbs(buf) ~= ""
    end, 10000, "the breadcrumbs")
    expect.matches(epicenter.breadcrumbs(buf), "handle_request")
  end)

  it("reports the fan of that definition", function()
    wait(function()
      return epicenter.statusline(buf) ~= ""
    end, 10000, "the statusline fragment")
    expect.matches(epicenter.statusline(buf), "^! %d+ <%-")
  end)

  it("costs at most one request per line the cursor reaches, however often it is read", function()
    wait(function()
      return epicenter.breadcrumbs(buf) ~= ""
    end, 10000, "the first answer")
    settle()
    requests.reset()

    -- A winbar is re-read on every redraw; that must never be a round trip.
    for _ = 1, 40 do
      epicenter.breadcrumbs(buf)
      epicenter.statusline(buf)
    end
    settle()
    expect.eq(requests.sent(), {}, "reading the cache must not talk to the server")

    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    for _ = 1, 40 do
      epicenter.breadcrumbs(buf)
    end
    wait(function()
      return #requests.sent() > 0
    end, 5000, "the new line's request")
    settle()
    expect.eq(requests.sent(), { "navgraph/symbolAt" }, "one line change, one request")
  end)

  it("costs nothing to move along a line", function()
    wait(function()
      return epicenter.breadcrumbs(buf) ~= ""
    end, 10000, "the first answer")
    settle()
    requests.reset()

    for column = 0, 6 do
      vim.api.nvim_win_set_cursor(0, { 10, column })
      epicenter.breadcrumbs(buf)
    end
    settle()
    expect.eq(requests.sent(), {}, "the chain is a property of the line, not the column")
  end)
end)

describe("crumbs with no server for the project", function()
  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
  end)

  after_each(function()
    crumbs.reset()
  end)

  it("is empty and silent rather than an error", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local function x() end" })
    vim.api.nvim_set_current_buf(buf)

    expect.eq(epicenter.breadcrumbs(buf), "")
    expect.eq(epicenter.statusline(buf), "")
    vim.wait(300, function()
      return false
    end, 10)
    expect.eq(epicenter.breadcrumbs(buf), "")
  end)

  it("is empty for a buffer that is not a file at all", function()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(scratch)
    expect.eq(epicenter.breadcrumbs(scratch), "")
    expect.eq(epicenter.statusline(scratch), "")
  end)
end)

describe("the opt-in winbar", function()
  local root, buf

  before_each(function()
    require("epicenter.config").reset()
    root = root or support.start_fake()
    buf = open_fixture(root, "app/config.lua", 4)
  end)

  after_each(function()
    crumbs.reset()
    require("epicenter.config").reset()
    epicenter.setup({ crumbs = { winbar = false }, lsp = { auto_start = false } })
  end)

  it("installs nothing by default", function()
    epicenter.setup({ lsp = { auto_start = false } })
    expect.eq(vim.wo[vim.api.nvim_get_current_win()].winbar, "")
  end)

  it("installs on the current code window when opted in", function()
    epicenter.setup({ crumbs = { winbar = true }, lsp = { auto_start = false } })
    expect.matches(vim.wo[vim.api.nvim_get_current_win()].winbar, "breadcrumbs")
  end)

  it("never overwrites a winbar the user set", function()
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].winbar = "mine"
    epicenter.setup({ crumbs = { winbar = true }, lsp = { auto_start = false } })
    expect.eq(vim.wo[win].winbar, "mine")
    vim.wo[win].winbar = ""
  end)

  it("takes its own winbar back down when the option is turned off", function()
    local win = vim.api.nvim_get_current_win()
    epicenter.setup({ crumbs = { winbar = true }, lsp = { auto_start = false } })
    expect.matches(vim.wo[win].winbar, "breadcrumbs")

    require("epicenter.config").reset()
    epicenter.setup({ crumbs = { winbar = false }, lsp = { auto_start = false } })
    expect.eq(vim.wo[win].winbar, "")
  end)

  it("toggles in one window from :Epicenter crumbs", function()
    local win = vim.api.nvim_get_current_win()
    epicenter.setup({ lsp = { auto_start = false } })
    epicenter.run("crumbs", {}, buf)
    expect.matches(vim.wo[win].winbar, "breadcrumbs")
    epicenter.run("crumbs", {}, buf)
    expect.eq(vim.wo[win].winbar, "")
  end)
end)
