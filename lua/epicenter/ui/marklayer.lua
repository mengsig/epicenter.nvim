--- Keeping a namespace's marks on the code they were placed on, across
--- repaints.
---
--- An extmark already follows the buffer's own edits. What does not is a
--- repaint that clears the namespace and re-places every mark from the line
--- numbers the SERVER sent: after three lines are inserted above, that snaps
--- the mark back three lines onto unrelated code. So a mark placed once is
--- thereafter updated in place - same id, whatever row it has moved to - and
--- only its decoration is recomputed.
---
--- Shared by `impact.marks` and `blast.ripples`, which differ only in what
--- they draw.
local M = {}

--- @param bufnr integer
--- @param ns integer
--- @param placed table<integer, integer>|nil line -> extmark id, from the
---   previous call for this buffer; nil the first time.
--- @param lines table<integer, any>|nil 1-based server line -> the value
---   `decorate` turns into extmark options. nil drops every mark.
--- @param decorate fun(value: any): table `nvim_buf_set_extmark` options
--- @return table<integer, integer>|nil the new line -> id map
function M.reapply(bufnr, ns, placed, lines, decorate)
  if not (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return nil
  end
  if not lines then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    return nil
  end

  local last = vim.api.nvim_buf_line_count(bufnr)
  local ids = {}
  for line, value in pairs(lines) do
    local id = placed and placed[line] or nil
    local row = line - 1
    if id then
      -- Where the buffer's own edits carried this mark, not where the answer
      -- said it was.
      local at = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, {})
      if at[1] then
        row = at[1]
      end
    end
    if row >= 0 and row < last then
      local opts = decorate(value)
      opts.id = id
      ids[line] = vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, opts)
    elseif id then
      vim.api.nvim_buf_del_extmark(bufnr, ns, id)
    end
  end

  -- Lines the new answer no longer carries.
  for line, id in pairs(placed or {}) do
    if not ids[line] then
      vim.api.nvim_buf_del_extmark(bufnr, ns, id)
    end
  end
  return ids
end

return M
