--- Collapsible tree rendered through `ui.list`: flattening is a pure function
--- over the node graph plus an expanded-key set.
local M = {}

local list = require("epicenter.ui.list")

--- Depth-first flatten of `roots` into display rows. Pure.
---
--- A node already on the current path is emitted as a `recursive` leaf rather
--- than followed, so a cyclic call graph cannot hang the UI.
---
--- @param roots any[]
--- @param expanded table<string, boolean>
--- @param opts { key_of: fun(node): string, children_of: fun(node): any[] }
--- @return { node: any, depth: integer, key: string, expandable: boolean, expanded: boolean, recursive: boolean }[]
function M.flatten(roots, expanded, opts)
  local rows = {}
  local on_path = {}

  local function walk(nodes, depth)
    for _, node in ipairs(nodes) do
      local key = opts.key_of(node)
      local children = opts.children_of(node) or {}
      local recursive = on_path[key] == true
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
        on_path[key] = true
        walk(children, depth + 1)
        on_path[key] = nil
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
---   children_of: fun(node): any[], render_row: fun(row, index): { text: string, spans?: table[] },
---   text_of?: fun(row): string }
function M.new(opts)
  local self = setmetatable({
    key_of = opts.key_of,
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
    { key_of = self.key_of, children_of = self.children_of }
  )
end

function Tree:refresh()
  self.list:set_items(self:rows())
end

function Tree:current()
  return self.list:current()
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
