local path = require("epicenter.features.path")
local support = require("support")

local function symbol(over)
  return vim.tbl_extend("force", {
    qualified = "M.start",
    name = "start",
    kind = "fn",
    file = "app/server.lua",
    uri = "file:///proj/app/server.lua",
    line = 14,
    endLine = 18,
  }, over or {})
end

describe("path ladder", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("draws one rung between each pair of symbols", function()
    -- The contract's navgraph/path returns a flat Symbol[] - no per-rung edge
    -- data (F4), so steps are Symbols directly, and the connector carries no
    -- calls/references label.
    local chain =
      path.chain_lines({ symbol(), symbol({ qualified = "M.handle_request", line = 9 }) })
    local text = table.concat(chain.lines, "\n")
    expect.matches(text, "M%.start")
    expect.matches(text, "M%.handle_request")
    expect.matches(text, "app/server%.lua:9")
  end)

  it("maps every symbol line to a jump target", function()
    local chain =
      path.chain_lines({ symbol(), symbol({ qualified = "M.handle_request", line = 9 }) })
    local lines = vim.tbl_keys(chain.targets)
    table.sort(lines)
    expect.eq(#lines, 2)
    expect.eq(chain.targets[lines[1]].line, 14)
    expect.eq(chain.targets[lines[2]].line, 9)
    for _, at in ipairs(lines) do
      expect.matches(chain.lines[at], "M%.")
    end
  end)

  it("reports how many lines each step has drawn, for the reveal", function()
    local chain = path.chain_lines({
      symbol(),
      symbol({ qualified = "M.handle_request" }),
      symbol({ qualified = "log_request" }),
    })
    expect.eq(#chain.reveal, 3)
    expect.truthy(chain.reveal[1] < chain.reveal[2] and chain.reveal[2] < chain.reveal[3])
    expect.eq(chain.reveal[3] + 1, #chain.lines, "one trailing blank line")
  end)

  it("a single-symbol chain (from == to) draws with no connector", function()
    local chain = path.chain_lines({ symbol() })
    expect.eq(#chain.reveal, 1)
    expect.matches(table.concat(chain.lines, "\n"), "M%.start")
  end)

  it("declares the command and its keymap", function()
    expect.eq(path.commands[1].name, "path")
    expect.eq(path.keymaps[1].suffix, "p")
  end)
end)

describe("path against the fake navgraph server", function()
  local root, buf, handle

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if handle and handle.win and handle.win:valid() then
      handle.win:close()
    end
    handle = nil
  end)

  local function lines()
    return vim.api.nvim_buf_get_lines(handle.win.buf, 0, -1, false)
  end

  it("finds the shortest chain between two named symbols", function()
    handle = require("epicenter").run("path", { "M.start", "log_request" }, buf)
    wait(function()
      return handle.win ~= nil
    end, 10000, "path panel")
    local text = table.concat(lines(), "\n")
    expect.matches(text, "M%.start")
    expect.matches(text, "M%.handle_request")
    expect.matches(text, "log_request")
  end)

  it("says so calmly when there is no chain", function()
    handle = require("epicenter").run("path", { "M.route", "M.start" }, buf)
    wait(function()
      return handle.win ~= nil
    end, 10000, "path panel")
    expect.matches(table.concat(lines(), "\n"), "no call path from M%.route to M%.start")
  end)

  it("treats an unknown symbol as no path rather than an error", function()
    handle = require("epicenter").run("path", { "nosuchsymbol", "M.start" }, buf)
    wait(function()
      return handle.win ~= nil
    end, 10000, "path panel")
    expect.matches(table.concat(lines(), "\n"), "no call path")
  end)
end)

--- F1: `navgraph/path` never answers an ambiguous name as "no call path" - it
--- sends the candidates back instead. `handle_request` collides on purpose:
--- M.handle_request (app/server.lua) and RequestHandler.handle_request
--- (app/handlers.py) share the bare name in the shared fixture.
describe("path ambiguity picker against the fake navgraph server (F1)", function()
  local root, buf, handle

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    if handle and handle.win then
      pcall(function()
        handle.win:close()
      end)
    end
    handle = nil
  end)

  it("offers a candidate picker rather than a confident 'no call path'", function()
    handle = require("epicenter").run("path", { "handle_request", "M.start" }, buf)
    wait(function()
      return handle.win ~= nil and handle.win.list:count() > 0
    end, 10000, "ambiguity candidate picker")

    local qualified = vim.tbl_map(function(item)
      return item.symbol.qualified
    end, handle.win.list:items())
    table.sort(qualified)
    expect.eq(qualified, { "M.handle_request", "RequestHandler.handle_request" })
  end)

  it("re-queries the path once the intended endpoint is chosen", function()
    handle = require("epicenter").run("path", { "handle_request", "M.start" }, buf)
    wait(function()
      return handle.win ~= nil and handle.win.list:count() > 0
    end, 10000, "ambiguity candidate picker")

    local index
    for i, item in ipairs(handle.win.list:items()) do
      if item.symbol.qualified == "M.handle_request" then
        index = i
      end
    end
    assert(index, "M.handle_request must be offered as a candidate")
    handle.win.list:select(index)
    handle.win:accept("edit")
    handle = nil -- accept() closes the picker itself

    local ladder_buf
    wait(function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local candidate = vim.api.nvim_win_get_buf(win)
        if vim.bo[candidate].filetype == "epicenter-path" then
          ladder_buf = candidate
          return true
        end
      end
      return false
    end, 10000, "the re-queried path ladder")

    local text = table.concat(vim.api.nvim_buf_get_lines(ladder_buf, 0, -1, false), "\n")
    expect.matches(text, "M%.handle_request")
    expect.matches(text, "M%.start")
    vim.api.nvim_buf_delete(ladder_buf, { force = true })
  end)
end)

describe("path window against the fake navgraph server, with real animation", function()
  local root, buf, handle

  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      path = { step_ms = 200 },
      animation = { close_ms = 80 },
    })
    -- Real animation: F1 and F10 are both invisible under CI's default
    -- reduce-motion (tests/minimal_init.lua).
    vim.g.epicenter_reduce_motion = false
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/server.lua")))
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    vim.g.epicenter_reduce_motion = true
    if handle and handle.win and handle.win:valid() then
      handle.win:close()
    end
    handle = nil
  end)

  it("F1: <CR> jumps into the window path was opened from, not the fading float", function()
    local source_win = vim.api.nvim_get_current_win()
    handle = require("epicenter").run("path", { "M.start", "log_request" }, buf)
    wait(function()
      return handle.win ~= nil
    end, 10000, "path panel")
    -- Targets are computed up front (chain_lines runs before the reveal
    -- tween starts), so <CR> mid-reveal must already jump correctly. Line 1
    -- is the leading blank line; the first symbol row is line 2 - wait for
    -- the buffer to actually have it (the reveal is staggered).
    wait(function()
      return vim.api.nvim_buf_line_count(handle.win.buf) >= 2
    end, 10000, "the first rung painted")
    vim.api.nvim_win_set_cursor(handle.win.win, { 2, 0 })
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(handle.win.buf, "n")) do
      if map.lhs == "<CR>" and map.callback then
        map.callback()
        break
      end
    end

    -- The source buffer is already server.lua (F4's fixture): confirm the
    -- cursor really moved to M.start's line (14), not just window identity.
    wait(function()
      return vim.api.nvim_win_get_cursor(0)[1] == 14
    end, 3000, "the jump moved the cursor to M.start")
    expect.eq(vim.api.nvim_get_current_win(), source_win, "and it landed in the source window")
  end)

  it("F10: closing mid-reveal does not raise a Lua error", function()
    handle = require("epicenter").run("path", { "M.start", "log_request" }, buf)
    wait(function()
      return handle.win ~= nil
    end, 10000, "path panel")
    -- step_ms=200 over 3 rungs: catch it with the first rung shown and the
    -- last not yet, i.e. genuinely mid-reveal.
    wait(function()
      if not handle.win:valid() then
        return false
      end
      local content = table.concat(vim.api.nvim_buf_get_lines(handle.win.buf, 0, -1, false), "\n")
      return content:match("M%.start") ~= nil and content:match("log_request") == nil
    end, 10000, "the ladder is mid-reveal")

    local logged = {}
    local original = require("epicenter.log").error
    require("epicenter.log").error = function(fmt, ...)
      table.insert(logged, fmt:format(...))
    end

    handle.win:close()
    -- Give any (bugged) queued tween frame a chance to fire against the dead
    -- buffer before asserting nothing was logged.
    vim.wait(400)
    require("epicenter.log").error = original

    expect.eq(#logged, 0, "no tween-frame error after close: " .. table.concat(logged, " | "))
  end)
end)

