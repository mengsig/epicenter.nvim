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
    local chain = path.chain_lines({
      { symbol = symbol() },
      { symbol = symbol({ qualified = "M.handle_request", line = 9 }), edge = { kind = "call" } },
    })
    local text = table.concat(chain.lines, "\n")
    expect.matches(text, "M%.start")
    expect.matches(text, "calls")
    expect.matches(text, "M%.handle_request")
    expect.matches(text, "app/server%.lua:9")
  end)

  it("marks a heuristic rung and names a reference edge", function()
    local chain = path.chain_lines({
      { symbol = symbol() },
      { symbol = symbol({ qualified = "M.route" }), edge = { kind = "ref", heuristic = true } },
    })
    local text = table.concat(chain.lines, "\n")
    expect.matches(text, "references %?")
  end)

  it("maps every symbol line to a jump target", function()
    local chain = path.chain_lines({
      { symbol = symbol() },
      { symbol = symbol({ qualified = "M.handle_request", line = 9 }), edge = { kind = "call" } },
    })
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
      { symbol = symbol() },
      { symbol = symbol({ qualified = "M.handle_request" }), edge = { kind = "call" } },
      { symbol = symbol({ qualified = "log_request" }), edge = { kind = "call" } },
    })
    expect.eq(#chain.reveal, 3)
    expect.truthy(chain.reveal[1] < chain.reveal[2] and chain.reveal[2] < chain.reveal[3])
    expect.eq(chain.reveal[3] + 1, #chain.lines, "one trailing blank line")
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
    expect.matches(text, "calls")
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
