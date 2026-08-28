--- Call hierarchy and type hierarchy, on the standard LSP methods the v1.1
--- protocol adds - so any editor benefits, and this plugin gets both trees for
--- the price of the panel it already has.
---
--- Both are lazy trees on `ui.panel`: one request opens the panel, `l` asks
--- for the next level. No config requires at file scope - see
--- `epicenter.registry`.
local M = {}

--- LSP `SymbolKind` back to the contract's kind names, so a hierarchy row
--- carries the same glyph every other panel gives that definition.
local KIND_NAME = {
  [5] = "class",
  [6] = "method",
  [8] = "field",
  [10] = "enum",
  [11] = "interface",
  [12] = "fn",
  [13] = "var",
  [14] = "const",
  [23] = "struct",
}

--- Direction -> the client helper answering it, and the key the answer's
--- entries carry the item under.
local CALL_METHOD = {
  incoming = { helper = "incoming_calls", key = "from" },
  outgoing = { helper = "outgoing_calls", key = "to" },
}

--- The three groups a type hierarchy shows, in the order they are drawn, and
--- how a node inside each expands.
local TYPE_GROUPS = {
  { key = "supertypes", label = "supertypes", helper = "supertypes" },
  { key = "subtypes", label = "subtypes", helper = "subtypes" },
  -- Implementors are locations, not hierarchy items: nothing to expand.
  { key = "implementors", label = "implementors", helper = nil },
}

--- The notice line a panel shows when this buffer's server predates the
--- method - two leading spaces, as every other panel notice has.
--- @return string|nil
local function unsupported(bufnr, method, what)
  local reason = require("epicenter.client").unsupported_reason(bufnr, method, what)
  return reason and ("  " .. reason) or nil
end

-- Nodes --------------------------------------------------------------------------

--- A hierarchy item's global identity: the definition it names, not the path
--- that reached it. `ui.tree` keys cycle detection off this, so the same
--- definition re-appearing on its own branch stops instead of looping.
--- @param item table a `CallHierarchyItem`/`TypeHierarchyItem`
--- @return string
function M.identity_of(item)
  return ("%s#%s@%d"):format(item.uri, item.data.qualified, item.range.start.line)
end

--- @param item table
--- @param parent_key string
--- @param opts { sites?: integer, expandable?: boolean }
local function node_of_item(item, parent_key, opts)
  local identity = M.identity_of(item)
  local node = {
    type = "item",
    key = parent_key .. "/" .. identity,
    identity = identity,
    name = item.data.qualified,
    item = item,
    sites = opts.sites or 0,
    exact = item.data.exact ~= false,
    children = {},
    loaded = not opts.expandable,
  }
  if opts.expandable then
    -- A hierarchy item carries no degree, so every node keeps a chevron until
    -- its own level has actually been asked for.
    node.children = { { type = "pending", key = node.key .. "/...", name = "" } }
  end
  return node
end

local function node_of_group(group, parent_key, items, helper)
  local key = parent_key .. "/~" .. group
  local children = {}
  for _, item in ipairs(items) do
    table.insert(children, node_of_item(item, key, { expandable = helper ~= nil }))
  end
  return {
    type = "group",
    key = key,
    identity = key,
    name = group,
    helper = helper,
    children = children,
    loaded = true,
  }
end

