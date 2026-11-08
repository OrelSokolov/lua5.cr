-- Менеджер корутин-таймеров (отложенные действия в модах,
-- scheme-логика с ожиданием): M корутин, каждая делает 8 wait(n)
-- с «случайными» задержками; менеджер каждый тик резюмит
-- просроченные. Порядок — массив, не pairs: детерминированно.
-- Профиль: create/resume/yield/status, передача значений.

local M = tonumber(arg and arg[1]) or 80000

local function wait(n)
  return coroutine.yield(n)
end

local function run_task(i)
  local s = i % 977
  for k = 1, 8 do
    local w = wait(k % 5 + 1 + s % 3)
    s = s + w + k
  end
  return s
end

local tasks = {}
for i = 1, M do
  tasks[i] = { co = coroutine.create(run_task), wake = 1 + i % 40, i = i }
end

local sum, alive = 0, M
local tick = 0
while alive > 0 do
  tick = tick + 1
  for j = 1, M do
    local t = tasks[j]
    if t and t.wake <= tick then
      local ok, res = coroutine.resume(t.co, t.i)
      if not ok then error(res) end
      if coroutine.status(t.co) == "dead" then
        sum = (sum + res) % 1000000007
        tasks[j] = false
        alive = alive - 1
      else
        t.wake = tick + res               -- res = сколько тиков спать
      end
    end
  end
  if tick > 100000 then break end         -- страховка
end

print(string.format("coro-mgr %d %d %d", M, tick, sum))
