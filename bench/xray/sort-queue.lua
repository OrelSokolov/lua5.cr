-- Приоритетная очередь на table.sort с компаратором
-- (task_manager, сортировки онлайн-объектов): очередь из M записей,
-- R раундов: достать срочные, поменять приоритеты половине,
-- пересортировать, добавить новых.
-- Профиль: компаратор из VM (колбэки в C-код sort), доступ к полям,
-- table.insert/remove.

local M     = tonumber(arg and arg[1]) or 2000
local ROUNDS = 1000

local function rnd(s)
  return (s * 1103515245 + 12345) % 2147483648
end

local function less(a, b)
  if a.prio ~= b.prio then return a.prio < b.prio end
  return a.id < b.id                     -- полный порядок: sort детерминирован
end

local q = {}
for i = 1, M do
  q[i] = { prio = (i * 2654435761) % 100000, id = i, tag = "t" .. (i % 50) }
end
table.sort(q, less)

local sum = 0
for r = 1, ROUNDS do
  for _ = 1, 16 do
    local it = table.remove(q, 1)
    sum = (sum + it.prio + it.id + #it.tag) % 1000000007
  end
  local n = #q
  for k = 1, n, 2 do
    q[k].prio = rnd(r * 40503 + k * 97) % 100000
  end
  table.sort(q, less)
  for k = 1, 16 do
    q[#q + 1] = {
      prio = rnd(k * 31 + r) % 100000,
      id = M + r * 16 + k,
      tag = "t" .. ((r + k) % 50),
    }
  end
end

print(string.format("sort-queue %d %d", M, sum))
