-- closures, varargs, multiple returns, metatables, OOP
local function counter()
  local n = 0
  return function() n = n + 1; return n end
end
local c = counter()
c(); c()
assert(c() == 3)

local function va(...)
  return select('#', ...), ...
end
local n, a, b = va("x", "y")
assert(n == 2 and a == "x" and b == "y")

local Animal = {}
Animal.__index = Animal
function Animal.new(name) return setmetatable({name=name}, Animal) end
function Animal:speak() return self.name .. " makes a sound" end
local Dog = setmetatable({}, {__index = Animal})
Dog.__index = Dog
function Dog.new(name) local o = Animal.new(name); return setmetatable(o, Dog) end
function Dog:speak() return self.name .. " barks" end
assert(Dog.new("rex"):speak() == "rex barks")

-- arithmetic metamethods
local V = {}
V.__index = V
V.__add = function(l, r) return setmetatable({x=l.x+r.x}, V) end
V.__eq = function(l, r) return l.x == r.x end
V.__lt = function(l, r) return l.x < r.x end
V.__tostring = function(v) return "V(" .. v.x .. ")" end
local v1, v2 = setmetatable({x=1}, V), setmetatable({x=2}, V)
assert((v1+v2).x == 3)
assert(v1 == setmetatable({x=1}, V))
assert(v1 < v2)
assert(tostring(v1) == "V(1)")

-- tail calls: deep recursion must not overflow
local function loop(n) if n == 0 then return "done" end; return loop(n - 1) end
assert(loop(300000) == "done")

-- numeric for with fresh closure var
local fns = {}
for i = 1, 3 do fns[i] = function() return i end end
assert(fns[1]() == 1 and fns[2]() == 2 and fns[3]() == 3)

print("smoke2 OK")
