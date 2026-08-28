--- The vendored contract against the server that defines it: every
--- `navgraph/*` method, answered by the real binary, checked field by field.
--- The fake lane proves the plugin matches the schema; this proves the schema
--- matches NavGraph.
local client = require("epicenter.client")
local events = require("epicenter.events")
local schema = require("contract.schema")
local support = require("support")

--- One request per method, with params the fixture tree can actually answer.
local function requests(root)
  local uri = vim.uri_from_fname(vim.fs.joinpath(root, "py_fastapi/app/services/user_service.py"))
  return {
    { "navgraph/status", {} },
    { "navgraph/symbolAt", { uri = uri, position = { line = 10, character = 8 } } },
    { "navgraph/search", { query = "user", limit = 10 } },
    { "navgraph/search", { query = "normalize_email", refs = true, limit = 5 } },
    { "navgraph/grep", { pattern = "def ", limit = 10 } },
    { "navgraph/blast", { symbol = "UserService.fetch", depth = 2, direction = "callers" } },
    { "navgraph/blast", { file = "py_fastapi/app/models.py", depth = 1 } },
    { "navgraph/callers", { symbol = "UserService.fetch", depth = 2 } },
    { "navgraph/calls", { symbol = "OrderService.place", depth = 2 } },
    { "navgraph/neighbors", { symbol = "UserService.fetch" } },
    { "navgraph/path", { from = "get_user", to = "UserService._query" } },
    { "navgraph/outline", { path = "py_fastapi/app/routes" } },
    { "navgraph/hot", { limit = 10 } },
    { "navgraph/unused", { limit = 10 } },
    { "navgraph/diff", { ref = "HEAD" } },
    { "navgraph/routes", { limit = 10 } },
    { "navgraph/events", { limit = 10 } },
    { "navgraph/imports", { path = "py_fastapi", limit = 10 } },
    { "navgraph/importers", { path = "py_fastapi/app/models.py" } },
    { "navgraph/graph", { path = "lua_game" } },
    { "navgraph/rescan", { full = false } },
  }
end

--- v1.1: one entry per method the addendum adds. `params` is built from the
--- live root, and a follow-up that needs an item the server itself resolved
--- asks for it first. Each runs as its own case, so a build that implements
--- some of the addendum and not the rest reports exactly which.
local V11 = {}

local function service_uri(root)
  return vim.uri_from_fname(vim.fs.joinpath(root, "py_fastapi/app/services/user_service.py"))
end

--- `UserService.fetch`, on its own definition line.
local function fetch_position()
  return { line = 10, character = 8 }
end

--- `class UserService:` - a type hierarchy needs a TYPE under the cursor,
--- which a method is not.
local function type_position()
  return { line = 7, character = 6 }
end

local function v11(method, params)
  table.insert(V11, { method = method, params = params })
end

v11("navgraph/tests", function()
  return { symbol = "UserService.fetch" }
end)
v11("navgraph/types", function()
  return { symbol = "UserService" }
end)
v11("navgraph/impact", function()
  return { depth = 1 }
end)
v11("navgraph/context", function()
  return { symbol = "UserService.fetch", budget = 800 }
end)
v11("navgraph/where", function(root)
  return { uri = service_uri(root), line = 12 }
end)

--- Each prepare asks at the position its own hierarchy needs.
local PREPARE_POSITION = {
  ["textDocument/prepareCallHierarchy"] = fetch_position,
  ["textDocument/prepareTypeHierarchy"] = type_position,
}

for prepare, position in pairs(PREPARE_POSITION) do
  v11(prepare, function(root)
    return { textDocument = { uri = service_uri(root) }, position = position() }
  end)
end
v11("textDocument/implementation", function(root)
  return { textDocument = { uri = service_uri(root) }, position = type_position() }
end)

--- The item a follow-up names is whatever the prepare resolved: building one
--- by hand would test the client's imagination, not the server.
local function prepared_item(root, prepare)
  local err, items = support.request(root, prepare, {
    textDocument = { uri = service_uri(root) },
    position = PREPARE_POSITION[prepare](),
  }, 30000)
  assert(not err, prepare .. " failed: " .. vim.inspect(err))
  local first = items and items[1]
  if not first then
    require("harness").skip(prepare .. " resolved nothing at the fixture position")
  end
  return { item = first }
end

for _, entry in ipairs({
  { "callHierarchy/incomingCalls", "textDocument/prepareCallHierarchy" },
  { "callHierarchy/outgoingCalls", "textDocument/prepareCallHierarchy" },
  { "typeHierarchy/supertypes", "textDocument/prepareTypeHierarchy" },
  { "typeHierarchy/subtypes", "textDocument/prepareTypeHierarchy" },
}) do
  v11(entry[1], function(root)
    return prepared_item(root, entry[2])
  end)
end

describe("real navgraph: the vendored contract", function()
  local root

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ lsp = { auto_start = false } })
    root = root or support.start_real()
  end)

  after_each(function()
    events.clear()
  end)

  it("covers every method epicenter.client can send", function()
    local asked = {}
    for _, entry in ipairs(requests(root)) do
      asked[entry[1]] = true
    end
    for _, entry in ipairs(V11) do
      asked[entry.method] = true
    end
    local missing = {}
    for _, method in pairs(client.METHODS) do
      if not asked[method] then
        table.insert(missing, method)
      end
    end
    table.sort(missing)
    expect.eq(missing, {}, "these methods are never asked of the real server")
  end)

  it("answers every method in the shape the schema promises", function()
    for _, entry in ipairs(requests(root)) do
      local method, params = entry[1], entry[2]
      -- What we are about to send must itself be contract-shaped.
      expect.eq(schema.check_params(method, params), nil, method .. " params")

      local err, result = support.request(root, method, params, 30000)
      expect.eq(err, nil, method .. " failed: " .. vim.inspect(err))
      expect.eq(
        schema.check_result(method, result),
        nil,
        method .. " result: " .. vim.inspect(result, { depth = 2 })
      )
    end
  end)

  for _, entry in ipairs(V11) do
    it(("answers %s in the shape the schema promises"):format(entry.method), function()
      support.require_method(root, entry.method, "the v1.1 contract")
      local params = entry.params(root)
      expect.eq(schema.check_params(entry.method, params), nil, entry.method .. " params")

      local err, result = support.request(root, entry.method, params, 30000)
      expect.eq(err, nil, entry.method .. " failed: " .. vim.inspect(err))
      expect.eq(
        schema.check_result(entry.method, result),
        nil,
        entry.method .. " result: " .. vim.inspect(result, { depth = 2 })
      )
    end)
  end

  it("emits navgraph/indexed in the shape the schema promises", function()
    local seen = nil
    events.on(events.INDEXED, function(payload)
      seen = payload
    end)
    support.request(root, "navgraph/rescan", { full = false }, 30000)
    wait(function()
      return seen ~= nil
    end, 20000, "navgraph/indexed")
    expect.eq(schema.check_indexed(seen), nil, vim.inspect(seen))
  end)
end)
