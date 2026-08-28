--- The v1.1 surface against the REAL navgraph binary. Every case first asks
--- the running server whether it announces the method under test; a build
--- that does not yet implement it SKIPS with that reason rather than failing
--- or quietly passing.
local epicenter = require("epicenter")
local support = require("support")

local SERVICE = "py_fastapi/app/services/user_service.py"
--- `def fetch(self, id: int):` - column 8 is on the method's own name.
local FETCH_LINE, FETCH_COLUMN = 11, 8

local function body(panel)
  return table.concat(vim.api.nvim_buf_get_lines(panel.win.buf, 0, -1, false), "\n")
end

local function open_service(root)
  local path = vim.fs.joinpath(root, SERVICE)
  local existing = vim.fn.bufnr(path)
  if existing ~= -1 then
    vim.api.nvim_buf_delete(existing, { force = true })
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { FETCH_LINE, FETCH_COLUMN })
  support.attach(root, buf)
  return buf
end

describe("real navgraph: the v1.1 surface", function()
  local root, buf, panel, notices

  before_each(function()
    require("epicenter.config").reset()
    epicenter.setup({ ui = { icons = "ascii" }, animate = false, lsp = { auto_start = false } })
    require("epicenter.ui.theme").apply()
    root = root or support.start_real()
    buf = open_service(root)
    notices = {}
    epicenter.notify = function(msg)
      table.insert(notices, msg)
    end
  end)

  after_each(function()
    if panel and panel.valid and panel:valid() then
      panel:close()
    end
    panel = nil
    require("epicenter.events").clear()
  end)

  it("roots the call hierarchy at the real definition under the cursor", function()
    support.require_method(root, "textDocument/prepareCallHierarchy", "call hierarchy")
    panel = epicenter.run("hierarchy", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 0
    end, 20000, "the real incoming calls")
    expect.matches(body(panel), "fetch")
  end)

  it("shows the real type hierarchy groups", function()
    support.require_method(root, "textDocument/prepareTypeHierarchy", "type hierarchy")
    vim.api.nvim_win_set_cursor(0, { 8, 6 }) -- `class UserService:`
    panel = epicenter.run("types", {}, buf)
    wait(function()
      return panel:valid() and body(panel):find("supertypes", 1, true) ~= nil
    end, 20000, "the real type groups")
    expect.matches(body(panel), "subtypes")
  end)

  it("yanks a real context bundle", function()
    support.require_method(root, "navgraph/context", "context")
    local register = require("epicenter.features.context").target_register()
    vim.fn.setreg(register, "")
    epicenter.run("context", {}, buf)
    wait(function()
      return vim.fn.getreg(register) ~= ""
    end, 20000, "the real bundle")
    expect.matches(vim.fn.getreg(register), "## `.*fetch")
    expect.matches(table.concat(notices, "\n"), "~%d+ tokens")
  end)

  it("names what encloses a real line", function()
    support.require_method(root, "navgraph/where", "where")
    epicenter.run("where", { SERVICE .. ":13" }, buf)
    wait(function()
      return #notices > 0
    end, 20000, "the real where answer")
    expect.matches(notices[1], "fetch")
  end)

  it("lists the real tests reaching this definition", function()
    support.require_method(root, "navgraph/tests", "tests panel")
    panel = epicenter.run("tests", {}, buf)
    wait(function()
      return panel:valid() and panel.list:count() > 0
    end, 20000, "the real tests")
    expect.matches(body(panel), "test_")
  end)

  it("reports the real working change's impact", function()
    support.require_method(root, "navgraph/impact", "impact")
    local err, result = support.request(root, "navgraph/impact", vim.empty_dict(), 20000)
    expect.eq(err, nil)
    expect.truthy(type(result.hunks) == "table", "an empty change is a result, never an error")
    expect.truthy(type(result.changeId) == "string")
  end)
end)
