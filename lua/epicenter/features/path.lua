--- The path finder: pick two symbols, get the call chain between them drawn as
--- a vertical ladder. No config requires at file scope - see `epicenter.registry`.
local M = {}

-- Forward-declared: `disambiguate` (below) re-queries through `find`, which
-- is defined after `show` since it is `show`'s only caller.
local find

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
---
--- The contract carries no per-rung edge data (no call/reference kind, no
--- heuristic marker) - `navgraph/path` returns a flat `Symbol[]`, so the
--- connector between two rungs is a plain arrow.
--- @param steps table[] Symbol[]
--- @return { lines: string[], spans: table[], targets: table<integer, table>, reveal: integer[] }
function M.chain_lines(steps)
  local icons = require("epicenter.ui.icons")
  local lines, spans, targets, reveal = { "" }, {}, {}, {}

  for i, symbol in ipairs(steps) do
    if i > 1 then
      local connector = ("  %s  "):format(icons.ui("chain"))
      table.insert(spans, { row = #lines, hl = "EpicenterMuted", from = 0, to = #connector })
      table.insert(lines, connector)
      local arrow = ("  %s"):format(icons.ui("chain_end"))
      table.insert(spans, { row = #lines, hl = "EpicenterAccent", from = 0, to = #arrow })
      table.insert(lines, arrow)
    end

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
  if not vim.api.nvim_buf_is_valid(win.buf) then
    return
  end
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
--- full chain inside this call. Returns the running tween handle (or nil when
--- it already finished synchronously), so the caller can cancel it on close
--- (F10): closing mid-reveal must not let a later frame touch a dead buffer.
local function reveal(win, chain)
  local animate = require("epicenter.ui.animate")
  local easing = require("epicenter.ui.easing")
  local cfg = require("epicenter.config").get()
  local steps = #chain.reveal
  if steps <= 1 then
    paint(win, chain, #chain.lines)
    return nil
  end
  local running = true
  local handle = animate.tween({
    duration = cfg.path.step_ms * steps,
    easing = easing.linear,
    on_frame = function(eased)
      local shown = math.max(1, math.min(steps, math.ceil(eased * steps)))
      paint(win, chain, chain.reveal[shown])
    end,
    on_done = function()
      running = false
      if win:valid() then
        paint(win, chain, #chain.lines)
      end
    end,
  })
  return running and handle or nil
end

--- @param on_close? fun() run once the window is actually gone (F10 hooks the
---   ladder-tween cancel here, at the same moment the buffer dies)
local function open_window(lines, title, footer, on_close)
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
    on_close = on_close,
  })
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      win:close()
    end, { buffer = win.buf, nowait = true, silent = true })
  end
  return win
end

--- A palette listing `{ symbol = Symbol }` items, common ground between a
--- live search (`pick`) and a fixed candidate list (`pick_candidate`).
local function symbol_palette(bufnr, title, opts)
  local icons = require("epicenter.ui.icons")
  local palette = require("epicenter.ui.palette")
  local search = require("epicenter.features.search")
  return palette.open(vim.tbl_extend("force", {
    title = title,
    prompt_prefix = " " .. icons.ui("search") .. " ",
    state = { bufnr = bufnr },
    render_item = search.render_symbol,
    preview_of = function(item)
      return {
        path = vim.uri_to_fname(item.symbol.uri),
        line = item.symbol.line,
        end_line = item.symbol.endLine,
      }
    end,
  }, opts))
end

--- A calm candidate picker for an ambiguous endpoint (F1): the contract sends
--- every same-name definition back rather than running the walk, so this
--- offers them the same way the rest of the plugin finds a symbol - from the
--- fixed candidate list the server already resolved, not a live query.
--- @param candidates table[] Symbol[]
local function pick_candidate(bufnr, title, candidates, on_pick)
  local items = vim.tbl_map(function(symbol)
    return { symbol = symbol }
  end, candidates)
  return symbol_palette(bufnr, title, {
    empty_text = "  no candidates",
    source = function(_, _, cb)
      cb(nil, items, #items)
    end,
    on_accept = function(item)
      on_pick(item.symbol.qualified)
    end,
  })
end

--- `from`/`to` are re-resolved through `find` (bottom of this file) once
--- every ambiguous side has a chosen candidate, so the re-query goes through
--- the exact same path a fresh `:Epicenter path` call would.
local function disambiguate(bufnr, from, to, ambiguous_from, ambiguous_to)
  if #ambiguous_from > 0 then
    return pick_candidate(
      bufnr,
      (" %s is ambiguous - pick one "):format(from),
      ambiguous_from,
      function(picked_from)
        if #ambiguous_to > 0 then
          pick_candidate(
            bufnr,
            (" %s is ambiguous - pick one "):format(to),
            ambiguous_to,
            function(picked_to)
              find(bufnr, picked_from, picked_to)
            end
          )
        else
          find(bufnr, picked_from, to)
        end
      end
    )
  end
  return pick_candidate(
    bufnr,
    (" %s is ambiguous - pick one "):format(to),
    ambiguous_to,
    function(picked_to)
      find(bufnr, from, picked_to)
    end
  )
end

--- @param result { path: table[], ambiguousFrom: table[], ambiguousTo: table[] }
---   `path` is a flat Symbol[], empty when no chain exists; the ambiguous
---   arrays carry same-name candidates the walk was never run against (F1).
local function show(result, from, to, previous_win, bufnr)
  local ambiguous_from = result.ambiguousFrom or {}
  local ambiguous_to = result.ambiguousTo or {}
  if #ambiguous_from > 0 or #ambiguous_to > 0 then
    return disambiguate(bufnr, from, to, ambiguous_from, ambiguous_to)
  end

  local steps = result.path or {}
  if #steps == 0 then
    local lines = { "", ("  no call path from %s to %s"):format(from, to), "" }
    local win = open_window(lines, " path ", " q close ")
    win:set_lines(lines)
    win:reveal()
    return win
  end

  local chain = M.chain_lines(steps)
  local title = (" path: %s -> %s "):format(from, to)
  -- The ladder tween handle lives here so the window's own on_close (fired
  -- exactly when its buffer dies) can cancel it - not a moment sooner.
  local ladder = { handle = nil }
  local win = open_window(chain.lines, title, " <CR> jump · y yank · q close ", function()
    if ladder.handle then
      ladder.handle.cancel()
      ladder.handle = nil
    end
  end)
  win:reveal()
  ladder.handle = reveal(win, chain)

  local function target()
    return chain.targets[vim.api.nvim_win_get_cursor(win.win)[1]]
  end
  vim.keymap.set("n", "<CR>", function()
    local found = target()
    if not found then
      return
    end
    win:close()
    -- Restore focus before the fade completes (F1), same as `ui.panel`: the
    -- scheduled jump must land in the window this was opened from, not the
    -- still-fading float.
    if previous_win and vim.api.nvim_win_is_valid(previous_win) then
      vim.api.nvim_set_current_win(previous_win)
    end
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

function find(bufnr, from, to)
  local client = require("epicenter.client")
  local previous_win = vim.api.nvim_get_current_win()
  local handle = { win = nil }
  client.path({ from = from, to = to }, function(err, result)
    if err then
      require("epicenter").notify(err.message or "navgraph did not answer", "error")
      return
    end
    handle.win = show(result or {}, from, to, previous_win, bufnr)
  end, { bufnr = bufnr, channel = "path" })
  return handle
end

--- Symbol picker built on the search palette, so both ends are chosen the same
--- way the rest of the plugin finds a symbol.
local function pick(bufnr, title, on_pick)
  local client = require("epicenter.client")
  local cfg = require("epicenter.config").get()
  return symbol_palette(bufnr, title, {
    debounce_ms = cfg.search.debounce_ms,
    empty_text = "  no symbols match",
    source = function(query, state, cb)
      client.search({ query = query, limit = cfg.search.limit }, function(err, result)
        if err then
          return cb(err)
        end
        cb(nil, result.items or {}, result.total)
      end, { bufnr = state.bufnr, channel = "path-pick" })
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

M.option_docs = {
  ["path"] = "time each rung of the path ladder takes to draw",
}

M.commands = {
  { name = "path", desc = "Call chain between two symbols", run = run },
}

M.keymaps = {
  { suffix = "p", command = "path", desc = "Epicenter: path between symbols" },
}

return M
