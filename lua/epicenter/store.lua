--- The little per-project state that must survive a restart: impact
--- approvals, palette frecency. One JSON file per (kind, root) under
--- `stdpath("state")`, so nothing this plugin remembers ever lands in the
--- project itself.
local M = {}

--- Overridden only by `M.set_root`.
local base = nil

local function dir_for(kind)
  return vim.fs.joinpath(base or vim.fn.stdpath("state"), "epicenter", kind)
end

--- Test seam: writes below `dir` instead of `stdpath("state")`, so a spec
--- never touches the user's own remembered state. `nil` restores the default.
function M.set_root(dir)
  base = dir
end

--- The file `kind` uses for `root`. Named by a hash of the root: a path is
--- not a filename, and two projects with the same basename are not one.
--- @return string
function M.path(kind, root)
  local slug = vim.fn.sha256(vim.fs.normalize(root)):sub(1, 16)
  return vim.fs.joinpath(dir_for(kind), slug .. ".json")
end

--- What was stored, or an empty table when nothing has been. A file that no
--- longer parses is reported to the log and treated as empty - the next
--- write replaces it - rather than raising into whatever asked.
--- @return table
function M.read(kind, root)
  local path = M.path(kind, root)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(decoded) ~= "table" then
    require("epicenter.log").warn("unreadable %s state at %s; starting fresh", kind, path)
    return {}
  end
  return decoded
end

--- @param value table
--- @return boolean ok, string|nil err
function M.write(kind, root, value)
  local path = M.path(kind, root)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return false, ("could not encode %s state: %s"):format(kind, tostring(encoded))
  end
  if vim.fn.writefile({ encoded }, path) ~= 0 then
    return false, ("could not write %s"):format(path)
  end
  return true, nil
end

return M
