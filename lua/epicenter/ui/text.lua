--- Row-text fitting: a shared, pure helper so a panel row never silently
--- loses the field it exists to show (F12).
local M = {}

local ELLIPSIS = "…"

--- Fits `head .. middle .. tail` inside `width` display columns by eliding
--- MIDDLE - typically a file path, the row's least essential field - rather
--- than letting the window edge cut off `tail` (a count, a bar, a line
--- number) with no indication anything was lost. Elides from the front of
--- `middle`, keeping its end: a path's filename says more than its leading
--- directories. Pure.
--- @param head string kept in full
--- @param middle string elided from the front when the row does not fit
--- @param tail string kept in full - the field most worth keeping visible
--- @param width integer? display columns available; nil/falsy skips fitting
--- @return string text `head .. shown_middle .. tail`
--- @return string shown_middle `middle`, unchanged or elided
function M.fit(head, middle, tail, width)
  if not width then
    return head .. middle .. tail, middle
  end
  if vim.fn.strdisplaywidth(head .. middle .. tail) <= width then
    return head .. middle .. tail, middle
  end
  local budget = width
    - vim.fn.strdisplaywidth(head)
    - vim.fn.strdisplaywidth(tail)
    - vim.fn.strdisplaywidth(ELLIPSIS)
  if budget <= 0 then
    return head .. ELLIPSIS .. tail, ELLIPSIS
  end
  local kept = middle
  while vim.fn.strdisplaywidth(kept) > budget do
    kept = vim.fn.strcharpart(kept, 1)
  end
  local shown = ELLIPSIS .. kept
  return head .. shown .. tail, shown
end

return M
