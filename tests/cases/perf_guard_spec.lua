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
  local root, requests

  before_each(function()
    root = root or support.start_fake()
    require("epicenter.config").reset()
    require("epicenter").setup({
      ui = { icons = "ascii" },
      animate = false,
      badges = "cursor",
      lsp = { auto_start = false },
    })
    requests = watch_requests(root)
  end)

  after_each(function()
    requests.restore()
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
  end

  it("costs at most one round trip per CursorHold", function()
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

    local sent = requests.sent()
    expect.truthy(
      #sent <= #holds,
      ("%d CursorHold sent %d requests: %s"):format(#holds, #sent, vim.inspect(sent))
    )
  end)

  it("costs at most one outline per buffer however often you re-enter it", function()
    local first = edit("app/config.lua", 4)
    local second = edit("app/server.lua", 9)
    require("epicenter.features.blast.badges").fetch(first)
    require("epicenter.features.blast.badges").fetch(second)
    quiesce()

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

    local sent = requests.sent()
    expect.truthy(
      #sent <= 2,
      ("six buffer entries sent %d requests: %s"):format(#sent, vim.inspect(sent))
    )
  end)
end)
