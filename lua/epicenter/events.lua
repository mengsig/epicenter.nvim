--- In-process pub/sub mirrored onto `User` autocmds, so both Lua callers and
--- `:autocmd User EpicenterIndexed` see the same events.
local M = {}

local compat = require("epicenter.compat")

M.INDEXED = "EpicenterIndexed"

local subscribers = {}
local next_id = 0

--- @param event string one of the M.* constants
--- @param fn fun(payload: table)
--- @return fun() unsubscribe
function M.on(event, fn)
  compat.validate("event", event, "string")
  compat.validate("fn", fn, "function")
  next_id = next_id + 1
  local id = next_id
  subscribers[event] = subscribers[event] or {}
  subscribers[event][id] = fn
  return function()
    if subscribers[event] then
      subscribers[event][id] = nil
    end
  end
end

--- Notifies in-process subscribers, then fires `User <event>` with `data`.
--- A failing subscriber is logged and skipped so one bad listener cannot
--- silence the rest; the failure is visible in `:Epicenter log`.
function M.emit(event, payload)
  compat.validate("event", event, "string")
  for _, fn in pairs(subscribers[event] or {}) do
    local ok, err = pcall(fn, payload)
    if not ok then
      require("epicenter.log").error("subscriber for %s failed: %s", event, err)
    end
  end
  vim.api.nvim_exec_autocmds("User", { pattern = event, data = payload, modeline = false })
end

--- Test seam: drops every subscriber.
function M.clear()
  subscribers = {}
end

return M
