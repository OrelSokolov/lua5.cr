# lua5.cr — pure-Crystal Lua 5.1 interpreter (MoonSharp port).
#
# See PLAN.md for the roadmap. Quick start:
#
#   interp = Lua::Interp.new
#   interp.run("print('hello')")
#
#   Lua.eval("1 + 2")            # => 3.0
#   bin/lua5 script.lua          # CLI
#
# Interop (the end goal):
#
#   class Greeter
#     @[LuaMethod]
#     def greet(name : String) : String
#       "hello, #{name}!"
#     end
#   end
#   expose Greeter
#   interp.expose_object("greeter", Greeter.new)
#   interp.run(%q{ greeter:greet("world") })

require "./token"
require "./lexer"
require "./ast"
require "./parser"
require "./value"
require "./vm"
require "./interp"
require "./jit/hotness"
require "./jit/runtime"
require "./jit/compiler"
require "./pattern"
require "./stdlib/base"
require "./stdlib/math"
require "./stdlib/table_lib"
require "./stdlib/string_lib"
require "./stdlib/os"
require "./stdlib/io"
require "./stdlib/package"
require "./stdlib/coroutine"
require "./stdlib/debug"
require "./interop"
