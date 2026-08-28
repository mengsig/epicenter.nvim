local prompt = require("epicenter.ui.prompt")

describe("debounce", function()
  it("coalesces a burst into a single call with the last arguments", function()
    local calls = {}
    local d = prompt.debounce(10, function(text)
      table.insert(calls, text)
    end)
    d.call("a")
    d.call("ab")
    d.call("abc")
    expect.eq(calls, {}, "nothing fires during the burst")
    wait(function()
      return #calls > 0
    end, 1000, "debounced call")
    expect.eq(calls, { "abc" })
    d.close()
  end)

  it("fires again for a later burst", function()
    local calls = 0
    local d = prompt.debounce(5, function()
      calls = calls + 1
    end)
    d.call("x")
    wait(function()
      return calls == 1
    end, 1000, "first call")
    d.call("y")
    wait(function()
      return calls == 2
    end, 1000, "second call")
    d.close()
  end)

  it("flush runs the pending call immediately", function()
    local seen
    local d = prompt.debounce(10000, function(text)
      seen = text
    end)
    d.call("now")
    expect.eq(d.pending(), true)
    d.flush()
    expect.eq(seen, "now")
    expect.eq(d.pending(), false)
    d.close()
  end)

  it("cancel drops the pending call", function()
    local calls = 0
    local d = prompt.debounce(5, function()
      calls = calls + 1
    end)
    d.call("x")
    d.cancel()
    vim.wait(40)
    expect.eq(calls, 0)
    d.close()
  end)

  it("flush is a no-op with nothing pending", function()
    local calls = 0
    local d = prompt.debounce(5, function()
      calls = calls + 1
    end)
    d.flush()
    expect.eq(calls, 0)
    d.close()
  end)
end)

describe("prompt", function()
  it("reports the text with the prefix stripped and debounces changes", function()
    require("epicenter.config").reset()
    local buf = vim.api.nvim_create_buf(false, true)
    local seen = {}
    local p = prompt.new({
      buf = buf,
      prefix = "> ",
      debounce_ms = 5,
      on_change = function(text)
        table.insert(seen, text)
      end,
    })
    p:set_text("navg")
    expect.eq(p:text(), "navg")
    p.debouncer.call(p:text())
    wait(function()
      return #seen > 0
    end, 1000, "on_change")
    expect.eq(seen[#seen], "navg")
    p:close()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
