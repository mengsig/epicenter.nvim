--- Cursor-to-symbol resolution against the REAL binary, and the fake lane's
--- fidelity to it (merge-gate F10/F11).
---
--- navgraph resolves the identifier UNDER THE COLUMN and nothing off one, so
--- a target aimed at column 0 of an indented definition is the one column
--- that can never work. A developer's cursor is inside a body essentially all
--- the time, so both cases below drive `<leader>ee` from a body line - the
--- real key, the real server, the two languages with the most indentation in
--- this fixture.
local epicenter = require("epicenter")
local fake_graph = require("fakelib.graph")
local fake_index = require("fakelib.index")
local support = require("support")

local PY = "py_fastapi/app/services/order_service.py"
local ZIG = "zig_tool/report.zig"

local function names(panel)
  return vim.tbl_map(function(node)
    return node.symbol.qualified
  end, panel.nodes)
end

describe("real navgraph: resolving what the cursor points at", function()
  local root, panel

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_real()
  end)

  after_each(function()
    if panel then
      panel:close()
      panel = nil
    end
  end)

  --- Opens `relative` with the cursor at (line, column) and presses the
  --- plugin's own blast key, rather than calling the command behind it.
  local function blast_at(relative, line, column)
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
    vim.api.nvim_win_set_cursor(0, { line, column })
    local leader = vim.g.mapleader or "\\"
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(leader .. "ee", true, false, true),
      "x",
      false
    )
    local opened = require("epicenter.features.blast.panel").current()
    assert(opened, "<leader>ee opened no panel")
    wait(function()
      return opened.answered > 0
    end, 20000, "the blast panel to answer")
    return opened
  end

  it("blasts from inside an indented Python function body", function()
    -- `        order = Order(order_id, ...)`, inside OrderService.place and
    -- on no definition's own name.
    panel = blast_at(PY, 25, 8)
    expect.eq(panel.message, nil, "the panel answered rather than refusing")
    expect.eq(panel.meta.root.qualified, "OrderService.place")
    expect.truthy(
      vim.tbl_contains(names(panel), "place_order"),
      "the real callers are missing: " .. vim.inspect(names(panel))
    )
  end)

  it("blasts from the leading indentation of that same body line", function()
    -- Column 0 of an indented line is where `<CR>` from any picker parks the
    -- cursor, and where the server resolves nothing at all.
    panel = blast_at(PY, 25, 0)
    expect.eq(panel.message, nil, "the panel answered rather than refusing")
    expect.eq(panel.meta.root.qualified, "OrderService.place")
  end)

  it("blasts from inside an indented Zig function body", function()
    -- `            sum += row.weight;`, inside Report.total.
    panel = blast_at(ZIG, 31, 12)
    expect.eq(panel.message, nil, "the panel answered rather than refusing")
    expect.eq(panel.meta.root.qualified, "Report.total")
    expect.truthy(
      vim.tbl_contains(names(panel), "summarize"),
      "the real caller is missing: " .. vim.inspect(names(panel))
    )
  end)

  it("blasts from the leading indentation of that same Zig body line", function()
    panel = blast_at(ZIG, 31, 0)
    expect.eq(panel.message, nil, "the panel answered rather than refusing")
    expect.eq(panel.meta.root.qualified, "Report.total")
  end)

  it("still refuses where the real server genuinely resolves nothing", function()
    -- A blank line inside the class body: no identifier anywhere on it.
    panel = blast_at(PY, 30, 0)
    expect.eq(panel.meta.root, nil)
    expect.matches(panel.message or "", "no symbol under the cursor")
  end)
end)

--- The divergence the two-lane design exists to catch: the fake used to
--- resolve a Target by LINE alone, so a position the real server answers with
--- `-32001` resolved perfectly offline and every blast spec passed while the
--- feature was broken against the binary. This runs the same targets through
--- both and requires the same answer.
describe("real navgraph: the fake resolves a Target the same way", function()
  local root, index

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ lsp = { auto_start = false } })
    root = root or support.start_real()
    -- The fake's own index over the SAME tree (its scanners read .py/.lua).
    index = index or fake_index.build(root)
  end)

  --- What the real server resolves a cursor target to: a qualified name, or
  --- nil when it answers TARGET_NOT_FOUND.
  local function real_target(relative, line, character)
    local uri = vim.uri_from_fname(vim.fs.joinpath(root, relative))
    local err, result = support.request(root, "navgraph/blast", {
      uri = uri,
      position = { line = line, character = character },
      depth = 1,
    })
    if err then
      expect.eq(err.code, -32001, "unexpected error: " .. vim.inspect(err))
      return nil
    end
    return result.roots[1] and result.roots[1].qualified or nil
  end

  local function fake_target(relative, line, character)
    local found = fake_graph.targets(index, {
      uri = vim.uri_from_fname(vim.fs.joinpath(root, relative)),
      position = { line = line, character = character },
    }, function()
      return relative
    end)
    return found[1] and found[1].qualified or nil
  end

  it("agrees on every column of a real body line, resolved and unresolved", function()
    -- 0-based (line, character) over order_service.py, each with the reason
    -- the column is interesting.
    local cases = {
      { 16, 0, "the leading indentation of a definition line" },
      { 16, 4, "a keyword (`async`), not a name" },
      { 16, 14, "the definition's own name (`place`)" },
      { 22, 8, "a local's name (`owner`)" },
      { 22, 30, "a called method (`_resolve_owner`)" },
      { 24, 0, "the leading indentation of a body line" },
      { 24, 8, "a local's name (`order`)" },
      { 26, 17, "a called method (`_append_line`)" },
    }
    local mismatches = {}
    for _, case in ipairs(cases) do
      local line, character, why = case[1], case[2], case[3]
      local real, fake = real_target(PY, line, character), fake_target(PY, line, character)
      if real ~= fake then
        table.insert(
          mismatches,
          ("%d:%d (%s) real=%s fake=%s"):format(
            line,
            character,
            why,
            tostring(real),
            tostring(fake)
          )
        )
      end
    end
    expect.eq(mismatches, {}, "the fake diverged from the real server")
  end)

  it("agrees that a whitespace column resolves nothing", function()
    expect.eq(real_target(PY, 24, 0), nil)
    expect.eq(fake_target(PY, 24, 0), nil)
  end)
end)
