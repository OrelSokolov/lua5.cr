# coroutine library. Port of lcorolib.c (Lua 5.1 semantics: resume returns
# [false, err] on error; wrap re-raises). The mechanism lives in vm.cr
# (return-based yield transport + resume_co state swap).
module Lua::Stdlib
  module Coroutine
    def self.install(i : Interp)
      co_lib = LuaTable.new

      co_lib.raw_set("create", LuaFunction.new("create", ->(i2 : Interp, args : Array(LuaValue)) {
        f = i2.func!(args, 0, "create")
        [LuaCoroutine.new(f)] of LuaValue
      }))

      co_lib.raw_set("resume", LuaFunction.new("resume", ->(i2 : Interp, args : Array(LuaValue)) {
        co = args[0]?
        i2.arg_error(1, "resume", "coroutine expected") unless co.is_a?(LuaCoroutine)
        rest = args.size > 1 ? args[1..] : ([] of LuaValue)
        i2.resume_co(co, rest)
      }))

      co_lib.raw_set("yield", LuaFunction.new("yield", ->(i2 : Interp, args : Array(LuaValue)) {
        i2.yield_co(args)
      }))

      co_lib.raw_set("status", LuaFunction.new("status", ->(i2 : Interp, args : Array(LuaValue)) {
        co = args[0]?
        i2.arg_error(1, "status", "coroutine expected") unless co.is_a?(LuaCoroutine)
        s = case co.status
            when .suspended? then "suspended"
            when .running?   then "running"
            when .normal?    then "normal"
            else                  "dead"
            end
        [s] of LuaValue
      }))

      co_lib.raw_set("wrap", LuaFunction.new("wrap", ->(i2 : Interp, args : Array(LuaValue)) {
        f = i2.func!(args, 0, "wrap")
        co = LuaCoroutine.new(f)
        [LuaFunction.new("wrapped", ->(i3 : Interp, wargs : Array(LuaValue)) {
          r = i3.resume_co(co, wargs)
          if Lua.truthy(r[0])
            r.size > 1 ? r[1..] : ([] of LuaValue)
          else
            raise LuaError.new(r[1]?)
          end
        })] of LuaValue
      }))

      # Lua 5.1 (and our LuaJIT diff target): the running coroutine, or
      # nil from the main thread — a single value.
      co_lib.raw_set("running", LuaFunction.new("running", ->(i2 : Interp, _args : Array(LuaValue)) {
        [i2.current_co] of LuaValue
      }))

      i.globals.raw_set("coroutine", co_lib)
    end
  end
end
