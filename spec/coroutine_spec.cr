require "./spec_helper"

describe "coroutines" do
  it "runs a body to completion" do
    lua_run(<<-LUA
      local t = {}
      local co = coroutine.create(function(a, b)
        t.a = a; t.b = b
      end)
      local ok, x, y = coroutine.resume(co, 1, 2)
      return ok and t.a == 1 and t.b == 2
    LUA
    )[0].should be_true
  end

  it "yields and resumes with values" do
    r = lua_run(<<-LUA
      local co = coroutine.create(function()
        local got = coroutine.yield(1, 2)
        return got, "done"
      end)
      local ok, a, b = coroutine.resume(co)
      local ok2, back = coroutine.resume(co, "sent")
      return ok, a, b, ok2, back
    LUA
    )
    r.should eq([true, 1.0, 2.0, true, "sent"])
  end

  it "passes resume arguments to the body on first resume" do
    lua_run(<<-LUA
      local co = coroutine.create(function(a, b)
        return coroutine.yield(a + b)
      end)
      local ok, s = coroutine.resume(co, 20, 22)
      return s == 42
    LUA
    )[0].should be_true
  end

  it "transitions status" do
    r = lua_run(<<-LUA
      local co = coroutine.create(function()
        coroutine.yield()
      end)
      local s0 = coroutine.status(co)
      coroutine.resume(co)
      local s1 = coroutine.status(co)
      coroutine.resume(co)
      return s0, s1, coroutine.status(co)
    LUA
    )
    r.should eq(["suspended", "suspended", "dead"])
  end

  it "reports normal for a coroutine resuming another" do
    r = lua_run(<<-LUA
      local co_status
      local co, other
      other = coroutine.create(function()
        co_status = coroutine.status(co) -- co resumed us: normal
        coroutine.yield()
      end)
      co = coroutine.create(function()
        coroutine.resume(other)
        return "inner-done"
      end)
      local ok, v = coroutine.resume(co)
      return ok, v, co_status, coroutine.status(other), coroutine.status(co)
    LUA
    )
    r.should eq([true, "inner-done", "normal", "suspended", "dead"])
  end

  it "returns false + error value when the body fails (table preserved)" do
    r = lua_run(<<-LUA
      local err_t = setmetatable({}, {__tostring = function() return "ERR" end})
      local co = coroutine.create(function()
        error(err_t)
      end)
      local ok, e = coroutine.resume(co)
      return ok, e == err_t, coroutine.status(co)
    LUA
    )
    r.should eq([false, true, "dead"])
  end

  it "refuses to resume dead / running / normal coroutines" do
    r = lua_run(<<-LUA
      local errs = {}
      local dead = coroutine.create(function() end)
      coroutine.resume(dead)
      _, errs.dead = coroutine.resume(dead)

      local a, b
      b = coroutine.create(function()
        _, errs.normal = coroutine.resume(a) -- a is normal here (it resumed us)
        coroutine.yield()
      end)
      a = coroutine.create(function()
        _, errs.running = coroutine.resume(a) -- a is running here
        coroutine.resume(b)
        coroutine.yield()
      end)
      coroutine.resume(a)
      return errs.dead, errs.running, errs.normal
    LUA
    )
    r[0].should eq("cannot resume dead coroutine")
    r[1].should eq("cannot resume running coroutine")
    r[2].should eq("cannot resume non-suspended coroutine")
  end

  it "refuses to yield outside a coroutine" do
    r = lua_run(<<-LUA
      local ok, e = pcall(coroutine.yield)
      return ok, e
    LUA
    )
    r[0].should be_false
    (r[1].as(String) =~ /outside a coroutine/).should_not be_nil
  end

  it "refuses to yield across a Crystal call boundary (sort comparator)" do
    r = lua_run(<<-LUA
      local co = coroutine.create(function()
        table.sort({3, 1, 2}, function(a, b)
          coroutine.yield()
          return a < b
        end)
      end)
      local ok, e = coroutine.resume(co)
      return ok, coroutine.status(co), e
    LUA
    )
    r[0].should be_false
    r[1].should eq("dead")
    (r[2].as(String) =~ /across a Crystal call boundary/).should_not be_nil
  end

  it "refuses to yield across pcall (5.1: pcall catches, body continues)" do
    r = lua_run(<<-LUA
      local pk, pe
      local co = coroutine.create(function()
        pk, pe = pcall(coroutine.yield)
      end)
      local ok = coroutine.resume(co)
      return ok, pk, pe, coroutine.status(co)
    LUA
    )
    r[0].should be_true
    r[1].should be_false
    (r[2].as(String) =~ /across a Crystal call boundary/).should_not be_nil
    r[3].should eq("dead")
  end

  it "supports tail-yield: return coroutine.yield(x)" do
    r = lua_run(<<-LUA
      local co = coroutine.create(function(x)
        local got = return_via_yield(x)
        return got, "end"
      end)
      function return_via_yield(x)
        return coroutine.yield(x)
      end
      local ok1, y1 = coroutine.resume(co, "first")
      local ok2, y2, y3 = coroutine.resume(co, "second")
      return ok1, y1, ok2, y2, y3
    LUA
    )
    r.should eq([true, "first", true, "second", "end"])
  end

  it "wrap forwards results and re-raises errors" do
    r = lua_run(<<-LUA
      local gen = coroutine.wrap(function(a)
        local b = coroutine.yield(a + 1)
        return b * 2
      end)
      local first = gen(10)
      local second = gen(5)
      local bad = coroutine.wrap(function() error("boom") end)
      local ok, e = pcall(bad)
      return first, second, ok, tostring(e)
    LUA
    )
    r[0].should eq(11.0)
    r[1].should eq(10.0)
    r[2].should be_false
    (r[3].as(String) =~ /boom/).should_not be_nil
  end

  it "running() returns the coroutine inside, nil in main" do
    r = lua_run(<<-LUA
      local co
      co = coroutine.create(function()
        return coroutine.running() == co
      end)
      local ok, same = coroutine.resume(co)
      return ok, same, coroutine.running() == nil, select("#", coroutine.running())
    LUA
    )
    r.should eq([true, true, true, 1.0])
  end

  it "closes upvalues when a coroutine dies" do
    r = lua_run(<<-LUA
      local saved
      local co = coroutine.create(function()
        do
          local x = 1
          saved = function() return x end
          x = 2
          coroutine.yield()
        end
      end)
      coroutine.resume(co)
      coroutine.resume(co)
      return saved()
    LUA
    )
    r[0].should eq(2.0)
  end

  it "interleaves two producers over the shared interpreter state" do
    r = lua_run(<<-LUA
      local function producer(n)
        return coroutine.create(function()
          for i = 1, n do coroutine.yield(i * n) end
        end)
      end
      local p1, p2 = producer(3), producer(5)
      local out = {}
      for round = 1, 3 do
        out[#out + 1] = select(2, coroutine.resume(p1))
        out[#out + 1] = select(2, coroutine.resume(p2))
      end
      return table.concat(out, ",")
    LUA
    )
    r[0].should eq("3,5,6,10,9,15")
  end
end
