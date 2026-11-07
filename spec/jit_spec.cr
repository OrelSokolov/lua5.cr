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
end
