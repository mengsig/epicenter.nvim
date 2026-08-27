local events = require("epicenter.events")

describe("events", function()
  before_each(function()
    events.clear()
  end)

  it("delivers payloads to subscribers", function()
    local seen
    events.on(events.INDEXED, function(p)
      seen = p
    end)
    events.emit(events.INDEXED, { files = 3 })
    expect.eq(seen, { files = 3 })
  end)

  it("unsubscribes", function()
    local calls = 0
    local off = events.on(events.INDEXED, function()
      calls = calls + 1
    end)
    events.emit(events.INDEXED, {})
    off()
    events.emit(events.INDEXED, {})
    expect.eq(calls, 1)
  end)

  it("keeps notifying after a subscriber errors", function()
    local reached = false
    events.on(events.INDEXED, function()
      error("boom")
    end)
    events.on(events.INDEXED, function()
      reached = true
    end)
    events.emit(events.INDEXED, {})
    expect.eq(reached, true)
  end)

  it("mirrors onto a User autocmd", function()
    local data
    local group = vim.api.nvim_create_augroup("EpicenterEventsSpec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = events.INDEXED,
      callback = function(ev)
        data = ev.data
      end,
    })
    events.emit(events.INDEXED, { symbols = 7 })
    vim.api.nvim_del_augroup_by_id(group)
    expect.eq(data, { symbols = 7 })
  end)
end)
