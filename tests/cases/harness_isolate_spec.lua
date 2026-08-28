--- F6: `harness.isolate()` runs between every spec file and must stop each
--- navgraph client exactly once. A second stop on an already-shutting-down
--- client races out a bare `exit` with no preceding `shutdown` - the exact
--- message shape a real server crash produces, which is how a genuine crash
--- goes unnoticed.
local harness = require("harness")
local support = require("support")

describe("harness.isolate() stops each navgraph client exactly once", function()
  it("does not re-stop a client stop_all() already handled", function()
    support.start_fake()
    local client = vim.lsp.get_clients({ name = "navgraph" })[1]
    expect.truthy(client, "the fake navgraph client must be attached before isolate() runs")

    local compat = require("epicenter.compat")
    local stop_calls = 0
    local original_stop = compat.lsp_stop
    compat.lsp_stop = function(c)
      if c.id == client.id then
        stop_calls = stop_calls + 1
      end
      return original_stop(c)
    end

    harness.isolate()

    compat.lsp_stop = original_stop
    expect.eq(stop_calls, 1, "isolate() must stop each client exactly once, not twice")
  end)
end)
