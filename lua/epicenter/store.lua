--- The little per-project state that must survive a restart: impact
--- approvals, palette frecency. One JSON file per (kind, root) under
--- `stdpath("state")`, so nothing this plugin remembers ever lands in the
--- project itself.
local M = {}

--- Bumped when the on-disk shape changes. A file that does not carry exactly
--- this version is discarded rather than mis-read as the current shape.
M.VERSION = 1

--- Overridden only by `M.set_root`.
local base = nil

--- Disambiguates temp files from more than one `write` call landing in the
--- same instance before the first has renamed (M2: the pid alone is unique
--- per Neovim instance, but not per call).
local temp_seq = 0

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
  -- `root.normalize`, never `vim.fs.normalize` alone: a project reached
  -- through a symlink is one project, not two state files.
  local slug = vim.fn.sha256(require("epicenter.root").normalize(root)):sub(1, 16)
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
  if decoded.version ~= M.VERSION or type(decoded.data) ~= "table" then
    require("epicenter.log").warn(
      "%s state at %s is not version %d; starting fresh",
      kind,
      path,
      M.VERSION
    )
    return {}
  end
  return decoded.data
end

--- @param value table
--- @return boolean ok, string|nil err
function M.write(kind, root, value)
  local path = M.path(kind, root)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok, encoded = pcall(vim.json.encode, { version = M.VERSION, data = value })
  if not ok then
    return false, ("could not encode %s state: %s"):format(kind, tostring(encoded))
  end
  -- Written beside the real file and renamed over it. Writing in place would
  -- leave a truncated file after a crash mid-write, and `read` reports that
  -- as "nothing was ever stored" - every approval in the project, gone.
  -- The name is per-writer: a name shared across instances (M2) let one
  -- instance's write silently land under another's "successful" rename -
  -- the loser reported ok=true while what it published was never its own data.
  temp_seq = temp_seq + 1
  local temp = ("%s.%d.%d.tmp"):format(path, vim.fn.getpid(), temp_seq)
  if vim.fn.writefile({ encoded }, temp) ~= 0 then
    return false, ("could not write %s"):format(temp)
  end
  local renamed, err = (vim.uv or vim.loop).fs_rename(temp, path)
  if not renamed then
    vim.fn.delete(temp)
    return false, ("could not replace %s: %s"):format(path, err or "rename failed")
  end
  return true, nil
end

return M
