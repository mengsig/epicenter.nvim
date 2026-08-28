--- Entry point for the tiny top-down game. Wires the engine modules together
-- and drives them from love2d-style callbacks.
local Game = require("game")
local Vec = require("vec")
local util = require("util")

-- The single live world. love.load builds it before the first frame.
local world

--- love2d load callback: build the world and seed it with a wave of entities.
function love.load()
  world = Game.new()
  spawnWave(world, 8)
end

--- love2d per-frame update: step the whole simulation by `dt` seconds.
function love.update(dt)
  world:step(dt)
end

--- love2d draw callback: report the live entity count once per frame.
function love.draw()
  util.log("entities: " .. world:count())
end

--- Seed `world` with `n` entities spread along a line, each nudged downward.
-- A plain global function (not attached to any module table).
function spawnWave(world, n)
  for i = 1, n do
    local e = world:spawn(i * 10, 0)
    e:push(Vec.dir.down)
  end
end

return true
