-- Строковая нагрузка HUD/новостей (news_manager, форматирование
-- сообщений): K сообщений через string.format, конкатенацию ..,
-- gsub-подстановку плейсхолдеров, периодически string.rep/sub/find.
-- Профиль: аллокация строк, format, gsub — то, чего в числовых
-- kernel'ах нет вовсе.

local K = tonumber(arg and arg[1]) or 1000000

local names = {
  "Wolf", "Fanatic", "Tracer", "Bes", "Seriy", "Mole", "Barin",
  "Orest", "Mitay", "Dushman", "Sakhrov", "Zhorik", "Ashot", "Hans",
}
local weapons = {
  "ak74", "mp5", "toz34", "spas12", "groza", "vintorez", "svd", "fort",
}
local tmpl     = "%s killed %s with %s at %dm"
local tmpl_hit = "<n> took <d> damage from <w>"

local function rnd(s)
  return (s * 1103515245 + 12345) % 2147483648
end

local function hstr(h, str)
  h = (h * 31 + #str) % 1000000007
  for j = 1, #str, 7 do
    h = (h * 31 + string.byte(str, j)) % 1000000007
  end
  return h
end

local sum = 0
for i = 1, K do
  local s = rnd(i * 31 + 7)
  local n1 = names[1 + s % #names]
  local n2 = names[1 + math.floor(s / 7) % #names]
  local w  = weapons[1 + math.floor(s / 13) % #weapons]
  local msg = string.format(tmpl, n1, n2, w, s % 400) ..
              " [" .. n1 .. "]"
  sum = hstr(sum, msg)
  if s % 3 == 0 then
    local line = string.gsub(tmpl_hit, "<n>", n2)
    line = string.gsub(line, "<d>", tostring(s % 250))
    line = string.gsub(line, "<w>", w)
    sum = hstr(sum, line)
  end
  if s % 97 == 0 then
    local blob = string.rep(msg, 3)       -- редкая длинная строка
    sum = hstr(sum, string.sub(blob, 10, 120))
  end
  if s % 11 == 0 then
    local p = string.find(msg, " with ", 1, true)
    sum = (sum + (p or 0)) % 1000000007
  end
end

print(string.format("news %d %d", K, sum))
