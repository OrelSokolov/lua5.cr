require "./spec_helper"

# M0 (JIT.md 5): hotness counters in the CALL path + tier-up stub.
describe "JIT hotness" do
  it "hands a hot closure to the compiler" do
    Lua::JIT.compiled_count = 0
    lua_run("local function f() end for i = 1, 600 do f() end")
    # both tier up: the main chunk (back-edge hotness, OSR) and f itself
    # (calls from the OSR'd caller bump the callee counter too)
    Lua::JIT.compiled_count.should eq(2)
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

  # M3 remainder: type feedback (JIT.md §2) — the interpreter samples
  # non-number operand shapes per pc into the Proto side-table; the JIT
  # specializes mono-numeric when the mask is clean and polymorphic
  # (helper fallback, no deopt churn) when it is not. Wrong speculation
  # deopts, the interpreter samples the new shape and on_deopt recompiles.
  #
  # Warm-up uses TWO loops of THRESHOLD/2 calls: a single loop past the
  # threshold would tier the MAIN chunk up first (back-edge hotness) and
  # OSR it — calls from machine code do not bump the callee's counter,
  # so the callee would stay short of the threshold and never compile.
  describe "type feedback" do
    it "compiles polymorphic from the first compile when strings were seen" do
      Lua::JIT.compiled_count = 0
      n = {Lua::JIT::THRESHOLD // 2, 1}.max
      r = lua_run(<<-LUA)
        local function add(a, b) return a + b end
        for i = 1, #{n} do add("1", "2") end
        for i = 1, #{n} do add("1", "2") end
        return add("10", "5"), add(2, 3), add(1.5, "1")
      LUA
      r[0].should eq(15.0) # tonumber coercion, helper path
      r[1].should eq(5.0)  # num/num inline path
      r[2].should eq(2.5)
    end

    it "recompiles after a deopt widens the feedback mask" do
      Lua::JIT.compiled_count = 0
      n = {Lua::JIT::THRESHOLD // 2, 1}.max
      r = lua_run(<<-LUA)
        local function mul(a, b) return a * b end
        for i = 1, #{n} do mul(i, 2) end   -- interpreted warm-up (mono mask)
        for i = 1, #{n} do mul(i, 2) end   -- mul compiles here (call #{n * 2})
        local a = mul("3", "4")            -- deopt + drift sample + recompile
        for i = 1, 100 do if mul("2", "5") ~= 10 then return "bad" end end
        return a, mul(3, 4)
      LUA
      r[0].should eq(12.0)
      r[1].should eq(12.0)
      Lua::JIT.compiled_count.should be >= 2 # initial compile + recompile
    end

    it "keeps string compares in machine code" do
      n = {Lua::JIT::THRESHOLD // 2, 1}.max
      r = lua_run(<<-LUA)
        local function lt(a, b) return a < b end
        local function le(a, b) return a <= b end
        for i = 1, #{n} do lt("a", "b"); le("a", "a") end
        for i = 1, #{n} do lt("a", "b"); le("a", "a") end
        return lt("abc", "abd"), lt("b", "a"), le("a", "a"), le("b", "a"), lt(1, 2)
      LUA
      r[0].should be_true # inline strcmp path
      r[1].should be_false
      r[2].should be_true
      r[3].should be_false
      r[4].should be_true # num/num path of the same polymorphic op
    end

    it "handles equality of every shape through the feedback path" do
      n = {Lua::JIT::THRESHOLD // 2, 1}.max
      r = lua_run(<<-LUA)
        local t1, t2 = {}, {}
        local function eqv(a, b) return a == b end
        local function neq(a, b) return a ~= b end
        for i = 1, #{n} do eqv(t1, t1); neq("a", "a") end
        for i = 1, #{n} do eqv(t1, t1); neq("a", "a") end
        return eqv(t1, t1), eqv(t1, t2), eqv("x", "x"), eqv("x", "y"),
               eqv(1, "1"), neq("x", "y"), neq(2, 2), eqv(true, true), eqv(nil, nil)
      LUA
      r[0].should be_true
      r[1].should be_false
      r[2].should be_true
      r[3].should be_false
      r[4].should be_false # no cross-type coercion in ==
      r[5].should be_true
      r[6].should be_false
      r[7].should be_true
      r[8].should be_true
    end

    it "runs metamethod arith and compare errors through the helper" do
      n = {Lua::JIT::THRESHOLD // 2, 1}.max
      r = lua_run(<<-LUA)
        local mt = setmetatable({}, {__add = function(x, y) return 42 end})
        local function add(a, b) return a + b end
        for i = 1, #{n} do add(mt, 1) end
        for i = 1, #{n} do add(mt, 1) end
        local function le(a, b) return a <= b end
        for i = 1, #{n} do le("a", "b") end
        for i = 1, #{n} do le("a", "b") end
        local ok = pcall(le, {}, {})
        return add(mt, 1), add(1, 2), ok
      LUA
      r[0].should eq(42.0)
      r[1].should eq(3.0)
      r[2].should be_false # compare error raised from the helper
    end

    it "specializes unary minus on strings" do
      n = {Lua::JIT::THRESHOLD // 2, 1}.max
      r = lua_run(<<-LUA)
        local function neg(a) return -a end
        for i = 1, #{n} do neg("5") end
        for i = 1, #{n} do neg("5") end
        return neg("5"), neg(3)
      LUA
      r[0].should eq(-5.0)
      r[1].should eq(-3.0)
    end
  end
end
