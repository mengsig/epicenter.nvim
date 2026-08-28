--- Tween engine: one `vim.uv` timer per running tween, no polling when idle.
--- The clock and the timer driver are injectable so the maths is testable
--- without wall-clock sleeps.
local M = {}

local compat = require("epicenter.compat")
local easing = require("epicenter.ui.easing")

local uv = vim.uv or vim.loop

--- @return fun(): number milliseconds, monotonic
function M.uv_clock()
  return function()
    return uv.hrtime() / 1e6
  end
end

--- Real driver: a repeating uv timer.
function M.uv_driver()
  local timer = nil
  return {
    start = function(interval_ms, tick)
      timer = uv.new_timer()
      timer:start(interval_ms, interval_ms, vim.schedule_wrap(tick))
    end,
    stop = function()
      if timer then
        timer:stop()
        if not timer:is_closing() then
          timer:close()
        end
        timer = nil
      end
    end,
  }
end

--- Test driver: `step()` advances exactly one frame.
--- @return { driver: table, step: fun(), running: fun(): boolean }
function M.manual_driver()
  local tick, running = nil, false
  return {
    driver = {
      start = function(_, fn)
        tick, running = fn, true
      end,
      stop = function()
        running = false
      end,
    },
    step = function()
      assert(tick, "driver was never started")
      tick()
    end,
    running = function()
      return running
    end,
  }
end

--- Runs `on_frame(eased, t)` from t=0 to t=1 over `duration` ms.
---
--- With motion off the tween does not start: `on_frame(1, 1)` and `on_done`
--- fire synchronously, so every call site lands on the final state either way.
---
--- @param opts { duration?: integer, easing?: fun(number): number,
---   on_frame: fun(eased: number, t: number), on_done?: fun(completed: boolean),
---   fps?: integer, frame_budget_ms?: number, motion?: boolean,
---   clock?: fun(): number, driver?: table }
--- @return { cancel: fun(), done: fun(): boolean }
function M.tween(opts)
  compat.validate("on_frame", opts.on_frame, "function")

  local cfg = require("epicenter.config").get()
  local motion = opts.motion
  if motion == nil then
    motion = require("epicenter.config").motion_enabled()
  end

  local duration = opts.duration or cfg.animation.open_ms
  local ease = opts.easing or easing.out_cubic
  local finished = false

  if not motion or duration <= 0 then
    opts.on_frame(1, 1)
    if opts.on_done then
      opts.on_done(true)
    end
    return {
      cancel = function() end,
      done = function()
        return true
      end,
    }
  end

  local clock = opts.clock or M.uv_clock()
  local driver = opts.driver or M.uv_driver()
  local budget = opts.frame_budget_ms or cfg.animation.frame_budget_ms
  local interval = math.max(1, math.floor(1000 / (opts.fps or cfg.animation.fps)))
  local start = clock()
  local skips_left = 0

  -- The floor a slow terminal must never fall below BY OUR OWN skipping,
  -- not by the redraw cost itself: skipping more ticks than this after a
  -- slow frame would only add delay a real render already forces, with no
  -- upside - so the skip count is capped at whatever still lets a painted
  -- frame occur at least every `min_frame_ms` (30fps) worth of ticks.
  local min_frame_ms = 1000 / 30
  local max_skips = math.max(0, math.floor(min_frame_ms / interval) - 1)

  local function finish(completed)
    if finished then
      return
    end
    finished = true
    driver.stop()
    if opts.on_done then
      opts.on_done(completed)
    end
  end

  local function tick()
    if finished then
      return
    end
    local t = math.min(1, (clock() - start) / duration)
    -- An over-budget frame drops ticks rather than queueing behind them - the
    -- count scales with how far over budget it ran, capped by `max_skips` so
    -- skipping itself never pushes the achievable rate below 30fps.
    if skips_left > 0 and t < 1 then
      skips_left = skips_left - 1
      return
    end
    local frame_start = clock()
    local ok, err = pcall(opts.on_frame, ease(t), t)
    if not ok then
      finish(false)
      require("epicenter.log").error("tween frame failed: %s", err)
      vim.schedule(function()
        vim.notify("epicenter: animation stopped: " .. tostring(err), vim.log.levels.ERROR)
      end)
      return
    end
    local cost = clock() - frame_start
    skips_left = cost > budget and math.min(max_skips, math.floor(cost / interval)) or 0
    if t >= 1 then
      finish(true)
    end
  end

  driver.start(interval, tick)

  return {
    cancel = function()
      finish(false)
    end,
    done = function()
      return finished
    end,
  }
end

return M
