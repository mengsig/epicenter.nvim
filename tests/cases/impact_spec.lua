--- The ambient impact surface: the approval store and the review grouping
--- (pure), then the marks, the panel and the gate end to end against the
--- fake server.
local support = require("support")
local epicenter = require("epicenter")
local approvals = require("epicenter.features.impact.approvals")
local impact = require("epicenter.features.impact")
local marks = require("epicenter.features.impact.marks")
local review = require("epicenter.features.impact.review")

local function symbol(over)
  return vim.tbl_extend("force", {
    id = 1,
    name = "handle",
    qualified = "M.handle",
    kind = "fn",
    file = "app/server.lua",
    uri = "file:///proj/app/server.lua",
    line = 9,
    endLine = 12,
    sig = "function M.handle()",
    language = "lua",
    callers = 1,
    callees = 1,
    exported = true,
    test = false,
    contentHash = "aaaa1111",
  }, over or {})
end

--- Two hunks, each reaching one caller, plus one node nothing reaches.
local function answer()
  return {
    roots = { symbol({ id = 1 }), symbol({ id = 2, qualified = "M.other", file = "app/b.lua" }) },
    nodes = {
      {
        symbol = symbol({ id = 3, qualified = "M.caller_a" }),
        depth = 1,
        via = { 3 },
        exact = true,
        contentHash = "cccc",
      },
      {
        symbol = symbol({ id = 4, qualified = "M.caller_b", file = "app/b.lua" }),
        depth = 1,
        via = { 4 },
        exact = false,
        contentHash = "dddd",
      },
      {
        symbol = symbol({ id = 5, qualified = "M.stray" }),
        depth = 2,
        via = {},
        exact = true,
        contentHash = "eeee",
      },
    },
    edges = {
      { from = 3, to = 1, exact = true, lines = { 4 } },
      { from = 4, to = 2, exact = false, lines = { 7 } },
    },
    summary = {
      symbols = 3,
      files = 2,
      tests = 0,
      maxDepth = 2,
      truncated = false,
      byDepth = { 2, 1 },
      byFile = {},
    },
    changeId = "change0001",
    truncated = false,
    hunks = {
      {
        uri = "file:///proj/app/server.lua",
        range = { start = { line = 8, character = 0 }, ["end"] = { line = 11, character = 0 } },
        roots = { symbol({ id = 1 }) },
      },
      {
        uri = "file:///proj/app/b.lua",
        range = { start = { line = 2, character = 0 }, ["end"] = { line = 5, character = 0 } },
        roots = { symbol({ id = 2, qualified = "M.other", file = "app/b.lua" }) },
      },
    },
  }
end

