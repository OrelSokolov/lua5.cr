require "./spec_helper"

# Interop: the whole point of lua5.cr — Crystal classes callable from Lua
# with no C boundary. This file covers the full phase-4 layer: methods,
# overloads, properties, constructors, inheritance, converters, errors.

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

# --- phase 4: overloads ---

class SpecWidget
  property level : Int32 = 0

  @[LuaMethod]
  def set(x : Int32) : Int32
    @level = x
  end

  @[LuaMethod]
  def set(name : String) : Int32
    @level = name.bytesize
  end

  @[LuaMethod]
  def set(a : Int32, b : Int32) : Int32
    @level = a + b
  end
end

expose SpecWidget

# --- phase 4: properties + constructor + inheritance ---

class SpecEntity
  property hp : Int32 = 100

  @[LuaConstructor]
  def initialize(@hp : Int32)
  end

  @[LuaConstructor]
  def initialize(@hp : Int32, bonus : Int32)
    @hp += bonus
  end

  @[LuaProperty]
  def hp : Int32
    @hp
  end

  @[LuaProperty]
  def hp=(v : Int32)
    @hp = v
  end

  @[LuaProperty]
  def title : String
    "entity-#{@hp}"
  end

  @[LuaMethod]
  def alive : Bool
    @hp > 0
  end
end

expose SpecEntity

class SpecBoss < SpecEntity
  @[LuaMethod]
  def damage(amount : Int32) : Int32
    @hp -= amount // 2 # bosses resist: Crystal integer division
  end
end

expose SpecBoss

# --- phase 4: converters ---

class SpecConvert
  @[LuaMethod]
  def sum(values : Array(Float64)) : Float64
    values.sum
  end

  @[LuaMethod]
  def shout(parts : Array(String)) : String
    parts.join("-").upcase
  end

  @[LuaMethod]
  def squares(n : Int32) : Array(Float64)
    (1..n).map { |i| (i * i).to_f64 }
  end

  @[LuaMethod]
  def greet(name : String?) : String
    name ? "hi #{name}" : "hi stranger"
  end
end

expose SpecConvert

# --- phase 4: error model ---

class SpecExploder
  @[LuaMethod]
  def boom : Int32
    raise ArgumentError.new("kaboom from crystal")
  end
end

expose SpecExploder

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

  it "dispatches overloads by argument types" do
    interp = Lua::Interp.new
    interp.expose_object("w", SpecWidget.new)
    r = interp.run(<<-LUA, "spec")
      assert(w:set(5) == 5)
      assert(w:set("abc") == 3)
      assert(w:set(10, 20) == 30)
      return w:set("hello")
    LUA
    r.should eq([5.0])
  end

  it "fails loudly when no overload matches" do
    interp = Lua::Interp.new
    interp.expose_object("w", SpecWidget.new)
    expect_raises(Lua::LuaError, /no overload matches/) do
      interp.run(%q{ w:set(true) }, "spec")
    end
  end

  it "exposes properties as Lua fields" do
    interp = Lua::Interp.new
    interp.expose_object("e", SpecEntity.new(50))
    interp.run(<<-LUA, "spec")
      assert(e.hp == 50)
      assert(e.title == "entity-50")
      e.hp = 10
      assert(e.hp == 10)
      assert(e:alive() == true)
    LUA
  end

  it "rejects unknown property writes loudly" do
    interp = Lua::Interp.new
    interp.expose_object("e", SpecEntity.new(50))
    expect_raises(Lua::LuaError, /no settable property/) do
      interp.run(%q{ e.nope = 1 }, "spec")
    end
  end

  it "constructs objects from Lua with overloaded constructors" do
    interp = Lua::Interp.new
    interp.expose_class("Entity", SpecEntity)
    interp.run(<<-LUA, "spec")
      local a = Entity.new(30)
      assert(a.hp == 30)
      local b = Entity.new(30, 5)
      assert(b.hp == 35)
      assert(a:alive() and b:alive())
    LUA
  end

  it "sees inherited methods through the superclass chain" do
    interp = Lua::Interp.new
    interp.expose_class("Boss", SpecBoss)
    r = interp.run(<<-LUA, "spec")
      local boss = Boss.new(100)
      assert(boss:alive())       -- inherited from SpecEntity
      boss.hp = 20               -- inherited property setter
      assert(boss.hp == 20)
      assert(boss:damage(10) == 15) -- own method
      return boss.title          -- inherited getter
    LUA
    r.should eq(["entity-15"])
  end

  it "converts tables to arrays and back" do
    interp = Lua::Interp.new
    interp.expose_object("conv", SpecConvert.new)
    r = interp.run(<<-LUA, "spec")
      assert(conv:sum({1, 2, 3.5}) == 6.5)
      assert(conv:shout({"a", "b", "c"}) == "A-B-C")
      local sq = conv:squares(3)
      assert(#sq == 3 and sq[1] == 1 and sq[3] == 9)
      assert(conv:greet("oleg") == "hi oleg")
      assert(conv:greet() == "hi stranger")
      assert(conv:greet(nil) == "hi stranger")
      return conv:sum({2, 2})
    LUA
    r.should eq([4.0])
  end

  it "rejects holey tables for array arguments" do
    interp = Lua::Interp.new
    interp.expose_object("conv", SpecConvert.new)
    expect_raises(Lua::LuaError, /hole at index/) do
      interp.run(%q{ local t = {1, nil, 3}; conv:sum(t) }, "spec")
    end
  end

  it "crosses Crystal exceptions into Lua pcall as errors" do
    interp = Lua::Interp.new
    interp.expose_object("x", SpecExploder.new)
    r = interp.run(<<-LUA, "spec")
      local ok, err = pcall(function() return x:boom() end)
      assert(not ok)
      assert(type(err) == "string" and string.find(err, "kaboom from crystal"))
      return ok
    LUA
    r.should eq([false])
  end

  it "carries error(table) to pcall unchanged (no losses)" do
    interp = Lua::Interp.new
    r = interp.run(<<-LUA, "spec")
      local marker = {}
      local ok, err = pcall(function() error(marker) end)
      assert(ok == false and err == marker)
      return err == marker
    LUA
    r.should eq([true])
  end
end
