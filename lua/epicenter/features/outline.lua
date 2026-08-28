--- The outline sidebar: the current buffer's symbols, nested, live, and
--- following the cursor. No config requires at file scope - see `epicenter.registry`.
local M = {}

--- The one sidebar. `nil` when it is closed.
local state = nil

--- Nests a flat Symbol[] by qualified name: `A.b` sits under `A` when both
--- are present in the file. The contract's outline is flat, in indexing
--- order (`{file,lang,symbols:Symbol[]}`) - the nesting shown here is client
--- rendering, not a protocol shape (F3).
--- @param symbols table[]
--- @return { symbol: table, children: table[] }[]
function M.tree_of(symbols)
  local nodes, by_qualified = {}, {}
  for _, symbol in ipairs(symbols or {}) do
    local node = { symbol = symbol, children = {} }
    local parent_key = symbol.qualified:match("^(.*)%.[%w_]+$")
    local parent = parent_key and by_qualified[parent_key]
    by_qualified[symbol.qualified] = node
    table.insert(parent and parent.children or nodes, node)
  end
  return nodes
end

--- Rows in display order. Pure.
--- @param nodes { symbol: table, children?: table[] }[]
--- @return { symbol: table, depth: integer }[]
function M.rows_of(nodes, depth, out)
  depth, out = depth or 0, out or {}
  for _, node in ipairs(nodes or {}) do
    table.insert(out, { symbol = node.symbol, depth = depth })
    M.rows_of(node.children, depth + 1, out)
  end
  return out
end

