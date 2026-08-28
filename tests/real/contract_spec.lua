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
