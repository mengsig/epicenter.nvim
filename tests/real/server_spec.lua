--- The real binary answering the server-level contract: what it reports about
--- the index, how it reindexes, and how it refuses.
local client = require("epicenter.client")
local events = require("epicenter.events")
local support = require("support")

describe("real navgraph: the server contract", function()
  local root

  before_each(function()
    require("epicenter.config").reset()
    -- Every attach in this lane is explicit, so another navgraph on $PATH can
    -- never race the fixture and be adopted instead.
    require("epicenter.config").setup({ lsp = { auto_start = false } })
    root = root or support.start_real()
  end)

  after_each(function()
    events.clear()
  end)

  it("negotiates protocol version 1 over the real fixture tree", function()
    local err, status = support.request(root, "navgraph/status", {})
    expect.eq(err, nil)
    expect.eq(status.protocolVersion, 1)
    expect.eq(status.root, root)
    expect.truthy(status.files >= 30, "the fixture tree indexes every source file")
    expect.truthy(status.symbols > 100, "got " .. tostring(status.symbols) .. " symbols")
    expect.truthy(status.edges > 0, "a real index resolves call edges")
    expect.matches(status.indexedAt, "^%d%d%d%d%-%d%d%-%d%d")
  end)

  it("indexes all three fixture languages", function()
    local _, status = support.request(root, "navgraph/status", {})
    for _, lang in ipairs({ "py", "go", "lua" }) do
      expect.truthy(
        (status.languages or {})[lang] ~= nil,
        "navgraph/status.languages has no " .. lang .. ": " .. vim.inspect(status.languages)
      )
    end
  end)

  it("emits navgraph/indexed on a rescan, and the client republishes it", function()
    local seen = nil
    events.on(events.INDEXED, function(payload)
      seen = payload
    end)
    local err = support.request(root, "navgraph/rescan", { full = false }, 30000)
    expect.eq(err, nil)
    wait(function()
      return seen ~= nil
    end, 15000, "navgraph/indexed notification")
    expect.eq(seen.reason, "rescan")
    expect.truthy(seen.symbols > 0)
  end)

  it("answers an unimplemented method with -32601, not an empty result", function()
    local err = support.request(root, "navgraph/doesnotexist", {})
    expect.truthy(err ~= nil, "an unknown method must be an error")
    expect.eq(err.code, -32601)
  end)

  it("resolves the symbol under a cursor position", function()
    local uri = vim.uri_from_fname(vim.fs.joinpath(root, "py_fastapi/app/services/user_service.py"))
    local err, result = support.request(root, "navgraph/symbolAt", {
      uri = uri,
      position = { line = 10, character = 8 },
    })
    expect.eq(err, nil)
    expect.eq(result.word, "fetch")
    expect.eq(result.symbol.qualified, "UserService.fetch")
    expect.eq(result.symbol.line, 11, "Symbol.line is 1-based, the position was 0-based")
  end)

  it("reports the same protocol version through :checkhealth's accessor", function()
    expect.eq(client.info(root).protocol_version, 1)
  end)
end)
