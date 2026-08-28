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

--- Stable across reindexes (no server-assigned ids). This is a symbol's
--- IDENTITY - the same symbol reached through two different callers must
--- resolve to the same identity, so the tree's cycle detection (F9) sees a
--- real recursive path instead of a phantom one.
local function symbol_key(symbol)
  return ("%s#%s@%d"):format(symbol.uri, symbol.qualified, symbol.line)
end

--- A node with more to fetch still needs a chevron, so it carries one
--- placeholder child until `l` replaces it with the real level.
local function seed(node)
  if not node.loaded then
    node.children = node.degree > 0
        and { { type = "pending", key = node.key .. "/...", name = "" } }
      or {}
  end
  return node
end

--- Fan-in/out (per direction) decides expandability before the level is
--- fetched: the contract carries no other "does this have edges" signal.
local function degree_of(view, symbol)
  return view.direction == "callees" and (symbol.callees or 0) or (symbol.callers or 0)
end

--- A row's identity is the symbol's global identity; its KEY is scoped by the
--- path that reached it, so the same symbol under two different parents is
--- two different rows (F9) - `ui.tree` uses `identity` only for cycle
--- detection and `key` for everything else (the `expanded` set, merge, seed).
--- @param child { symbol: table, exact: boolean, lines: integer[], ext: string[], recursion: boolean }
local function node_of_child(view, child, parent_key)
  local symbol = child.symbol
  local identity = symbol_key(symbol)
  return seed({
    type = "symbol",
    key = parent_key .. "/" .. identity,
    identity = identity,
    name = symbol.qualified,
    symbol = symbol,
    exact = child.exact ~= false,
    lines = child.lines or {},
    ext = child.ext or {},
    server_recursion = child.recursion == true,
    degree = degree_of(view, symbol),
    children = {},
    loaded = false,
  })
end

local function node_of_extern(name, parent_key)
  local key = parent_key .. "/ext:" .. tostring(name)
  return {
    type = "extern",
    key = key,
    identity = key,
    name = tostring(name),
    children = {},
    loaded = true,
  }
end

