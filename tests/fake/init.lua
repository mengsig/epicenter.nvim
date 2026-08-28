--- Handler registry for the fake navgraph server.
---
--- Every `tests/fake/<area>.lua` returns a table of `["navgraph/method"] =
--- function(ctx, params)` handlers; they are merged here. Adding coverage for
--- a new area is one new file - no edit to an existing one. Two areas claiming
--- the same method is a hard error, so a collision is never silent.
local M = {}

local function area_files()
  local this = debug.getinfo(1, "S").source:sub(2)
  local dir = vim.fs.dirname(this)
  local files = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.lua$") and name ~= "init.lua" then
      table.insert(files, (name:gsub("%.lua$", "")))
    end
  end
  table.sort(files)
  return files
end

--- @return table<string, fun(ctx: table, params: table): any>
function M.handlers()
  local merged, owner = {}, {}
  for _, area in ipairs(area_files()) do
    local handlers = require("fake." .. area)
    for method, fn in pairs(handlers) do
      if owner[method] then
        error(("fake server: %s handled by both %q and %q"):format(method, owner[method], area))
      end
      owner[method] = area
      merged[method] = fn
    end
  end
  return merged
end

return M