describe("impact approvals", function()
  it("keys an entry on the definition and the hash of its source", function()
    expect.eq(approvals.key(symbol()), "M.handle@app/server.lua#aaaa1111")
    local hashless = symbol()
    hashless.contentHash = nil
    expect.eq(approvals.key(hashless), nil, "no hash, nothing to key on")
  end)

  it("keeps an approval while that definition's source is unchanged", function()
    local state = { entries = {}, changes = {}, change_id = "change0001" }
    approvals.set(state, symbol(), true)
    expect.truthy(approvals.approved(state, symbol()))
    expect.falsy(
      approvals.approved(state, symbol({ contentHash = "bbbb2222" })),
      "editing that definition brings it back unreviewed"
    )
  end)

  it("does not carry an approval over to a change nobody has reviewed", function()
    local state = { entries = {}, changes = {}, change_id = "change0001" }
    approvals.set(state, symbol(), true)
    -- Same impacted definition, untouched - but the working change is new.
    state.change_id = "change0002"
    expect.falsy(
      approvals.approved(state, symbol()),
      "an approval given for one change says nothing about the next"
    )
    state.change_id = "change0001"
    expect.truthy(approvals.approved(state, symbol()), "undoing the edit restores the tick")
  end)

  it("forgets entries older than the changes it keeps", function()
    local state = { entries = {}, changes = {} }
    for i = 1, 10 do
      state.change_id = "change" .. i
      approvals.set(state, symbol({ contentHash = "hash" .. i }), true)
      state = vim.tbl_extend("force", approvals.prune(state, state.change_id), {
        change_id = state.change_id,
      })
    end
    expect.eq(#state.changes, 8, "the change ring is bounded")
    expect.falsy(approvals.approved(state, symbol({ contentHash = "hash1" })))
    expect.truthy(approvals.approved(state, symbol({ contentHash = "hash10" })))
  end)

  it("a no-op `u` on a row nobody approved does not record a revoke (L1)", function()
    local state = { entries = {}, changes = {}, change_id = "change0001" }
    local changed = approvals.set(state, symbol(), false)
    expect.falsy(changed, "there was nothing to undo")
    expect.falsy(state.revoked and state.revoked[approvals.key(symbol())])
  end)

  it(
    "a stray `u` on an unapproved row does not poison another instance's later real approval (L1)",
    function()
      local dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, "p")
      require("epicenter.store").set_root(dir)
      local root = vim.fs.joinpath(dir, "project")
      vim.fn.mkdir(root, "p")

      -- Instance A never approved this row. It presses `u` on it by mistake
      -- (a real no-op) - the poison, if any, sits unsaved in memory: `u`'s
      -- own approve() returns early on `not changed` and never saves.
      local a = approvals.load(root, "change1")
      local a_changed = approvals.set(a, symbol({ contentHash = "h1" }), false)
      expect.falsy(a_changed, "nothing to undo")

      -- Instance B approves that same row for real and saves it.
      local b = approvals.load(root, "change1")
      expect.truthy(approvals.set(b, symbol({ contentHash = "h1" }), true))
      expect.truthy(approvals.save(root, b))

      -- A's own later, unrelated save (e.g. approving a different row) must
      -- not carry a poisoned revoke for the row it never touched.
      expect.truthy(approvals.set(a, symbol({ contentHash = "h2" }), true))
      expect.truthy(approvals.save(root, a))

      local reloaded = approvals.load(root, "change1")
      expect.truthy(
        approvals.approved(reloaded, symbol({ contentHash = "h1" })),
        "B's real approval must survive A's earlier no-op `u`"
      )

      require("epicenter.store").set_root(nil)
    end
  )
end)

describe("the impact review model", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("groups each impacted definition under the hunk that reaches it", function()
    local groups = review.group_by_hunk(answer(), "callers")
    expect.matches(groups[1].label, "app/server%.lua:9$")
    expect.eq(groups[1].nodes[1].symbol.qualified, "M.caller_a")
    expect.eq(groups[2].nodes[1].symbol.qualified, "M.caller_b")
  end)

  it("reports a node no edge reaches rather than dropping it", function()
    local groups = review.group_by_hunk(answer(), "callers")
    local last = groups[#groups]
    expect.eq(last.label, "elsewhere")
    expect.eq(last.nodes[1].symbol.qualified, "M.stray")
  end)

  it("counts what has been reviewed", function()
    local groups = review.group_by_hunk(answer(), "callers")
    local state = { entries = {}, changes = {}, change_id = "change0001" }
    expect.eq({ review.counts(groups, state) }, { 0, 3 })
    approvals.set(state, groups[1].nodes[1].symbol, true)
    expect.eq({ review.counts(groups, state) }, { 1, 3 })
  end)

  it("exports a markdown checklist with the ticked rows ticked", function()
    local groups = review.group_by_hunk(answer(), "callers")
    local state = { entries = {}, changes = {}, change_id = "change0001" }
    approvals.set(state, groups[1].nodes[1].symbol, true)
    local text = review.checklist(groups, state)
    expect.matches(text, "## impact · 1/3 reviewed")
    expect.matches(text, "### .*app/server%.lua:9")
    expect.matches(text, "%- %[x%] `M%.caller_a`")
    expect.matches(text, "%- %[ %] `M%.caller_b`.*%?", "a heuristic edge is marked")
  end)

  it("marks a reviewed row, and a heuristic one", function()
    local groups = review.group_by_hunk(answer(), "callers")
    local state = { entries = {}, changes = {}, change_id = "change0001" }
    local row = {
      node = { type = "impacted", name = "M.caller_b", node = groups[2].nodes[1] },
      depth = 1,
      expanded = false,
    }
    expect.matches(review.render_row(row, state).text, "%?")
    approvals.set(state, groups[2].nodes[1].symbol, true)
    expect.matches(review.render_row(row, state).text, "%+", "the ascii ok glyph")
  end)
end)

describe("the inline marker", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, impact = { marker = "hit" } })
  end)

  it("names the marker word and the hunk it came from", function()
    expect.eq(
      marks.note({ depth = 1, label = "app/server.lua:9", approved = false }),
      "! hit · app/server.lua:9"
    )
  end)

  it("turns into a check once reviewed", function()
    expect.matches(marks.note({ depth = 1, label = "x", approved = true }), "^%+ reviewed")
  end)
