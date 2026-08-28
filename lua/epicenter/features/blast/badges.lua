--- Fan-in / fan-out at the end of a definition line, so the shape of the graph
--- is readable without opening anything.
---
--- One data source for both modes: `navgraph/outline` for the buffer, cached
--- and refreshed on reindex. "cursor" shows the badge for the definition the
--- cursor is inside; "all" shows every definition in the file.
local M = {}

local animate = require("epicenter.ui.animate")

local NS = vim.api.nvim_create_namespace("epicenter.badges")

--- No server for this project is the ordinary case for an unindexed buffer,
--- not a failure worth a log line.
local NO_SERVER = -32002

--- bufnr -> the file's definitions, as `navgraph/outline` returned them.
local outlines = {}
--- bufnr -> what is currently painted, so an unchanged badge does not replay.
local painted = {}
local reveals = {}
--- bufnr -> { tick, generation } of the last outline fetch started. Caches
--- per reindex generation, so a burst of BufEnter/BufWinEnter/reindex on an
--- unchanged buffer costs at most one `navgraph/outline` round trip.
local fetched_at = {}
local index_generation = 0
local augroup = nil

--- @param symbol { callers?: integer, callees?: integer }
function M.text(symbol)
  local icons = require("epicenter.ui.icons")
  return ("%s %d  %s %d"):format(
    icons.ui("fan_in"),
    symbol.callers or 0,
    icons.ui("fan_out"),
    symbol.callees or 0
  )
end

--- Which lines get a badge. Pure.
--- @param symbols table[] definitions from `navgraph/outline`
--- @param mode "cursor"|"all"
--- @param cursor_line integer 1-based
--- @return { line: integer, text: string }[]
function M.entries(symbols, mode, cursor_line)
  if mode == "all" then
    return vim.tbl_map(function(symbol)
      return { line = symbol.line, text = M.text(symbol) }
    end, symbols)
  end

  local innermost = nil
  for _, symbol in ipairs(symbols) do
    local last = symbol.endLine or symbol.line
    local inside = symbol.line <= cursor_line and cursor_line <= last
    if inside and (not innermost or symbol.line > innermost.line) then
      innermost = symbol
    end
  end
  return innermost and { { line = innermost.line, text = M.text(innermost) } } or {}
end

local function signature(entries)
  return table.concat(
    vim.tbl_map(function(entry)
      return ("%d:%s"):format(entry.line, entry.text)
    end, entries),
    "|"
  )
end

