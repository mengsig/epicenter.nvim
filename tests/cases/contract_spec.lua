--- Every request this plugin can build, checked against the vendored contract
--- (`tests/contract/`). The fake server enforces the same schema on the wire;
--- this spec proves the enforcement covers every feature, by driving each
--- command through a recording session and validating what it sent.
local client = require("epicenter.client")
local epicenter = require("epicenter")
local registry = require("epicenter.registry")
local schema = require("contract.schema")

--- Helpers the plugin exposes but no feature calls yet. Listed explicitly, so
--- the first feature that uses one has to take it off this list - and be
--- covered by the drive below.
local UNCALLED = {
  ["navgraph/neighbors"] = true,
  ["navgraph/routes"] = true,
  ["navgraph/events"] = true,
  ["navgraph/imports"] = true,
  ["navgraph/importers"] = true,
  -- v1.1 helpers whose panels land in the next wave.
  ["navgraph/types"] = true,
}

local function symbol(over)
  return vim.tbl_extend("force", {
    id = 1,
    name = "handle",
    qualified = "M.handle",
    kind = "fn",
    file = "app/server.lua",
    uri = "file:///proj/app/server.lua",
    line = 3,
    endLine = 9,
    sig = "function M.handle()",
    language = "lua",
    callers = 1,
    callees = 1,
    exported = true,
    test = false,
    contentHash = "0123456789abcdef",
  }, over or {})
end

local EMPTY_SUMMARY = {
  symbols = 0,
  files = 0,
  tests = 0,
  maxDepth = 0,
  truncated = false,
  byDepth = {},
  byFile = {},
}

local EMPTY_BLAST = { roots = {}, nodes = {}, edges = {}, summary = EMPTY_SUMMARY }

--- Just enough of a real answer for a feature to carry on to its next
--- request; each one is itself checked against the result schema below.
local ANSWERS = {
  ["navgraph/status"] = {
    root = "/proj",
    protocolVersion = 1,
    version = "0",
    files = 1,
    symbols = 1,
    edges = 0,
    languages = { lua = 1 },
    overlays = 0,
    indexedAt = "2026-01-01T00:00:00Z",
    lastIndexMs = 1,
    cache = false,
  },
  ["navgraph/symbolAt"] = {
    word = "handle",
    symbol = symbol(),
    enclosing = symbol(),
    candidates = {},
  },
  ["navgraph/search"] = { items = {}, total = 0 },
  ["navgraph/grep"] = { items = {}, total = 0, truncated = false },
  ["navgraph/blast"] = EMPTY_BLAST,
  ["navgraph/diff"] = { ref = "HEAD", blast = EMPTY_BLAST },
  ["navgraph/callers"] = {
    root = {
      symbol = symbol(),
      exact = true,
      lines = {},
      children = {},
      ext = {},
      recursion = false,
    },
  },
  ["navgraph/calls"] = {
    root = {
      symbol = symbol(),
      exact = true,
      lines = {},
      children = {},
      ext = {},
      recursion = false,
    },
  },
  ["navgraph/path"] = { path = {}, ambiguousFrom = {}, ambiguousTo = {} },
  ["navgraph/outline"] = { files = {} },
  ["navgraph/hot"] = { items = {} },
  ["navgraph/unused"] = { items = {} },
  ["navgraph/graph"] = {
    path = ".navgraph/graph-0.html",
    nodes = 0,
    nodesTotal = 0,
    truncated = false,
  },
}
ANSWERS["navgraph/rescan"] = ANSWERS["navgraph/status"]

--- v1.1: the standard LSP hierarchy methods. `data` is what lets a follow-up
--- request name the same definition the server resolved.
local function hierarchy_item()
  return {
    name = "handle",
    kind = 12,
    uri = "file:///proj/app/server.lua",
    range = {
      start = { line = 2, character = 0 },
      ["end"] = { line = 8, character = 0 },
    },
    selectionRange = {
      start = { line = 2, character = 0 },
      ["end"] = { line = 2, character = 6 },
    },
    data = { id = 1, qualified = "M.handle", file = "app/server.lua" },
  }
end

