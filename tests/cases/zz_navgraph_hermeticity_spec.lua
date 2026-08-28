--- F5: the fake lane must never resolve a real $PATH/managed navgraph. Named
--- to sort last (`tests/run.lua` sorts `tests/cases/*_spec.lua`
--- alphabetically) so it sees every spawn the whole suite made, not only its
--- own - a spec earlier in the run is exactly what leaked one before this fix.
local support = require("support")

--- A cmd is acceptable when its leading elements are exactly `fake_cmd(root)`
--- for SOME root - `client_integration_spec.lua` appends its own trailing
--- `--tag=...` marker to force a "different cmd" restart, which is still the
--- fake server, just decorated.
local function is_fake_cmd(cmd)
  local root = cmd[8]
  if root == nil then
    return false
  end
  local expected = support.fake_cmd(root)
  for i = 1, #expected do
    if cmd[i] ~= expected[i] then
      return false
    end
  end
  return true
end

describe("hermeticity: every navgraph client this run started", function()
  it("used only the fake server cmd - never $PATH or the managed install", function()
    local spawns = _G.EPICENTER_TEST_NAVGRAPH_SPAWNS or {}
    expect.truthy(#spawns > 0, "no navgraph client spawned this run - the guard would be vacuous")
    for _, cmd in ipairs(spawns) do
      expect.truthy(is_fake_cmd(cmd), "unexpected navgraph cmd: " .. table.concat(cmd, " "))
    end
  end)
end)