--- One display row. Pure.
function M.render_row(row)
  local icons = require("epicenter.ui.icons")
  local symbol = row.symbol
  local text = ("%s%s %s"):format(("  "):rep(row.depth + 1), icons.kind(symbol.kind), symbol.name)
  local location = ("  %d"):format(symbol.line)
  return {
    text = text .. location,
    spans = { { hl = "EpicenterMuted", from = #text, to = #text + #location } },
  }
end

--- Index of the innermost row whose body contains `line`. Pure.
--- @return integer|nil
function M.enclosing_index(rows, line)
  local best = nil
  for i, row in ipairs(rows) do
    local symbol = row.symbol
    if symbol.line <= line and line <= (symbol.endLine or symbol.line) then
      if not best or symbol.line >= rows[best].symbol.line then
        best = i
      end
    end
  end
  return best
end

local function kind_cycle()
  return require("epicenter.features.search").KIND_CYCLE
end

local function visible(rows, kind_index)
  local kinds = kind_cycle()[kind_index].kinds
  if not kinds then
    return rows
  end
  return vim.tbl_filter(function(row)
    return vim.tbl_contains(kinds, row.symbol.kind)
  end, rows)
end

local function set_footer()
  local label = kind_cycle()[state.kind_index].label
  state.panel:set_footer(
    (" %d%s "):format(state.panel.list:count(), label and (" · " .. label) or "")
  )
end

local function apply(rows)
  state.rows = rows
  state.panel:set_items(visible(rows, state.kind_index))
  set_footer()
  M.sync_cursor()
end

local function request()
  local client = require("epicenter.client")
  local root_mod = require("epicenter.root")
  local uri = state.uri
  local root = root_mod.find(state.source_buf)
  local path = root_mod.relative(state.source_buf, root)
  client.outline({ path = path }, function(err, result)
    if not state or not state.panel:valid() or state.uri ~= uri then
      return
    end
    if err then
      state.panel:notice("  " .. (err.message or "navgraph did not answer"))
      return
    end
    local files = result and result.files or {}
    local matched
    for _, entry in ipairs(files) do
      if entry.file == path then
        matched = entry
        break
      end
    end
    matched = matched or files[1]
    apply(M.rows_of(M.tree_of(matched and matched.symbols)))
  end, { bufnr = state.source_buf, channel = "outline" })
end

--- Highlights the symbol the cursor sits in. Cheap enough to run on every
--- debounced `CursorMoved`.
function M.sync_cursor()
  if not state or not state.panel:valid() then
    return
  end
  local win = state.source_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local at = M.enclosing_index(state.panel.list:items(), vim.api.nvim_win_get_cursor(win)[1])
  if at then
    state.panel.list:select(at)
    state.panel:draw()
  end
end

local function retarget(bufnr, win)
  state.source_buf = bufnr
  state.source_win = win
  state.uri = vim.uri_from_bufnr(bufnr)
  state.panel:set_title(
    (" outline: %s "):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"))
  )
  state.panel:set_items({})
  request()
end

local function is_source(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

local function target_of(row)
  return {
    path = vim.uri_to_fname(row.symbol.uri),
    line = row.symbol.line,
    end_line = row.symbol.endLine,
  }
end

--- Jumps in the source window and leaves the sidebar open - unlike every
--- other panel's `<CR>`, this one is a persistent widget you keep browsing
--- from, so it overrides `ui.panel`'s default close-then-jump action.
local function jump_from_sidebar(row)
  local panel_mod = require("epicenter.ui.panel")
  if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  end
  panel_mod.jump(target_of(row), "edit")
end

local function sidebar_box()
  local cfg = require("epicenter.config").get()
  local height = math.max(3, vim.o.lines - vim.o.cmdheight - 3)
  local width = math.max(16, math.min(cfg.outline.width, vim.o.columns - 4))
  return { row = 0, col = 0, width = width, height = height }
end

local function install_autocmds()
  local group = vim.api.nvim_create_augroup("EpicenterOutline", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function(event)
      if state and event.buf == state.source_buf then
        state.debouncer.call()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(event)
      if state and event.buf ~= state.source_buf and is_source(event.buf) then
        retarget(event.buf, vim.api.nvim_get_current_win())
      end
    end,
  })
  return group
end

local function open(ctx)
  local cfg = require("epicenter.config").get()
  local events = require("epicenter.events")
  local panel_mod = require("epicenter.ui.panel")

  state = {
    source_buf = ctx.bufnr,
    source_win = vim.api.nvim_get_current_win(),
    uri = vim.uri_from_bufnr(ctx.bufnr),
    rows = {},
    kind_index = 1,
  }

  state.panel = panel_mod.open({
    title = (" outline: %s "):format(
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.bufnr), ":t")
    ),
    footer = " 0 ",
    box = sidebar_box(),
    reflow = sidebar_box,
    filetype = "epicenter-outline",
    empty_text = "  loading...",
    render_row = M.render_row,
    text_of = function(row)
      return row.symbol.name
    end,
    target_of = target_of,
    hints = { ["<C-k>"] = "cycle the kind filter" },
    on_filter = function()
      set_footer()
    end,
    keys = {
      -- Overrides `ui.panel`'s default <CR> (which closes before jumping):
      -- the sidebar is persistent, not a one-shot picker.
      ["<CR>"] = function(self)
        local row = self:current()
        if row then
          jump_from_sidebar(row)
        end
      end,
      ["<C-k>"] = function()
        local cycle = kind_cycle()
        state.kind_index = (state.kind_index % #cycle) + 1
        state.panel:set_items(visible(state.rows, state.kind_index))
        set_footer()
      end,
      ["<Up>"] = function(self)
        self.list:move(-1)
        self:draw()
      end,
      ["<Down>"] = function(self)
        self.list:move(1)
        self:draw()
      end,
    },
    on_close = function()
      if state then
        state.unsubscribe()
        state.debouncer.close()
        state.refresh_debounce.close()
        pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
        state = nil
      end
    end,
  })

  state.debouncer = require("epicenter.ui.prompt").debounce(cfg.outline.debounce_ms, function()
    M.sync_cursor()
  end)
  -- A separate debouncer from the cursor-sync one above: `navgraph/indexed`
  -- fires after every reindex, including the 2s watch poll, so a typing burst
  -- would otherwise issue one `navgraph/outline` request per keystroke window.
  state.refresh_debounce = require("epicenter.ui.prompt").debounce(
    cfg.outline.debounce_ms,
    function()
      if state and state.panel:valid() then
        request()
      end
    end
  )
  state.unsubscribe = require("epicenter.events").on(events.INDEXED, function()
    if state and state.panel:valid() then
      state.refresh_debounce.call()
    end
  end)
  state.augroup = install_autocmds()

  request()
  return state.panel
end

--- Open, or focus, or close: one key gets you into the sidebar and back out.
local function run(ctx)
  if state and state.panel:valid() then
    if vim.api.nvim_get_current_win() == state.panel.win.win then
      state.panel:close()
      return nil
    end
    state.panel.win:focus()
    return state.panel
  end
  return open(ctx)
end

M.name = "outline"
M.summary = "Live symbol outline of the current buffer, in a sidebar"

M.options = {
  outline = { width = 34, debounce_ms = 80 },
}

M.commands = {
  { name = "outline", desc = "Symbol outline of the current file", run = run },
}

M.keymaps = {
  { suffix = "o", command = "outline", desc = "Epicenter: outline" },
}

--- Test seam: the live sidebar, or nil.
function M.current()
  return state
end

return M
