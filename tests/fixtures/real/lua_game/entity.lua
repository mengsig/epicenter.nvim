--- A single moving actor. Entities own a position and velocity and integrate
-- themselves forward each tick using the shared vector helpers.
local Vec = require("vec")

local Entity = {}
Entity.__index = Entity

--- Construct an entity at (x, y) with zero velocity, alive.
function Entity.new(x, y)
  local self = setmetatable({}, Entity)
  self.pos = Vec.make(x, y)
  self.vel = Vec.make(0, 0)
  self.alive = true
  return self
end

--- Add direction vector `d` to this entity's velocity.
function Entity:push(d)
  self.vel = Vec.add(self.vel, d)
end

--- Integrate position from velocity over `dt` seconds.
function Entity:advance(dt)
  self.pos = Vec.add(self.pos, Vec.scale(self.vel, dt))
end

--- Mark this entity dead so the game reaps it on the next step.
function Entity:kill()
  self.alive = false
end

return Entity
