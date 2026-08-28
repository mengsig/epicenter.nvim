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

  it(
    "cycle detection uses identity_of, not key_of, so a diamond is not a false cycle (F9)",
    function()
      -- Two distinct ROWS (different keys, e.g. path-scoped) for the same
      -- underlying node (same identity) must not trip recursion detection just
      -- because they share one identity - only a real cycle on one path does.
      local leaf1 = { name = "leaf", identity = "leaf", children = {} }
      local leaf2 = { name = "leaf", identity = "leaf", children = {} }
      local diamond = {
        node("root", { node("alpha", { leaf1 }), node("beta", { leaf2 }) }),
      }
      local opts = {
        key_of = function(n)
          return n.name
        end,
        identity_of = function(n)
          return n.identity or n.name
        end,
        children_of = OPTS.children_of,
      }
      local rows = tree.flatten(diamond, { root = true, alpha = true, beta = true }, opts)
      local leaves = vim.tbl_filter(function(r)
        return r.node.identity == "leaf"
      end, rows)
      expect.eq(#leaves, 2, "both rows render")
      expect.eq(
        leaves[1].recursive,
        false,
        "reaching the same identity via two parents is not a cycle"
      )
      expect.eq(leaves[2].recursive, false)
    end
  )

  it("without identity_of, cycle detection falls back to key_of unchanged", function()
    local a = node("a")
    local b = node("b")
    a.children = { b }
    b.children = { a }
    local rows = tree.flatten({ a }, { a = true, b = true }, OPTS)
    expect.eq(rows[3].recursive, true)
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

  it("keeps a <Tab> mark across an expand, and drops it on a new result set", function()
    t:set_roots({ node("a", { node("a1"), node("a2") }), node("b") })
    t.list:select(2)
    expect.eq(t.list:toggle_mark(), true)
    expect.eq(#t.list:marked_or_all(), 1, "one row marked")

    -- Expanding re-flattens every row into a fresh table.
    t.list:select(1)
    t:set_open(true)
    expect.eq(t.list:count(), 4)
    expect.eq(#t.list:marked_or_all(), 1, "the mark is still on the row it was put on")
    expect.eq(t.list:marked_or_all()[1].node.name, "b")

    t:set_roots({ node("x"), node("y") })
    expect.eq(#t.list:marked_or_all(), 2, "a genuinely fresh result set starts unmarked")
  end)
end)
