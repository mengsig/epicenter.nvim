local config = require("app.config")

local M = {}

local function log_request(method, path)
  return method .. path
end

function M.handle_request(method, path)
  log_request(method, path)
  return config.route(method, path)
end

function M.start(port)
  M.handle_request("GET", "/")
  M.handle_request("POST", "/items")
  return port
end

return M
