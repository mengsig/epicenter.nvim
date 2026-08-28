--- Ring-graded marks on the impacted definition lines themselves, so the blast
--- radius is visible in the code, not only in the panel.
---
--- Marks are placed on every impacted line of a loaded buffer rather than on
--- the visible slice: extmarks off screen cost nothing to keep and this needs
--- no scroll tracking to stay correct.
local M = {}

local theme = require("epicenter.ui.theme")

local NS = vim.api.nvim_create_namespace("epicenter.ripples")

--- Strength grade; ring 3 and deeper share the faintest one.
M.GROUPS = { "EpicenterRipple1", "EpicenterRipple2", "EpicenterRipple3" }
local LINE_ALPHA = { 0.18, 0.10, 0.05 }
local SIGN_ALPHA = { 1.0, 0.62, 0.38 }
local SIGNS = { "▍", "▏", "▏" }
local ASCII_SIGNS = { "|", ":", "." }

--- path -> line -> ring, or nil when no panel is open.
local impacted = nil
local augroup = nil

local function grade(ring)
  return math.max(1, math.min(ring, #M.GROUPS))
end

--- Derives the ripple groups from the accent over the editor background (not
--- the float background - these land in ordinary windows).
function M.define()
  local accent = vim.api.nvim_get_hl(0, { name = "EpicenterAccent", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local muted = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  for i, group in ipairs(M.GROUPS) do
    vim.api.nvim_set_hl(0, group, {
      bg = theme.blend(accent.fg, normal.bg, LINE_ALPHA[i]),
      fg = theme.blend(accent.fg, muted.fg or normal.fg, SIGN_ALPHA[i]),
    })
  end
end

local function sign_for(ring)
  local set = require("epicenter.config").get().ui.icons == "ascii" and ASCII_SIGNS or SIGNS
  return set[grade(ring)]
end

--- @param bufnr integer
local function paint(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local lines = name ~= "" and impacted and impacted[vim.fs.normalize(name)] or nil
  if not lines then
    return
  end
  local last = vim.api.nvim_buf_line_count(bufnr)
  for line, ring in pairs(lines) do
    if line >= 1 and line <= last then
      local group = M.GROUPS[grade(ring)]
      vim.api.nvim_buf_set_extmark(bufnr, NS, line - 1, 0, {
        line_hl_group = group,
        sign_text = sign_for(ring),
        sign_hl_group = group,
        priority = 90,
      })
    end
  end
end

local function paint_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    paint(bufnr)
  end
end

--- Marks the impacted lines and keeps them marked as files are opened.
--- @param nodes epicenter.blast.Node[] each carrying the protocol's `depth`
function M.apply(nodes)
  if not require("epicenter.config").get().ripples then
    return M.clear()
  end
  local by_path = {}
  for _, node in ipairs(nodes) do
    if node.state ~= "removed" and node.symbol.uri then
      local path = vim.fs.normalize(vim.uri_to_fname(node.symbol.uri))
      local lines = by_path[path] or {}
      by_path[path] = lines
      local line = node.symbol.line
      if not lines[line] or node.depth < lines[line] then
        lines[line] = node.depth
      end
    end
  end
  impacted = by_path

  M.define()
  augroup = augroup or vim.api.nvim_create_augroup("EpicenterRipples", { clear = true })
  vim.api.nvim_clear_autocmds({ group = augroup })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufReadPost" }, {
    group = augroup,
    callback = function(event)
      paint(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      M.define()
    end,
  })
  paint_all()
end

--- Drops every mark. Called when the panel closes.
function M.clear()
  impacted = nil
  if augroup then
    vim.api.nvim_clear_autocmds({ group = augroup })
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    end
  end
end

--- Ring marked on `line` of `bufnr`, or nil. For tests and `:checkhealth`.
function M.ring_at(bufnr, line)
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    NS,
    { line - 1, 0 },
    { line - 1, -1 },
    { details = true }
  )
  local mark = marks[1]
  if not mark then
    return nil
  end
  for i, group in ipairs(M.GROUPS) do
    if mark[4].line_hl_group == group then
      return i
    end
  end
  return nil
end

M.namespace = NS

return M