end)

describe("inline marks on a real buffer", function()
  local dir, path, bufnr

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, impact = { marker = "hit" } })
    dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    path = vim.fs.joinpath(dir, "s.lua")
    vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3", "target()" }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    bufnr = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    marks.clear()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.bo[bufnr].modified = false
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    bufnr = nil
    vim.fn.delete(dir, "rf")
  end)

  local function marked_line(target)
    local all = vim.api.nvim_buf_get_extmarks(target, marks.namespace, 0, -1, {})
    return all[1] and (all[1][2] + 1) or nil
  end

  it("keeps a mark on the code it was placed on, repaint included", function()
    marks.apply({ { path = path, line = 4, depth = 1, label = "x", approved = false } })
    expect.eq(marked_line(bufnr), 4)

    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "-- one", "-- two", "-- three" })
    expect.eq(marked_line(bufnr), 7, "the extmark follows the buffer's own edit")

    -- BufWinEnter fires on every window switch, and used to re-place every
    -- mark from the line numbers the last answer named.
    vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = bufnr })
    expect.eq(marked_line(bufnr), 7, "a repaint must not snap it back")
    expect.matches(marks.mark_at(bufnr, 7).text, "hit")

    -- A fresh answer for the same line does the same: an approval repaints.
    marks.apply({ { path = path, line = 4, depth = 1, label = "x", approved = true } })
    expect.eq(marked_line(bufnr), 7)
    expect.matches(marks.mark_at(bufnr, 7).text, "reviewed")
  end)

  it("paints when the server names the file through a symlinked path", function()
    local link = vim.fs.normalize(vim.fn.tempname())
    local ok = vim.uv.fs_symlink(dir, link)
    if not ok then
      return skip("this platform would not make a symlink")
    end
    -- A server rooted at the alias sends paths through it; Neovim's buffer
    -- name is the resolved one. Same file, two spellings.
    marks.apply({
      { path = vim.fs.joinpath(link, "s.lua"), line = 4, depth = 1, label = "x", approved = false },
    })
    expect.truthy(marks.mark_at(bufnr, 4) ~= nil, "the alias resolves to the same file")
    vim.fn.delete(link)
  end)
end)

