--- The game/state engine: owns a pool of entities and advances the whole
-- simulation one tick at a time.
local Entity = require("entity")
local util = require("util")

local Game = {}
Game.__index = Game

--- Remove dead entities from `game` in place. Module-private helper.
local function reap(game)
  local live = {}
  for _, e in ipairs(game.entities) do
    if e.alive then
      table.insert(live, e)
    end
  end
  game.entities = live
end

--- Create an empty game world with no entities and a zero tick counter.
function Game.new()
  local self = setmetatable({}, Game)
  self.entities = {}
  self.tick = 0
  return self
end

--- Spawn a new entity at (x, y), register it in the pool, and return it.
function Game:spawn(x, y)
  local e = Entity.new(x, y)
  table.insert(self.entities, e)
  return e
end

--- Advance every entity by `dt`, bump the (clamped) tick, and reap the dead.
function Game:step(dt)
  self.tick = util.clamp(self.tick + 1, 0, 1000)
  for _, e in ipairs(self.entities) do
    e:advance(dt)
  end
  reap(self)
end

--- Number of entities currently in the pool. Assignment-form method field.
Game.count = function(self)
  return #self.entities
end

return Game
