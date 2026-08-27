local tree = require("epicenter.ui.tree")

local function node(name, children)
  return { name = name, children = children or {} }
end

local OPTS = {
  key_of = function(n)
    return n.name
  end,
  children_of = function(n)
    return n.children
  end,
}

local function names(rows)
  return vim.tbl_map(function(row)
    return ("%s%s"):format(string.rep("  ", row.depth), row.node.name)
  end, rows)
end

describe("tree flatten", function()
  local roots = {
    node("a", { node("a1", { node("a1x") }), node("a2") }),
    node("b"),
  }

  it("shows only the roots when nothing is expanded", function()
    expect.eq(names(tree.flatten(roots, {}, OPTS)), { "a", "b" })
  end)

  it("expands one level at a time", function()
    expect.eq(names(tree.flatten(roots, { a = true }, OPTS)), { "a", "  a1", "  a2", "b" })
    expect.eq(
      names(tree.flatten(roots, { a = true, a1 = true }, OPTS)),
      { "a", "  a1", "    a1x", "  a2", "b" }
    )
  end)

  it("ignores an expanded key that is not visible", function()
    expect.eq(names(tree.flatten(roots, { a1 = true }, OPTS)), { "a", "b" })
  end)

  it("marks leaves as not expandable", function()
    local rows = tree.flatten(roots, { a = true }, OPTS)
    expect.eq(rows[1].expandable, true)
    expect.eq(rows[1].expanded, true)
    expect.eq(rows[3].expandable, false, "a2 has no children")
    expect.eq(rows[4].expandable, false, "b has no children")
  end)

  it("stops at a cycle instead of recursing forever", function()
    local a = node("a")
    local b = node("b")
    a.children = { b }
    b.children = { a }
    local rows = tree.flatten({ a }, { a = true, b = true }, OPTS)
    expect.eq(names(rows), { "a", "  b", "    a" })
    expect.eq(rows[3].recursive, true)
    expect.eq(rows[3].expandable, false, "a recursive node is a leaf")
  end)

  it("handles no roots", function()
    expect.eq(tree.flatten({}, {}, OPTS), {})
  end)
end)

describe("tree object", function()
  local buf, t

  before_each(function()
    require("epicenter.config").reset()
    buf = vim.api.nvim_create_buf(false, true)
    t = tree.new({
      buf = buf,
      height = 10,
      key_of = OPTS.key_of,
      children_of = OPTS.children_of,
      render_row = function(row)
        return { text = string.rep("  ", row.depth) .. row.node.name }
      end,
    })
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("toggles the node under the cursor and keeps the cursor on it", function()
    t:set_roots({ node("a", { node("a1") }), node("b") })
    expect.eq(t.list:count(), 2)
    expect.eq(t:set_open(nil), true)
    expect.eq(t.list:count(), 3)
    expect.eq(t:current().node.name, "a", "the cursor stays on the toggled node")
    t:set_open(nil)
    expect.eq(t.list:count(), 2)
  end)

  it("reports false when the row cannot expand", function()
    t:set_roots({ node("leaf") })
    expect.eq(t:set_open(nil), false)
  end)

  it("can expand the roots up front", function()
    t:set_roots({ node("a", { node("a1") }) }, { expand_roots = true })
    expect.eq(t.list:count(), 2)
  end)
end)
