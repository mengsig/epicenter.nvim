--- Quickfix / location-list export, shared by every panel and palette.
---
--- The rows a widget shows are already `{ target, text }` pairs; this turns
--- them into Vim's own list format and opens it, so `:cnext` walks exactly
--- what was on screen.
local M = {}

--- @class epicenter.qf.Row
--- @field target epicenter.Target the row's `{ path, line, character? }`
--- @field text string the row's own display text

--- Vim's list items for `rows`. Pure.
--- @param rows epicenter.qf.Row[]
--- @return table[]
function M.entries(rows)
  local items = {}
  for _, row in ipairs(rows or {}) do
    local target = row.target
    if target and target.path then
      table.insert(items, {
        filename = target.path,
        lnum = math.max(1, target.line or 1),
        col = math.max(1, (target.character or 0) + 1),
        text = vim.trim(row.text or ""),
      })
    end
  end
  return items
end

--- @param list "quickfix"|"loclist"
--- @return string
local function opener(list)
  return list == "loclist" and "lopen" or "copen"
end

--- Fills the list and opens it. Returns how many entries were sent, so a
--- caller can say "nothing to send" rather than opening an empty window.
--- @param opts { rows: epicenter.qf.Row[], list?: "quickfix"|"loclist", title?: string }
--- @return integer count
function M.send(opts)
  local list = opts.list == "loclist" and "loclist" or "quickfix"
  local items = M.entries(opts.rows)
  local title = opts.title or "epicenter"
  if #items == 0 then
    return 0
  end

  if list == "loclist" then
    vim.fn.setloclist(0, {}, " ", { title = title, items = items })
  else
    vim.fn.setqflist({}, " ", { title = title, items = items })
  end
  vim.cmd("botright " .. opener(list))
  return #items
end

--- `M.send` plus the user-facing notice, the way every panel reports it.
--- @param opts { rows: epicenter.qf.Row[], list?: "quickfix"|"loclist", title?: string }
function M.send_and_notify(opts)
  local count = M.send(opts)
  local label = opts.list == "loclist" and "location list" or "quickfix"
  if count == 0 then
    require("epicenter").notify("nothing to send to the " .. label, "warn")
    return 0
  end
  require("epicenter").notify(("sent %d to the %s"):format(count, label))
  return count
end

return M
