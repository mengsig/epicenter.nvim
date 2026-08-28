local model = require("epicenter.features.blast.model")

local function symbol(qualified, file, line, extra)
  return vim.tbl_extend("force", {
    qualified = qualified,
    name = qualified:match("[%w_]+$"),
    kind = "fn",
    file = file,
    line = line,
    endLine = line + 3,
    uri = "file:///proj/" .. file,
  }, extra or {})
end

local function result(entries)
  return {
    nodes = vim.tbl_map(function(entry)
      return {
        symbol = symbol(entry[1], entry[2], entry[3], entry[5]),
        depth = entry[4],
        via = {},
        exact = entry[6] ~= true,
      }
    end, entries),
  }
end

local FIXTURE = result({
  { "M.start", "app/server.lua", 14, 2 },
  { "M.handle_request", "app/server.lua", 9, 1 },
  { "RequestHandler.handle", "app/handlers.py", 2, 1, nil, true },
})

describe("blast model", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("orders nodes by ring, then file, then position", function()
    expect.eq(
      vim.tbl_map(function(node)
        return node.symbol.qualified
      end, model.nodes(FIXTURE)),
      { "RequestHandler.handle", "M.handle_request", "M.start" }
    )
  end)

  it("keeps the shallowest depth when two entries name one symbol", function()
    local nodes = model.nodes(result({
      { "M.start", "app/server.lua", 14, 3 },
      { "M.start", "app/server.lua", 14, 1 },
    }))
    expect.eq(#nodes, 1)
    expect.eq(nodes[1].depth, 1)
  end)

  it("keeps two distinct same-named definitions in one file as two rows (#F5)", function()
    local nodes = model.nodes(result({
      { "M.start", "app/server.lua", 10, 1 },
      { "M.start", "app/server.lua", 20, 1 },
    }))
    expect.eq(#nodes, 2, "two different definitions must not collapse into one")
    local lines = vim.tbl_map(function(node)
      return node.symbol.line
    end, nodes)
    table.sort(lines)
    expect.eq(lines, { 10, 20 })
    -- Keys stay distinct so diff/transition track each independently.
    expect.ne(nodes[1].key, nodes[2].key)
  end)

  it("does not disambiguate by line when only one definition owns a key (#F5)", function()
    -- A single symbol's key must stay line-free so a realtime re-index -
    -- which shifts lines - still reads it as the same node (no key churn).
    local before = model.nodes(result({ { "M.start", "app/server.lua", 14, 1 } }))
    local after = model.nodes(result({ { "M.start", "app/server.lua", 20, 1 } }))
    expect.eq(before[1].key, after[1].key)
    expect.eq(model.diff(before, after), { added = {}, removed = {} })
  end)

  it("survives a result with no nodes at all", function()
    expect.eq(model.nodes(nil), {})
    expect.eq(model.nodes({}), {})
    expect.eq(model.rows({}), {})
    expect.eq(model.empty_summary(), {
      symbols = 0,
      files = 0,
      tests = 0,
      maxDepth = 0,
      truncated = false,
    })
  end)

  it("groups rows into rings, then files, and counts each heading", function()
    local rows = model.rows(model.nodes(FIXTURE))
    expect.eq(
      vim.tbl_map(function(row)
        return row.kind
      end, rows),
      { "ring", "file", "node", "file", "node", "ring", "file", "node" }
    )
    expect.eq(rows[1].depth, 1)
    expect.eq(rows[1].count, 2, "ring 1 holds two symbols across two files")
    expect.eq(rows[2].file, "app/handlers.py")
    expect.eq(rows[4].file, "app/server.lua")
    expect.eq(rows[6].depth, 2)
  end)

  it("leaves counting to the server's summary rather than recounting rows", function()
    expect.eq(model.counts, nil, "the panel reads blast.summary, so there is one source")
  end)

  it("renders a ring heading, a file heading and a row", function()
    local rows = model.rows(model.nodes(FIXTURE))
    expect.eq(model.render_row(rows[1]).text, "  ring 1  2")
    expect.eq(model.render_row(rows[2]).text, "    app/handlers.py")
    expect.matches(
      model.render_row(rows[3]).text,
      "RequestHandler%.handle  app/handlers%.py:2  %?$"
    )
    expect.falsy(model.render_row(rows[5]).text:find("?", 1, true), "an exact edge carries no mark")
  end)

  it("dims a test row and tags it", function()
    local nodes = model.nodes(result({
      { "spec.covers", "tests/server_spec.lua", 4, 1, { test = true } },
    }))
    local row = model.render_row(model.rows(nodes)[3])
    expect.matches(row.text, "test$")
    local name_span = nil
    for _, span in ipairs(row.spans) do
      if row.text:sub(span.from + 1, span.to) == "spec.covers" then
        name_span = span
      end
    end
    expect.eq(name_span.hl, "EpicenterMuted", "a test row is dimmed, not normal weight")
  end)

  it("dims a departing row the same way", function()
    local nodes = model.nodes(result({ { "M.start", "app/server.lua", 14, 1 } }))
    nodes[1].state = "removed"
    local row = model.render_row(model.rows(nodes)[3])
    for _, span in ipairs(row.spans) do
      expect.ne(span.hl, "EpicenterNormal")
    end
  end)

  it("names the root, or the ref for a diff", function()
    expect.matches(
      model.title_line({ kind = "blast", root = symbol("M.start", "app/server.lua", 14) }).text,
      "M%.start  app/server%.lua:14$"
    )
    expect.matches(
      model.title_line({ kind = "diff", ref = "origin/main" }).text,
      "changes vs origin/main$"
    )
    -- F3: with no root the title is the panel's own name. It must NOT guess a
    -- reason - "still loading" and "nothing here" reach here alike, and the
    -- body row is what says which.
    expect.matches(model.title_line({ kind = "blast" }).text, "^  blast radius$")
  end)

  -- F12: at a narrow width, the file elides before the line number does.
  it("elides a long file before the title ever loses its line number", function()
    local root = symbol("OrderService.place", "py_fastapi/app/services/order_service.py", 17)
    local rendered = model.title_line({ kind = "blast", root = root }, 30)
    expect.truthy(vim.fn.strdisplaywidth(rendered.text) <= 30, "fits: " .. rendered.text)
    expect.matches(rendered.text, "…", "the file was elided")
    expect.matches(rendered.text, ":17$", "the line number survives")
  end)

  it("writes the server's summary as chips, with the query mode after them", function()
    local summary = { symbols = 1, files = 1, tests = 0, maxDepth = 1 }
    local state =
      { direction = "callers", tests = "with", strict = false, follow = false, depth = 1 }
    expect.matches(
      model.chips_line(summary, state).text,
      "^  1 symbol · 1 file · 0 tests · depth 1"
    )
    expect.matches(model.chips_line(summary, state).text, "callers · tests with$")

    local loud = model.chips_line(
      vim.tbl_extend("force", summary, { changed = 2, truncated = true }),
      { direction = "callees", tests = "only", strict = true, follow = true, depth = 1 }
    ).text
    expect.matches(loud, "^  2 changed · ")
    expect.matches(loud, "depth 1 · truncated")
    expect.matches(loud, "callees · tests only · strict · follow$")
  end)

  -- F12: the counts are what the panel is FOR, so a width too narrow for
  -- both drops the mode indicator whole rather than truncating it mid-word.
  it("drops the mode indicator rather than truncate it, when the two do not fit", function()
    local summary = { symbols = 1, files = 1, tests = 0, maxDepth = 1 }
    local state =
      { direction = "callers", tests = "with", strict = false, follow = false, depth = 1 }
    local wide = model.chips_line(summary, state, 200).text
    expect.matches(wide, "callers · tests with$", "both parts fit at a generous width")

    local narrow = model.chips_line(summary, state, 20).text
    expect.matches(narrow, "^  1 symbol · 1 file · 0 tests · depth 1$")
    expect.falsy(narrow:find("callers", 1, true), "the mode indicator was dropped, not cut")
  end)

  --- F2: `+` and `-` re-query and repaint. On a graph that is already
  --- exhausted - most symbols bottom out in a ring or two - the answer is
  --- identical, so nothing on screen changed and the keys read as dead. The
  --- chip carries the depth ASKED FOR alongside the depth reached.
  it("names the depth asked for whenever the answer fell short of it", function()
    local state = { direction = "callers", tests = "with", strict = false, follow = false }
    local function chip(reached, asked)
      return model.chips_line(
        { symbols = 1, files = 1, tests = 0, maxDepth = reached },
        vim.tbl_extend("force", state, { depth = asked })
      ).text
    end
    expect.matches(chip(2, 2), "depth 2 ", "no second number when the walk reached it")
    expect.falsy(chip(2, 2):find("of", 1, true))
    expect.matches(chip(2, 3), "depth 2 of 3", "the graph bottomed out short of the ask")
    expect.matches(chip(2, 6), "depth 2 of 6")
    -- A panel with no answer yet must not claim a depth it never asked for.
    expect.matches(chip(0, 2), "depth 0 of 2")
  end)

  it("reports what arrived and what left, in a stable order", function()
    local before = model.nodes(FIXTURE)
    local after = model.nodes(result({
      { "M.handle_request", "app/server.lua", 9, 1 },
      { "M.route", "app/config.lua", 3, 1 },
    }))
    local delta = model.diff(before, after)
    expect.eq(delta.added, { "file:///proj/app/config.lua#M.route" })
    expect.eq(delta.removed, {
      "file:///proj/app/handlers.py#RequestHandler.handle",
      "file:///proj/app/server.lua#M.start",
    })
  end)

  it("keeps departing rows in place while the change plays", function()
    local before = model.nodes(FIXTURE)
    local after = model.nodes(result({
      { "M.handle_request", "app/server.lua", 9, 1 },
      { "M.route", "app/config.lua", 3, 1 },
    }))
    local union = model.transition(before, after)
    local states = {}
    for _, node in ipairs(union) do
      states[node.symbol.qualified] = node.state or "settled"
    end
    expect.eq(states, {
      ["M.route"] = "added",
      ["M.handle_request"] = "settled",
      ["RequestHandler.handle"] = "removed",
      ["M.start"] = "removed",
    })
    expect.eq(union[1].symbol.qualified, "M.route", "the union keeps one total order")
  end)

  it("leaves the inputs untouched when it builds the union", function()
    local before = model.nodes(FIXTURE)
    model.transition(before, {})
    for _, node in ipairs(before) do
      expect.eq(node.state, nil)
    end
  end)

  it("flips direction, cycles the tests scope and clamps depth", function()
    expect.eq(model.flip_direction("callers"), "callees")
    expect.eq(model.flip_direction("callees"), "callers")
    expect.eq(model.cycle_tests("with"), "without")
    expect.eq(model.cycle_tests("without"), "only")
    expect.eq(model.cycle_tests("only"), "with")
    expect.eq(model.clamp_depth(0, 6), 1)
    expect.eq(model.clamp_depth(9, 6), 6)
    expect.eq(model.clamp_depth(3, 6), 3)
  end)

  it("sends the query mode and the target together", function()
    local state = { depth = 2, direction = "callers", tests = "with", strict = false }
    expect.eq(model.params(state, { ref = "HEAD" }), {
      depth = 2,
      direction = "callers",
      tests = "with",
      strict = false,
      ref = "HEAD",
    })
  end)

  it("gives a jump target for a row, and none for a heading", function()
    local rows = model.rows(model.nodes(FIXTURE))
    expect.eq(model.target(rows[1]), nil)
    expect.eq(model.target(rows[3]), {
      path = "/proj/app/handlers.py",
      line = 2,
      end_line = 5,
    })
  end)

  it("finds the first identifier past a doc-comment marker (#D4)", function()
    expect.eq(model.first_identifier_column('        """Return the user, or None."""'), 11)
    expect.eq(model.first_identifier_column("    /// Sum of every row's weight."), 8)
    expect.eq(model.first_identifier_column("    /** Sum of every row. */"), 8)
    expect.eq(model.first_identifier_column("    --- Sum of every row."), 8)
    expect.eq(model.first_identifier_column("    place_order()"), 4, "an ordinary body line")
  end)

  it("finds no identifier on a blank or marker-only line (#D4)", function()
    expect.eq(model.first_identifier_column(""), nil)
    expect.eq(model.first_identifier_column("        "), nil)
    expect.eq(model.first_identifier_column("    ///"), nil)
  end)
end)