--- F1 (merge gate): `qualified` is NOT unique - `router` is four definitions
--- in this plugin's own real fixture, and `SymbolId` is sixteen in NavGraph's
--- own source. Re-asking with the picked candidate's bare `qualified` sends
--- the identical request, gets the identical ambiguity back, and reopens the
--- identical picker, forever. These drive a scripted server because no fake
--- fixture carries a same-`qualified` collision; `tests/real/navigate_spec.lua`
--- covers the real four.
describe("path ambiguity on candidates that share a qualified name (F1)", function()
  local client = require("epicenter.client")
  local root, buf, handle, asked

  --- Four `router` definitions, one per route module - the real fixture's own
  --- collision, shaped as the contract sends it back.
  local function routers()
    local files = {
      "py_fastapi/app/routes/users.py",
      "py_fastapi/app/routes/items.py",
      "py_fastapi/app/routes/auth.py",
      "py_fastapi/app/routes/orders.py",
    }
    return vim.tbl_map(function(file)
      return {
        qualified = "router",
        name = "router",
        kind = "var",
        file = file,
        uri = "file:///demo/" .. file,
        line = 7,
        endLine = 7,
      }
    end, files)
  end

  --- A session answering `navgraph/path` from `script(params)`, recording
  --- every `from` it was asked for.
  local function scripted(script)
    return {
      request = function(_, method, params, cb)
        table.insert(asked, params.from)
        local answer = script(params)
        vim.schedule(function()
          cb(nil, answer)
        end)
        return { cancel = function() end }
      end,
      dropped_count = function()
        return 0
      end,
    }
  end

  local function pick_first()
    wait(function()
      return handle.win ~= nil and handle.win.list:count() > 0
    end, 10000, "the ambiguity picker")
    handle.win.list:select(1)
    handle.win:accept("edit")
  end

  --- A synthetic root, with `root.find` pinned to it for the block: a
  --- scripted session registered at whatever root the current buffer happens
  --- to resolve to would displace the fixture server another spec file is
  --- still using (`client_session_spec.lua` pins it the same way).
  local ROOT = "/tmp/epicenter-path-ambiguity-root"
  local original_find

  before_each(function()
    asked = {}
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" }, animate = false })
    require("epicenter.ui.theme").apply()
    buf = vim.api.nvim_create_buf(false, true)
    root = ROOT
    original_find = require("epicenter.root").find
    require("epicenter.root").find = function()
      return ROOT
    end
  end)

  after_each(function()
    require("epicenter.root").find = original_find
    client.stop(root)
    handle = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local candidate = vim.api.nvim_win_get_buf(win)
      if
        #vim.api.nvim_list_wins() > 1 and (vim.bo[candidate].filetype or ""):match("^epicenter")
      then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("re-asks with the candidate's file, so a same-qualified pick resolves", function()
    local candidates = routers()
    client.register_session(
      root,
      scripted(function(params)
        if params.from == "router" then
          return { path = {}, ambiguousFrom = candidates, ambiguousTo = {} }
        end
        return { path = { candidates[1] }, ambiguousFrom = {}, ambiguousTo = {} }
      end)
    )

    handle = require("epicenter").run("path", { "router", "router" }, buf)
    pick_first()

    wait(function()
      return #asked == 2
    end, 10000, "the re-query")
    expect.eq(
      asked[2],
      "router@py_fastapi/app/routes/users.py",
      "the re-query must name the file, the only thing that separates them"
    )
  end)

  it("keeps --qf across the picker, so the re-run's rows still reach the list", function()
    local candidates = routers()
    client.register_session(
      root,
      scripted(function(params)
        if params.from == "router" then
          return { path = {}, ambiguousFrom = candidates, ambiguousTo = {} }
        end
        return { path = { candidates[1] }, ambiguousFrom = {}, ambiguousTo = {} }
      end)
    )
    -- The export itself is captured rather than run: a real quickfix window
    -- (and the toast that follows it) left standing in a headless session
    -- aborts the next test's first redraw.
    local qf = require("epicenter.ui.qf")
    local sent = nil
    local original_send = qf.send_and_notify
    qf.send_and_notify = function(opts)
      sent = opts
    end

    -- L4: restored even if run()/pick_first() raises - an unrestored stub
    -- here silently disables every later test's real quickfix assertions.
    local pcall_ok, waited = pcall(function()
      handle = require("epicenter").run("path", { "router", "M.start", "--qf" }, buf)
      pick_first()
      return vim.wait(10000, function()
        return sent ~= nil
      end, 10)
    end)
    qf.send_and_notify = original_send
    if not pcall_ok then
      error(waited, 0)
    end

    expect.truthy(waited, "the flag survived the picker and reached the re-run's rows")
    expect.eq(sent.list, "quickfix")
    expect.eq(#sent.rows, 1, "the resolved path's one step")
  end)

  it("stops instead of reopening when even the file cannot separate them", function()
    -- `main` is a package and a function on the same line range of one Go
    -- file in the real fixture: `name@path` narrows to two, not one.
    local twins = vim.list_slice(routers(), 1, 2)
    twins[2] = vim.tbl_extend("force", {}, twins[1], { kind = "fn", line = 15 })
    client.register_session(
      root,
      scripted(function()
        return { path = {}, ambiguousFrom = twins, ambiguousTo = {} }
      end)
    )

    handle = require("epicenter").run("path", { "router", "M.start" }, buf)
    pick_first()

    local ladder
    wait(function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local candidate = vim.api.nvim_win_get_buf(win)
        if vim.bo[candidate].filetype == "epicenter-path" then
          ladder = candidate
          return true
        end
      end
      return false
    end, 10000, "the honest answer, rather than the picker again")

    local text = table.concat(vim.api.nvim_buf_get_lines(ladder, 0, -1, false), "\n")
    expect.matches(text, "2 definitions of router share py_fastapi/app/routes/users%.py")
    expect.matches(text, "cannot be told apart")
    expect.eq(#asked, 2, "exactly one re-query, then it stopped")
  end)
end)
