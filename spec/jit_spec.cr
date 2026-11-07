require "./spec_helper"

# M0 (JIT.md 5): hotness counters in the CALL path + tier-up stub.
describe "JIT hotness" do
  it "hands a hot closure to the compiler" do
    Lua::JIT.compiled_count = 0
    lua_run("local function f() end for i = 1, 600 do f() end")
    Lua::JIT.compiled_count.should eq(1)
  end

  it "does not tier up below the threshold" do
    Lua::JIT.compiled_count = 0
    lua_run("local function f() end for i = 1, #{Lua::JIT::THRESHOLD - 1} do f() end")
    Lua::JIT.compiled_count.should eq(0)
  end

  it "counts calls through the slow path too (varargs)" do
    Lua::JIT.compiled_count = 0
    lua_run("local function f(...) end local g = function() return f() end " \
            "for i = 1, #{Lua::JIT::THRESHOLD + 100} do g() end")
    Lua::JIT.compiled_count.should be >= 1
  end

  # M1 (JIT.md 5): a hot function compiles to machine code and produces
  # correct results — arithmetic, calls, deopt on non-numbers.
  it "compiles a hot function and keeps semantics" do
    r = lua_run(<<-LUA)
      local function add(a, b) return a + b end
      local s = 0
      for i = 1, #{Lua::JIT::THRESHOLD + 100} do s = add(s, i) end
      local function fib(n) if n < 2 then return 1 end return fib(n-2) + fib(n-1) end
      for i = 1, #{Lua::JIT::THRESHOLD + 100} do if fib(10) ~= 89 then return "fib-bad" end end
      local function lt(a, b) return a < b end
      for i = 1, #{Lua::JIT::THRESHOLD + 100} do lt(i, i + 1) end
      return s, fib(10), lt("a", "b")
    LUA
    n = Lua::JIT::THRESHOLD + 100
    r[0].should eq((1..n).sum.to_f64)
    r[1].should eq(89.0)
    r[2].should eq(true)
  end

  # M3: inlined numeric GETTABLE/SETTABLE array-part fast path. nil stores
  # must keep #t correct (len_cache), non-fast shapes (strings, holes,
  # metamethods, non-integral keys) take the helper and stay exact.
  it "inlined table fast path keeps semantics" do
    r = lua_run(<<-LUA)
      local function warm(f) for i = 1, #{Lua::JIT::THRESHOLD + 100} do f(i) end end
      local t, s = {}, 0
      warm(function(i) t[i] = i end)          -- appends (helper path)
      warm(function(i) s = s + t[i] end)      -- in-bounds reads (fast path)
      warm(function(i) t[i] = i * 2 end)      -- in-bounds writes (fast path)
      local nils = 0
      warm(function(i) if t[3] == nil then nils = nils + 1 end end)
      t[3] = nil                               -- nil store: len_cache update
      warm(function(i) t[5] = i + 0.5 end)     -- non-integral? no: value; key is integral
      local r = {}
      r[1] = #t
      r[2] = (t[2.5] == nil)                   -- non-integral key -> hash part
      r[3] = (t[1001] == nil)                  -- out of array range
      r[4] = (t["2"] == nil)                   -- string key miss (2.0 ~= "2")
      local mt = setmetatable({}, {__index = function(_, k) return k * 10 end})
      warm(function(i) s = s + mt[i] end)      -- metatable -> helper path
      r[5] = mt[7]
      local h = {[1] = "a"}                     -- single-entry array part
      warm(function(i) if h[1] ~= "a" then error("h1") end end)
      r[6] = h[1]
      t[3] = nil
      local u = {} for i = 1, 10 do u[i] = i end u[3] = nil
      warm(function(i) t[u[2]] = 5 end)
      r[7] = #u
      return s > 0, unpack(r)
    LUA
    r[0].should be_true
    r[1].should eq(2.0) # #t after t[3]=nil (first border)
    r[2].should be_true
    r[3].should be_true
    r[4].should be_true
    r[5].should eq(70.0)
    r[6].should eq("a")
    r[7].should eq(2.0)
  end
end
