-- ООП в стиле игровых скриптов (все объекты игры для Lua — классы,
-- у нас — аналог на setmetatable): иерархия Entity -> NPC -> Stalker
-- и Entity -> Monster, полиморфные update/on_hit, super-вызовы,
-- методы, найденные через 3 уровня __index.
-- Профиль: метатабельная диспетчеризация, вызовы методов, self-доступ.

local N     = tonumber(arg and arg[1]) or 5000
local TICKS = 1000

local function class(parent)
  local c = {}
  c.__index = c
  setmetatable(c, { __index = parent })
  return c
end

local Entity = class(nil)
function Entity.new(cls, id)
  local o = {
    id = id, hp = 100.0, x = id % 64, z = (id * 3) % 64,
    log = 0, dead = false,
  }
  return setmetatable(o, cls)
end
function Entity:emit(val)                 -- находится через цепочку __index
  self.log = (self.log + val) % 1000000007
  return self.log
end
function Entity:update(dt)
  self.x = (self.x + dt) % 64
end
function Entity:on_hit(dmg)
  self.hp = self.hp - dmg
  if self.hp <= 0 then self.dead = true end
  return self.dead
end

local NPC = class(Entity)
function NPC:update(dt)
  Entity.update(self, dt)                 -- super-вызов
  self.hp = self.hp - dt * 0.5
end

local Stalker = class(NPC)
function Stalker:update(dt)
  NPC.update(self, dt)
  self.x = (self.x + dt * 2) % 64
end
function Stalker:attack(target, dmg)
  local died = target:on_hit(dmg)
  self:emit(dmg)                          -- метод класса Entity
  return died
end

local Monster = class(Entity)
function Monster:update(dt)
  self.z = (self.z + dt * 3) % 64
  Entity.update(self, dt)
end

local objs = {}
for i = 1, N do
  objs[i] = (i % 2 == 0) and Entity.new(Stalker, i) or Entity.new(Monster, i)
end

local sum = 0
for tick = 1, TICKS do
  local dt = tick % 4 + 1
  for i = 1, N do
    local o = objs[i]
    o:update(dt)                          -- полиморфизм: Stalker/Monster
    if not o.dead and i % 4 == 0 then     -- только сталкеры умеют attack
      local t = objs[1 + (i * 7) % N]
      o:attack(t, dt * 0.5)               -- cross-вызовы on_hit/emit
    end
    if o.dead and (i + tick) % 37 == 0 then
      o.hp = 100.0                        -- «респавн»
      o.dead = false
    end
  end
  for i = 1, N do
    local o = objs[i]
    sum = (sum + o.id + o.log + math.floor(o.hp * 4)) % 1000000007
  end
end

print(string.format("oop %d %d", N, sum))
