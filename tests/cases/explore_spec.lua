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

local function node_of(edge)
  return explore.node_of_edge(edge, "root")
end

describe("explorer rows", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("shows the kind, the qualified name and the location", function()
    local rendered = explore.render_row(row(node_of({ symbol = symbol(), degree = 2 })))
    expect.matches(rendered.text, "M%.handle_request")
    expect.matches(rendered.text, "app/server%.lua:9")
  end)

  it("badges a repeated edge, a reference edge and a heuristic edge", function()
    local rendered = explore.render_row(row(node_of({
      symbol = symbol(),
      count = 2,
      kind = "ref",
      heuristic = true,
    })))
    expect.matches(rendered.text, "2x")
    expect.matches(rendered.text, "ref")
    expect.matches(rendered.text, "%?")
  end)

  it("omits the count badge for a single edge", function()
    local rendered = explore.render_row(row(node_of({ symbol = symbol(), count = 1 })))
    expect.falsy(rendered.text:match("1x"))
  end)

  it("marks a node already open further up the branch", function()
    local rendered =
      explore.render_row(row(node_of({ symbol = symbol() }), { recursive = true, depth = 2 }))
    expect.matches(rendered.text, "recursive")
    expect.matches(rendered.text, "^    ", "depth indents the row")
  end)

  it("shows an unresolved call muted, with no location", function()
    local rendered = explore.render_row(row(node_of({ name = "os.getenv", resolved = false })))
    expect.matches(rendered.text, "os%.getenv")
    expect.falsy(rendered.text:match(":%d"))
    expect.eq(rendered.spans[1].hl, "EpicenterMuted")
  end)

  it("groups the unresolved calls under one ~ ext row", function()
    local children = explore.merge_children({ key = "root", children = {} }, {
      { symbol = symbol(), resolved = true, degree = 0 },
      { name = "os.getenv", resolved = false },
      { name = "print", resolved = false },
    })
    expect.eq(#children, 2, "two resolved-or-group rows")
    local group = children[2]
    expect.eq(group.type, "ext")
    expect.eq(#group.children, 2)
    local rendered = explore.render_row(row(group, { expandable = true, expanded = true }))
    expect.matches(rendered.text, "~ ext %(2%)")
  end)

  it("renders the not-yet-fetched child as a quiet placeholder", function()
    local node = node_of({ symbol = symbol(), degree = 3 })
    expect.eq(#node.children, 1, "a node with edges is expandable before it is fetched")
    expect.eq(node.children[1].type, "pending")
    expect.matches(explore.render_row(row(node.children[1])).text, "%.%.%.")
  end)

  it("gives a node with no edges nothing to expand", function()
    expect.eq(#node_of({ symbol = symbol(), degree = 0 }).children, 0)
  end)

  it("keeps an already-loaded subtree across a refresh, and drops what is gone", function()
    local parent = { key = "root", children = {} }
    parent.children = explore.merge_children(parent, {
      { symbol = symbol(), resolved = true, degree = 1 },
      { symbol = symbol({ qualified = "M.start", line = 14 }), resolved = true, degree = 0 },
    })
    local kept = parent.children[1]
    kept.loaded = true
    kept.children = { { key = "grandchild", type = "symbol" } }

    parent.children = explore.merge_children(parent, {
      { symbol = symbol({ endLine = 20 }), resolved = true, degree = 4, count = 3 },
    })
    expect.eq(#parent.children, 1, "M.start is gone")
    expect.eq(parent.children[1], kept, "the surviving node is the same node")
    expect.eq(parent.children[1].children[1].key, "grandchild", "its loaded subtree survives")
    expect.eq(parent.children[1].degree, 4, "but its edge facts are refreshed")
    expect.eq(parent.children[1].edge.count, 3)
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
