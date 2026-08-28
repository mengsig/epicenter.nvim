--- F5: `harness.report()`'s tally used to be written with no leading
--- newline, so on a spec that provokes an on-purpose LSP crash (whose exit
--- notice Neovim itself prints without a trailing newline in headless mode)
--- the pass/fail summary landed glued onto that notice's own line - on the
--- one line a release is cut from.
local harness = require("harness")

local function capture()
  local written = {}
  local write = function(...)
    for i = 1, select("#", ...) do
      table.insert(written, (select(i, ...)))
    end
  end
  return written, write
end

describe("harness.report()", function()
  it("opens on its own line, never glued onto whatever printed before it", function()
    local written, write = capture()
    local code = harness.report(2, 0, {}, 3, 15, write)

    local joined = table.concat(written)
    expect.truthy(
      vim.startswith(joined, "\n"),
      "the report must start with a newline: " .. vim.inspect(joined)
    )
    expect.matches(joined, "2 passed, 0 failed")
    expect.eq(code, 0)
  end)

  it("still fails the run when a case failed", function()
    local _, write = capture()
    local code = harness.report(1, 1, { { ok = false, name = "x", err = "boom" } }, 1, 5, write)
    expect.eq(code, 1)
  end)
end)
