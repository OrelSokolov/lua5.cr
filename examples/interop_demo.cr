# Interop demo: Crystal objects exposed to Lua — the whole point of lua5.cr.
# Run: crystal run examples/interop_demo.cr
require "../src/lua5"

class Task
  property title : String
  property priority : Int32

  @[LuaConstructor]
  def initialize(@title : String, @priority : Int32)
  end

  @[LuaMethod]
  def get_title(prefix : String) : String
    "#{prefix}: #{@title}"
  end

  @[LuaMethod]
  def bump(amount : Int32) : Int32
    @priority += amount
  end

  # overloads: dispatch by argument types at the call site
  @[LuaMethod]
  def scale(factor : Float64) : Float64
    @priority * factor
  end

  @[LuaMethod]
  def scale(tag : String) : String
    "#{tag}##{@priority}"
  end

  @[LuaProperty]
  def title : String
    @title
  end

  @[LuaProperty]
  def title=(v : String)
    @title = v
  end

  @[LuaMethod]
  def tags(parts : Array(String)) : Array(String)
    parts.map { |p| "#{p}!" }
  end
end

expose Task

# inheritance: UrgentTask sees everything Task exposes
class UrgentTask < Task
  @[LuaMethod]
  def is_done : Bool
    @priority > 100
  end
end

expose UrgentTask

interp = Lua::Interp.new

# objects flow in both directions: expose an instance...
task = Task.new("fix the parser", 10)
interp.expose_object("task", task)
# ...and expose the class itself, constructible from Lua
interp.expose_class("Task", Task)
interp.expose_class("UrgentTask", UrgentTask)

interp.run(<<-LUA, "demo")
assert(task:get_title("oleg") == "oleg: fix the parser")
assert(task:bump(5) == 15)
assert(task:scale(2.0) == 30.0)          -- Float64 overload
assert(task:scale("t") == "t#15")        -- String overload
assert(task.title == "fix the parser")   -- property getter
task.title = "renamed"                   -- property setter
assert(task.title == "renamed")

-- construct Crystal objects from Lua (overloaded constructors inherit):
local u = UrgentTask.new("from lua", 200)
assert(u.title == "from lua")             -- inherited property getter
assert(u:is_done() == true)               -- own method
assert(u:bump(-50) == 150)                -- inherited method
u.title = "renamed-from-lua"              -- inherited property setter
assert(u.title == "renamed-from-lua")

-- tables convert to Array(String) and back:
local t = task:tags({"a", "b"})
assert(#t == 2 and t[1] == "a!")

-- Crystal exceptions cross into Lua as errors:
local ok, err = pcall(function() task:get_title(42) end)
assert(not ok and type(err) == "string")
print("interop demo OK")
LUA

# Lua code mutated the Crystal objects directly — shared state, no copying:
raise "shared object broken" unless task.title == "renamed" && task.priority == 15
puts "crystal-side: title=#{task.title} priority=#{task.priority}"
