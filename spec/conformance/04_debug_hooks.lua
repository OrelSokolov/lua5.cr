-- debug hooks (5.1 ldebug/lvm): line/call/return/count events, per-state
-- hooks, tail-call levels, thread-aware debug functions.
-- Compact distillation of the lua5.1-tests db.lua sections that guard the
-- VM-level hook machinery.

local function dostring(s) return assert(loadstring(s))() end

-- line traces: fresh chunk frame fires at pc 0, backward jumps (loops)
-- re-fire, FORLOOP is attributed the `for` line
local function test (s, l)
  local function f (event, line)
    assert(event == 'line')
    local want = table.remove(l, 1)
    assert(want == line, "wrong trace!!")
  end
  debug.sethook(f, "l"); loadstring(s)(); debug.sethook()
  assert(table.getn(l) == 0)
end

test([[if
math.sin(1)
then
  a=1
else
  a=2
end
]], {2,4,7})

test([[local a
a=1
while a<=3 do
  a=a+1
end
]], {2,3,4,3,4,3,4,3,5})

test([[for i=1,3 do
  a=i
end
]], {1,2,1,2,1,2,1,3})

test([[for i,v in pairs{'a','b'} do
  a=i..v
end
]], {1,2,1,2,1,3})

test([[for i=1,4 do a=1 end]], {1,1,1,1,1})

-- count hooks: one instruction per empty loop iteration
local a = 0
debug.sethook(function (e) a = a + 1 end, "", 1)
a = 0; for i=1,1000 do end; assert(1000 < a and a < 1012)
debug.sethook(function (e) a = a + 1 end, "", 4)
a = 0; for i=1,1000 do end; assert(250 < a and a < 255)
local f, m, c = debug.gethook()
assert(m == "" and c == 4)
debug.sethook(function (e) a = a + 1 end, "", 4000)
a = 0; for i=1,1000 do end; assert(a == 0)
assert(({debug.gethook()})[3] == 4000)
debug.sethook()

-- call/return/tail-return events: g1's `g(x)` is a regular call, the
-- others tail calls (the interleaved return trace proves the frame model)
local b = {}
local function f (x) if x then return 'r' end end
function g(x) return f(x) end
function g1(x) g(x) end
local function h (x) local fg = g1; return fg(x) end
debug.sethook(function (e) table.insert(b, e) end, "cr")
h(false)
debug.sethook()
local res = {"return", "call", "call", "call", "call",
  "return", "tail return", "return", "tail return", "call"}
for _, k in ipairs(res) do assert(k == table.remove(b, 1)) end

-- call hooks see the callee at level 2 (C functions included)
local seen = {}
debug.sethook(function (e)
  if e == "call" then
    seen[debug.getinfo(2, "f").func] = true
  end
end, "crl")
local function cf(u, v) return u .. v end
assert(cf('a', 'b') == 'ab')
assert(string.rep('x', 2) == 'xx')
assert(seen[cf] and seen[assert] and seen[string.rep])
debug.sethook()
assert(debug.gethook() == nil)

-- hook installed from inside a hook fires right after it returns
local X = nil
local t = {}
function t:m(p, ...) local q = p end
debug.sethook(function (e)
  assert(e == "call")
  debug.sethook(function (ev, l)
    assert(ev == "line")
    assert(debug.getinfo(2, "l").currentline == l)
    debug.sethook(nil)
    X = {}
    local i = 1
    while true do
      local n, v = debug.getlocal(2, i)
      if not n then break end
      X[n] = v
      i = i + 1
    end
  end, "l")
end, "c")
t:m(1, 2, 3, 4)
-- xray's LuaJIT is built without LUA_COMPAT_VARARG: no implicit `arg`
-- local in vararg functions (verified against the engine build, see the
-- VibeRay lua_run corpus), so frame 2 has no `arg` local at all
assert(X.self == t and X.p == 1 and X.q == nil and X.arg == nil)

-- tail levels: what="tail", no func, getfenv is a loud error there
-- (pcall's C frame shifts the count, as in 5.1)
local function tf (x)
  if x then
    assert(debug.getinfo(1, "S").what == "Lua")
    local tail = debug.getinfo(2)
    assert(not pcall(getfenv, 3))
    assert(tail.what == "tail" and tail.short_src == "(tail call)" and
           tail.linedefined == -1 and tail.func == nil)
    assert(debug.getinfo(3, "f").func == g1)
    assert(getfenv(3))
    assert(debug.getinfo(4, "S").what == "tail")
    assert(not pcall(getfenv, 5))
    assert(debug.getinfo(5, "S").what == "main")
    return 'done'
  end
end
function g(x) return tf(x) end
function g1(x) g(x) end -- regular call + implicit valueless return
local function th (x) local fg = g1; return fg(x) end
th(true) -- the asserts inside tf carry the test

-- per-coroutine hooks + suspended-coroutine inspection
local tr = {}
local co = coroutine.create(function (x)
  local a = 1
  coroutine.yield(debug.getinfo(1, "l"))
  coroutine.yield(debug.getinfo(1, "l").currentline)
  return a
end)
local foo = function (e, ln) table.insert(tr, ln) end
debug.sethook(co, foo, "l")
assert(debug.gethook(co) == foo)
local _, l = coroutine.resume(co, 10)
assert(type(l) == "table")
assert(#tr == 2 and tr[1] == l.currentline - 1 and tr[2] == l.currentline)
local x = debug.getinfo(co, 1, "lfLS")
assert(x.currentline == l.currentline and x.activelines[x.currentline])
assert(type(x.func) == "function")
assert(debug.getinfo(co, 2) == nil)
local n, v = debug.getlocal(co, 1, 1)
assert(n == "x" and v == 10)
n, v = debug.getlocal(co, 1, 2)
assert(n == "a" and v == 1)
debug.setlocal(co, 1, 2, "hi")
local ok2, got = coroutine.resume(co)
assert(ok2 and got == l.currentline + 1) -- second yield: currentline
assert(#tr == 3)
local ok3, ret = coroutine.resume(co)
assert(ok3 and ret == "hi")
assert(#tr == 4 and tr[4] == l.currentline + 2)
assert(debug.gethook(co) == foo)
assert(debug.gethook() == nil)

-- traceback of a suspended coroutine: innermost is the interrupted
-- yield (a C frame), tail calls show as "(tail call)"
local function r (n) if n > 0 then return r(n - 1) else coroutine.yield() end end
local rc = coroutine.create(r)
coroutine.resume(rc, 3)
local tb = debug.traceback(rc)
local i = 0
local pat = {"'yield'", "04_debug_hooks.lua", "tail", "tail", "tail"}
for line in string.gmatch(tb, "[^\n]+\n?") do
  assert(i == 0 or string.find(line, pat[i]))
  i = i + 1
end
assert(pat[i] == nil)

-- traceback: message forms
assert(debug.traceback(print) == print)
assert(string.find(debug.traceback("hi"), "^hi\n"))
assert(not string.find(debug.traceback("hi"), "'traceback'"))
assert(string.find(debug.traceback("hi", 0), "'traceback'"))

print("04_debug_hooks OK")
