--- What the plugin costs when you are not using it.
---
--- The contract: with every panel closed and badges off, moving the cursor
--- around - across buffers, across windows - sends nothing to the server and
--- leaves no timer running. With badges on the cost stays bounded: at most one
--- round trip per CursorHold, and at most one per buffer entered.
---
--- Counted at the two seams that can leak: the client's rpc transport (every
--- `navgraph/*` the plugin sends, whichever feature sent it) and the tween
--- driver (every animation frame timer, whoever started it).
local support = require("support")

local IDLE_EVENTS = { "CursorMoved", "CursorHold", "BufEnter", "BufWinEnter", "WinEnter" }

--- `animate.tween` resolves its timer through `animate.uv_driver`, so wrapping
--- that counts every animation actually driven by a real timer.
local function watch_tweens()
  local animate = require("epicenter.ui.animate")
  local base = animate.uv_driver
  local started, live = 0, 0
  animate.uv_driver = function()
    local driver = base()
    return {
      start = function(interval, tick)
        started, live = started + 1, live + 1
        driver.start(interval, tick)
      end,
      stop = function()
        live = live - 1
        driver.stop()
      end,
    }
  end
  return {
    started = function()
      return started
    end,
    live = function()
      return live
    end,
    reset = function()
      started = 0
    end,
    restore = function()
      animate.uv_driver = base
    end,
  }
end

--- @param root string workspace whose session to instrument
local function watch_requests(root)
  local session =
    assert(require("epicenter.client").session_for_root(root), "no navgraph session for " .. root)
  local base = session.rpc.request
  local sent = {}
  session.rpc.request = function(method, params, handler)
    table.insert(sent, method)
    return base(method, params, handler)
  end
  return {
    sent = function()
      return sent
    end,
    reset = function()
      sent = {}
    end,
    restore = function()
      session.rpc.request = base
    end,
  }
end

--- Lets every scheduled callback and in-flight response land, so "nothing
--- happened" means nothing happened rather than nothing happened yet.
local function settle(ms)
  vim.wait(ms or 300, function()
    return false
  end, 10)
end

describe("idle cost", function()
  local root, requests, tweens, buffers

  local function open(relative, line)
    local path = vim.fs.joinpath(root, relative)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    support.attach(root, bufnr)
    return bufnr
  end

  --- Every trigger an idle editor produces, on every open buffer.
  local function move_around()
    for _, bufnr in ipairs(buffers) do
      vim.api.nvim_set_current_buf(bufnr)
      for _, line in ipairs({ 1, 3, 5, 7 }) do
        local last = vim.api.nvim_buf_line_count(bufnr)
        vim.api.nvim_win_set_cursor(0, { math.min(line, last), 0 })
        for _, event in ipairs(IDLE_EVENTS) do
          vim.api.nvim_exec_autocmds(event, { buffer = bufnr, modeline = false })
        end
      end
    end
    settle()
  end

  local function configure(opts)
    require("epicenter.config").reset()
    require("epicenter").setup(
      vim.tbl_extend(
        "force",
        { ui = { icons = "ascii" }, animate = true, lsp = { auto_start = false } },
        opts or {}
      )
    )
    require("epicenter.ui.theme").apply()
  end

  before_each(function()
    -- The animator only starts a real timer with motion on, and the test init
    -- turns motion off globally; without this the tween counter would read
    -- zero whatever the plugin did.
    vim.g.epicenter_reduce_motion = nil
    root = root or support.start_fake()
    tweens = watch_tweens()
    requests = watch_requests(root)
    buffers = nil
  end)

  after_each(function()
    requests.restore()
    tweens.restore()
    vim.g.epicenter_reduce_motion = true
    require("epicenter.features.blast.badges").setup({ badges = false })
  end)

  it("sends nothing and runs no timer while the cursor moves, badges off", function()
    configure({ badges = false })
    buffers = { open("app/config.lua", 4), open("app/server.lua", 9) }
    settle()
    requests.reset()
    tweens.reset()

    move_around()

    expect.eq(requests.sent(), {}, "an idle editor must not talk to the server")
    expect.eq(tweens.started(), 0, "an idle editor must not start an animation")
    expect.eq(tweens.live(), 0, "no timer may be left running")
  end)

  it("registers no cursor autocmd at all with badges off", function()
    configure({ badges = false })
    local ours = {}
    for _, autocmd in
      ipairs(vim.api.nvim_get_autocmds({
        event = { "CursorMoved", "CursorMovedI", "CursorHold", "CursorHoldI" },
      }))
    do
      if (autocmd.group_name or ""):match("^Epicenter") then
        table.insert(ours, autocmd.group_name .. ":" .. autocmd.event)
      end
    end
    expect.eq(ours, {})
  end)

  it("leaves nothing behind after a panel closes", function()
    configure({ badges = false })
    buffers = { open("app/config.lua", 4) }
    local palette = require("epicenter").run("search", {}, buffers[1])
    wait(function()
      return palette.list:count() > 0
    end, 10000, "search results")
    palette:close({ motion = false })
    wait(function()
      return not palette.results_win:valid()
    end, 5000, "palette to close")
    settle()

    requests.reset()
    tweens.reset()
    move_around()

    expect.eq(requests.sent(), {}, "a closed panel must not keep querying")
    expect.eq(tweens.started(), 0)
    expect.eq(tweens.live(), 0, "the palette's tweens must all be stopped")
  end)
end)

