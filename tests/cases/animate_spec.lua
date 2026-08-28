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

  it("scales the skip to how far over budget a frame ran, at a higher fps", function()
    -- 120fps -> an 8.33ms interval; a 100ms frame is 12 intervals over, but
    -- the skip must cap at 3 (4 intervals = 33.3ms = exactly the 30fps floor).
    local clock, driver = fake_clock(), animate.manual_driver()
    local frame_at = {}
    animate.tween({
      duration = 10000,
      motion = true,
      fps = 120,
      frame_budget_ms = 4,
      clock = clock.fn,
      driver = driver.driver,
      on_frame = function()
        table.insert(frame_at, clock.now)
        clock.now = clock.now + 100 -- a very expensive frame
      end,
    })
    clock.now = 10
    for _ = 1, 6 do
      driver.step()
    end
    expect.eq(#frame_at, 2, "3 ticks skipped after the slow frame, not just 1")
  end)

  it("caps the skip so a catastrophically slow frame cannot stall the tween further", function()
    -- 120fps -> an 8.33ms interval -> the cap is 3 skips (4 intervals =
    -- 33.3ms = the 30fps floor). A 100ms frame and a 500ms frame both hit
    -- that same cap - skipping more would only add delay with no upside.
    local function frames_over(cost)
      local clock, driver = fake_clock(), animate.manual_driver()
      local count = 0
      animate.tween({
        duration = 1e6,
        motion = true,
        fps = 120,
        frame_budget_ms = 4,
        clock = clock.fn,
        driver = driver.driver,
        on_frame = function()
          count = count + 1
          clock.now = clock.now + cost
        end,
      })
      clock.now = 10
      for _ = 1, 8 do
        driver.step()
      end
      return count
    end
    expect.eq(frames_over(100), frames_over(500), "both cap at the same skip count")
  end)

  it("does not skip once a frame is back under budget", function()
    local clock, driver = fake_clock(), animate.manual_driver()
    local frames = 0
    local slow = true
    animate.tween({
      duration = 1000,
      motion = true,
      frame_budget_ms = 8,
      clock = clock.fn,
      driver = driver.driver,
      on_frame = function()
        frames = frames + 1
        clock.now = clock.now + (slow and 20 or 1)
        slow = false
      end,
    })
    clock.now = 10
    driver.step() -- slow frame -> one skip at the default 60fps
    driver.step() -- skipped
    driver.step() -- fast frame, no further skip
    driver.step()
    expect.eq(frames, 3)
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
