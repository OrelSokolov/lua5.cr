-- Churn маленьких таблиц (временные таблицы scheme-логики, дескрипторы
-- спавна): M таблиц за тик, каждая — hash-поля + array-часть +
-- вложенная таблица + строковый ключ; часть уезжает в кольцо
-- «долго живущих», большинство умирает сразу.
-- Профиль: аллокации таблиц/строк, GC-давление мелкими объектами
-- (в отличие от binary-trees — много мелкого, а не глубокое дерево).

local M     = tonumber(arg and arg[1]) or 24000
local TICKS = 60

local function rnd(s)
  return (s * 1103515245 + 12345) % 2147483648
end

local ring = {}
local sum = 0
for tick = 1, TICKS do
  for i = 1, M do
    local s = rnd(tick * 97 + i * 31)
    local go = { x = s % 64, y = (i % 8) * 8, z = (s / 64) % 64 }
    local t = {
      id = i,
      section = "logic@" .. i,            -- строка → аллокация
      level_vertex = s % 100000,
      go = go,
    }
    for k = 1, 4 do t[k] = (s + k * 7) % 100 end
    sum = (sum + t.go.x + t[2] + #t.section) % 1000000007
    if s % 64 == 0 then                   -- 1/64 переживает тик
      local slot = (i % 256) + 1
      ring[slot] = t
    end
  end
  for k = 1, 256 do
    local t = ring[k]
    if t then sum = (sum + t.id + t.go.y) % 1000000007 end
  end
end

print(string.format("spawn %d %d", M, sum))
