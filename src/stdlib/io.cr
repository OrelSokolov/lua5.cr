# Minimal io library: io.write/io.flush. io.write without trailing newline
# is what the LuaJIT-test-cleanup benchmarks use for all output; the full
# io (files, lines) is Phase 2 per PLAN.md.
module Lua
  module Stdlib
    module IoLib
      def self.install(i : Interp)
        tbl = LuaTable.new
        tbl.raw_set("write", LuaFunction.new("io.write", ->(i2 : Interp, args : Array(LuaValue)) {
          i2.write_out(args.map { |a| i2.lua_tostring(a) }.join)
          [] of LuaValue
        }))
        tbl.raw_set("flush", LuaFunction.new("io.flush", ->(_i2 : Interp, _args : Array(LuaValue)) {
          STDOUT.flush
          [] of LuaValue
        }))
        i.globals.raw_set("io", tbl)
      end
    end
  end
end
