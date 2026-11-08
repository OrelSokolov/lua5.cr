-- Векторная математика на плоских таблицах {x,y,z} (AI-логика
-- скриптов без движковых векторов): N сущностей, K тиков,
-- шаг «физики», дистанция до цели, нормализация направления.
-- Только +,-,*,/,sqrt — IEEE-детерминированные операции
-- (никаких sin/cos: libm может отличаться между сборками).

local N     = tonumber(arg and arg[1]) or 3000
local TICKS = 3000

local targets = {}
for i = 1, 64 do
  targets[i] = { x = (i * 37) % 512 - 256, y = (i * 11) % 64 - 32, z = (i * 53) % 512 - 256 }
end

local ents = {}
for i = 1, N do
  ents[i] = {
    x = i % 512 - 256, y = i % 64 - 32, z = (i * 7) % 512 - 256,
    vx = (i % 7) * 0.5 - 1.5, vy = (i % 5) * 0.25 - 0.5, vz = (i % 9) * 0.5 - 2.0,
    tg = 1 + (i * 13) % 64,
  }
end

local sum = 0
for _ = 1, TICKS do
  for i = 1, N do
    local e = ents[i]
    local t = targets[e.tg]
    e.x = e.x + e.vx
    e.y = e.y + e.vy
    e.z = e.z + e.vz
    local dx, dy, dz = t.x - e.x, t.y - e.y, t.z - e.z
    local d2 = dx * dx + dy * dy + dz * dz
    local d = math.sqrt(d2)
    if d > 1 then
      local inv = 0.01 / d                -- steer к цели + торможение
      e.vx = e.vx * 0.99 + dx * inv
      e.vy = e.vy * 0.99 + dy * inv
      e.vz = e.vz * 0.99 + dz * inv
    end
    sum = (sum + math.floor(d * 16)) % 1000000007
  end
end

print(string.format("veclib %d %d", N, sum))
