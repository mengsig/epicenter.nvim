local function run_checkhealth()
  vim.cmd("silent checkhealth epicenter")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local text = table.concat(lines, "\n")
  vim.cmd("bwipeout!")
  return text
end

describe("checkhealth epicenter", function()
  before_each(function()
    require("epicenter.config").reset()
  end)

  it("reports on neovim, the binary, servers and icons", function()
    local report = run_checkhealth()
    expect.matches(report, "epicenter%.nvim")
    expect.matches(report, "neovim")
    expect.matches(report, "navgraph")
    expect.matches(report, "icons")
    expect.falsy(report:match("Failed to run healthcheck"), report)
  end)

  it("tells the user how to get the binary when it is missing", function()
    require("epicenter.config").setup({ navgraph = { path = "/definitely/not/here/navgraph" } })
    local report = run_checkhealth()
    expect.matches(report, "/definitely/not/here/navgraph")
    expect.matches(report, ":Epicenter install")
  end)

  it("says no server is running before any buffer is indexed", function()
    local report = run_checkhealth()
    expect.matches(report, "no navgraph server running yet")
  end)

  it(
    "reports the resolved binary version hermetically, distinguishing OK from ERROR (F19)",
    function()
      -- With a real navgraph on $PATH, this used to shell out to it for real -
      -- non-hermetic, and the old assertions were weak enough to pass either way.
      local install = require("epicenter.install")
      local original_resolve, original_system = install.resolve, vim.system
      install.resolve = function()
        return "/fake/navgraph", nil
      end
      vim.system = function(_, _)
        return {
          wait = function()
            return { code = 0, stdout = "navgraph 9.9.9\n", stderr = "" }
          end,
        }
      end

      local ok, report = pcall(run_checkhealth)

      install.resolve = original_resolve
      vim.system = original_system

      expect.eq(ok, true, report)
      expect.matches(report, "OK.*navgraph binary: /fake/navgraph")
      expect.matches(report, "OK.*navgraph version: navgraph 9%.9%.9")
      expect.falsy(report:match("ERROR"), "a healthy resolve must never report ERROR")
    end
  )
end)
