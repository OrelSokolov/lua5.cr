-- pcall / error / xpcall / assert semantics
local ok, err = pcall(function() error("boom") end)
assert(ok == false and err:find("boom$") ~= nil)

local ok2, err2 = pcall(function() error("plain", 0) end)
assert(ok2 == false and err2 == "plain")

local ok3, err3 = pcall(function() error({code = 42}) end)
assert(ok3 == false and type(err3) == "table" and err3.code == 42)

assert(pcall(error) == false) -- error(nil) -> false, nil

local ok4, msg = pcall(function() local x = nil; return x.field end)
assert(ok4 == false and msg:find("attempt to index") ~= nil)

local ok5 = pcall(function() return 1, 2 end)
assert(ok5 == true)

-- xpcall with handler
local ok6, res = xpcall(function() error("oops") end, function(e) return "handled: " .. e end)
assert(ok6 == false and res:find("^handled") ~= nil)

-- assert returns all args
assert(select(2, assert(1, "a", "b")) == "a")

-- loadstring
local f, e = loadstring("return 6*7")
assert(f and f() == 42)
local f2, e2 = loadstring("retur nonsense")
assert(f2 == nil and type(e2) == "string")

-- select/unpack edge cases
assert(select("#") == 0)
assert(select("#", nil, nil) == 2)
local t = {10, 20, 30}
local a, b, c = unpack(t)
assert(a == 10 and b == 20 and c == 30)

-- next / pairs iteration and deletion-safe enough for MVP
local pt = {x = 1, y = 2, z = 3}
local sum = 0
for k, v in pairs(pt) do sum = sum + v end
assert(sum == 6)

-- raw*
local rt = setmetatable({}, {__index = function() return 99 end, __eq = function() return true end})
assert(rt.missing == 99)
assert(rawget(rt, "missing") == nil)
assert(rawequal(rt, rt) and not rawequal(rt, {}))

-- while/repeat/break
local i = 0
while true do i = i + 1; if i > 4 then break end end
assert(i == 5)
local j = 0
repeat local k = j + 1; j = k until k >= 3
assert(j == 3)

-- numeric for negative step
local acc = {}
for x = 3, 1, -1 do acc[#acc+1] = x end
assert(#acc == 3 and acc[1] == 3 and acc[3] == 1)

-- tostring/getmetatable
assert(tostring(12) == "12" and tostring(nil) == "nil" and tostring(true) == "true")
local mt = {}
local withmt = setmetatable({}, mt)
assert(getmetatable(withmt) == mt)
local prot = setmetatable({}, {__metatable = "locked"})
assert(getmetatable(prot) == "locked")
assert(not pcall(setmetatable, prot, nil))

-- string coercion in arithmetic
assert("10" + 5 == 15 and "3" * "4" == 12)
assert(10 .. 20 == "1020")

print("smoke4 OK")
