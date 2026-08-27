--- The path finder: pick two symbols, get the call chain between them drawn as
--- a vertical ladder. No config requires at file scope - see `epicenter.registry`.
local M = {}

local EDGE_LABEL = { call = "calls", ref = "references" }

local function append(text, spans, chunk, hl)
  if chunk == "" then
    return text
  end
  table.insert(spans, { row = nil, hl = hl, from = #text, to = #text + #chunk })
  return text .. chunk
end

--- The chain as buffer content. Pure, so the drawing is testable without a
--- server: `reveal[n]` is how many lines the first `n` steps occupy, which is
--- what the per-step animation paints.
--- @param steps { symbol: table, edge?: { kind?: string, heuristic?: boolean } }[]
--- @return { lines: string[], spans: table[], targets: table<integer, table>, reveal: integer[] }
function M.chain_lines(steps)
  local icons = require("epicenter.ui.icons")
  local lines, spans, targets, reveal = { "" }, {}, {}, {}

  for i, step in ipairs(steps) do
    if i > 1 then
      local edge = step.edge or {}
      local label = EDGE_LABEL[edge.kind or "call"] or "calls"
      if edge.heuristic then
        label = label .. " ?"
      end
      local connector = ("  %s  "):format(icons.ui("chain"))
      table.insert(
        spans,
        { row = #lines, hl = "EpicenterMuted", from = 0, to = #connector + #label }
      )
      table.insert(lines, connector .. label)
      local arrow = ("  %s"):format(icons.ui("chain_end"))
      table.insert(spans, { row = #lines, hl = "EpicenterAccent", from = 0, to = #arrow })
      table.insert(lines, arrow)
    end

    local symbol = step.symbol
    local row_spans = {}
    local text = ("  %s %s"):format(icons.kind(symbol.kind), symbol.qualified)
    text = append(text, row_spans, ("  %s:%d"):format(symbol.file, symbol.line), "EpicenterMuted")
    for _, span in ipairs(row_spans) do
      span.row = #lines
      table.insert(spans, span)
    end
    table.insert(lines, text)
    targets[#lines] =
      { path = vim.uri_to_fname(symbol.uri), line = symbol.line, end_line = symbol.endLine }
    reveal[i] = #lines
  end

  table.insert(lines, "")
  return { lines = lines, spans = spans, targets = targets, reveal = reveal }
end

local function paint(win, chain, upto)
  local ns = vim.api.nvim_create_namespace("epicenter.path")
  local shown = vim.list_slice(chain.lines, 1, upto)
  win:set_lines(shown)
  vim.api.nvim_buf_clear_namespace(win.buf, ns, 0, -1)
  for _, span in ipairs(chain.spans) do
    if span.row < #shown then
      pcall(vim.api.nvim_buf_set_extmark, win.buf, ns, span.row, span.from, {
        end_col = span.to,
        hl_group = span.hl,
        strict = false,
      })
    end
  end
end

--- Draws the ladder one step at a time. With motion off the tween lands on the
--- full chain inside this call.
local function reveal(win, chain)
  local animate = require("epicenter.ui.animate")
  local easing = require("epicenter.ui.easing")
  local cfg = require("epicenter.config").get()
  local steps = #chain.reveal
  if steps <= 1 then
    paint(win, chain, #chain.lines)
    return
  end
  animate.tween({
    duration = cfg.path.step_ms * steps,
    easing = easing.linear,
    on_frame = function(eased)
      local shown = math.max(1, math.min(steps, math.ceil(eased * steps)))
      paint(win, chain, chain.reveal[shown])
    end,
    on_done = function()
      if win:valid() then
        paint(win, chain, #chain.lines)
      end
    end,
  })
end

local function open_window(lines, title, footer)
  local cfg = require("epicenter.config").get()
  local window = require("epicenter.ui.window")
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 4)
  end
  local win = window.open({
    box = window.box({
      width = width,
      height = #lines,
      max_width = cfg.ui.max_width,
      max_height = cfg.ui.max_height,
    }),
    title = title,
    footer = footer,
    filetype = "epicenter-path",
    enter = true,
  })
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      win:close()
    end, { buffer = win.buf, nowait = true, silent = true })
  end
  return win
end

--- @param result { found?: boolean, steps?: table[] }
local function show(result, from, to)
  local steps = result.steps or {}
  if result.found == false or #steps == 0 then
    local lines = { "", ("  no call path from %s to %s"):format(from, to), "" }
    local win = open_window(lines, " path ", " q close ")
    win:set_lines(lines)
    win:reveal()
    return win
  end

  local chain = M.chain_lines(steps)
  local title = (" path: %s -> %s "):format(from, to)
  local win = open_window(chain.lines, title, " <CR> jump · y yank · q close ")
  win:reveal()
  reveal(win, chain)

  local function target()
    return chain.targets[vim.api.nvim_win_get_cursor(win.win)[1]]
  end
  vim.keymap.set("n", "<CR>", function()
    local found = target()
    if not found then
      return
    end
    win:close()
    vim.schedule(function()
      require("epicenter.ui.panel").jump(found, "edit")
    end)
  end, { buffer = win.buf, nowait = true, silent = true })
  vim.keymap.set("n", "y", function()
    local found = target()
    if not found then
      return
    end
    local text = ("%s:%d"):format(vim.fn.fnamemodify(found.path, ":~:."), found.line)
    vim.fn.setreg(vim.v.register or '"', text)
    require("epicenter").notify("yanked " .. text)
  end, { buffer = win.buf, nowait = true, silent = true })
  return win
end

local function find(bufnr, from, to)
  local client = require("epicenter.client")
  local handle = { win = nil }
  client.path({ from = from, to = to }, function(err, result)
    if err then
      require("epicenter").notify(err.message or "navgraph did not answer", "error")
      return
    end
    handle.win = show(result or {}, from, to)
  end, { bufnr = bufnr, channel = "path" })
  return handle
end

--- Symbol picker built on the search palette, so both ends are chosen the same
--- way the rest of the plugin finds a symbol.
local function pick(bufnr, title, on_pick)
  local client = require("epicenter.client")
  local cfg = require("epicenter.config").get()
  local icons = require("epicenter.ui.icons")
  local palette = require("epicenter.ui.palette")
  local search = require("epicenter.features.search")

  return palette.open({
    title = title,
    prompt_prefix = " " .. icons.ui("search") .. " ",
    debounce_ms = cfg.search.debounce_ms,
    state = { bufnr = bufnr },
    empty_text = "  no symbols match",
    source = function(query, state, cb)
      client.search({ query = query, limit = cfg.search.limit }, function(err, result)
        if err then
          return cb(err)
        end
        cb(nil, result.items or {}, result.total)
      end, { bufnr = state.bufnr, channel = "path-pick" })
    end,
    render_item = search.render_symbol,
    preview_of = function(item)
      return {
        path = vim.uri_to_fname(item.symbol.uri),
        line = item.symbol.line,
        end_line = item.symbol.endLine,
      }
    end,
    on_accept = function(item)
      on_pick(item.symbol.qualified)
    end,
  })
end

local function run(ctx)
  local from, to = ctx.args[1], ctx.args[2]
  if from and to then
    return find(ctx.bufnr, from, to)
  end
  if from then
    return pick(ctx.bufnr, " path to ", function(picked)
      find(ctx.bufnr, from, picked)
    end)
  end
  return pick(ctx.bufnr, " path from ", function(start)
    pick(ctx.bufnr, " path to ", function(finish)
      find(ctx.bufnr, start, finish)
    end)
  end)
end

M.name = "path"
M.summary = "The call chain between two symbols"

M.options = {
  path = { step_ms = 45 },
}

M.commands = {
  { name = "path", desc = "Call path between two symbols", run = run },
}

M.keymaps = {
  { suffix = "p", command = "path", desc = "Epicenter: path between symbols" },
}

M.EDGE_LABEL = EDGE_LABEL

return M
