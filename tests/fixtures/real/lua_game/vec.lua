--- 2D vector helpers, built as a table of small pure functions plus a nested
-- table of unit directions. Shared by the engine's entities.
local Vec = {
  --- Make a fresh vector `{ x, y }`.
  make = function(x, y)
    return { x = x, y = y }
  end,

  --- Component-wise sum of two vectors.
  add = function(a, b)
    return { x = a.x + b.x, y = a.y + b.y }
  end,

  --- Scale vector `v` by scalar `s`.
  scale = function(v, s)
    return { x = v.x * s, y = v.y * s }
  end,

  --- Squared length of `v` (no sqrt). Currently unused by the engine.
  lensq = function(v)
    return v.x * v.x + v.y * v.y
  end,

  -- Nested table (construct): named unit directions plus a helper that lives
  -- one level deep, to probe how nested function fields are attributed.
  dir = {
    up = { x = 0, y = -1 },
    down = { x = 0, y = 1 },
    opposite = function(d)
      return { x = -d.x, y = -d.y }
    end,
  },
}

return Vec
