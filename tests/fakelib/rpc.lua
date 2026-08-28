--- LSP stdio framing for the fake server. Blocking reads on stdin: the fake
--- runs as its own `nvim --headless -l` process and never needs an event loop.
local M = {}

--- Reads one framed message body. Returns nil at EOF.
--- @return string|nil body
function M.read_body(input)
  local length = nil
  while true do
    local line = input:read("l")
    if line == nil then
      return nil
    end
    line = line:gsub("\r$", "")
    if line == "" then
      break
    end
    local n = line:match("^Content%-Length:%s*(%d+)$")
    if n then
      length = tonumber(n)
    end
  end
  if not length then
    return nil
  end
  return input:read(length)
end

function M.write(output, message)
  local body = vim.json.encode(message)
  output:write(("Content-Length: %d\r\n\r\n%s"):format(#body, body))
  output:flush()
end

function M.respond(output, id, result)
  M.write(output, { jsonrpc = "2.0", id = id, result = result == nil and vim.NIL or result })
end

function M.respond_error(output, id, code, message, data)
  M.write(output, {
    jsonrpc = "2.0",
    id = id,
    error = { code = code, message = message, data = data },
  })
end

function M.notify(output, method, params)
  M.write(output, { jsonrpc = "2.0", method = method, params = params })
end

return M
