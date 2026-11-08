require "./spec_helper"

# M0 (JIT.md 5): hotness counters in the CALL path + tier-up stub.
describe "JIT hotness" do
  it "hands a hot closure to the compiler" do
    Lua::JIT.compiled_count = 0
    # f's body has a GETGLOBAL — outside the M5 inline region — so f cannot
    # be served by hot-call inlining and must tier up on its own counter.
    lua_run("local function f(i) return math.floor(i) end " \
            "for i = 1, 600 do f(i) end")
    # both tier up: the main chunk (back-edge hotness, OSR) and f itself
    # (calls from the OSR'd caller bump the callee counter too)
    Lua::JIT.compiled_count.should eq(2)
  end

  it "inlines a monomorphic callee instead of compiling it" do
    GC.collect # earlier weak-table specs leave live registrations: a weak
    # table alive anywhere deopts closure-creating loops at back-edges, and
    # this chunk creates the f closure — drop the dead state first
    Lua::JIT.compiled_count = 0
    lua_run("local function f() end for i = 1, 600 do f() end")
    # M5: the OSR'd main chunk inlines f at its single call site before
    # f's own counter reaches the threshold; the inline serves every
    # further call, so the callee never compiles on its own (verified by
    # IR dump: zero jit_dispatch_call call sites in the compile).
    Lua::JIT.compiled_count.should eq(1)
  end

  it "does not tier up below the threshold" do
    Lua::JIT.compiled_count = 0
    # NBF1: Interp#call (native→Lua entry, incl. the chunk's own entry via
    # Interp#run) bumps hotness too, so the chunk has 1 call + N back-edges;
    # keep both the chunk and f strictly under THRESHOLD.
    lua_run("local function f() end for i = 1, #{Lua::JIT::THRESHOLD - 2} do f() end")
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

  # M5 (JIT.md 5): hot-call inlining. A call-site's monomorphic callee is
  # recorded by the interpreter (and by jit_dispatch_call for calls made
  # from JIT code), and the compiler emits the callee body into the caller
  # behind a closure-identity guard. Guard misses and guard deopts inside
  # the region re-run the CALL interpreted, so every shape below must keep
  # exact interpreter semantics.
  describe "hot-call inlining" do
    it "inlines a numeric helper and keeps results bit-exact" do
      n = Lua::JIT::THRESHOLD + 100
      r = lua_run(<<-LUA)
        local function A(i, j)
          local ij = i + j - 1
          return 1.0 / (ij * (ij - 1) * 0.5 + i)
        end
        local s = 0
        for i = 1, #{n} do s = s + A(i, 2) end
        return s, A(3, 4)
      LUA
      exp = (1..n).sum { |i| ij = i.to_f64 + 2 - 1; 1.0 / (ij * (ij - 1) * 0.5 + i) }
      r[0].should eq(exp)
      ij = 3.0 + 4 - 1
      r[1].should eq(1.0 / (ij * (ij - 1) * 0.5 + 3))
    end

    it "deopts and drops the inline when the callee goes polymorphic" do
      n = Lua::JIT::THRESHOLD + 100
      r = lua_run(<<-LUA)
        local function add(a, b) return a + b end
        local function drive(a, b)
          local s = 0
          for i = 1, #{n} do s = s + add(a, b) end
          return s
        end
        local r1 = drive(1, 2)       -- numeric: compiles with the inline
        local r2 = drive("1", "2")   -- guard deopt: re-run, coerce, recompile
        return r1, r2, add("2", "3")
      LUA
      r[0].should eq(3.0 * n)
      r[1].should eq(3.0 * n)
      r[2].should eq(5.0)
    end

    it "takes the slow path when the site rebinds to another proto" do
      n = Lua::JIT::THRESHOLD + 100
      k = Lua::JIT::THRESHOLD + 50
      r = lua_run(<<-LUA)
        local function f(x) return x * 2 end
        local g = f
        local s = 0
        for i = 1, #{n} do
          s = s + g(i)
          if i == #{k} then g = function(x) return x + 1000 end end
        end
        return s, g(1), f(3)
      LUA
      exp = (1..n).sum { |i| i <= k ? i * 2 : i + 1000 }
      r[0].should eq(exp)
      r[1].should eq(1001.0)
      r[2].should eq(6.0)
    end

    it "inlines fixed multi-result returns per want" do
      n = Lua::JIT::THRESHOLD + 100
      r = lua_run(<<-LUA)
        local function two() return 1, 2 end
        local a, b = 0, 0
        for i = 1, #{n} do
          local x, y = two()
          a = a + x
          b = b + y
          two()
        end
        local c = two()
        return a, b, c
      LUA
      r[0].should eq(n.to_f64)
      r[1].should eq(2.0 * n)
      r[2].should eq(1.0)
    end

    it "inlines upvalue reads and early returns" do
      n = Lua::JIT::THRESHOLD + 100
      r = lua_run(<<-LUA)
        local k = 3
        local function addk(x) return x + k end
        local function sgn(x)
          if x < 0 then return -1 end
          if x > 0 then return 1 end
          return 0
        end
        local s, t, u = 0, 0, 0
        for i = 1, #{n} do s = s + addk(i); t = t + sgn(i); u = u + sgn(-i) end
        return s, t, u, addk(10), sgn(0)
      LUA
      r[0].should eq((1..n).sum { |i| i + 3 }.to_f64)
      r[1].should eq(n.to_f64)
      r[2].should eq(-n.to_f64)
      r[3].should eq(13.0)
      r[4].should eq(0.0)
    end

    it "raises proper errors from an inlined callee" do
      n = Lua::JIT::THRESHOLD + 100
      r = lua_run(<<-LUA)
        local function add(a, b) return a + b end
        for i = 1, #{n} do add(i, 1) end
        local ok, err = pcall(add, {}, 1)
        local ok2, r2 = pcall(add, 2, 5)
        return ok, (err:match("arithmetic") ~= nil), ok2, r2
      LUA
      r[0].should be_false
      r[1].should be_true
      r[2].should be_true
      r[3].should eq(7.0)
    end

    it "keeps NaN compare semantics in machine code" do
      n = Lua::JIT::THRESHOLD + 100
      r = lua_run(<<-LUA)
        local function ne(a, b) return a ~= b end
        local function eq(a, b) return a == b end
        local nan = 0 / 0
        for i = 1, #{n} do ne(i, i + 1); eq(i, i) end
        return ne(nan, nan), eq(nan, nan), ne(1, 2), eq(2, 2)
      LUA
      r[0].should be_true # UNE, not ONE: NaN ~= NaN is true in Lua
      r[1].should be_false
      r[2].should be_true
      r[3].should be_true
    end
  end

  # Weak tables put the loop back-edge GC in play: the JIT back-edge gate
  # runs the same weak-GC tick as the interpreter (stale-register clear +
  # weak sweep every 32nd edge) instead of deopting the whole loop, so a
  # hot loop *waiting* on a weak-table sweep still observes it clear.
  it "hot loops keep driving the weak-table sweep from machine code" do
    r = lua_run(<<-LUA)
      local t = setmetatable({}, {__mode = 'v'})
      do
        local held = { 1 }
        t.held = held
      end
      local n = 0
      while t.held ~= nil and n < 500000 do
        n = n + 1
        local junk = { n } -- allocation pressure: Boehm reclaims `held`
      end
      return t.held == nil, n < 500000
    LUA
    r[0].should be_true
    r[1].should be_true
  end

  it "reports finalizer errors from the weak-GC tick without crashing" do
    r = lua_run(<<-LUA)
      local ok, err = pcall(function()
        local t = setmetatable({}, {__mode = 'v'})
        do
          local d = newproxy(true)
          getmetatable(d).__gc = function() error("boom") end
          t.d = d
          d = nil
        end
        local n = 0
        while n < 500000 do
          n = n + 1
          local junk = { n }
        end
        return "no-error"
      end)
      return ok, err
    LUA
    # __gc errors are warned, not raised (5.1 luaC semantics): the loop
    # finishes normally and pcall sees the inner return value.
    r[0].should be_true
    r[1].should eq("no-error")
  end

  # A captured register written by a __gc finalizer (run by the weak-GC
  # tick on the back-edge) must be OBSERVED by a hot loop reading it:
  # frames whose proto creates closures deopt at weak back-edges (the
  # interpreter re-reads the slot); capture-free frames tick in place —
  # but nothing external can write their slots, so both are exact.
  # (5.1 finalizes userdata only — newproxy, not tables.)
  it "observes finalizer writes to a captured loop variable" do
    r = lua_run(<<-LUA)
      local total = 0
      local function bump() total = total + 100 end
      do
        local d = newproxy(true)
        getmetatable(d).__gc = bump
        d = nil
      end
      local t = setmetatable({}, {__mode = 'v'})
      do
        local hold = { 1 }
        t.h = hold
      end
      local n = 0
      local saw = false
      while n < 300000 and not saw do
        n = n + 1
        local junk = { n }
        if total >= 100 then saw = true end
      end
      return saw, total >= 100
    LUA
    r[0].should be_true # the loop saw the finalizer's write mid-flight
    r[1].should be_true
  end
end
