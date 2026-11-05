require "./spec_helper"

# Interop: the whole point of lua5.cr — Crystal classes callable from Lua
# with no C boundary.

class SpecCounter
  getter count : Int32 = 0

  @[LuaMethod]
  def add(x : Int32) : Int32
    @count += x
  end

  @[LuaMethod]
  def label(name : String) : String
    "counter:#{name}:#{@count}"
  end

  @[LuaMethod]
  def half : Float64
    @count / 2.0
  end
end

expose SpecCounter

class SpecLinked
  # returning another exposed object exercises userdata round-trips
  @[LuaMethod]
  def peer : SpecCounter
    SpecCounter.new
  end
end

expose SpecLinked

describe Lua::Interop do
  it "exposes methods with typed args" do
    interp = Lua::Interp.new
    interp.expose_object("counter", SpecCounter.new)
    interp.run(<<-LUA, "spec")
      assert(counter:add(2) == 2)
      assert(counter:add(40) == 42)
      assert(counter:label("x") == "counter:x:42")
      assert(counter:half() == 21)
    LUA
  end

  it "rejects wrong argument types loudly" do
    interp = Lua::Interp.new
    interp.expose_object("counter", SpecCounter.new)
    expect_raises(Lua::LuaError, /integer expected/) do
      interp.run(%q{ counter:add("nope") }, "spec")
    end
  end

  it "wraps exposed objects returned from methods" do
    interp = Lua::Interp.new
    interp.expose_object("linked", SpecLinked.new)
    r = interp.run(%q{ local p = linked:peer(); return p:add(5) }, "spec")
    r.should eq([5.0])
  end

  it "shares object state between Lua and Crystal" do
    interp = Lua::Interp.new
    c = SpecCounter.new
    interp.expose_object("counter", c)
    interp.run(%q{ counter:add(7) }, "spec")
    c.count.should eq(7)
  end
end
