require "./spec_helper"

describe Lua::Lexer do
  it "lexes keywords and names" do
    toks = Lua::Lexer.new("local x = function return end").tokens
    kinds = toks.map(&.kind)
    kinds.should contain(Lua::Tk::Local)
    kinds.should contain(Lua::Tk::Function)
    kinds.should contain(Lua::Tk::Return)
    kinds.should contain(Lua::Tk::End)
  end

  it "lexes numbers" do
    Lua::Lexer.new("3 3.5 .5 1e3 0x1A").tokens.select(&.kind.num?).map(&.num)
      .should eq([3.0, 3.5, 0.5, 1000.0, 26.0])
  end

  it "lexes strings with escapes" do
    Lua::Lexer.new(%q{"a\tb\65c"}).tokens[0].text.bytes.should eq("a\tbAc".bytes)
  end

  it "lexes long strings with levels" do
    Lua::Lexer.new("[==[a]]b]==]").tokens[0].text.should eq("a]]b")
  end

  it "counts lines" do
    toks = Lua::Lexer.new("a\nb\nc").tokens.reject(&.kind.eof?)
    toks.map(&.line).should eq([1, 2, 3])
  end
end

describe Lua::Parser do
  it "parses precedence" do
    # 2+3*4^2 == 2+(3*(4^2)) == 50
    lua_eval("2+3*4^2").should eq(50.0)
    lua_eval("-2^2").should eq(-4.0) # unary minus binds looser than ^
    lua_eval("2^-2").should eq(0.25)
  end

  it "rejects ambiguous call-vs-statement syntax like Lua 5.1" do
    # '(' args on a new line after a callable expression: ambiguous
    expect_raises(Lua::SyntaxError, /ambiguous syntax/) do
      Lua::Interp.new.run("local f = print\nf\n(1)")
    end
    # a statement STARTING with '(' after a complete statement is fine
    # (fails at runtime, not parse time — like PUC 5.1)
    expect_raises(Lua::LuaError, /attempt to call/) do
      Lua::Interp.new.run("local x = 1\n(x)()")
    end
  end
end

describe Lua::Interp do
  it "evaluates arithmetic and coercion" do
    lua_eval("1/0").should eq(Float64::INFINITY)
    lua_eval("0/0").as(Float64).nan?.should be_true
    lua_eval("-7 % 3").should eq(2.0)
    lua_eval(%q{"10" + 5}).should eq(15.0)
    lua_eval("10 .. 20").should eq("1020")
  end

  it "formats numbers like %.14g" do
    lua_eval("tostring(3)").should eq("3")
    lua_eval("tostring(0.5)").should eq("0.5")
    lua_eval("tostring(1/0)").should eq("inf")
    lua_eval("string.format('%.3f', 1.5)").should eq("1.500")
  end

  it "handles closures sharing upvalues" do
    lua_run(<<-LUA).should eq([105.0])
      local n = 0
      local function inc() n = n + 1 end
      inc(); inc()
      local function get() return n end
      return get() + 103
    LUA
  end

  it "keeps proper tail calls flat" do
    lua_run(<<-LUA).should eq(["done"])
      local function loop(n)
        if n == 0 then return "done" end
        return loop(n - 1)
      end
      return loop(1000000)
    LUA
  end

  it "yields fresh loop variables per iteration" do
    lua_run(<<-LUA).map(&.as(Float64)).should eq([1.0, 2.0, 3.0])
      local fns = {}
      for i = 1, 3 do fns[i] = function() return i end end
      return fns[1](), fns[2](), fns[3]()
    LUA
  end

  it "supports OOP via metatables" do
    lua_run(<<-LUA).should eq(["rex barks"])
      local Animal = {}
      Animal.__index = Animal
      function Animal.new(name) return setmetatable({name=name}, Animal) end
      function Animal:speak() return self.name .. " makes a sound" end
      local Dog = setmetatable({}, {__index = Animal})
      Dog.__index = Dog
      function Dog.new(name) return setmetatable(Animal.new(name), Dog) end
      function Dog:speak() return self.name .. " barks" end
      return Dog.new("rex"):speak()
    LUA
  end

  it "propagates error values through pcall untouched" do
    lua_run(<<-LUA).should eq([false, 7.0])
      local ok, err = pcall(function() error({code = 7}) end)
      return ok, err.code
    LUA
  end

  it "runs string patterns" do
    lua_eval(%q{("2024-01-15"):match("(%d+)-(%d+)-(%d+)")}).should eq("2024")
    lua_eval(%q{("  trim  "):match("^%s*(.-)%s*$")}).should eq("trim")
    lua_eval(%q{("hello hello"):match("(%a+) %1")}).should eq("hello")
    lua_eval(%q{("(a(b)c) tail"):match("%b()")}).should eq("(a(b)c)")
    lua_eval(%q{("abc"):gsub("", "-")}).should eq("-a-b-c-")
    lua_eval(%q{("x=1, y=2"):gsub("(%w+)=(%w+)", "%2=%1")}).should eq("1=x, 2=y")
  end
end

describe "debug library" do
  it "getlocal/setlocal read and write frame locals" do
    lua_run(<<-LUA).should eq(["OK"])
      local function g(a, b)
        local x = 5
        local function probe()
          assert(debug.getlocal(2, 1) == "a")
          assert(select(2, debug.getlocal(2, 3)) == 5)
          assert(debug.setlocal(2, 3, 6) == "x")
        end
        probe()
        assert(x == 6)
        return "OK"
      end
      return g(1, 2)
    LUA
  end

  it "getlocal falls back to (*temporary) in the live window" do
    lua_run(<<-LUA).should eq([true, 1.0, true])
      local res = {}
      local function f(a, b)
        local n1, v1 = debug.getlocal(2, 3)
        res[1] = (n1 == "(*temporary)")
        res[2] = v1
        res[3] = (debug.getlocal(2, 4) == nil)
        return 0
      end
      local function g(a, b) return (a + 1) + f() end
      g(0, 0)
      return res[1], res[2], res[3]
    LUA
  end
end

describe "Lua-visible GC" do
  it "clears weak values and weak keys" do
    lua_run(<<-LUA).should eq([true, true])
      local x = {}
      setmetatable(x, {__mode = 'v'})
      do local t = {} t[1] = {} x.t = t end
      x.s = "kept"
      collectgarbage()
      local a = (x.t == nil and x.s == "kept")
      local y = {}
      setmetatable(y, {__mode = 'k'})
      local keep = {}
      y[keep] = 1
      do local tmp = {} y[tmp] = 2 end
      collectgarbage()
      local n = 0
      for k in pairs(y) do n = n + 1 end
      return a, (n == 1 and y[keep] == 1)
    LUA
  end

  it "runs __gc finalizers with the real object" do
    lua_run(<<-LUA).should eq(["fired", "finalized"])
      local u = newproxy(true)
      getmetatable(u).__gc = function(o)
        assert(type(o) == "userdata")
        _G.res = "fired"
        _G.done = "finalized"
      end
      u = nil
      collectgarbage()
      return _G.res, _G.done
    LUA
  end

  it "reports gcinfo and honors collectgarbage options" do
    lua_run(<<-LUA).should eq([true, true, 200.0])
      local kb, rem = gcinfo()
      local a = (type(kb) == "number" and type(rem) == "number")
      collectgarbage("stop")
      collectgarbage("restart")
      collectgarbage()
      local old = collectgarbage("setpause", 300)
      collectgarbage("setpause", old)
      return a, (collectgarbage("step", 1000000) == true), old
    LUA
  end
end
