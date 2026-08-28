--- Assorted helpers (logging, clamping) plus intentionally-dead fixture
-- symbols so `navgraph unused` has a clear target.
local M = {}

--- Print `msg` to stdout with the game prefix.
function M.log(msg)
  print("[game] " .. msg)
end

--- Clamp `v` into the inclusive range [lo, hi].
function M.clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

-- intentionally dead (fixture): a private helper nothing calls.
local function countKeys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

-- intentionally dead (fixture): a config "type" table nothing references.
local DeadConfig = {
  retries = 3,
  verbose = false,
}

return M
