local animate = require("epicenter.ui.animate")
local easing = require("epicenter.ui.easing")

local function fake_clock()
  local state = { now = 0 }
  state.fn = function()
    return state.now
  end
  return state
end

describe("animate", function()
  it("walks t from 0 to 1 over the duration", function()
    local clock, driver = fake_clock(), animate.manual_driver()
    local seen = {}
    local handle = animate.tween({
      duration = 100,
      motion = true,
      easing = easing.linear,
      clock = clock.fn,
      driver = driver.driver,
      on_frame = function(eased, t)
        table.insert(seen, { eased = eased, t = t })
      end,
    })

    clock.now = 25
    driver.step()
    clock.now = 100
    driver.step()

    expect.eq(#seen, 2)
    expect.near(seen[1].t, 0.25)
    expect.near(seen[2].t, 1)
    expect.eq(handle.done(), true)
    expect.eq(driver.running(), false, "the timer must stop when the tween ends")
  end)

  it("reports completion once", function()
    local clock, driver = fake_clock(), animate.manual_driver()
    local completed = 0
    animate.tween({
      duration = 10,
      motion = true,
      clock = clock.fn,
      driver = driver.driver,
      on_frame = function() end,
      on_done = function()
        completed = completed + 1
      end,
    })
    clock.now = 10
    driver.step()
    driver.step()
    expect.eq(completed, 1)
  end)

  it("cancel stops the timer and reports incompletion", function()
    local clock, driver = fake_clock(), animate.manual_driver()
    local completed = nil
    local frames = 0
    local handle = animate.tween({
      duration = 100,
      motion = true,
      clock = clock.fn,
      driver = driver.driver,
      on_frame = function()
        frames = frames + 1
      end,
      on_done = function(ok)
        completed = ok
      end,
    })
    clock.now = 10
    driver.step()
    handle.cancel()
    clock.now = 50
    driver.step()
    expect.eq(frames, 1, "no frame runs after cancel")
    expect.eq(completed, false)
    expect.eq(driver.running(), false)
  end)

  it("skips the frame after one that blew the budget", function()
    local clock, driver = fake_clock(), animate.manual_driver()
    local frames = 0
    animate.tween({
      duration = 1000,
      motion = true,
      frame_budget_ms = 8,
      clock = clock.fn,
      driver = driver.driver,
      on_frame = function()
        frames = frames + 1
        clock.now = clock.now + 20 -- an expensive frame
      end,
    })
    clock.now = 10
    driver.step()
    expect.eq(frames, 1)
    driver.step() -- dropped, not queued
    expect.eq(frames, 1)
    driver.step()
    expect.eq(frames, 2)
  end)

  it("lands on the final state synchronously when motion is off", function()
    local seen, completed = nil, nil
    local handle = animate.tween({
      duration = 500,
      motion = false,
      on_frame = function(eased, t)
        seen = { eased, t }
      end,
      on_done = function(ok)
        completed = ok
      end,
    })
    expect.eq(seen, { 1, 1 })
    expect.eq(completed, true)
    expect.eq(handle.done(), true)
  end)

  it("treats a zero duration as instant", function()
    local seen = nil
    animate.tween({
      duration = 0,
      motion = true,
      on_frame = function(eased)
        seen = eased
      end,
    })
    expect.eq(seen, 1)
  end)
end)
