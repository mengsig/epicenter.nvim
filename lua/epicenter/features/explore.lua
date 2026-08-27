--- The callers / callees explorer: a tree whose children are fetched one level
--- at a time, so opening it costs a single request no matter how big the graph.
--- No config requires at file scope - see `epicenter.registry`.
local M = {}

--- Direction -> the `epicenter.client` helper that answers it.
local METHOD = { callers = "callers", callees = "calls" }

local TESTS_CYCLE = { "with", "without", "only" }

local function next_tests(current)
  for i, value in ipairs(TESTS_CYCLE) do
    if value == current then
      return TESTS_CYCLE[(i % #TESTS_CYCLE) + 1]
    end
  end
  return TESTS_CYCLE[1]
end

local function append(text, spans, chunk, hl)
  if chunk == "" then
    return text
  end
  table.insert(spans, { hl = hl, from = #text, to = #text + #chunk })
  return text .. chunk
end

-- Nodes ------------------------------------------------------------------------

--- Stable across reindexes (no server-assigned ids), and unique per parent so
--- the tree's cycle detection sees the same node as the same key.
local function symbol_key(symbol)
  return ("%s#%s@%d"):format(symbol.uri, symbol.qualified, symbol.line)
end

--- A node with edges it has not fetched yet still needs a chevron, so it
--- carries one placeholder child until `l` replaces it with the real level.
local function seed(node)
  if not node.loaded then
    node.children = node.degree > 0
        and { { type = "pending", key = node.key .. "/...", name = "" } }
      or {}
  end
  return node
end

--- @param edge { symbol?: table, name?: string, resolved?: boolean,
---   heuristic?: boolean, kind?: string, count?: integer, degree?: integer }
local function node_of_edge(edge, parent_key)
  local resolved = edge.resolved ~= false and edge.symbol ~= nil and edge.symbol ~= vim.NIL
  local symbol = resolved and edge.symbol or nil
  return seed({
    type = resolved and "symbol" or "extern",
    key = resolved and symbol_key(symbol) or (parent_key .. "/ext:" .. tostring(edge.name)),
    name = resolved and symbol.qualified or tostring(edge.name),
    symbol = symbol,
    edge = {
      kind = edge.kind or "call",
      count = edge.count or 1,
      heuristic = edge.heuristic == true,
    },
    degree = resolved and (edge.degree or 0) or 0,
    children = {},
    loaded = false,
  })
end

--- Children of `node` for `edges`, keeping already-loaded subtrees whose key
--- still appears (a reindex diffs the rows, it never rebuilds the tree).
--- @param node table
--- @param edges table[]
--- @return table[]
function M.merge_children(node, edges)
  local previous = {}
  for _, child in ipairs(node.children) do
    previous[child.key] = child
    if child.type == "ext" then
      for _, extern in ipairs(child.children) do
        previous[extern.key] = extern
      end
    end
  end

  local resolved, externs = {}, {}
  for _, edge in ipairs(edges) do
    local fresh = node_of_edge(edge, node.key)
    local kept = previous[fresh.key]
    if kept then
      kept.symbol, kept.name, kept.edge, kept.degree =
        fresh.symbol, fresh.name, fresh.edge, fresh.degree
      fresh = seed(kept)
    end
    table.insert(fresh.type == "extern" and externs or resolved, fresh)
  end

  if #externs > 0 then
    local group = previous[node.key .. "/~ext"]
      or { type = "ext", key = node.key .. "/~ext", name = "ext", children = {}, loaded = true }
    group.children = externs
    table.insert(resolved, group)
  end
  return resolved
end

-- Rendering --------------------------------------------------------------------

--- One display row. Pure, so the layout is testable without a server.
--- @param row { node: table, depth: integer, expandable: boolean, expanded: boolean, recursive: boolean }
--- @return { text: string, spans: table[] }
function M.render_row(row)
  local icons = require("epicenter.ui.icons")
  local node, spans = row.node, {}
  local indent = ("  "):rep(row.depth)

  if node.type == "pending" then
    local text = indent .. "   ..."
    return { text = text, spans = { { hl = "EpicenterMuted", from = 0, to = #text } } }
  end

  local chevron = "  "
  if row.expandable then
    chevron = icons.ui(row.expanded and "expanded" or "collapsed") .. " "
  end

  if node.type == "ext" then
    local text = indent .. chevron
    text = append(text, spans, ("~ ext (%d)"):format(#node.children), "EpicenterMuted")
    return { text = text, spans = spans }
  end

  local text = indent .. chevron
  if node.type == "extern" then
    text = append(text, spans, node.name, "EpicenterMuted")
  else
    text = text .. icons.kind(node.symbol.kind) .. " " .. node.name
    text =
      append(text, spans, ("  %s:%d"):format(node.symbol.file, node.symbol.line), "EpicenterMuted")
  end

  local edge = node.edge or {}
  if (edge.count or 0) > 1 then
    text = append(text, spans, ("  %dx"):format(edge.count), "EpicenterCount")
  end
  if edge.kind == "ref" then
    text = append(text, spans, "  ref", "EpicenterMuted")
  end
  if edge.heuristic then
    text = append(text, spans, "  ?", "EpicenterInfo")
  end
  if row.recursive then
    text = append(text, spans, "  recursive", "EpicenterMuted")
  end
  return { text = text, spans = spans }
end

--- Footer: how many rows, and which toggles are on.
function M.footer(view, rows)
  local parts = { ("%d"):format(rows) }
  if view.refs then
    table.insert(parts, "refs")
  end
  if view.strict then
    table.insert(parts, "strict")
  end
  table.insert(parts, "tests: " .. view.tests)
  return (" %s "):format(table.concat(parts, " · "))
end

-- The panel --------------------------------------------------------------------

local function request_params(view, ref)
  local cfg = require("epicenter.config").get()
  local params = {
    depth = 1,
    refs = view.refs,
    strict = view.strict,
    tests = view.tests,
    limit = cfg.explore.limit,
  }
  if type(ref) == "string" then
    params.symbol = ref
  else
    params.uri = ref.uri
    params.position = ref.position
  end
  return params
end

--- One level of edges for `ref`, on a per-node channel so a superseded answer
--- (a fast `l` or a burst of reindexes) is dropped rather than painted.
local function fetch(view, ref, channel, cb)
  local client = require("epicenter.client")
  client[METHOD[view.direction]](request_params(view, ref), cb, {
    bufnr = view.bufnr,
    channel = "explore:" .. view.direction .. ":" .. channel,
  })
end

--- Reference the server resolves back to `node`.
local function ref_of(node)
  return node.symbol.qualified
end

local function expand(view, node)
  if node.pending or node.loaded then
    return
  end
  node.pending = true
  fetch(view, ref_of(node), node.key, function(err, result)
    node.pending = false
    if not view.panel:valid() then
      return
    end
    if err then
      require("epicenter").notify(err.message or "navgraph did not answer", "error")
      seed(node)
      view.panel:refresh_tree()
      return
    end
    node.loaded = true
    node.children = M.merge_children(node, result.edges or {})
    view.tree:set_expanded(node.key, #node.children > 0)
    view.panel:refresh_tree()
    view.panel:set_footer(M.footer(view, view.panel.list:count()))
  end)
end

--- Re-fetches every loaded node that is currently open, so a reindex updates
--- what the user is looking at without collapsing it.
local function refresh_open(view)
  local function walk(node)
    if node.loaded and view.tree:is_expanded(node.key) then
      fetch(view, ref_of(node), node.key, function(err, result)
        if not view.panel:valid() then
          return
        end
        if err then
          -- A background refresh keeps the rows it has; the log carries why.
          require("epicenter.log").warn(
            "explorer refresh failed for %s: %s",
            node.name,
            err.message
          )
          return
        end
        node.children = M.merge_children(node, result.edges or {})
        view.panel:refresh_tree()
      end)
    end
    for _, child in ipairs(node.children) do
      if child.type == "symbol" then
        walk(child)
      end
    end
  end
  if view.root then
    walk(view.root)
  end
end

local function load_root(view, ref)
  fetch(view, ref, "root", function(err, result)
    if not view.panel:valid() then
      return
    end
    if err then
      view.panel:notice("  " .. (err.message or "navgraph did not answer"))
      return
    end
    local root = result.root
    if not root or root == vim.NIL or not root.symbol or root.symbol == vim.NIL then
      view.panel:notice("  no symbol to explore here")
      return
    end
    view.root = {
      type = "symbol",
      key = symbol_key(root.symbol),
      name = root.symbol.qualified,
      symbol = root.symbol,
      degree = root.degree or 0,
      children = {},
      loaded = true,
    }
    view.root.children = M.merge_children(view.root, result.edges or {})
    view.panel:set_roots({ view.root }, { expand_roots = true })
    view.panel:set_title((" %s %s "):format(view.direction, root.symbol.qualified))
    view.panel:set_footer(M.footer(view, view.panel.list:count()))
  end)
end

--- @param direction "callers"|"callees"
local function open(direction, ctx)
  local cfg = require("epicenter.config").get()
  local events = require("epicenter.events")
  local panel_mod = require("epicenter.ui.panel")

  local ref = ctx.args[1]
  if not ref then
    local win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(win)
    ref = {
      uri = vim.uri_from_bufnr(ctx.bufnr),
      position = { line = cursor[1] - 1, character = cursor[2] },
    }
  end

  local view = {
    direction = direction,
    bufnr = ctx.bufnr,
    refs = false,
    strict = false,
    tests = cfg.lsp.init_options.tests,
    root = nil,
  }

  local function reload(self)
    view.root = nil
    self:set_roots({})
    self:set_footer(M.footer(view, 0))
    load_root(view, ref)
  end

  view.panel = panel_mod.open({
    title = (" %s "):format(direction),
    footer = M.footer(view, 0),
    filetype = "epicenter-explore",
    empty_text = "  loading...",
    tree = {
      key_of = function(node)
        return node.key
      end,
      children_of = function(node)
        return node.children
      end,
    },
    render_row = M.render_row,
    text_of = function(row)
      return row.node.name or ""
    end,
    target_of = function(row)
      local symbol = row.node.symbol
      return symbol
          and { path = vim.uri_to_fname(symbol.uri), line = symbol.line, end_line = symbol.endLine }
        or nil
    end,
    keys = {
      l = function(self)
        local row = self:current()
        if not row or row.recursive then
          return
        end
        local node = row.node
        if node.type == "symbol" and not node.loaded and node.degree > 0 then
          expand(view, node)
        end
        -- Opens now, so the placeholder shows while the level is in flight.
        self.tree:set_open(true)
        self:draw()
      end,
      h = function(self)
        self.tree:set_open(false)
        self:draw()
      end,
      r = function(self)
        view.refs = not view.refs
        reload(self)
      end,
      s = function(self)
        view.strict = not view.strict
        reload(self)
      end,
      t = function(self)
        view.tests = next_tests(view.tests)
        reload(self)
      end,
    },
    on_close = function()
      if view.unsubscribe then
        view.unsubscribe()
        view.unsubscribe = nil
      end
    end,
  })

  view.tree = view.panel.tree
  view.unsubscribe = events.on(events.INDEXED, function()
    if view.panel:valid() then
      refresh_open(view)
    end
  end)

  load_root(view, ref)
  return view.panel
end

M.name = "explore"
M.summary = "Who calls this symbol, and what it calls, one level at a time"

M.options = {
  explore = { limit = 100 },
}

M.commands = {
  {
    name = "callers",
    desc = "Who calls the symbol under the cursor",
    run = function(ctx)
      return open("callers", ctx)
    end,
  },
  {
    name = "callees",
    desc = "What the symbol under the cursor calls",
    run = function(ctx)
      return open("callees", ctx)
    end,
  },
}

M.keymaps = {
  { suffix = "c", command = "callers", desc = "Epicenter: callers" },
  { suffix = "C", command = "callees", desc = "Epicenter: callees" },
}

M.node_of_edge = node_of_edge
M.next_tests = next_tests

return M
