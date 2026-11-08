-- Диспетчер колбэков (аналог script_callback_ex и luabind-функторов
-- в xray-16: движок дергает Lua-функции каждый кадр):
-- M подписчиков на 4 события, K тиков; колбэки — замыкания из фабрики,
-- часть отписывается и переподписывается на лету.
-- Профиль: вызовы функций из VM, замыкания, string-keyed lookup,
-- table.remove/insert в горячем цикле.

local M     = tonumber(arg and arg[1]) or 20000
local TICKS = 600

local ENAMES = { "on_hit", "on_death", "on_update", "on_item" }
local handlers = {}
for k = 1, #ENAMES do handlers[ENAMES[k]] = {} end

local fired = 0

local function subscribe(list, i)
  local f = function(id, a, b)
    fired = fired + 1
    return (i + id) % 97 + (a or 0) - (b or 0)
  end
  list[#list + 1] = f
  return f
end

for i = 1, M do
  subscribe(handlers[ENAMES[1 + (i * 7) % #ENAMES]], i)
end

local sum = 0
for tick = 1, TICKS do
  for k = 1, #ENAMES do
    local list = handlers[ENAMES[k]]
    local a1, a2 = tick, tick * 3 + k
    for j = #list, 1, -1 do
      local f = list[j]
      if f == false then
        table.remove(list, j)
      else
        sum = (sum + f(j, a1, a2)) % 1000000007
        if (j + tick) % 23 == 0 then list[j] = false end           -- отписка
        if (j * 13 + tick) % 41 == 0 then subscribe(list, j + tick) end
      end
    end
  end
end

print(string.format("events %d %d", M, (sum + fired) % 1000000007))
