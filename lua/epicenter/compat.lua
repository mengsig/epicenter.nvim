--- Where Neovim 0.10 and 0.11+ disagree, in one place.
---
--- 0.11 turned the LSP client's plain functions into methods and flattened
--- `vim.validate`'s signature. Calling either the new way on 0.10 does not
--- fail loudly - `client:stop()` passes the client itself as `force`, and
--- SIGTERM never reaches a server blocked on a read - so every call site goes
--- through here rather than branching on its own.
local M = {}

--- A session cannot change Neovim version, so this is resolved once.
M.HAS_011 = vim.fn.has("nvim-0.11") == 1

--- @param name string
--- @param value any
--- @param kind string
function M.validate(name, value, kind)
  if M.HAS_011 then
    vim.validate(name, value, kind)
  else
    vim.validate({ [name] = { value, kind } })
  end
end

--- Starts a language server. On 0.11+ `vim.lsp.start` reuses and attaches;
--- on 0.10 it has no `attach` option and silently attaches the CURRENT buffer,
--- so the lower-level `start_client` is used and the attach is explicit.
--- @param config table
--- @param bufnr integer|nil buffer to attach, or nil to attach nothing
--- @return integer|nil client_id
function M.lsp_start(config, bufnr)
  if M.HAS_011 then
    return vim.lsp.start(config, { bufnr = bufnr, attach = bufnr ~= nil })
  end
  local client_id = vim.lsp.start_client(config)
  if client_id and bufnr then
    vim.lsp.buf_attach_client(bufnr, client_id)
  end
  return client_id
end

--- @param client table
--- @return boolean sent, integer|nil request_id
function M.lsp_request(client, method, params, handler)
  if M.HAS_011 then
    return client:request(method, params, handler)
  end
  return client.request(method, params, handler)
end

function M.lsp_cancel(client, id)
  if M.HAS_011 then
    client:cancel_request(id)
  else
    client.cancel_request(id)
  end
end

--- Graceful stop. Never force: a server blocked on a synchronous read never
--- sees SIGTERM, and on 0.10 `client:stop()` would pass the client as `force`.
function M.lsp_stop(client)
  if M.HAS_011 then
    client:stop()
  else
    client.stop()
  end
end

function M.lsp_notify(client, method, params)
  if M.HAS_011 then
    return client:notify(method, params)
  end
  return client.notify(method, params)
end

--- @param bufnr? integer
function M.lsp_supports_method(client, method, bufnr)
  if M.HAS_011 then
    return client:supports_method(method, { bufnr = bufnr })
  end
  return client.supports_method(method, { bufnr = bufnr })
end

return M
