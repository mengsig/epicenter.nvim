--- Easing curves. Pure: t in [0,1] -> eased in [0,1], input clamped.
local M = {}

local function clamp(t)
  if t < 0 then
    return 0
  end
  if t > 1 then
    return 1
  end
  return t
end

function M.linear(t)
  return clamp(t)
end

function M.out_cubic(t)
  t = clamp(t)
  local f = 1 - t
  return 1 - f * f * f
end

function M.in_cubic(t)
  t = clamp(t)
  return t * t * t
end

function M.in_out_cubic(t)
  t = clamp(t)
  if t < 0.5 then
    return 4 * t * t * t
  end
  local f = -2 * t + 2
  return 1 - (f * f * f) / 2
end

function M.out_quart(t)
  t = clamp(t)
  local f = 1 - t
  return 1 - f * f * f * f
end

--- Linear interpolation, used by every tween call site.
function M.lerp(from, to, t)
  return from + (to - from) * t
end

M.clamp = clamp

return M
