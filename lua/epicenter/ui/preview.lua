--- Read-only slice of a file with the target range highlighted.
local M = {}

local MAX_SLICE = 400

--- Reads lines `from`..`to` (1-based, inclusive) without loading the whole
--- file. Returns the lines plus the first line number actually read.
--- @return string[]|nil lines, string|nil err
function M.read_slice(path, from, to)
  local fh, err = io.open(path, "r")
  if not fh then
    return nil, err
  end
  local lines, n = {}, 0
  for line in fh:lines() do
    n = n + 1
    if n >= from then
      table.insert(lines, (line:gsub("\r$", "")))
    end
    if n >= to then
      break
    end
  end
  fh:close()
  return lines, nil
end

--- @class epicenter.Preview
local Preview = {}
Preview.__index = Preview

--- @param opts { buf: integer, win: integer, height: integer }
function M.new(opts)
  vim.bo[opts.buf].modifiable = false
  return setmetatable({
    buf = opts.buf,
    win = opts.win,
    height = opts.height,
    ns = vim.api.nvim_create_namespace("epicenter.preview"),
    shown = nil,
  }, Preview)
end

function Preview:set_height(height)
  self.height = math.max(1, height)
end

function Preview:clear(message)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  self.shown = nil
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { message or "" })
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
end

--- Shows the file around `line`, highlighting `line`..`end_line` (1-based).
--- @param target { path: string, line: integer, end_line?: integer }
function Preview:show(target)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local key = ("%s:%d"):format(target.path, target.line)
  if self.shown == key then
    return
  end

  local context = math.max(1, math.floor(self.height / 4))
  local from = math.max(1, target.line - context)
  local to = math.min(from + math.max(self.height, 1) + 5, from + MAX_SLICE)

  local lines, err = M.read_slice(target.path, from, to)
  if not lines then
    self:clear("  cannot read " .. vim.fn.fnamemodify(target.path, ":~:.") .. ": " .. tostring(err))
    return
  end

  self.shown = key
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false

  local ft = vim.filetype.match({ filename = target.path, contents = lines })
  if ft and vim.bo[self.buf].filetype ~= ft then
    vim.bo[self.buf].filetype = ft
    -- Treesitter is best-effort: a slice is not always parseable, and a
    -- missing parser must not break the preview.
    pcall(vim.treesitter.start, self.buf, ft)
  end

  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
  local first = target.line - from
  local last = math.min((target.end_line or target.line) - from, #lines - 1)
  for row = first, math.max(first, last) do
    if row >= 0 and row < #lines then
      vim.api.nvim_buf_set_extmark(self.buf, self.ns, row, 0, { line_hl_group = "EpicenterRange" })
    end
  end

  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_cursor(self.win, { math.max(1, first + 1), 0 })
    vim.wo[self.win].cursorline = true
  end
end

M.Preview = Preview

return M
