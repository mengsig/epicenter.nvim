--- Workspace-root detection: one navgraph server per root.
local M = {}

local uv = vim.uv or vim.loop

--- Walks upward from dir looking for the first marker present, markers checked
--- in order at each level (so `.navgraph` beats `.git` in the same directory).
--- @param dir string
--- @param markers string[]
--- @return string|nil
function M.find_from(dir, markers)
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  local current = vim.fs.normalize(dir)
  while current do
    for _, marker in ipairs(markers) do
      if uv.fs_stat(vim.fs.joinpath(current, marker)) then
        return current
      end
    end
    local parent = vim.fs.dirname(current)
    if not parent or parent == current then
      return nil
    end
    current = parent
  end
  return nil
end

--- Root for a buffer: nearest marker above the file, else the cwd.
--- @param bufnr? integer
--- @param markers? string[]
--- @return string
function M.find(bufnr, markers)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  markers = markers or require("epicenter.config").get().lsp.root_markers

  local cwd = vim.fs.normalize(uv.cwd() or ".")
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return cwd
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" then
    return M.find_from(cwd, markers) or cwd
  end

  local dir = vim.fs.dirname(vim.fs.normalize(name))
  return M.find_from(dir, markers) or cwd
end

--- Root-relative path of a buffer, as the contract's `file` fields are
--- (`docs/lsp.md`: "root-relative paths, as the CLI prints them"). `nil` for
--- an unnamed buffer or one outside `root`.
--- @param bufnr integer
--- @param root string
--- @return string|nil
function M.relative(bufnr, root)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  local normalized = vim.fs.normalize(name)
  local root_norm = vim.fs.normalize(root)
  if not vim.startswith(normalized, root_norm .. "/") then
    return nil
  end
  return normalized:sub(#root_norm + 2)
end

return M
