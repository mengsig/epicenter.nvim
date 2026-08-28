--- The working change's blast, marked in the code itself: a sign in the
--- gutter and a calm note at the end of each impacted definition's line.
---
--- Marks go on every impacted line of a loaded buffer, not the visible slice:
--- an off-screen extmark costs nothing to keep and needs no scroll tracking
--- to stay correct. Same shape as `blast.ripples`, different question - that
--- one answers "what is this panel showing", this one "what did I break".
local M = {}

local theme = require("epicenter.ui.theme")
local root_mod = require("epicenter.root")

local NS = vim.api.nvim_create_namespace("epicenter.impact")

M.GROUPS = { "EpicenterImpact1", "EpicenterImpact2", "EpicenterImpact3" }
M.DONE_GROUP = "EpicenterImpactDone"
local LINE_ALPHA = { 0.9, 0.6, 0.4 }
local SIGNS = { "▍", "▏", "▏" }
local ASCII_SIGNS = { "|", ":", "." }

--- path -> line -> { depth, label, approved }, or nil with nothing marked.
--- Keys are `root.normalize`d: the server's paths come from a canonicalized
--- root, so a symlinked checkout would never match a raw buffer name.
local marked = nil
--- bufnr -> line -> extmark id, so a repaint moves marks instead of snapping
--- them back to the line numbers the last answer named.
local placed = {}
local augroup = nil

local function grade(depth)
  return math.max(1, math.min(depth or 1, #M.GROUPS))
end

--- The marker groups, derived from the accent over the EDITOR background -
--- these land in ordinary windows, not in a float.
function M.define()
  local accent = vim.api.nvim_get_hl(0, { name = "EpicenterAccent", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local muted = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  for i, group in ipairs(M.GROUPS) do
    vim.api.nvim_set_hl(0, group, {
      fg = theme.blend(accent.fg, muted.fg or normal.fg, LINE_ALPHA[i]),
    })
  end
  vim.api.nvim_set_hl(0, M.DONE_GROUP, {
    fg = theme.blend(muted.fg, normal.bg, 0.7),
    italic = true,
  })
end

local function sign_for(depth)
  local set = require("epicenter.config").get().ui.icons == "ascii" and ASCII_SIGNS or SIGNS
  return set[grade(depth)]
end

--- The end-of-line note for one impacted definition. Pure.
--- @param entry { depth: integer, label: string, approved: boolean }
--- @return string
function M.note(entry)
  local icons = require("epicenter.ui.icons")
  if entry.approved then
    return ("%s reviewed · %s"):format(icons.ui("ok"), entry.label)
  end
  local marker = require("epicenter.config").get().impact.marker
  return ("%s %s · %s"):format(icons.ui("impact"), marker, entry.label)
end

--- @param entry { depth: integer, label: string, approved: boolean }
local function decorate(entry)
  local group = entry.approved and M.DONE_GROUP or M.GROUPS[grade(entry.depth)]
  return {
    virt_text = { { "  " .. M.note(entry), group } },
    virt_text_pos = "eol",
    sign_text = sign_for(entry.depth),
    sign_hl_group = group,
    priority = 80,
  }
end

local function paint(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    placed[bufnr] = nil
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local lines = name ~= "" and marked and marked[root_mod.normalize(name)] or nil
  placed[bufnr] =
    require("epicenter.ui.marklayer").reapply(bufnr, NS, placed[bufnr], lines, decorate)
end

local function paint_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    paint(bufnr)
  end
end

--- Marks the impacted lines and keeps them marked as files are opened.
--- @param entries { path: string, line: integer, depth: integer, label: string, approved: boolean }[]
function M.apply(entries)
  if not require("epicenter.config").get().impact.inline then
    return M.clear()
  end
  local by_path = {}
  -- One realpath per distinct file, not per impacted definition: a deep
  -- impact is thousands of entries over a handful of files.
  local canonical = {}
  for _, entry in ipairs(entries) do
    local path = canonical[entry.path]
    if not path then
      path = root_mod.normalize(entry.path)
      canonical[entry.path] = path
    end
    by_path[path] = by_path[path] or {}
    local existing = by_path[path][entry.line]
    -- One line, one mark: the nearest ring wins, so a definition reached
    -- twice is not reported as the fainter of the two.
    if not existing or entry.depth < existing.depth then
      by_path[path][entry.line] = entry
    end
  end
  marked = by_path

  M.define()
  augroup = augroup or vim.api.nvim_create_augroup("EpicenterImpactMarks", { clear = true })
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
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = augroup,
    callback = function(event)
      placed[event.buf] = nil
    end,
  })
  paint_all()
end

--- Drops every mark. Called the moment the working change is gone.
function M.clear()
  marked = nil
  placed = {}
  if augroup then
    vim.api.nvim_clear_autocmds({ group = augroup })
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    end
  end
end

--- The mark on `line` of `bufnr`, or nil. For tests.
--- @return { text: string, group: string }|nil
function M.mark_at(bufnr, line)
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
  local chunk = mark[4].virt_text and mark[4].virt_text[1] or {}
  return { text = chunk[1] or "", group = chunk[2] or "" }
end

M.namespace = NS

return M