--- One display row. Pure, so the layout is testable without a server.
--- @param row { node: table, depth: integer, expandable: boolean, expanded: boolean, recursive: boolean }
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

  local function append(text, chunk, hl)
    if chunk == "" then
      return text
    end
    table.insert(spans, { hl = hl, from = #text, to = #text + #chunk })
    return text .. chunk
  end

  if node.type == "group" then
    local text = indent .. chevron
    return {
      text = append(text, ("%s (%d)"):format(node.name, #node.children), "EpicenterTitle"),
      spans = spans,
    }
  end

  local item = node.item
  local text = indent .. chevron .. icons.kind(KIND_NAME[item.kind]) .. " " .. node.name
  text =
    append(text, ("  %s:%d"):format(item.data.file, item.range.start.line + 1), "EpicenterMuted")
  if node.sites > 1 then
    text = append(text, ("  %dx"):format(node.sites), "EpicenterCount")
  end
  if not node.exact then
    text = append(text, "  ?", "EpicenterInfo")
  end
  if row.recursive then
    text = append(text, "  recursive", "EpicenterMuted")
  end
  return { text = text, spans = spans }
end

local function target_of(row)
  local item = row.node.item
  if not item then
    return nil
  end
  return {
    path = vim.uri_to_fname(item.uri),
    line = item.range.start.line + 1,
    end_line = item.range["end"].line + 1,
  }
end

local function tree_spec()
  return {
    key_of = function(node)
      return node.key
    end,
    identity_of = function(node)
      return node.identity or node.key
    end,
    children_of = function(node)
      return node.children
    end,
  }
end

--- The `{ textDocument, position }` a prepare request takes.
local function prepare_params(bufnr)
  local blast = require("epicenter.features.blast")
  local target = blast.cursor_target(bufnr)
  return { textDocument = { uri = target.uri }, position = target.position }
end

-- Call hierarchy -----------------------------------------------------------------

local function fetch_calls(view, item, channel, cb)
  local method = CALL_METHOD[view.direction]
  require("epicenter.client")[method.helper]({ item = item }, cb, {
    bufnr = view.bufnr,
    channel = ("hierarchy:%s:%s"):format(view.direction, channel),
  })
end

local function calls_to_nodes(view, entries, parent_key)
  local key = CALL_METHOD[view.direction].key
  local nodes = {}
  for _, entry in ipairs(entries or {}) do
    table.insert(
      nodes,
      node_of_item(entry[key], parent_key, { sites = #(entry.fromRanges or {}), expandable = true })
    )
  end
  return nodes
end

local function expand_call(view, node)
  if node.pending or node.loaded then
    return
  end
  node.pending = true
  fetch_calls(view, node.item, node.key, function(err, entries)
    node.pending = false
    if not view.panel:valid() then
      return
    end
    if err then
      require("epicenter").notify(err.message or "navgraph did not answer", "error")
      return
    end
    node.loaded = true
    node.children = calls_to_nodes(view, entries, node.key)
    view.tree:set_expanded(node.key, #node.children > 0)
    view.panel:refresh_tree()
    view.panel:set_footer(M.footer(view))
  end)
end

function M.footer(view)
  return (" %d · %s · d flip · l/h expand "):format(view.panel.list:count(), view.direction)
end

local function load_call_root(view)
  local client = require("epicenter.client")
  local reason = unsupported(view.bufnr, "textDocument/prepareCallHierarchy", "call hierarchy")
  if reason then
    return view.panel:notice(reason)
  end

  client.prepare_call_hierarchy(prepare_params(view.bufnr), function(err, items)
    if not view.panel:valid() then
      return
    end
    if err then
      return view.panel:notice("  " .. (err.message or "navgraph did not answer"))
    end
    local item = items and items[1]
    if not item then
      return view.panel:notice("  no symbol under the cursor")
    end
    view.item = item
    fetch_calls(view, item, "root", function(call_err, entries)
      if not view.panel:valid() then
        return
      end
      if call_err then
        return view.panel:notice("  " .. (call_err.message or "navgraph did not answer"))
      end
      local root = node_of_item(item, "", { expandable = false })
      root.children = calls_to_nodes(view, entries, root.key)
      view.root = root
      view.panel:set_roots({ root }, { expand_roots = true })
      view.panel:set_title((" %s calls · %s "):format(view.direction, item.data.qualified))
      view.panel:set_footer(M.footer(view))
    end)
  end, { bufnr = view.bufnr, channel = "hierarchy:prepare" })
end

local function open_call_hierarchy(ctx)
  local panel_mod = require("epicenter.ui.panel")
  local direction = ctx.args[1] == "outgoing" and "outgoing" or "incoming"
  local view = { bufnr = ctx.bufnr, direction = direction }

  view.panel = panel_mod.open({
    title = " call hierarchy ",
    footer = " loading... ",
    filetype = "epicenter-hierarchy",
    empty_text = "  loading...",
    tree = tree_spec(),
    render_row = M.render_row,
    text_of = function(row)
      return row.node.name or ""
    end,
    target_of = target_of,
    hints = { l = "expand", h = "collapse", d = "flip incoming/outgoing" },
    keys = {
      l = function(self)
        local row = self:current()
        if not row or row.recursive then
          return
        end
        if row.node.type == "item" and not row.node.loaded then
          expand_call(view, row.node)
        end
        self.tree:set_open(true)
        self:draw()
      end,
      h = function(self)
        self.tree:set_open(false)
        self:draw()
      end,
      d = function(self)
        view.direction = view.direction == "incoming" and "outgoing" or "incoming"
        self:set_roots({})
        self:set_footer(" loading... ")
        load_call_root(view)
      end,
    },
  })

  view.tree = view.panel.tree
  load_call_root(view)
  return view.panel
end

-- Type hierarchy -----------------------------------------------------------------

local function expand_type(view, node, helper)
  if node.pending or node.loaded then
    return
  end
  node.pending = true
  require("epicenter.client")[helper]({ item = node.item }, function(err, items)
    node.pending = false
    if not view.panel:valid() then
      return
    end
    if err then
      require("epicenter").notify(err.message or "navgraph did not answer", "error")
      return
    end
    node.loaded = true
    node.children = {}
    for _, item in ipairs(items or {}) do
      table.insert(node.children, node_of_item(item, node.key, { expandable = true }))
    end
    view.tree:set_expanded(node.key, #node.children > 0)
    view.panel:refresh_tree()
  end, { bufnr = view.bufnr, channel = "types:" .. node.key })
end

--- The helper that expands a node, found from the group it sits under: a
--- supertype expands upward, a subtype downward, an implementor not at all.
local function helper_for(key)
  for _, group in ipairs(TYPE_GROUPS) do
    if key:find("/~" .. group.label, 1, true) then
      return group.helper
    end
  end
  return nil
end

--- Implementors come back as `Location[]`, not items - enough to jump to, so
--- they are shown as leaves rather than dropped.
local function implementor_nodes(locations, parent_key)
  local nodes = {}
  for _, location in ipairs(locations or {}) do
    local file = vim.fn.fnamemodify(vim.uri_to_fname(location.uri), ":t")
    local item = {
      name = file,
      kind = 5,
      uri = location.uri,
      range = location.range,
      selectionRange = location.range,
      data = {
        id = 0,
        qualified = file,
        file = vim.fn.fnamemodify(vim.uri_to_fname(location.uri), ":~:."),
      },
    }
    table.insert(nodes, node_of_item(item, parent_key, { expandable = false }))
  end
  return nodes
end

--- Asks for all three groups and paints once they have all answered, so the
--- panel never grows a group at a time under the cursor.
local function load_type_root(view, item)
  local client = require("epicenter.client")
  local answers, pending = {}, 3

  local function settle()
    pending = pending - 1
    if pending > 0 or not view.panel:valid() then
      return
    end
    local root = node_of_item(item, "", { expandable = false })
    for _, group in ipairs(TYPE_GROUPS) do
      local items = answers[group.key] or {}
      local children = group.key == "implementors"
          and implementor_nodes(items, root.key .. "/~" .. group.label)
        or nil
      local node = children
          and {
            type = "group",
            key = root.key .. "/~" .. group.label,
            identity = root.key .. "/~" .. group.label,
            name = group.label,
            children = children,
            loaded = true,
          }
        or node_of_group(group.label, root.key, items, group.helper)
      table.insert(root.children, node)
    end
    view.root = root
    -- A group that has an answer opens with it: three closed folders would
    -- hide the whole point of the panel.
    for _, node in ipairs(root.children) do
      view.tree:set_expanded(node.key, #node.children > 0)
    end
    view.panel:set_roots({ root }, { expand_roots = true })
    view.panel:set_title((" types · %s "):format(item.data.qualified))
    view.panel:set_footer((" %d · l/h expand "):format(view.panel.list:count()))
  end

  local function ask(helper, key, params, channel)
    client[helper](params, function(err, result)
      answers[key] = (not err) and result or {}
      settle()
    end, { bufnr = view.bufnr, channel = "types:" .. channel })
  end

  ask("supertypes", "supertypes", { item = item }, "supertypes")
  ask("subtypes", "subtypes", { item = item }, "subtypes")
  ask("implementation", "implementors", prepare_params(view.bufnr), "implementors")
end

local function open_type_hierarchy(ctx)
  local client = require("epicenter.client")
  local panel_mod = require("epicenter.ui.panel")
  local view = { bufnr = ctx.bufnr }

  view.panel = panel_mod.open({
    title = " types ",
    footer = " loading... ",
    filetype = "epicenter-types",
    empty_text = "  loading...",
    tree = tree_spec(),
    render_row = M.render_row,
    text_of = function(row)
      return row.node.name or ""
    end,
    target_of = target_of,
    hints = { l = "expand", h = "collapse" },
    keys = {
      l = function(self)
        local row = self:current()
        if not row or row.recursive then
          return
        end
        local helper = row.node.type == "item" and helper_for(row.node.key) or nil
        if helper and not row.node.loaded then
          expand_type(view, row.node, helper)
        end
        self.tree:set_open(true)
        self:draw()
      end,
      h = function(self)
        self.tree:set_open(false)
        self:draw()
      end,
    },
  })
  view.tree = view.panel.tree

  local reason = unsupported(ctx.bufnr, "textDocument/prepareTypeHierarchy", "type hierarchy")
  if reason then
    view.panel:notice(reason)
    return view.panel
  end

  client.prepare_type_hierarchy(prepare_params(ctx.bufnr), function(err, items)
    if not view.panel:valid() then
      return
    end
    if err then
      return view.panel:notice("  " .. (err.message or "navgraph did not answer"))
    end
    local item = items and items[1]
    if not item then
      return view.panel:notice("  no type under the cursor")
    end
    load_type_root(view, item)
  end, { bufnr = ctx.bufnr, channel = "types:prepare" })

  return view.panel
end

M.name = "hierarchy"
M.summary = "Call hierarchy and type hierarchy, on the standard LSP methods"

M.commands = {
  {
    name = "hierarchy",
    desc = "Call hierarchy at the cursor",
    run = open_call_hierarchy,
    rows = true,
    complete = function(lead)
      return vim.tbl_filter(function(value)
        return vim.startswith(value, lead)
      end, { "incoming", "outgoing" })
    end,
  },
  {
    name = "types",
    desc = "Supertypes, subtypes and implementors",
    run = open_type_hierarchy,
    rows = true,
  },
}

M.keymaps = {
  { suffix = "H", command = "hierarchy", desc = "Epicenter: call hierarchy" },
  { suffix = "T", command = "types", desc = "Epicenter: type hierarchy" },
}

M.TYPE_GROUPS = TYPE_GROUPS
M.KIND_NAME = KIND_NAME

return M