describe("bounded cost with badges on", function()
  local root, requests, tweens

  before_each(function()
    -- Real animation (F4): the CursorHold path's actual cost is a reveal
    -- tween, not a request - `animate = false` was hiding the one seam
    -- that is real. Same override the idle-cost block above uses.
    vim.g.epicenter_reduce_motion = nil
    root = root or support.start_fake()
    require("epicenter.config").reset()
    require("epicenter").setup({
      ui = { icons = "ascii" },
      animate = true,
      badges = "cursor",
      lsp = { auto_start = false },
    })
    requests = watch_requests(root)
    tweens = watch_tweens()
  end)

  after_each(function()
    requests.restore()
    tweens.restore()
    vim.g.epicenter_reduce_motion = true
    require("epicenter.features.blast.badges").setup({ badges = false })
  end)

  local function edit(relative, line)
    local path = vim.fs.joinpath(root, relative)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    support.attach(root, bufnr)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    return bufnr
  end

  --- The fake server pushes `navgraph/indexed` for a while after a buffer
  --- opens, and each one legitimately invalidates the badge cache. Wait for
  --- that to stop before measuring, or the count under test is someone else's.
  local function quiesce()
    local ok = vim.wait(5000, function()
      local before = #requests.sent()
      vim.wait(200)
      return #requests.sent() == before
    end, 50)
    expect.truthy(ok, "the server never stopped reindexing")
    requests.reset()
    tweens.reset()
  end

  --- CursorHold is wired to `badges.M.refresh`, which repaints from the
  --- already-fetched outline cache and never itself issues a request - a
  --- `<=` bound here would still pass with the whole CursorHold path deleted
  --- (F4). The exact bound is 0, structurally, not "small".
  it("CursorHold repaints from the cached outline and sends nothing", function()
    local bufnr = edit("app/config.lua", 4)
    require("epicenter.features.blast.badges").fetch(bufnr)
    quiesce()

    local holds = { 3, 8, 3, 8, 3, 8 }
    for _, line in ipairs(holds) do
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      vim.api.nvim_exec_autocmds("CursorHold", { buffer = bufnr, modeline = false })
    end
    vim.wait(300, function()
      return false
    end, 10)

    expect.eq(
      requests.sent(),
      {},
      "CursorHold must never itself cost a round trip, however many times it fires"
    )
  end)

  --- The request CursorHold cannot cost still has to come from somewhere: a
  --- real edit invalidates the outline cache (`fetched_at` keys on
  --- changedtick), and the reindex it triggers costs a `navgraph/outline` -
  --- but the CursorHolds that follow must not cost anything further.
  it("a real edit costs a navgraph/outline, not one per CursorHold after", function()
    local bufnr = edit("app/config.lua", 4)
    require("epicenter.features.blast.badges").fetch(bufnr)
    quiesce()

    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "-- edited" })
    local reached = vim.wait(5000, function()
      return #requests.sent() > 0
    end, 20)
    -- Let the edit's own reindex traffic fully settle - a single edit can
    -- legitimately produce more than one debounced navgraph/indexed - before
    -- measuring. Never written to disk; clear `modified` (even on a later
    -- assertion failure) so a later test's `:edit` on this fixture file does
    -- not refuse to reload it.
    vim.wait(1000, function()
      local before = #requests.sent()
      vim.wait(200)
      return #requests.sent() == before
    end, 20)
    vim.bo[bufnr].modified = false
    assert(reached, "the edit never reached the server")
    local after_edit = #requests.sent()

    for _, line in ipairs({ 3, 9, 3 }) do
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      vim.api.nvim_exec_autocmds("CursorHold", { buffer = bufnr, modeline = false })
    end
    vim.wait(300, function()
      return false
    end, 10)

    -- Not pinned to exactly 1: the fake's watch poll (2s, on by default) can
    -- legitimately land its own independent reindex in the same window, so
    -- more than one is a real possibility, not a bug. What matters is that
    -- the edit costs *something*, and the CursorHolds after cost nothing
    -- more.
    expect.truthy(
      after_edit >= 1,
      "the edit must have triggered at least one navgraph/outline fetch"
    )
    expect.eq(
      #requests.sent(),
      after_edit,
      "CursorHold after the edit must not cost anything further"
    )
  end)

  it("costs nothing extra to re-enter an already-current buffer", function()
    local first = edit("app/config.lua", 4)
    local second = edit("app/server.lua", 9)
    require("epicenter.features.blast.badges").fetch(first)
    require("epicenter.features.blast.badges").fetch(second)
    quiesce()

    -- `refresh_visible` only re-fetches the currently visible buffer, so
    -- `first`'s cache can legitimately go stale while `second` is on screen
    -- (a background reindex from opening/attaching `second`). One warm-up
    -- pass lets that real, one-time catch-up happen - it is not what this
    -- test is about.
    for _, bufnr in ipairs({ first, second }) do
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr, modeline = false })
      vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = bufnr, modeline = false })
    end
    vim.wait(300, function()
      return false
    end, 10)
    requests.reset()

    -- What is actually under test: once both caches are current, re-entering
    -- either buffer any number of times must cost nothing at all.
    for _ = 1, 3 do
      for _, bufnr in ipairs({ first, second }) do
        vim.api.nvim_set_current_buf(bufnr)
        vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr, modeline = false })
        vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = bufnr, modeline = false })
      end
    end
    vim.wait(300, function()
      return false
    end, 10)

    expect.eq(
      requests.sent(),
      {},
      "re-entering an already-current buffer must never re-fetch its outline"
    )
  end)

  --- The tween a `<=` request bound would have hidden entirely (F4): each
  --- badge change reveals with at most one tween (M.place cancels any
  --- running reveal before starting the next), and an unchanged badge
  --- starts none at all.
  it("repaints with at most one tween, and none when the badge is unchanged", function()
    local bufnr = edit("app/config.lua", 4)
    require("epicenter.features.blast.badges").fetch(bufnr)
    quiesce()

    -- Line 4 (M.route) -> line 8 (M.load_config): a genuinely different
    -- badge, so exactly one reveal tween is expected, not zero.
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    vim.api.nvim_exec_autocmds("CursorHold", { buffer = bufnr, modeline = false })
    vim.wait(300, function()
      return false
    end, 10)
    expect.truthy(
      tweens.started() <= 1,
      ("one badge change started %d tweens"):format(tweens.started())
    )
    expect.eq(tweens.live(), 0, "the reveal must finish, not leave a timer running")

    -- Holding on the same line again: the badge text is unchanged, so
    -- M.refresh must not repaint (and therefore not tween) at all.
    local before = tweens.started()
    vim.api.nvim_exec_autocmds("CursorHold", { buffer = bufnr, modeline = false })
    vim.wait(300, function()
      return false
    end, 10)
    expect.eq(tweens.started(), before, "an unchanged badge must not start a tween")
  end)
end)
