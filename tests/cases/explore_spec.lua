local explore = require("epicenter.features.explore")
local support = require("support")

local function symbol(over)
  return vim.tbl_extend("force", {
    qualified = "M.handle_request",
    name = "handle_request",
    kind = "method",
    file = "app/server.lua",
    uri = "file:///proj/app/server.lua",
    line = 9,
    endLine = 13,
    callers = 2,
    callees = 0,
  }, over or {})
end

local function row(node, over)
  return vim.tbl_extend("force", {
    node = node,
    depth = 0,
    expandable = false,
    expanded = false,
    recursive = false,
  }, over or {})
end

local CALLERS = { direction = "callers" }

--- @param child { symbol: table, exact?: boolean, lines?: integer[], ext?: string[], recursion?: boolean }
local function node_of(child, view)
  return explore.node_of_child(view or CALLERS, child, "root")
end

describe("explorer rows", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("shows the kind, the qualified name and the location", function()
    local rendered =
      explore.render_row(row(node_of({ symbol = symbol(), exact = true, lines = { 9 } })))
    expect.matches(rendered.text, "M%.handle_request")
    expect.matches(rendered.text, "app/server%.lua:9")
  end)

  it("badges a repeated edge and a heuristic edge", function()
    local rendered = explore.render_row(row(node_of({
      symbol = symbol(),
      exact = false,
      lines = { 9, 10 },
    })))
    expect.matches(rendered.text, "2x")
    expect.matches(rendered.text, "%?")
  end)

  it("omits the count badge for a single edge", function()
    local rendered =
      explore.render_row(row(node_of({ symbol = symbol(), exact = true, lines = { 9 } })))
    expect.falsy(rendered.text:match("1x"))
  end)

  it("marks a node already open further up the branch", function()
    local rendered = explore.render_row(
      row(node_of({ symbol = symbol(), exact = true, lines = {} }), { recursive = true, depth = 2 })
    )
    expect.matches(rendered.text, "recursive")
    expect.matches(rendered.text, "^    ", "depth indents the row")
  end)

  it("marks a node the server itself flagged recursive", function()
    local rendered = explore.render_row(
      row(node_of({ symbol = symbol(), exact = true, lines = {}, recursion = true }))
    )
    expect.matches(rendered.text, "recursive")
  end)

  it("groups the unresolved calls under one ~ ext row, muted, with no location", function()
    local children = explore.merge_children(CALLERS, { key = "root", children = {} }, {
      children = { { symbol = symbol(), exact = true, lines = { 9 } } },
      ext = { "os.getenv", "print" },
    })
    expect.eq(#children, 2, "one resolved row plus the ext group")
    local group = children[2]
    expect.eq(group.type, "ext")
    expect.eq(#group.children, 2)
    local rendered = explore.render_row(row(group, { expandable = true, expanded = true }))
    expect.matches(rendered.text, "~ ext %(2%)")

    local extern = explore.render_row(row(group.children[1]))
    expect.matches(extern.text, "os%.getenv")
    expect.falsy(extern.text:match(":%d"))
    expect.eq(extern.spans[1].hl, "EpicenterMuted")
  end)

  it("renders the not-yet-fetched child as a quiet placeholder", function()
    local node = node_of({ symbol = symbol({ callers = 3 }), exact = true, lines = { 9 } })
    expect.eq(#node.children, 1, "a node with edges is expandable before it is fetched")
    expect.eq(node.children[1].type, "pending")
    expect.matches(explore.render_row(row(node.children[1])).text, "%.%.%.")
  end)

  it("gives a node with no edges nothing to expand", function()
    expect.eq(#node_of({ symbol = symbol({ callers = 0 }), exact = true, lines = {} }).children, 0)
  end)

  it("keeps an already-loaded subtree across a refresh, and drops what is gone", function()
    local parent = { key = "root", children = {} }
    parent.children = explore.merge_children(CALLERS, parent, {
      children = {
        { symbol = symbol({ callers = 1 }), exact = true, lines = { 9 } },
        {
          symbol = symbol({ qualified = "M.start", name = "start", line = 14, callers = 0 }),
          exact = true,
          lines = { 15 },
        },
      },
      ext = {},
    })
    local kept = parent.children[1]
    kept.loaded = true
    kept.children = { { key = "grandchild", type = "symbol" } }

    parent.children = explore.merge_children(CALLERS, parent, {
      children = {
        { symbol = symbol({ endLine = 20, callers = 4 }), exact = true, lines = { 9, 10, 11 } },
      },
      ext = {},
    })
    expect.eq(#parent.children, 1, "M.start is gone")
    expect.eq(parent.children[1], kept, "the surviving node is the same node")
    expect.eq(parent.children[1].children[1].key, "grandchild", "its loaded subtree survives")
    expect.eq(parent.children[1].degree, 4, "but its edge facts are refreshed")
    expect.eq(#parent.children[1].lines, 3)
  end)

  it("scopes the row key to the path, not just the symbol (F9)", function()
    local leaf = symbol({ qualified = "leaf", name = "leaf", line = 5 })
    local under_alpha =
      explore.node_of_child(CALLERS, { symbol = leaf, exact = true, lines = { 1 } }, "root/alpha")
    local under_beta =
      explore.node_of_child(CALLERS, { symbol = leaf, exact = true, lines = { 1 } }, "root/beta")
    expect.truthy(
      under_alpha.key ~= under_beta.key,
      "distinct rows for the same symbol under two parents"
    )
    expect.eq(under_alpha.identity, under_beta.identity, "but the same symbol identity")
  end)

  it("a diamond does not auto-expand the same symbol under a second parent (F9)", function()
    local leaf = symbol({ qualified = "leaf", name = "leaf", line = 5, callers = 2 })
    local alpha_sym = symbol({ qualified = "alpha", name = "alpha", line = 10, callers = 1 })
    local beta_sym = symbol({ qualified = "beta", name = "beta", line = 15, callers = 1 })

    local root = { key = "root", identity = "root", children = {} }
    root.children = explore.merge_children(CALLERS, root, {
      children = {
        { symbol = alpha_sym, exact = true, lines = { 1 } },
        { symbol = beta_sym, exact = true, lines = { 2 } },
      },
      ext = {},
    })
    local alpha, beta = root.children[1], root.children[2]

    alpha.loaded = true
    alpha.children = explore.merge_children(CALLERS, alpha, {
      children = { { symbol = leaf, exact = true, lines = { 1 } } },
      ext = {},
    })
    beta.loaded = true
    beta.children = explore.merge_children(CALLERS, beta, {
      children = { { symbol = leaf, exact = true, lines = { 1 } } },
      ext = {},
    })
    local leaf_under_alpha, leaf_under_beta = alpha.children[1], beta.children[1]
    expect.truthy(leaf_under_alpha.key ~= leaf_under_beta.key)

    -- Expand leaf under alpha only.
    leaf_under_alpha.loaded = true
    leaf_under_alpha.children = { { key = "grandchild", type = "symbol", children = {} } }

    local tree = require("epicenter.ui.tree")
    local opts = {
      key_of = function(n)
        return n.key
      end,
      identity_of = function(n)
        return n.identity
      end,
      children_of = function(n)
        return n.children
      end,
    }
    local expanded =
      { [root.key] = true, [alpha.key] = true, [leaf_under_alpha.key] = true, [beta.key] = true }
    local flat = tree.flatten({ root }, expanded, opts)

    local beta_leaf_row
    for _, r in ipairs(flat) do
      if r.key == leaf_under_beta.key then
        beta_leaf_row = r
      end
    end
    expect.truthy(beta_leaf_row, "the row still renders")
    expect.eq(
      beta_leaf_row.expanded,
      false,
      "opening leaf under alpha does not open it under beta too"
    )
    expect.eq(
      beta_leaf_row.node.type,
      "symbol",
      "beta's copy is a real fetched node, not a stuck placeholder"
    )
    expect.eq(beta_leaf_row.node.symbol.qualified, "leaf")
  end)

  it("cycles the test scope and reports the toggles in the footer", function()
    expect.eq(explore.next_tests("with"), "without")
    expect.eq(explore.next_tests("without"), "only")
    expect.eq(explore.next_tests("only"), "with")
    expect.matches(explore.footer({ refs = true, strict = true, tests = "only" }, 7), "7")
    expect.matches(explore.footer({ refs = true, strict = true, tests = "only" }, 7), "refs")
    expect.matches(explore.footer({ refs = true, strict = true, tests = "only" }, 7), "strict")
    expect.matches(
      explore.footer({ refs = false, strict = false, tests = "only" }, 7),
      "tests: only"
    )
  end)

  it("declares both directions and their keymaps", function()
    expect.eq(
      vim.tbl_map(function(c)
        return c.name
      end, explore.commands),
      { "callers", "callees" }
    )
    expect.eq(
      vim.tbl_map(function(k)
        return k.suffix
      end, explore.keymaps),
      { "c", "C" }
    )
  end)
end)

describe("explorer against the fake navgraph server", function()
  local root, buf, panel

  local function press(lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel.win.buf, "n")) do
      if map.lhs == lhs and map.callback then
        return map.callback()
      end
    end
    error("no mapping for " .. lhs)
  end

  local function rows()
    return vim.api.nvim_buf_get_lines(panel.win.buf, 0, -1, false)
  end

  local function wait_row(at, pattern, label)
    wait(function()
      local line = rows()[at]
      return line ~= nil and line:match(pattern) ~= nil
    end, 10000, label)
    return rows()
  end

  local function wait_rows(count, label)
    wait(function()
      return panel.list:count() == count
    end, 10000, label)
    return rows()
  end

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.events").clear()
  end)

  it("roots the tree at the named symbol and lists its callers", function()
    panel = require("epicenter").run("callers", { "log_request" }, buf)
    local lines = wait_rows(2, "callers of log_request")
    expect.matches(lines[1], "log_request")
    expect.matches(lines[2], "M%.handle_request")
    expect.matches(lines[2], "app/server%.lua:9")
    expect.matches(lines[2], "^  >", "a row with more to fetch shows it before you ask")
  end)

  it("roots the tree at the symbol under the cursor", function()
    vim.api.nvim_win_set_cursor(0, { 15, 5 })
    panel = require("epicenter").run("callers", {}, buf)
    wait(function()
      return panel.list:count() > 0 and panel:current().node.name == "M.handle_request"
    end, 10000, "cursor-rooted tree")
  end)

  it("fetches the next level only when the row is expanded", function()
    panel = require("epicenter").run("callers", { "log_request" }, buf)
    wait_rows(2, "first level")
    panel.list:select(2)
    press("l")
    local lines = wait_row(3, "M%.start", "second level")
    expect.matches(lines[3], "2x", "M.start calls it twice")

    press("h")
    expect.eq(panel.list:count(), 2, "collapsing hides the fetched level again")
  end)

  it("marks a trailing-name resolution heuristic and strict mode drops it", function()
    panel = require("epicenter").run("callees", { "M.handle_request" }, buf)
    local lines = wait_rows(3, "callees")
    local heuristic = vim.tbl_filter(function(line)
      return line:match("%?") ~= nil
    end, lines)
    expect.eq(#heuristic, 1, "M.route resolves by trailing name only")
    expect.matches(heuristic[1], "M%.route")

    press("s")
    local strict = wait_rows(2, "strict callees")
    expect.matches(strict[2], "log_request")
  end)

  it("narrows to test symbols and comes back empty rather than erroring", function()
    panel = require("epicenter").run("callees", { "M.handle_request" }, buf)
    wait_rows(3, "callees")
    press("t")
    press("t")
    wait_rows(1, "tests-only callees")
    expect.matches(rows()[1], "M%.handle_request", "the root stays, it just has no edges")
  end)

  it("coalesces a burst of reindexes into one debounced pass (F11)", function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      animate = false,
      explore = { debounce_ms = 250 },
    })
    panel = require("epicenter").run("callers", { "log_request" }, buf)
    wait_rows(2, "first level")
    panel.list:select(2)
    press("l")
    wait_row(3, "M%.start", "second level")

    local client = require("epicenter.client")
    local calls, original = 0, client.callers
    client.callers = function(...)
      calls = calls + 1
      return original(...)
    end

    local ok = pcall(function()
      for _ = 1, 5 do
        support.request(root, "navgraph/rescan", {})
      end
      wait(function()
        return calls == 2
      end, 10000, "one settled pass for the 2 expanded rows, not one pass per reindex")
      -- Confirm it stays at 2: a bug that fires per-reindex would keep growing.
      vim.wait(500)
      expect.eq(calls, 2)
    end)
    client.callers = original
    assert(ok)
  end)

  it("refreshes the open rows when the index changes, without collapsing", function()
    panel = require("epicenter").run("callers", { "log_request" }, buf)
    wait_rows(2, "first level")
    panel.list:select(2)
    press("l")
    wait_row(3, "M%.start", "second level")

    support.request(root, "navgraph/rescan", {})
    wait(function()
      return panel.list:count() == 3 and rows()[3]:match("M%.start") ~= nil
    end, 10000, "tree still open after the reindex")
  end)
end)
