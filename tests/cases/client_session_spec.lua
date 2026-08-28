local client = require("epicenter.client")

--- Records requests instead of sending them, so responses land on demand.
local function fake_rpc()
  local self = { sent = {}, cancelled = {}, ok = true }
  self.rpc = {
    request = function(method, params, handler)
      if not self.ok then
        return false, nil
      end
      table.insert(self.sent, { method = method, params = params, handler = handler })
      return true, #self.sent
    end,
    cancel = function(id)
      self.cancelled[id] = true
    end,
  }
  self.respond = function(id, err, result)
    self.sent[id].handler(err, result)
  end
  return self
end

describe("client session", function()
  it("passes the method and params through and delivers the response", function()
    local rpc = fake_rpc()
    local session = client.session(rpc.rpc)
    local seen = nil
    session:request("navgraph/search", { query = "a" }, function(err, result)
      seen = { err = err, result = result }
    end)
    expect.eq(rpc.sent[1].method, "navgraph/search")
    expect.eq(rpc.sent[1].params, { query = "a" })
    rpc.respond(1, nil, { total = 2 })
    expect.eq(seen, { err = nil, result = { total = 2 } })
  end)

  it("drops a stale response once a newer request is issued on the channel", function()
    local rpc = fake_rpc()
    local session = client.session(rpc.rpc)
    local delivered = {}
    session:request("navgraph/search", { query = "ha" }, function(_, result)
      table.insert(delivered, result)
    end, { channel = "search" })
    session:request("navgraph/search", { query = "han" }, function(_, result)
      table.insert(delivered, result)
    end, { channel = "search" })

    rpc.respond(2, nil, "newest")
    rpc.respond(1, nil, "stale")

    expect.eq(delivered, { "newest" }, "the superseded response never reaches the caller")
    expect.eq(session:dropped_count(), 1)
  end)

  it("keeps out-of-order responses on different channels", function()
    local rpc = fake_rpc()
    local session = client.session(rpc.rpc)
    local delivered = {}
    session:request("navgraph/search", {}, function(_, r)
      table.insert(delivered, r)
    end, { channel = "search" })
    session:request("navgraph/grep", {}, function(_, r)
      table.insert(delivered, r)
    end, { channel = "grep" })
    rpc.respond(2, nil, "grep")
    rpc.respond(1, nil, "search")
    expect.eq(delivered, { "grep", "search" })
    expect.eq(session:dropped_count(), 0)
  end)

  it("delivers both responses when no channel is given", function()
    local rpc = fake_rpc()
    local session = client.session(rpc.rpc)
    local count = 0
    for _ = 1, 2 do
      session:request("navgraph/status", {}, function()
        count = count + 1
      end)
    end
    rpc.respond(2, nil, {})
    rpc.respond(1, nil, {})
    expect.eq(count, 2)
  end)

  it("cancel reaches the transport and silences the callback", function()
    local rpc = fake_rpc()
    local session = client.session(rpc.rpc)
    local calls = 0
    local handle = session:request("navgraph/blast", {}, function()
      calls = calls + 1
    end)
    handle.cancel()
    expect.eq(rpc.cancelled[1], true)
    rpc.respond(1, nil, {})
    expect.eq(calls, 0)
    handle.cancel()
    expect.eq(calls, 0, "cancelling twice is harmless")
  end)

  it("reports a send failure to the caller instead of hanging", function()
    local rpc = fake_rpc()
    rpc.ok = false
    local session = client.session(rpc.rpc)
    local err = nil
    session:request("navgraph/status", {}, function(e)
      err = e
    end)
    expect.truthy(err ~= nil, "a failed send must surface, not vanish")
    expect.matches(err.message, "could not send")
  end)

  it("errors when no server runs for the buffer's root", function()
    local err = nil
    client.request("navgraph/status", {}, function(e)
      err = e
    end, { root = "/nonexistent/root/for/spec" })
    expect.matches(err.message, "not running")
  end)

  it("never falls through to the buffer's root when an explicit root has no server", function()
    -- A caller naming a root with no server must get -32002, never a
    -- different project's answer just because the current buffer has one.
    local root_mod = require("epicenter.root")
    local original_find = root_mod.find
    root_mod.find = function()
      return "/tmp/epicenter-spec-buffer-root"
    end

    local rpc = fake_rpc()
    client.register_session("/tmp/epicenter-spec-buffer-root", client.session(rpc.rpc))

    local err, result = nil, nil
    client.request("navgraph/status", {}, function(e, r)
      err, result = e, r
    end, { root = "/tmp/epicenter-spec-explicit-root-with-no-server" })

    root_mod.find = original_find

    expect.eq(#rpc.sent, 0, "the wrong root's session must never receive the request")
    expect.eq(result, nil, "no answer must come back when the named root has no server")
    expect.truthy(err ~= nil)
    expect.matches(err.message, "not running")
  end)
end)

describe("client supported files", function()
  it("recognises the extensions navgraph indexes", function()
    for _, path in ipairs({ "a.lua", "b.py", "c.ZIG", "d/e.tsx", "f.rs" }) do
      expect.eq(client.is_supported(path), true, path)
    end
  end)

  it("ignores everything else", function()
    for _, path in ipairs({ "README.md", "Makefile", "a.txt", "noextension" }) do
      expect.eq(client.is_supported(path), false, path)
    end
  end)
end)
