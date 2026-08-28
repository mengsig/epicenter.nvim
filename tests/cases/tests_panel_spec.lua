--- The tests panel: the grouping and the runner template (pure), then the
--- panel end to end against the fake server, which speaks `navgraph/tests`.
local support = require("support")
local epicenter = require("epicenter")
local tests = require("epicenter.features.tests")

local function symbol(over)
  return vim.tbl_extend("force", {
    id = 1,
    name = "test_dispatch",
    qualified = "FlowCase.test_dispatch",
    kind = "fn",
    file = "app/test_flow.py",
    uri = "file:///proj/app/test_flow.py",
    line = 7,
    endLine = 8,
    sig = "def test_dispatch(self):",
    language = "py",
    callers = 0,
    callees = 1,
    exported = true,
    test = true,
    contentHash = "abc123",
  }, over or {})
end

describe("the tests panel model", function()
  before_each(function()
    require("epicenter.config").reset()
    require("epicenter.config").setup({ ui = { icons = "ascii" } })
  end)

  it("groups by file, files sorted, tests by depth then line", function()
    local files = tests.group_by_file({
      { symbol = symbol({ file = "b.py", line = 9 }), depth = 2, via = {} },
      { symbol = symbol({ file = "a.py", line = 30, name = "test_late" }), depth = 3, via = {} },
      { symbol = symbol({ file = "a.py", line = 20, name = "test_early" }), depth = 1, via = {} },
    })
    expect.eq(
      vim.tbl_map(function(node)
        return node.name
      end, files),
      { "a.py", "b.py" }
    )
    expect.eq(files[1].children[1].symbol.name, "test_early")
    expect.eq(files[1].children[2].depth, 3)
  end)

  it("renders a file heading with its count, and a test with its depth", function()
    local files = tests.group_by_file({ { symbol = symbol(), depth = 2, via = {} } })
    local heading = tests.render_row({ node = files[1], depth = 0, expanded = true })
    expect.matches(heading.text, "app/test_flow%.py %(1%)")

    local row = tests.render_row({ node = files[1].children[1], depth = 1, expanded = false })
    expect.matches(row.text, "FlowCase%.test_dispatch")
    expect.matches(row.text, "app/test_flow%.py:7")
    expect.matches(row.text, "d2")
  end)
end)

describe("the test runner template", function()
  local RUNNERS = { python = "pytest %f::%s", zig = "zig test %f" }

  it("substitutes the file and the test's own name", function()
    local command = tests.command_for(symbol({ uri = "file:///proj/app/test_flow.py" }), RUNNERS)
    expect.eq(command, "pytest /proj/app/test_flow.py::test_dispatch")
  end)

  it("reaches the same template whether the server says py or python", function()
    expect.eq(tests.language_of(symbol({ language = "py" })), "python")
    expect.eq(tests.language_of(symbol({ language = "python" })), "python")
    expect.matches(tests.command_for(symbol({ language = "python" }), RUNNERS), "^pytest")
  end)

  it("names the missing template rather than running something else", function()
    local command, reason = tests.command_for(symbol({ language = "ruby" }), RUNNERS)
    expect.eq(command, nil)
    expect.matches(reason, "tests%.runner%.ruby")
  end)
end)

describe("the tests panel against the fake navgraph server", function()
  local root, buf, panel

  local function body()
    return table.concat(vim.api.nvim_buf_get_lines(panel.win.buf, 0, -1, false), "\n")
  end

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_fake()
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, "app/handlers.py")))
    buf = vim.api.nvim_get_current_buf()
    -- `def dispatch(method, path):` - column 5 is on the function's own name.
    vim.api.nvim_win_set_cursor(0, { 9, 5 })
    support.attach(root, buf)
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    -- The runner's scratch split is the user's to close; a spec's is not.
    -- Left open it survives into the NEXT spec file, where headless
    -- Neovim's grid assertion aborts the whole run.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local win_buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[win_buf].filetype == "epicenter-test-output" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    require("epicenter.events").clear()
  end)

  it("lists the tests reaching the symbol, grouped by their file", function()
    panel = epicenter.run("tests", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "the tests")

    expect.matches(body(), "app/test_flow%.py")
    expect.matches(body(), "test_dispatch")
    expect.matches(vim.api.nvim_win_get_config(panel.win.win).title[1][1], "dispatch")
  end)

  it("says so when nothing tests the symbol, instead of an empty box", function()
    panel = epicenter.run("tests", { "M.route" }, buf)
    wait(function()
      return panel:valid() and body():find("no test reaches", 1, true) ~= nil
    end, 10000, "the empty notice")
  end)

  it("jumps to the test a row names", function()
    panel = epicenter.run("tests", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "the tests")
    panel.list:select(2)
    local target = panel:target()
    expect.truthy(target ~= nil)
    expect.matches(target.path, "test_flow%.py$")
  end)

  it("sends the rows to the quickfix list, file headings excluded", function()
    panel = epicenter.run("tests", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "the tests")
    local rows = panel:export_rows()
    expect.truthy(#rows > 0)
    for _, row in ipairs(rows) do
      expect.matches(row.target.path, "%.py$")
    end
  end)

  it("runs the test under the cursor, streaming into a scratch split", function()
    require("epicenter.config").setup({
      ui = { icons = "ascii" },
      animate = false,
      lsp = { auto_start = false },
      tests = { runner = { python = "echo ran %s in %f" } },
    })
    panel = epicenter.run("tests", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 1
    end, 10000, "the tests")

    panel.list:select(2)
    vim.api.nvim_set_current_win(panel.win.win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("r", true, false, true), "x", false)

    local output = wait(function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[bufnr].filetype == "epicenter-test-output" then
          local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
          if text:find("[exit 0]", 1, true) then
            return text
          end
        end
      end
      return nil
    end, 10000, "the runner output")

    expect.matches(output, "%$ echo ran test_dispatch in ")
    expect.matches(output, "ran test_dispatch in ")
  end)
end)

describe("the tests panel against a v1.0 server", function()
  local buf, panel, temp

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    -- Its own root: register_session overwrites whatever record a root holds.
    temp = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(vim.fs.joinpath(temp, ".navgraph"), "p")
    local path = vim.fs.joinpath(temp, "only.py")
    vim.fn.writefile({ "def only():", "    return 1" }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    _G.EPICENTER_SENT = {}
    require("epicenter.client").register_session(temp, {
      request = function(_, method)
        table.insert(_G.EPICENTER_SENT, method)
        return { cancel = function() end }
      end,
      dropped_count = function()
        return 0
      end,
    }, { experimental = { navgraph = { protocolVersion = 1, methods = {} } } })
  end)

  after_each(function()
    if panel and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.client").stop(temp)
    _G.EPICENTER_SENT = nil
  end)

  it("says the server is too old and sends nothing", function()
    panel = epicenter.run("tests", {}, buf)
    local text = table.concat(vim.api.nvim_buf_get_lines(panel.win.buf, 0, -1, false), "\n")
    expect.matches(text, "protocol 1%.1")
    expect.eq(_G.EPICENTER_SENT, {})
  end)
end)
