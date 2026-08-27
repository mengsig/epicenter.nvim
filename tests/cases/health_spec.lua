local function run_checkhealth()
  vim.cmd("silent checkhealth epicenter")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local text = table.concat(lines, "\n")
  vim.cmd("bwipeout!")
  return text
end

describe("checkhealth epicenter", function()
  local install = require("epicenter.install")
  local original_resolve, original_system, system_calls

  -- Every case runs hermetically by default (F5): no real `navgraph --version`
  -- shell-out. A case that needs the real resolve() failure path restores it
  -- itself - is_executable() is a filesystem check, never a host shell-out.
  before_each(function()
    require("epicenter.config").reset()
    original_resolve, original_system = install.resolve, vim.system
    system_calls = {}
    install.resolve = function()
      return "/fake/navgraph", nil
    end
    vim.system = function(cmd, _)
      table.insert(system_calls, cmd)
      return {
        wait = function()
          return { code = 0, stdout = "navgraph 9.9.9\n", stderr = "" }
        end,
      }
    end
  end)

  after_each(function()
    install.resolve = original_resolve
    vim.system = original_system
  end)

  -- Every recorded vim.system call must have gone through the fake, never a
  -- real host binary (F5): fails loudly if a code path escapes stubbing.
  local function expect_hermetic()
    expect.truthy(#system_calls > 0, "check_binary should have called vim.system")
    for _, cmd in ipairs(system_calls) do
      expect.eq(cmd[1], "/fake/navgraph", "must not shell out to a real navgraph binary: " .. vim.inspect(cmd))
    end
  end

  it("reports on neovim, the binary, servers and icons", function()
    local report = run_checkhealth()
    expect.matches(report, "epicenter%.nvim")
    expect.matches(report, "neovim")
    expect.matches(report, "navgraph")
    expect.matches(report, "icons")
    expect.falsy(report:match("Failed to run healthcheck"), report)
    expect_hermetic()
  end)

  it("tells the user how to get the binary when it is missing", function()
    install.resolve = original_resolve
    require("epicenter.config").setup({ navgraph = { path = "/definitely/not/here/navgraph" } })
    local report = run_checkhealth()
    expect.matches(report, "/definitely/not/here/navgraph")
    expect.matches(report, ":Epicenter install")
  end)

  it("says no server is running before any buffer is indexed", function()
    local report = run_checkhealth()
    expect.matches(report, "no navgraph server running yet")
    expect_hermetic()
  end)

  it(
    "reports the resolved binary version hermetically, distinguishing OK from ERROR (F19)",
    function()
      local ok, report = pcall(run_checkhealth)

      expect.eq(ok, true, report)
      expect.matches(report, "OK.*navgraph binary: /fake/navgraph")
      expect.matches(report, "OK.*navgraph version: navgraph 9%.9%.9")
      expect.falsy(report:match("ERROR"), "a healthy resolve must never report ERROR")
      expect_hermetic()
    end
  )
end)
