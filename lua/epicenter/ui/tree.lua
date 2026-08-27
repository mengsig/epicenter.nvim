--- Collapsible tree rendered through `ui.list`: flattening is a pure function
--- over the node graph plus an expanded-key set.
local M = {}

local list = require("epicenter.ui.list")

--- Depth-first flatten of `roots` into display rows. Pure.
---
--- A node already on the current path is emitted as a `recursive` leaf rather
--- than followed, so a cyclic call graph cannot hang the UI. Cycle detection
--- runs on `identity_of` (a node's identity - what "the same node" means),
--- separately from `key_of` (a row's identity - what the `expanded` set and
--- the caller's own merge key off): the same node reached through two
--- different parents is two different ROWS, but recursion must still catch
--- the same node re-appearing on its OWN path.
---
--- @param roots any[]
--- @param expanded table<string, boolean>
--- @param opts { key_of: fun(node): string, children_of: fun(node): any[],
---   identity_of?: fun(node): string }
--- @return { node: any, depth: integer, key: string, expandable: boolean, expanded: boolean, recursive: boolean }[]
function M.flatten(roots, expanded, opts)
  local rows = {}
  local on_path = {}
  local identity_of = opts.identity_of or opts.key_of

  local function walk(nodes, depth)
    for _, node in ipairs(nodes) do
      local key = opts.key_of(node)
      local identity = identity_of(node)
      local children = opts.children_of(node) or {}
      local recursive = on_path[identity] == true
      local expandable = #children > 0 and not recursive
      local is_open = expandable and expanded[key] == true
      table.insert(rows, {
        node = node,
        depth = depth,
        key = key,
        expandable = expandable,
        expanded = is_open,
        recursive = recursive,
      })
      if is_open then
        on_path[identity] = true
        walk(children, depth + 1)
        on_path[identity] = nil
      end
    end
  end

  walk(roots, 0)
  return rows
end

--- @class epicenter.Tree
local Tree = {}
Tree.__index = Tree

--- @param opts { buf: integer, height: integer, key_of: fun(node): string,
---   children_of: fun(node): any[], identity_of?: fun(node): string,
---   render_row: fun(row, index): { text: string, spans?: table[] },
---   text_of?: fun(row): string }
function M.new(opts)
  local self = setmetatable({
    key_of = opts.key_of,
    identity_of = opts.identity_of,
    children_of = opts.children_of,
    roots = {},
    expanded = {},
  }, Tree)
  self.list = list.new({
    buf = opts.buf,
    height = opts.height,
    render_item = opts.render_row,
    text_of = opts.text_of,
    empty_text = opts.empty_text,
  })
  return self
end

function Tree:set_roots(roots, opts)
  self.roots = roots or {}
  if opts and opts.expand_roots then
    for _, node in ipairs(self.roots) do
      self.expanded[self.key_of(node)] = true
    end
  end
  self:refresh()
end

function Tree:rows()
  return M.flatten(
    self.roots,
    self.expanded,
    { key_of = self.key_of, identity_of = self.identity_of, children_of = self.children_of }
  )
end

function Tree:refresh()
  self.list:set_items(self:rows())
end

function Tree:current()
  return self.list:current()
end

--- Opens or closes `key` without it being under the cursor: a lazily loaded
--- tree expands the node whose children have just arrived.
--- @param key string
--- @param open boolean
function Tree:set_expanded(key, open)
  self.expanded[key] = open or nil
end

--- @param key string
function Tree:is_expanded(key)
  return self.expanded[key] == true
end

--- @param open boolean|nil nil toggles
function Tree:set_open(open)
  local row = self:current()
  if not row or not row.expandable then
    return false
  end
  local want = open
  if want == nil then
    want = not row.expanded
  end
  self.expanded[row.key] = want or nil
  local index = self.list:index()
  self:refresh()
  self.list:select(index)
  return true
end

M.Tree = Tree

return M
