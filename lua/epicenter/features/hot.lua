--- Fan-in hot spots, symbols nothing reaches, and the graph export.
--- No config requires at file scope - see `epicenter.registry`.
local M = {}

local function target_of(symbol)
  return { path = vim.uri_to_fname(symbol.uri), line = symbol.line, end_line = symbol.endLine }
end

--- Row for a hot spot: the symbol, its location, and a bar scaled to the
--- busiest symbol in the list. Pure.
--- @param item { symbol: table, fanIn?: integer }
--- @param max integer the largest fan-in in the same list
function M.render_hot(item, max, width)
  local icons = require("epicenter.ui.icons")
  local toast = require("epicenter.ui.toast")
  local symbol, spans = item.symbol, {}
  local count = item.fanIn or 0

  local head = (" %s %s"):format(icons.kind(symbol.kind), symbol.qualified)
  local location = ("  %s:%d"):format(symbol.file, symbol.line)
  table.insert(spans, { hl = "EpicenterMuted", from = #head, to = #head + #location })

  local bar = "  "
    .. toast.bar(
      max > 0 and count / max or 0,
      width,
      icons.ui("progress_full"),
      icons.ui("progress_empty")
    )
  local at = #head + #location
  table.insert(spans, { hl = "EpicenterAccent", from = at, to = at + #bar })
  local tail = (" %d"):format(count)
  table.insert(spans, { hl = "EpicenterCount", from = at + #bar, to = at + #bar + #tail })

  return { text = head .. location .. bar .. tail, spans = spans }
end

--- Row for an unused symbol. Pure.
function M.render_unused(symbol)
  local icons = require("epicenter.ui.icons")
  local head = (" %s %s"):format(icons.kind(symbol.kind), symbol.qualified)
  local location = ("  %s:%d"):format(symbol.file, symbol.line)
  return {
    text = head .. location,
    spans = { { hl = "EpicenterMuted", from = #head, to = #head + #location } },
  }
end

--- Hot spots in the order the panel actually presents them: by `fanIn`
--- descending, the number each row prints and each bar is scaled to.
---
--- The contract ranks by connectivity, which is `fanInExact` and more besides
--- - a real answer put a 7 last, below four rows of 2, 1, 1, 1, so the bar
--- chart read as broken and "ranked by fan-in" was untrue (F9). Ranking here
--- rather than dropping the claim keeps the number, the bar and the order the
--- same story. Stable: ties keep the server's own tie-break. Pure.
--- @param items { fanIn?: integer }[]
--- @return table[] a new list
function M.rank(items)
  local decorated = {}
  for index, item in ipairs(items or {}) do
    table.insert(decorated, { item = item, index = index })
  end
  table.sort(decorated, function(a, b)
    local left, right = a.item.fanIn or 0, b.item.fanIn or 0
    if left ~= right then
      return left > right
    end
    return a.index < b.index
  end)
  return vim.tbl_map(function(entry)
    return entry.item
  end, decorated)
end

--- Widest bar in a hot-spots list - `M.rank`'s first row, found by scanning so
--- an unranked list still scales correctly rather than flattening every row
--- above `items[1]` to full.
--- @param items { fanIn: integer }[]
--- @return integer
function M.bar_scale(items)
  local max = 0
  for _, item in ipairs(items or {}) do
    max = math.max(max, item.fanIn or 0)
  end
  return max
end

local function open_hot(ctx)
  local cfg = require("epicenter.config").get()
  local client = require("epicenter.client")
  local panel_mod = require("epicenter.ui.panel")
  local root_mod = require("epicenter.root")

  local root = root_mod.find(ctx.bufnr)
  local path = ctx.args[1] or root_mod.relative(ctx.bufnr, root)
  local view = { path = path, max = 0 }
  view.scope = view.path and "buffer" or "repo"

  local function load()
    client.hot({
      path = view.scope == "buffer" and view.path or nil,
      limit = cfg.hot.limit,
    }, function(err, result)
      if not view.panel:valid() then
        return
      end
      if err then
        view.panel:notice("  " .. (err.message or "navgraph did not answer"))
        return
      end
      local items = M.rank(result.items)
      view.max = M.bar_scale(items)
      view.panel:set_items(items, { stagger = true })
      view.panel:set_footer((" %d · %s "):format(#items, view.scope))
    end, { bufnr = ctx.bufnr, channel = "hot" })
  end

  view.panel = panel_mod.open({
    title = " hot spots ",
    footer = (" 0 · %s "):format(view.scope),
    filetype = "epicenter-hot",
    empty_text = "  nothing depends on anything here",
    render_row = function(item)
      return M.render_hot(item, view.max, cfg.hot.bar_width)
    end,
    text_of = function(item)
      return item.symbol.qualified
    end,
    target_of = function(item)
      return target_of(item.symbol)
    end,
    hints = { b = "toggle buffer/repo scope" },
    keys = {
      b = function()
        if not view.path then
          require("epicenter").notify("this buffer is not a file - repo scope only")
          return
        end
        view.scope = view.scope == "buffer" and "repo" or "buffer"
        load()
      end,
    },
  })

  load()
  return view.panel
end

local function open_unused(ctx)
  local cfg = require("epicenter.config").get()
  local client = require("epicenter.client")
  local panel_mod = require("epicenter.ui.panel")

  local view = { no_public = false }

  local function load()
    client.unused({ noPublic = view.no_public, limit = cfg.unused.limit }, function(err, result)
      if not view.panel:valid() then
        return
      end
      if err then
        view.panel:notice("  " .. (err.message or "navgraph did not answer"))
        return
      end
      view.panel:set_items(result.items or {}, { stagger = true })
      view.panel:set_footer(
        (" %d%s "):format(view.panel.list:count(), view.no_public and " · no public" or "")
      )
    end, { bufnr = ctx.bufnr, channel = "unused" })
  end

  view.panel = panel_mod.open({
    title = " unused ",
    footer = " 0 ",
    filetype = "epicenter-unused",
    empty_text = "  everything here is reached",
    -- Items are {symbol, testOnly} (F5): rendering and jumping key off .symbol.
    render_row = function(item)
      return M.render_unused(item.symbol)
    end,
    text_of = function(item)
      return item.symbol.qualified
    end,
    target_of = function(item)
      return target_of(item.symbol)
    end,
    hints = { p = "hide public symbols" },
    keys = {
      p = function()
        view.no_public = not view.no_public
        load()
      end,
    },
  })

  if ctx.args[1] then
    view.panel:set_filter(ctx.args[1])
  end
  load()
  return view.panel
end

--- The toast for a graph export. Names the truncation honestly when the
--- renderer's own node cap capped the view, rather than reporting flat
--- success on a partial graph (F2). Pure, so it is testable without a server.
--- @param result { truncated: boolean, nodes?: integer, nodesTotal?: integer }
--- @return string message, string? level
function M.graph_message(absolute, result)
  local message = "graph written to " .. vim.fn.fnamemodify(absolute, ":~")
  if not result.truncated then
    return message, nil
  end
  return ("%s (%d of %d nodes shown)"):format(message, result.nodes or 0, result.nodesTotal or 0),
    "warn"
end

local function export_graph(ctx)
  local root_mod = require("epicenter.root")
  local progress = require("epicenter.ui.toast").progress("exporting the graph")
  local root = root_mod.find(ctx.bufnr)
  -- {path} is a FILTER over which subgraph to draw - the server always
  -- chooses the output path (F6); never treat this as somewhere to write.
  require("epicenter.client").graph({ path = ctx.args[1] }, function(err, result)
    if err or not result or not result.path then
      progress.finish(err and err.message or "navgraph returned no file", "error")
      return
    end
    -- `path` comes back root-relative, per contract.
    local absolute = vim.fs.joinpath(root, result.path)
    progress.finish(M.graph_message(absolute, result))
    vim.ui.open(absolute)
  end, { bufnr = ctx.bufnr, channel = "graph" })
end

M.name = "hot"
M.summary = "Fan-in hot spots, unreached symbols, and the graph export"

M.options = {
  hot = { limit = 30, bar_width = 12 },
  unused = { limit = 200 },
}

M.commands = {
  { name = "hot", desc = "Most depended-on symbols, ranked by fan-in", run = open_hot },
  { name = "unused", desc = "Symbols nothing in the index reaches", run = open_unused },
  { name = "graph", desc = "Write the call graph to a file and open it", run = export_graph },
}

M.keymaps = {
  { suffix = "h", command = "hot", desc = "Epicenter: hot spots" },
}

return M
