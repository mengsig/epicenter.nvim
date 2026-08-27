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
    local chain = path.chain_lines({ symbol(), symbol({ qualified = "M.handle_request", line = 9 }) })
    local text = table.concat(chain.lines, "\n")
    expect.matches(text, "M%.start")
    expect.matches(text, "M%.handle_request")
    expect.matches(text, "app/server%.lua:9")
  end)

  it("maps every symbol line to a jump target", function()
    local chain = path.chain_lines({ symbol(), symbol({ qualified = "M.handle_request", line = 9 }) })
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