--- @param chars integer|nil characters of each badge to show; nil shows all
local function paint(bufnr, entries, chars)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  local last = vim.api.nvim_buf_line_count(bufnr)
  for _, entry in ipairs(entries) do
    local text = chars and vim.fn.strcharpart(entry.text, 0, chars) or entry.text
    if entry.line >= 1 and entry.line <= last and text ~= "" then
      vim.api.nvim_buf_set_extmark(bufnr, NS, entry.line - 1, 0, {
        virt_text = { { "  " .. text, "EpicenterMuted" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end
end

--- Reveals the badge left to right - the terminal's version of a fade in.
--- @param opts? { animate?: table } test seam forwarded to the tween
function M.place(bufnr, entries, opts)
  opts = opts or {}
  if reveals[bufnr] then
    reveals[bufnr].cancel()
    reveals[bufnr] = nil
  end
  painted[bufnr] = signature(entries)

  local width = 0
  for _, entry in ipairs(entries) do
    width = math.max(width, vim.fn.strchars(entry.text))
  end
  if width == 0 then
    paint(bufnr, {})
    return
  end

  local running = true
  local handle = animate.tween(vim.tbl_extend("force", {
    duration = require("epicenter.config").get().animation.open_ms,
    on_frame = function(eased)
      paint(bufnr, entries, math.max(1, math.ceil(eased * width)))
    end,
    on_done = function()
      running = false
      reveals[bufnr] = nil
      paint(bufnr, entries)
    end,
  }, opts.animate or {}))
  reveals[bufnr] = running and handle or nil
end

function M.clear(bufnr)
  if reveals[bufnr] then
    reveals[bufnr].cancel()
    reveals[bufnr] = nil
  end
  painted[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  end
end

--- The buffer's path as the server names it: root-relative, exactly what
--- `navgraph/outline` returns in `files[].file`.
--- @return string|nil
function M.relative_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  local root_mod = require("epicenter.root")
  local path = root_mod.normalize(name)
  local cfg = require("epicenter.config").get()
  local root = root_mod.find(bufnr, cfg.lsp.root_markers)
  if root ~= "" and vim.startswith(path, root .. "/") then
    return path:sub(#root + 2)
  end
  return path
end

--- @return boolean whether navgraph indexes this buffer at all
function M.eligible(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and require("epicenter.client").is_supported(name)
end

--- Repaints from the cached outline. Cheap: no request, no work when nothing
--- about the badge changed.
--- @param opts? { animate?: table }
function M.refresh(bufnr, opts)
  local cfg = require("epicenter.config").get()
  if cfg.badges == false or not vim.api.nvim_buf_is_valid(bufnr) then
    return M.clear(bufnr)
  end
  local symbols = outlines[bufnr]
  if not symbols then
    return
  end
  local win = vim.fn.bufwinid(bufnr)
  local cursor_line = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 1
  local entries = M.entries(symbols, cfg.badges, cursor_line)
  if painted[bufnr] == signature(entries) then
    return
  end
  M.place(bufnr, entries, opts)
end

--- Asks the server for the file's definitions, then repaints.
--- @param opts? { animate?: table }
function M.fetch(bufnr, opts)
  local cfg = require("epicenter.config").get()
  if cfg.badges == false or not M.eligible(bufnr) then
    return
  end
  -- No server for this project yet: nothing to ask, and badges are decoration.
  if not require("epicenter.client").session_for_buf(bufnr) then
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local last = fetched_at[bufnr]
  if last and last.tick == tick and last.generation == index_generation then
    return
  end
  fetched_at[bufnr] = { tick = tick, generation = index_generation }
  -- `navgraph/outline` filters by a path substring and answers with one entry
  -- per matching file, so ask for this file and take the exact match back.
  local relative = M.relative_path(bufnr)
  require("epicenter.client").outline({ path = relative }, function(err, result)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if err then
        outlines[bufnr] = nil
        M.clear(bufnr)
        if err.code ~= NO_SERVER then
          require("epicenter.log").warn(
            "badges: outline failed for %s: %s",
            vim.api.nvim_buf_get_name(bufnr),
            err.message or "?"
          )
        end
        return
      end
      outlines[bufnr] = M.symbols_for(result, relative)
      M.refresh(bufnr, opts)
    end)
  end, { bufnr = bufnr, channel = "badges:" .. bufnr })
end

--- The definitions of one file out of a `navgraph/outline` answer. Pure.
--- @param result { files: { file: string, symbols: table[] }[] }
--- @return table[]
function M.symbols_for(result, relative)
  for _, entry in ipairs(result and result.files or {}) do
    if entry.file == relative then
      return entry.symbols or {}
    end
  end
  return {}
end

local function refresh_visible()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      M.fetch(vim.api.nvim_win_get_buf(win))
    end
  end
end

--- Idempotent: a second `epicenter.setup()` takes the old wiring down first.
--- @param cfg table resolved config
function M.setup(cfg)
  augroup = augroup or vim.api.nvim_create_augroup("EpicenterBadges", { clear = true })
  vim.api.nvim_clear_autocmds({ group = augroup })
  -- Cancel every running reveal directly, not only the ones for a buffer
  -- `outlines` still remembers - a buffer whose fetch is in flight has a
  -- pending reveal too, and a loop keyed on `outlines` would miss it.
  for _, handle in pairs(reveals) do
    handle.cancel()
  end
  for bufnr in pairs(outlines) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    end
  end
  outlines, painted, reveals, fetched_at = {}, {}, {}, {}
  index_generation = 0
  if cfg.badges == false then
    return
  end

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = augroup,
    callback = function(event)
      M.fetch(event.buf)
    end,
  })
  if cfg.badges == "cursor" then
    vim.api.nvim_create_autocmd("CursorHold", {
      group = augroup,
      callback = function(event)
        M.refresh(event.buf)
      end,
    })
  end
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = require("epicenter.events").INDEXED,
    callback = function()
      index_generation = index_generation + 1
      refresh_visible()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    callback = function(event)
      if reveals[event.buf] then
        reveals[event.buf].cancel()
      end
      outlines[event.buf] = nil
      painted[event.buf] = nil
      reveals[event.buf] = nil
      fetched_at[event.buf] = nil
    end,
  })
end

M.namespace = NS

--- Test seam: the outline the badges are drawn from.
function M.outline_of(bufnr)
  return outlines[bufnr]
end

return M
