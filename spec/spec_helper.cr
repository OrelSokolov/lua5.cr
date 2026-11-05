require "spec"
require "../src/lua5"

# Evaluate a Lua expression and return the single result.
def lua_eval(src : String) : Lua::LuaValue
  Lua::Interp.new.run("return #{src}", "spec")[0]?
end

def lua_run(src : String) : Array(Lua::LuaValue)
  Lua::Interp.new.run(src, "spec")
end