ANSWERS["textDocument/prepareCallHierarchy"] = { hierarchy_item() }
ANSWERS["callHierarchy/incomingCalls"] = {
  { from = hierarchy_item(), fromRanges = {} },
}
ANSWERS["callHierarchy/outgoingCalls"] = {
  { to = hierarchy_item(), fromRanges = {} },
}
ANSWERS["textDocument/prepareTypeHierarchy"] = { hierarchy_item() }
ANSWERS["typeHierarchy/supertypes"] = {}
ANSWERS["typeHierarchy/subtypes"] = {}
ANSWERS["textDocument/implementation"] = {}

ANSWERS["navgraph/context"] = {
  symbol = symbol(),
  definition = {
    text = "function M.handle() end",
    range = {
      start = { line = 2, character = 0 },
      ["end"] = { line = 8, character = 0 },
    },
  },
  signature = "function M.handle()",
  callers = {},
  callees = {},
  types = {},
  tests = {},
  truncated = false,
  tokensEstimate = 12,
}
ANSWERS["navgraph/impact"] = vim.tbl_extend("force", EMPTY_BLAST, {
  hunks = {},
  changeId = "deadbeefdeadbeef",
  truncated = false,
})
ANSWERS["navgraph/tests"] = {
  symbol = symbol(),
  tests = {},
  summary = { count = 0, maxDepth = 0 },
  truncated = false,
}
ANSWERS["navgraph/where"] = {
  enclosing = symbol(),
  breadcrumbs = { symbol() },
  file = "app/server.lua",
}

--- A session that records what a feature sent and answers from ANSWERS, so
--- chained requests (symbolAt -> blast) reach their second call.
local function recorder()
  local calls = {}
  return {
    calls = calls,
    request = function(_, method, params, cb, _opts)
      table.insert(calls, { method = method, params = vim.deepcopy(params) })
      local answer = ANSWERS[method]
      vim.schedule(function()
        if answer then
          cb(nil, vim.deepcopy(answer))
        else
          cb({ code = -32601, message = "no canned answer for " .. method }, nil)
        end
      end)
      return { cancel = function() end }
    end,
    dropped_count = function()
      return 0
    end,
  }
end

--- Types into a palette: grep asks nothing until there is a pattern.
local function typed(text)
  return function(handle)
    handle:query(text)
  end
end

--- Commands that reach the server. `install` downloads, `log` opens a file and
--- `restart` respawns a process - none of them issue a `navgraph/*` request.
--- @type { [1]: string, [2]: string[], [3]?: fun(handle: table) }[]
local DRIVEN = {
  { "status", {} },
  { "rescan", {} },
  { "search", {}, typed("handle") },
  { "grep", {}, typed("handle") },
  { "blast", {} },
  { "blast", { "M.handle" } },
  { "hover", {} },
  { "diff", {} },
  { "diff", { "origin/main" } },
  { "callers", {} },
  { "callees", {} },
  { "peek", {} },
  { "crumbs", {} },
  { "hierarchy", {} },
  { "hierarchy", { "outgoing" } },
  { "types", {} },
  { "context", {} },
  { "context", { "M.handle", "--budget", "500" } },
  { "where", {} },
  { "where", { "app/server.lua:4" } },
  { "tests", {} },
  { "impact", {} },
  { "review", {} },
  { "path", { "M.handle", "M.start" } },
  { "outline", {} },
  { "hot", {} },
  { "unused", {} },
  { "graph", {} },
}