describe("impact against the fake navgraph server", function()
  local root, edited, watched, panel, state_dir

  local function body(target)
    local target_buf = target.surface and target.surface.buf or target.win.buf
    return table.concat(vim.api.nvim_buf_get_lines(target_buf, 0, -1, false), "\n")
  end

  --- Loads a file. `attach` also opens it on the server, which is what puts
  --- an overlay on it - and an overlay IS the working change, so the file
  --- being watched for markers must NOT be attached, or it would be part of
  --- the change rather than impacted by it.
  local function open(relative, attach)
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, relative)))
    local bufnr = vim.api.nvim_get_current_buf()
    if attach then
      support.attach(root, bufnr)
    end
    return bufnr
  end

  before_each(function()
    require("epicenter.config").reset()
    -- Its own state directory: approvals must not land in the user's.
    state_dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(state_dir, "p")
    require("epicenter.store").set_root(state_dir)

    epicenter.setup({
      ui = { icons = "ascii" },
      animate = false,
      lsp = { auto_start = false },
      impact = { debounce_ms = 10 },
    })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    -- config.lua is what gets edited; server.lua calls into it, so that is
    -- where the impact actually lands.
    watched = open("app/server.lua", false)
    edited = open("app/config.lua", true)
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    impact.reset()
    for _, bufnr in ipairs({ edited, watched }) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.bo[bufnr].modified = false
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    edited, watched = nil, nil
    require("epicenter.store").set_root(nil)
    require("epicenter.events").clear()
  end)

  --- Marks the buffer unsaved, which is what "there is a working change"
  --- means, and lets the reindex it provokes come back.
  local function edit()
    vim.api.nvim_buf_set_lines(edited, 3, 4, false, { "function M.route(method, path, extra)" })
  end

  local function answered()
    return wait(function()
      local state = impact.current()
      return state ~= nil and #state.groups > 0 and state.groups[1].nodes[1] ~= nil
    end, 10000, "the impact answer")
  end

  it("marks nothing while nothing is unsaved", function()
    expect.falsy(impact.has_working_change(root))
    require("epicenter.events").emit(require("epicenter.events").INDEXED, {})
    vim.wait(300)
    expect.eq(impact.current(), nil, "no working change, no request")
    expect.eq(marks.mark_at(watched, 9), nil)
  end)

  it(
    "forgets rather than pins approvals to the change a failed request left behind (L2)",
    function()
      edit()
      answered()

      local client = require("epicenter.client")
      local original_impact = client.impact
      client.impact = function(_, cb)
        cb({ message = "boom" })
      end

      -- Restored even if the wait below times out (L4): a stub left in place
      -- would silently fail every later test's real impact request.
      local ok, err = pcall(function()
        require("epicenter.events").emit(require("epicenter.events").INDEXED, {})
        wait(function()
          return impact.current() == nil
        end, 10000, "a failed request must not pin approvals to the previous change")
      end)
      client.impact = original_impact
      if not ok then
        error(err, 0)
      end

      expect.eq(impact.statusline(), "", "no stale review is claimed once the request failed")
    end
  )

  it("marks every impacted definition once the buffer is unsaved", function()
    edit()
    answered()

    local marked = wait(function()
      for line = 1, vim.api.nvim_buf_line_count(watched) do
        local mark = marks.mark_at(watched, line)
        if mark then
          return mark
        end
      end
      return nil
    end, 10000, "an inline marker")
    expect.matches(marked.text, "affected ·")
    expect.matches(impact.statusline(), "impact %d+/%d+ reviewed")
  end)

  it("takes the marks down again when the change is saved away", function()
    edit()
    answered()

    vim.bo[edited].modified = false
    require("epicenter.events").emit(require("epicenter.events").INDEXED, {})
    wait(function()
      return impact.current() == nil
    end, 10000, "the cleared impact")
    expect.eq(impact.statusline(), "")
  end)

  it("reviews a row, remembers it, and exports the checklist", function()
    edit()
    answered()

    panel = epicenter.run("review", {}, edited)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "the review rows")

    -- Row 1 is the hunk heading; row 2 is the first impacted definition.
    panel.list:select(2)
    local symbol_row = panel:current().node.node.symbol
    vim.api.nvim_set_current_win(panel.win.win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("a", true, false, true), "x", false)

    expect.truthy(approvals.approved(impact.current().state, symbol_row))
    expect.matches(vim.api.nvim_win_get_config(panel.win.win).title[1][1], "1/%d+ reviewed")
    expect.truthy(
      approvals.approved(approvals.load(root, impact.current().result.changeId), symbol_row),
      "the approval survives a reload from disk"
    )

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("u", true, false, true), "x", false)
    expect.falsy(approvals.approved(impact.current().state, symbol_row))

    review.export(impact.current())
    expect.matches(
      vim.fn.getreg(require("epicenter.features.context").target_register()),
      "## impact · 0/%d+ reviewed"
    )
  end)

  it("does not claim a missing content hash on the ordinary `u`/`a` no-op (L1)", function()
    edit()
    answered()

    panel = epicenter.run("review", {}, edited)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "the review rows")

    local notices = {}
    local original_notify = epicenter.notify
    epicenter.notify = function(msg, level)
      table.insert(notices, { msg = msg, level = level })
    end

    panel.list:select(2)
    vim.api.nvim_set_current_win(panel.win.win)
    -- `u` on a row nobody has approved yet: a real no-op, not a missing hash.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("u", true, false, true), "x", false)

    epicenter.notify = original_notify
    for _, notice in ipairs(notices) do
      expect.falsy(
        notice.msg:find("no content hash", 1, true),
        "an ordinary no-op must not claim a missing content hash: " .. notice.msg
      )
    end
  end)

  it("--qf sends the rows the review panel had already filled itself with", function()
    vim.fn.setqflist({}, "f")
    edit()
    answered()

    epicenter.run("review", { "--qf" }, edited)
    wait(function()
      return #vim.fn.getqflist() > 0
    end, 10000, "the quickfix list to fill")
    for _, entry in ipairs(vim.fn.getqflist()) do
      expect.truthy(entry.lnum >= 1)
    end
    vim.fn.setqflist({}, "f")
  end)

  --- A real keypress in the window that holds the panel.
  local function press(panel_handle, keys)
    vim.api.nvim_set_current_win(panel_handle.win.win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  local function approve_every_row(panel_handle)
    for index = 1, panel_handle.list:count() do
      panel_handle.list:select(index)
      local row = panel_handle:current()
      if row and row.node.type == "impacted" then
        press(panel_handle, "a")
      end
    end
  end

  it("never reports a change nobody has looked at as reviewed", function()
    edit()
    answered()

    panel = epicenter.run("review", {}, edited)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "the review rows")
    approve_every_row(panel)

    local reviewed, total = review.counts(impact.current().groups, impact.current().state)
    expect.truthy(total > 0, "the change impacts something")
    expect.eq(reviewed, total, "every impacted definition approved")
    expect.matches(impact.statusline(), ("impact %d/%d reviewed"):format(total, total))
    local before = impact.current().result.changeId

    -- A second, different edit to the same definition. None of the impacted
    -- sources moved, so every approval key still matches - but this is a new
    -- change, and nobody has looked at what it reaches.
    vim.api.nvim_buf_set_lines(edited, 3, 4, false, {
      "function M.route(method, path, extra, and_more)",
    })
    wait(function()
      local state = impact.current()
      return state ~= nil and state.result.changeId ~= before
    end, 10000, "the impact answer for the second change")

    local now_reviewed, now_total = review.counts(impact.current().groups, impact.current().state)
    expect.truthy(now_total > 0)
    expect.eq(now_reviewed, 0, "a change nobody reviewed reads as nobody reviewed it")
    expect.matches(impact.statusline(), ("impact 0/%d reviewed"):format(now_total))
    expect.matches(
      review.checklist(impact.current().groups, impact.current().state),
      "## impact · 0/%d+ reviewed"
    )
  end)

  it("keeps an open review panel bound to the session across a save and a re-edit", function()
    edit()
    answered()

    panel = epicenter.run("review", {}, edited)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "the review rows")

    -- Saved away: no working change, and the panel says so.
    vim.bo[edited].modified = false
    require("epicenter.events").emit(require("epicenter.events").INDEXED, {})
    wait(function()
      return impact.current() == nil
    end, 10000, "the cleared impact")

    -- Edited again: the answer refills the session the panel is holding.
    vim.api.nvim_buf_set_lines(edited, 3, 4, false, {
      "function M.route(method, path, again)",
    })
    wait(function()
      local state = impact.current()
      return state ~= nil and #state.groups > 0 and panel.list:count() > 1
    end, 10000, "the repainted review rows")

    panel.list:select(2)
    local symbol_row = panel:current().node.node.symbol
    press(panel, "a")

    expect.truthy(
      approvals.approved(impact.current().state, symbol_row),
      "the panel approves into the session the marks and the statusline read"
    )
    expect.matches(impact.statusline(), "impact 1/%d+ reviewed")
  end)

  it("M1: does not crash on a real `e` keypress once the working change is gone", function()
    edit()
    answered()

    panel = epicenter.run("review", {}, edited)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "the review rows")

    -- Saved away: `reload` hands the panel a nil session, but the panel stays
    -- open and keyed - the `e` key still calls `M.export(session)` directly.
    vim.bo[edited].modified = false
    require("epicenter.events").emit(require("epicenter.events").INDEXED, {})
    wait(function()
      return impact.current() == nil
    end, 10000, "the cleared impact")

    -- A keymap callback error is caught and reported by Neovim itself (it
    -- never reaches pcall around nvim_feedkeys), so v:errmsg is the real
    -- signal that the E5108 crash from the merge-gate report recurred.
    vim.v.errmsg = ""
    press(panel, "e")
    expect.eq(vim.v.errmsg, "", "the `e` key must not crash the panel")
  end)

  it("opens the blast panel rooted at the hunks", function()
    edit()
    panel = epicenter.run("impact", {}, edited)
    wait(function()
      return panel:valid() and body(panel):find("hunk", 1, true) ~= nil
    end, 10000, "the impact panel")
    expect.matches(body(panel), "the working change")
  end)
