--- The one capability this plugin declines, proven against the real server.
---
--- navgraph opens `window/workDoneProgress/create` with a STRING id and then
--- answers the client's reply to it as if that reply were a fresh request;
--- Neovim's client rejects the resulting `{ id = "navgraph-progress", error }`
--- as a response id it never issued and raises in the read loop. Nothing here
--- consumes `$/progress`, so the plugin declines it - and it has to say so,
--- because Neovim's own default capabilities ask for it.
local client = require("epicenter.client")
local support = require("support")

--- Runs one initialize/initialized exchange over a pipe and returns every
--- frame the server wrote before stdin EOF shut it down.
--- @return table[] messages
local function exchange(capabilities)
  local root = support.real_root()
  local frames = {}
  local function frame(message)
    local body = vim.json.encode(message)
    table.insert(frames, ("Content-Length: %d\r\n\r\n%s"):format(#body, body))
  end
  frame({
    jsonrpc = "2.0",
    id = 1,
    method = "initialize",
    params = { rootUri = vim.uri_from_fname(root), capabilities = capabilities },
  })
  frame({ jsonrpc = "2.0", method = "initialized", params = vim.empty_dict() })

  local done =
    vim.system(support.real_cmd(root), { stdin = table.concat(frames), text = true }):wait(60000)
  assert(done.code == 0, "navgraph exited " .. tostring(done.code) .. ": " .. tostring(done.stderr))

  local messages = {}
  for length, body in (done.stdout or ""):gmatch("Content%-Length:%s*(%d+)\r?\n\r?\n()") do
    local text = done.stdout:sub(body, body + tonumber(length) - 1)
    local ok, decoded = pcall(vim.json.decode, text)
    if ok then
      table.insert(messages, decoded)
    end
  end
  return messages
end

local function methods_of(messages)
  return vim.tbl_map(function(message)
    return message.method or ("response:" .. tostring(message.id))
  end, messages)
end

describe("real navgraph: work-done progress", function()
  it("sends workDoneProgress/create when a client advertises the capability", function()
    local methods = methods_of(exchange({ window = { workDoneProgress = true } }))
    expect.truthy(
      vim.tbl_contains(methods, "window/workDoneProgress/create"),
      "expected the progress handshake, got " .. vim.inspect(methods)
    )
  end)

  it("stays silent under the capabilities this plugin actually sends", function()
    local methods = methods_of(exchange(client.capabilities()))
    expect.falsy(
      vim.tbl_contains(methods, "window/workDoneProgress/create"),
      "epicenter declines workDoneProgress, so the handshake must not start: "
        .. vim.inspect(methods)
    )
    expect.truthy(
      vim.tbl_contains(methods, "navgraph/indexed"),
      "the index notification still arrives"
    )
  end)

  it("overrides a Neovim default that would otherwise ask for it", function()
    expect.eq(
      vim.lsp.protocol.make_client_capabilities().window.workDoneProgress,
      true,
      "if Neovim ever stops advertising this, the override below is dead weight"
    )
    expect.eq(client.capabilities().window.workDoneProgress, false)
  end)
end)