--- Children of `node` for a fetched `root_node` (the contract's `Node`):
--- its resolved `children` plus a `~ext` group for its own `ext` names.
--- Keeps already-loaded subtrees whose key still appears (a reindex diffs
--- the rows, it never rebuilds the tree).
--- @param view table
--- @param node table
--- @param root_node { children: table[], ext: string[] }
--- @return table[]
function M.merge_children(view, node, root_node)
  local previous = {}
  for _, child in ipairs(node.children) do
    previous[child.key] = child
    if child.type == "ext" then
      for _, extern in ipairs(child.children) do
        previous[extern.key] = extern
      end
    end
  end

  local resolved = {}
  for _, child in ipairs(root_node.children or {}) do
    local fresh = node_of_child(view, child, node.key)
    local kept = previous[fresh.key]
    if kept then
      kept.symbol, kept.exact, kept.lines, kept.ext, kept.server_recursion, kept.degree =
        fresh.symbol, fresh.exact, fresh.lines, fresh.ext, fresh.server_recursion, fresh.degree
      fresh = seed(kept)
    end
    table.insert(resolved, fresh)
  end

  local ext_names = root_node.ext or {}
  if #ext_names > 0 then
    local group_key = node.key .. "/~ext"
    local group = previous[group_key]
      or {
        type = "ext",
        key = group_key,
        identity = group_key,
        name = "ext",
        children = {},
        loaded = true,
      }
    local externs = {}
    for _, name in ipairs(ext_names) do
      local fresh = node_of_extern(name, node.key)
      table.insert(externs, previous[fresh.key] or fresh)
    end
    group.children = externs
    table.insert(resolved, group)
  end
  return resolved
end

-- Rendering --------------------------------------------------------------------

local function is_recursive(row)
  return row.recursive or row.node.server_recursion == true
end

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

  local count = #(node.lines or {})
  if count > 1 then
    text = append(text, spans, ("  %dx"):format(count), "EpicenterCount")
  end
  if node.exact == false then
    text = append(text, spans, "  ?", "EpicenterInfo")
  end
  if is_recursive(row) then
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
  return (" %s · l/h expand · r/s/t toggle "):format(table.concat(parts, " · "))
end

-- The panel --------------------------------------------------------------------

local function request_params(view, ref)
  local params = {
    depth = 1,
    refs = view.refs,
    strict = view.strict,
    tests = view.tests,
  }
  if type(ref) == "string" then
    params.symbol = ref
  else
    params.uri = ref.uri
    params.position = ref.position
  end
  return params
end

--- One level for `ref`, on a per-node channel so a superseded answer (a fast
--- `l` or a burst of reindexes) is dropped rather than painted.
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

--- A missing/nil `root` reads as "nothing here" - never invents a shape.
local function empty_root()
  return { children = {}, ext = {} }
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
    node.children = M.merge_children(view, node, result.root or empty_root())
    view.tree:set_expanded(node.key, #node.children > 0)
    view.panel:refresh_tree()
    view.panel:set_footer(M.footer(view, view.panel.list:count()))
  end)
end

--- Re-fetches every loaded, currently-expanded node in one pass, repainting
--- once the whole batch lands rather than after each fetch (F11): a burst of
--- reindexes is itself coalesced by the caller's debounce.
local function refresh_open(view)
  local pending = 0
  local function settle()
    pending = pending - 1
    if pending == 0 and view.panel:valid() then
      view.panel:refresh_tree()
    end
  end

  local function walk(node)
    if node.loaded and view.tree:is_expanded(node.key) then
      pending = pending + 1
      fetch(view, ref_of(node), node.key, function(err, result)
        if not view.panel:valid() then
          pending = pending - 1
          return
        end
        if err then
          -- A background refresh keeps the rows it has; the log carries why.
          require("epicenter.log").warn(
            "explorer refresh failed for %s: %s",
            node.name,
            err.message
          )
          settle()
          return
        end
        node.children = M.merge_children(view, node, result.root or empty_root())
        settle()
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
    local root_node = result.root
    if
      not root_node
      or root_node == vim.NIL
      or not root_node.symbol
      or root_node.symbol == vim.NIL
    then
      view.panel:notice("  no symbol to explore here")
      return
    end
    local symbol = root_node.symbol
    view.root = {
      type = "symbol",
      key = symbol_key(symbol),
      identity = symbol_key(symbol),
      name = symbol.qualified,
      symbol = symbol,
      degree = degree_of(view, symbol),
      children = {},
      loaded = true,
    }
    view.root.children = M.merge_children(view, view.root, root_node)
    view.panel:set_roots({ view.root }, { expand_roots = true })
    view.panel:set_title((" %s %s "):format(view.direction, symbol.qualified))
    view.panel:set_footer(M.footer(view, view.panel.list:count()))
  end)
end

--- @param direction "callers"|"callees"
local function open(direction, ctx)
  local cfg = require("epicenter.config").get()
  local events = require("epicenter.events")
  local panel_mod = require("epicenter.ui.panel")

  -- Shared with the blast panel and the hover card, so all three aim a cursor
  -- target at the same column (F10).
  local ref = ctx.args[1] or require("epicenter.features.blast").cursor_target(ctx.bufnr)

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
      identity_of = function(node)
        return node.identity or node.key
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
    hints = { l = "expand", h = "collapse", r = "refs", s = "strict", t = "tests" },
    keys = {
      l = function(self)
        local row = self:current()
        if not row or is_recursive(row) then
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
      if view.refresh_debounce then
        view.refresh_debounce.close()
        view.refresh_debounce = nil
      end
    end,
  })

  view.tree = view.panel.tree
  view.refresh_debounce = require("epicenter.ui.prompt").debounce(
    cfg.explore.debounce_ms,
    function()
      if view.panel:valid() then
        refresh_open(view)
      end
    end
  )
  view.unsubscribe = events.on(events.INDEXED, function()
    if view.panel:valid() then
      view.refresh_debounce.call()
    end
  end)

  load_root(view, ref)
  return view.panel
end

M.name = "explore"
M.summary = "Who calls this symbol, and what it calls, one level at a time"

M.options = {
  explore = { debounce_ms = 100 },
}

M.option_docs = {
  ["explore"] = "quiet time after a reindex before rows refetch",
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

M.node_of_child = node_of_child
M.next_tests = next_tests

return M
