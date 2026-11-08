-- «Кадр» smart-terrain / xr_logic (xray-16: db.storage[npc_id]):
-- N объектов в большой хеш-таблице, K тиков; каждый тик — перебор
-- pairs, фильтрация по состоянию, запись полей, «поиск цели»
-- линейным сканом по соседям, редкие delete/insert (rehash).
-- Профиль: generic-for по хеш-таблице, целочисленные апдейты.
-- Детерминизм: поведение объекта зависит только от (id, tick),
-- «рандом» — чистый LCG без math.random (последовательности
-- PUC Lua и LuaJIT не совпадают).

local N     = tonumber(arg and arg[1]) or 4000
local TICKS = 600

local storage = {}
local ids = {}

for i = 1, N do
  local id = i * 7 + 3                 -- разреженные id → hash-часть
  ids[i] = id
  storage[id] = {
    hp = 40 + (i % 60), section = (i % 4 == 0) and "stalker" or "monster",
    state = i % 3, level = 100 + (i % 5),
    x = i % 64, z = (i * 3) % 64, target = nil,
  }
end

local function rnd(s)
  return (s * 1103515245 + 12345) % 2147483648
end

local sum = 0
for tick = 1, TICKS do
  local active = 0
  for id, st in pairs(storage) do
    local s = rnd(id * 31 + tick)
    if st.state == 0 then
      if s % 16 == 0 then st.state = 1; st.level = st.level + 1 end
    elseif st.state == 1 then
      st.hp = st.hp - 1
      if st.hp <= 20 or s % 32 == 0 then st.state = 2; st.target = nil end
      if s % 8 == 0 then
        -- «выбор цели»: линейный скан по соседям
        local best, bd = nil, 2000000000
        for k = 1, 8 do
          local nst = storage[ids[1 + (s + k * 97) % N]]
          local d = (nst.x - st.x) * (nst.x - st.x) + (nst.z - st.z) * (nst.z - st.z)
          if d < bd then bd, best = d, nst end
        end
        st.target = best
        sum = (sum + bd) % 1000000007
      end
      active = active + 1
    else
      if s % 64 == 0 then
        st.state = 0
        st.hp = 40 + (id % 60)
      end
    end
  end
  sum = (sum + active) % 1000000007
  -- редкий delete/insert: аллокация + rehash, как при спавне/деспавне NPC
  if tick % 20 == 0 then
    local victim = ids[1 + (tick * 13) % N]
    local st = storage[victim]
    storage[victim] = nil
    storage[victim] = st
  end
end

print(string.format("xr-update %d %d", N, sum))
