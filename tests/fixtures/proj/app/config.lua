local M = {}

function M.route(method, path)
  return method .. " " .. path
end

function M.load_config(path)
  return { path = path }
end

return M
