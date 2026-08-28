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
---
--- `opts.min_middle` guards against the opposite starvation (D1): with no
--- floor, an unbounded `tail` (e.g. a grep match's whole source line) can
--- still budget `middle` down to nothing. Given a floor, `middle` never
--- elides past it; once `head` + the floor + `tail` still overflow, `tail`
--- itself elides from the right instead, with its own trailing ellipsis.
--- @param head string kept in full
--- @param middle string elided from the front when the row does not fit
--- @param tail string kept in full when `middle` has room left to give
--- @param width integer? display columns available; nil/falsy skips fitting
--- @param opts? { min_middle?: string } `middle` never elides below this
--- @return string text `head .. shown_middle .. shown_tail`
--- @return string shown_middle `middle`, unchanged or elided
function M.fit(head, middle, tail, width, opts)
  if not width then
    return head .. middle .. tail, middle
  end
  if vim.fn.strdisplaywidth(head .. middle .. tail) <= width then
    return head .. middle .. tail, middle
  end
  local head_width = vim.fn.strdisplaywidth(head)
  local ellipsis_width = vim.fn.strdisplaywidth(ELLIPSIS)
  local budget = width - head_width - vim.fn.strdisplaywidth(tail) - ellipsis_width

  local floor = opts and opts.min_middle
  local floor_width = floor and (ellipsis_width + vim.fn.strdisplaywidth(floor))
  if not floor or budget >= floor_width then
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

  -- `middle` at its floor and `tail` at full length still overflow: hold the
  -- floor and elide `tail` from the right instead.
  local shown = ELLIPSIS .. floor
  local tail_budget = width - head_width - floor_width - ellipsis_width
  if tail_budget <= 0 then
    return head .. shown, shown
  end
  local kept_tail = tail
  while vim.fn.strdisplaywidth(kept_tail) > tail_budget do
    kept_tail = vim.fn.strcharpart(kept_tail, 0, vim.fn.strchars(kept_tail) - 1)
  end
  return head .. shown .. kept_tail .. ELLIPSIS, shown
end

return M
