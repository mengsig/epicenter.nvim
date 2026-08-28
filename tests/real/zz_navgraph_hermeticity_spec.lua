--- F5: the real lane must never fall back to a bare $PATH lookup or spawn
--- the fake server - only the explicitly configured real binary
--- (`support.real_bin()`, `$NAVGRAPH_BIN` or the Makefile default). Named to
--- sort last so it sees every spawn the whole lane made, including the F7
--- `vim.lsp.enable` route (`lsp/navgraph.lua`), whose cmd carries no
--- `--root` flag and so cannot be matched against `support.real_cmd()`
--- verbatim - only the resolved binary and subcommand matter here.
local support = require("support")

describe("hermeticity: every navgraph client the real lane started", function()
  it("used only the explicitly configured real binary", function()
    local spawns = _G.EPICENTER_TEST_NAVGRAPH_SPAWNS or {}
    expect.truthy(#spawns > 0, "no navgraph client spawned this run - the guard would be vacuous")
    for _, cmd in ipairs(spawns) do
      expect.eq(cmd[1], support.real_bin(), "unexpected binary: " .. table.concat(cmd, " "))
      expect.eq(cmd[2], "lsp", "unexpected subcommand: " .. table.concat(cmd, " "))
    end
  end)
end)