describe("the request contract", function()
  it("has a schema for every method epicenter.client can send", function()
    for name, method in pairs(client.METHODS) do
      expect.truthy(
        schema.method(method) ~= nil,
        ("epicenter.client.%s sends %s, which has no contract schema"):format(name, method)
      )
    end
  end)

  it("answers this spec drives features with are themselves contract-shaped", function()
    for method, answer in pairs(ANSWERS) do
      expect.eq(schema.check_result(method, answer), nil, method)
    end
  end)

  it("refuses a param the contract does not name", function()
    expect.matches(
      schema.check_params("navgraph/outline", { uri = "file:///x" }) or "",
      'unknown param "uri"',
      "outline filters by a path substring, never by a uri"
    )
    expect.matches(
      schema.check_params("navgraph/callers", { symbol = "x", limit = 5 }) or "",
      'unknown param "limit"',
      "callers has no limit; the client caps the list"
    )
  end)

  it("refuses an ill-typed param and a missing Target", function()
    expect.matches(schema.check_params("navgraph/search", { query = 7 }) or "", "expected a string")
    expect.matches(
      schema.check_params("navgraph/blast", { depth = 2 }) or "",
      "needs a Target",
      "a blast with no target form must not reach the server"
    )
    expect.matches(
      schema.check_params("navgraph/blast", { symbol = "x", file = "y" }) or "",
      "one Target form only"
    )
    expect.matches(
      schema.check_params("navgraph/blast", { uri = "file:///x" }) or "",
      "uri and position go together"
    )
    expect.matches(
      schema.check_params("navgraph/search", { query = "x", tests = "sometimes" }) or "",
      "must be one of with, without, only"
    )
  end)
end)

describe("every feature builds contract-shaped requests", function()
  local session, buf, root, opened, ui_open

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()

    buf = vim.api.nvim_get_current_buf()
    root = require("epicenter.root").find(buf)
    session = recorder()
    -- A v1.1 handshake: without it every v1.1-gated feature would correctly
    -- refuse to send, and this spec would prove nothing about their requests.
    client.register_session(root, session, {
      callHierarchyProvider = true,
      typeHierarchyProvider = true,
      implementationProvider = true,
      experimental = {
        navgraph = {
          protocolVersion = 1,
          protocolMinor = 1,
          methods = {
            "navgraph/impact",
            "navgraph/tests",
            "navgraph/types",
            "navgraph/context",
            "navgraph/where",
          },
        },
      },
    })

    opened = {}
    ui_open = vim.ui.open
    vim.ui.open = function() end
  end)

  after_each(function()
    vim.ui.open = ui_open
    for _, handle in ipairs(opened) do
      pcall(function()
        (handle.close and handle or handle.win):close()
      end)
    end
    client.stop(root)
  end)

  --- Runs every command, then waits for the traffic to go quiet - a chained
  --- request (symbolAt -> blast) is sent from a scheduled callback, so the
  --- last call is not necessarily in flight when the last command returns.
  local function drive_all()
    for _, entry in ipairs(DRIVEN) do
      local handle = epicenter.run(entry[1], entry[2], buf)
      if type(handle) == "table" then
        table.insert(opened, handle)
        if entry[3] then
          entry[3](handle)
        end
      end
    end

    local quiet_since, count = vim.uv.hrtime(), #session.calls
    vim.wait(5000, function()
      if #session.calls ~= count then
        count, quiet_since = #session.calls, vim.uv.hrtime()
        return false
      end
      return (vim.uv.hrtime() - quiet_since) / 1e6 > 100
    end, 5)
  end

  it("sends nothing the contract does not define, from any command", function()
    drive_all()

    expect.truthy(#session.calls > 0, "no feature reached the server at all")
    for _, call in ipairs(session.calls) do
      expect.eq(
        schema.check_params(call.method, call.params),
        nil,
        ("%s params: %s"):format(call.method, vim.inspect(call.params))
      )
    end
  end)

  it("exercises every method a feature can reach", function()
    drive_all()

    local seen = {}
    for _, call in ipairs(session.calls) do
      seen[call.method] = true
    end

    local missing = {}
    for _, method in pairs(client.METHODS) do
      if not UNCALLED[method] and not seen[method] then
        table.insert(missing, method)
      end
    end
    table.sort(missing)
    expect.eq(missing, {}, "these methods were never sent by any command above")
  end)

  it("covers every ready subcommand, or names why not", function()
    -- `tour` is not driven here: it opens the OTHER commands on timers, and
    -- every one of them is already driven above.
    local skipped = { install = true, log = true, restart = true, tour = true }
    local driven = {}
    for _, entry in ipairs(DRIVEN) do
      driven[entry[1]] = true
    end
    for _, name in ipairs(registry.command_names()) do
      if registry.command(name).status == "ready" and not skipped[name] then
        expect.truthy(driven[name], name .. " is not driven by the contract spec")
      end
    end
  end)
end)
