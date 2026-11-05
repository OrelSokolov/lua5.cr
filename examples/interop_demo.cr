# Interop demo: Crystal objects exposed to Lua — the whole point of lua5.cr.
# Run: crystal run examples/interop_demo.cr
require "../src/lua5"

class Task
  property title : String
  getter priority : Int32

  def initialize(@title, @priority : Int32)
  end

  @[LuaMethod]
  def get_title(prefix : String) : String
    "#{prefix}: #{@title}"
  end

  @[LuaMethod]
  def bump(amount : Int32) : Int32
    @priority += amount
  end

  @[LuaMethod]
  def ratio(divisor : Float64) : Float64
    @priority / divisor
  end

  @[LuaMethod]
  def is_done : Bool
    @priority > 100
  end
end

expose Task

interp = Lua::Interp.new
task = Task.new("fix the parser", 10)
interp.expose_object("task", task)

interp.run(<<-LUA, "demo")
assert(task:get_title("oleg") == "oleg: fix the parser")
assert(task:bump(5) == 15)
assert(task:bump(90) == 105)
assert(task:is_done() == true)
assert(task:ratio(10) == 10.5)
print("interop demo OK")
LUA

# Lua code mutated the Crystal object directly — shared state, no copying:
raise "shared object broken" unless task.priority == 105
puts "crystal-side priority: #{task.priority}"
