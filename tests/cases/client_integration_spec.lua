local support = require("support")
local client = require("epicenter.client")
local events = require("epicenter.events")

describe("client against the fake navgraph server", function()
  local root

  before_each(function()
    require("epicenter.config").reset()
    if not root then
      root = support.start_fake()
    end
  end)

  after_each(function()
    events.clear()
  end)

  it("negotiates protocol version 1 and advertises its navgraph methods", function()
    local err, status = support.request(root, "navgraph/status", {})
    expect.eq(err, nil)
    expect.eq(status.protocolVersion, 1)
    expect.eq(status.files, 3)
    expect.truthy(status.symbols > 0)
    expect.matches(status.indexedAt, "^%d%d%d%d%-%d%d%-%d%d")
  end)

  it("answers a search with ranked items and match indices", function()
    local err, result = support.request(root, "navgraph/search", { query = "handle_request" })
    expect.eq(err, nil)
    local first = result.items[1]
    expect.eq(first.symbol.qualified, "M.handle_request")
    expect.eq(first.symbol.file, "app/server.lua")
    expect.truthy(#first.matches > 0)
    expect.matches(first.symbol.uri, "^file://")
  end)

  it("answers refs:true with use sites, not the identical definition list", function()
    local err, defs = support.request(root, "navgraph/search", { query = "log_request" })
    expect.eq(err, nil)
    local err2, refs =
      support.request(root, "navgraph/search", { query = "log_request", refs = true })
    expect.eq(err2, nil)
    expect.ne(
      defs.items[1].symbol.qualified,
      refs.items[1].symbol.qualified,
      "refs mode must show a use site's enclosing definition, not the same definition list"
    )
    expect.truthy(refs.items[1].lines ~= nil, "refs items must carry the use-site line numbers")
  end)

  it("answers a grep over the same sources", function()
    local err, result = support.request(root, "navgraph/grep", { pattern = "log_request" })
    expect.eq(err, nil)
    expect.truthy(result.total >= 2)
    expect.eq(result.items[1].file, "app/server.lua")
  end)

  it("resolves the symbol under a position", function()
    local uri = vim.uri_from_fname(vim.fs.joinpath(root, "app/server.lua"))
    local err, result = support.request(root, "navgraph/symbolAt", {
      uri = uri,
      position = { line = 8, character = 13 },
    })
    expect.eq(err, nil)
    expect.eq(result.word, "handle_request")
    expect.eq(result.symbol.qualified, "M.handle_request")
  end)

  it("returns -32601 for a method it does not implement", function()
    local err = support.request(root, "navgraph/doesnotexist", {})
    expect.truthy(err ~= nil, "an unknown method must be an error, not an empty result")
    expect.eq(err.code, -32601)
  end)

  it("emits EpicenterIndexed when the server reindexes", function()
    local seen = nil
    events.on(events.INDEXED, function(payload)
      seen = payload
    end)
    support.request(root, "navgraph/rescan", {})
    wait(function()
      return seen ~= nil
    end, 5000, "navgraph/indexed notification")
    expect.eq(seen.reason, "rescan")
    expect.truthy(seen.symbols > 0)
  end)

  it("cancels an in-flight request without delivering it", function()
    local calls = 0
    local handle = client.request("navgraph/search", { query = "handle" }, function()
      calls = calls + 1
    end, { root = root })
    handle.cancel()
    vim.wait(300)
    expect.eq(calls, 0)
  end)

  it("reuses one server per root", function()
    local id = client.start({ root = root, cmd = support.fake_cmd(root) })
    local again = client.start({ root = root, cmd = support.fake_cmd(root) })
    expect.eq(id, again)
    expect.eq(#client.roots(), 1)
  end)

  it("re-attaches every buffer that was open before a crash", function()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/config.lua")))
    local buf1 = vim.api.nvim_get_current_buf()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    local buf2 = vim.api.nvim_get_current_buf()
    expect.ne(buf1, buf2, "the two fixture files must land in two different buffers")

    local id = client.start({ root = root, cmd = support.fake_cmd(root), bufnr = buf1 })
    client.start({ root = root, bufnr = buf2 })
    wait(function()
      return #vim.lsp.get_clients({ bufnr = buf1 }) > 0
        and #vim.lsp.get_clients({ bufnr = buf2 }) > 0
    end, 5000, "both buffers attached before the crash")

    -- Crash it: exit without shutdown first, exactly what a killed process
    -- leaves behind (the fake reports exit 1 in that case).
    vim.lsp.get_client_by_id(id):notify("exit", {})

    wait(function()
      local info = client.info(root)
      return info.client_id ~= nil and info.client_id ~= id
    end, 10000, "navgraph to restart after the crash")

    wait(function()
      return #vim.lsp.get_clients({ bufnr = buf1 }) > 0
        and #vim.lsp.get_clients({ bufnr = buf2 }) > 0
    end, 5000, "both buffers re-attached to the restarted server")
  end)

  it("restarts with the caller's cmd instead of silently keeping the running one", function()
    local original_cmd = support.fake_cmd(root)
    local different_cmd = vim.deepcopy(original_cmd)
    table.insert(different_cmd, "--tag=different")

    local id = client.start({ root = root, cmd = original_cmd })
    local buf = vim.api.nvim_get_current_buf()

    local new_id = client.start({ root = root, cmd = different_cmd, bufnr = buf })
    expect.ne(new_id, id, "a cmd mismatch must restart the server, not silently reuse it")

    wait(function()
      local c = vim.lsp.get_client_by_id(new_id)
      return c ~= nil and vim.deep_equal(c.config.cmd, different_cmd)
    end, 10000, "the new client to run the cmd the caller asked for")

    wait(function()
      return #vim.lsp.get_clients({ bufnr = buf }) > 0
    end, 5000, "the buffer to be attached to the restarted client")
  end)
end)