end)

--- Both panels are gated on the same v1.1-only method, and both used to say
--- so with a toast that left the freshly opened panel blank and unexplained.
--- The gate now writes into the panel itself, the same channel a query error
--- uses - and it is panel state, re-checked on every re-query (a reindex, a
--- keypress), not just the open that first showed it: a stand-in v1.0
--- session proves the blast panel never sends the request on any of those
--- paths. The review panel issues no request of its own (it renders from
--- the cached session - see `impact/review.lua`), so only its notice is
--- worth proving there.
describe("the protocol 1.1 gate on impact/review", function()
  local root, buf, panel

  local function body(target)
    local target_buf = target.surface and target.surface.buf or target.win.buf
    return table.concat(vim.api.nvim_buf_get_lines(target_buf, 0, -1, false), "\n")
  end

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(vim.fs.joinpath(root, ".navgraph"), "p")
    local path = vim.fs.joinpath(root, "old.lua")
    vim.fn.writefile({ "local function handle() end", "return handle" }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.client").stop(root)
    vim.fn.delete(root, "rf")
  end)

  --- A v1.0 server: `navgraph/impact` is not in `methods`, so `supports`
  --- answers false and the panel must not even ask.
  local function register_v10()
    local sent = {}
    require("epicenter.client").register_session(root, {
      request = function(_, method, _params, cb)
        table.insert(sent, method)
        vim.schedule(function()
          cb({ code = -32601, message = "method not found" }, nil)
        end)
        return { cancel = function() end }
      end,
      dropped_count = function()
        return 0
      end,
    }, { experimental = { navgraph = { protocolVersion = 1, methods = {} } } })
    return sent
  end

  it("shows the gate as a persistent line in the blast panel, not a toast", function()
    local sent = register_v10()
    panel = epicenter.run("impact", {}, buf)
    wait(function()
      return panel:valid() and body(panel):find("protocol 1.1", 1, true) ~= nil
    end, 5000, "the gate's notice")
    expect.eq(sent, {}, "a v1.0 server is never asked navgraph/impact")
  end)

  it("shows the gate as a persistent line in the review panel, not a toast", function()
    local sent = register_v10()
    panel = epicenter.run("review", {}, buf)
    wait(function()
      return panel ~= nil and panel:valid() and body(panel):find("protocol 1.1", 1, true) ~= nil
    end, 5000, "the gate's notice")
    expect.eq(sent, {}, "a v1.0 server is never asked navgraph/impact")
  end)

  --- HIGH-1: the gate used to be a one-shot argument to the FIRST query
  --- only. A reindex re-queries on a debounce - this proves it still finds
  --- the gate in place and never puts `navgraph/impact` on the wire.
  it("keeps the gate through a reindex - a v1.0 server is never re-asked", function()
    local sent = register_v10()
    panel = epicenter.run("impact", {}, buf)
    wait(function()
      return panel:valid() and body(panel):find("protocol 1.1", 1, true) ~= nil
    end, 5000, "the gate's notice")

    require("epicenter.events").emit(require("epicenter.events").INDEXED, {})
    panel.realtime.flush()

    -- Reindexing also wakes unrelated ambient features (outline badges) on
    -- the same wire - `navgraph/impact` specifically is what must stay off.
    expect.falsy(
      vim.tbl_contains(sent, "navgraph/impact"),
      "a reindex must not send navgraph/impact to a v1.0 server: " .. vim.inspect(sent)
    )
    expect.matches(body(panel), "protocol 1.1", "the notice survives the reindex")
  end)

  --- HIGH-1: every live keypress (+/-/d/t/s) re-queries too - toggle_strict
  --- stands in for all of them, since they all funnel through `Panel:query`.
  it("keeps the gate through a keypress - a v1.0 server is never re-asked", function()
    local sent = register_v10()
    panel = epicenter.run("impact", {}, buf)
    wait(function()
      return panel:valid() and body(panel):find("protocol 1.1", 1, true) ~= nil
    end, 5000, "the gate's notice")

    panel:toggle_strict()

    expect.eq(sent, {}, "a keypress must not send navgraph/impact to a v1.0 server")
    expect.matches(body(panel), "protocol 1.1", "the notice survives the keypress")
  end)

  it("clears the gate once a capable session appears, and answers for real", function()
    local sent = register_v10()
    panel = epicenter.run("impact", {}, buf)
    wait(function()
      return panel:valid() and body(panel):find("protocol 1.1", 1, true) ~= nil
    end, 5000, "the gate's notice")

    -- A 1.1 server takes over the same root - the recovery this codebase's
    -- own INFO-2 note called "accidental": this proves it is now deliberate.
    -- Only `navgraph/impact` succeeds, so an unrelated ambient method (the
    -- outline badges' reindex fetch) still 32601s exactly as it did above.
    require("epicenter.client").register_session(root, {
      request = function(_, method, _params, cb)
        table.insert(sent, method)
        vim.schedule(function()
          if method == "navgraph/impact" then
            cb(nil, { roots = {}, summary = {}, changeId = "1" })
          else
            cb({ code = -32601, message = "method not found" }, nil)
          end
        end)
        return { cancel = function() end }
      end,
      dropped_count = function()
        return 0
      end,
    }, { experimental = { navgraph = { protocolVersion = 2, methods = { "navgraph/impact" } } } })

    require("epicenter.events").emit(require("epicenter.events").INDEXED, {})
    panel.realtime.flush()

    wait(function()
      return body(panel):find("protocol 1.1", 1, true) == nil
    end, 5000, "the panel to repaint from a real answer")
    expect.truthy(
      vim.tbl_contains(sent, "navgraph/impact"),
      "the gate clears and the real method goes out: " .. vim.inspect(sent)
    )
  end)
end)
