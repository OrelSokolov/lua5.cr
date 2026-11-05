# Base library. Port of MoonSharp StdLib/BaseLibrary.cs (lbaselib.c).
module Lua::Stdlib
  module Base
    def self.install(i : Interp)
      i.native("print") do |i2, args|
        i2.puts_out(args.map { |a| i2.lua_tostring(a) }.join("\t"))
        [] of LuaValue
      end

      i.native("type") do |i2, args|
        v = args[0]?
        i2.arg_error(1, "type", "value expected") if v.nil? && args.empty?
        [Lua.type_name(v)] of LuaValue
      end

      i.native("tostring") do |i2, args|
        v = args[0]?
        [i2.lua_tostring(v)] of LuaValue
      end

      i.native("tonumber") do |i2, args|
        v = args[0]?
        base = args[1]?
        if base.nil?
          if v.is_a?(Float64) || v.is_a?(String)
            n = Lua.tonumber(v)
            n ? [n] of LuaValue : [nil] of LuaValue
          else
            [nil] of LuaValue
          end
        else
          b = Lua.tonumber(base)
          i2.arg_error(2, "tonumber", "number expected") unless b
          bi = b.not_nil!.to_i
          i2.arg_error(2, "tonumber", "base out of range") if bi < 2 || bi > 36
          s = case v
              when String  then v
              when Float64 then Lua.fmt_num(v)
              else
                next [nil] of LuaValue
              end
          n = s.strip.downcase.to_i64?(bi)
          n ? [n.to_f64] of LuaValue : [nil] of LuaValue
        end
      end

      # next / pairs
      nextfn = ->(i2 : Interp, args : Array(LuaValue)) {
        t = i2.table!(args, 0, "next")
        k = args[1]?
        keys = t.raw_keys
        idx : Int32
        if k.nil?
          idx = 0
        else
          found = keys.index { |x| i2.lua_eq(x, k) }
          i2.raise_lua("invalid key to 'next'") if found.nil?
          idx = found.not_nil! + 1
        end
        while idx < keys.size
          key = keys[idx]
          val = t.raw_get(key)
          unless val.nil?
            return [key, val] of LuaValue
          end
          idx += 1
        end
        [] of LuaValue
      }
      i.native("next", &nextfn)

      i.native("pairs") do |i2, args|
        t = i2.table!(args, 0, "pairs")
        [LuaFunction.new("next", nextfn), t, nil] of LuaValue
      end

      ipairs_iter = ->(i2 : Interp, args : Array(LuaValue)) {
        t = args[0]?
        n = i2.num!(args, 1, "ipairs")
        idx = n.to_i + 1
        v = i2.getindex(t, idx.to_f64)
        if v.nil?
          [] of LuaValue
        else
          [idx.to_f64, v] of LuaValue
        end
      }
      i.native("ipairs") do |i2, args|
        t = i2.table!(args, 0, "ipairs")
        [LuaFunction.new("ipairs_iter", ipairs_iter), t, 0.0] of LuaValue
      end

      i.native("select") do |i2, args|
        n = args[0]?
        rest = args.size > 1 ? args[1..] : ([] of LuaValue)
        if n == "#"
          [(rest.size).to_f64] of LuaValue
        else
          idx = i2.num!(args, 0, "select").to_i
          if idx < 0
            idx += rest.size + 1
          end
          i2.raise_lua("bad argument #1 to 'select' (index out of range)") if idx < 1
          if idx > rest.size
            [] of LuaValue
          else
            rest[idx - 1..]
          end
        end
      end

      i.native("unpack") do |i2, args|
        t = i2.table!(args, 0, "unpack")
        len = t.raw_length
        from = args.size > 1 ? i2.num!(args, 1, "unpack").to_i : 1
        to = args.size > 2 ? i2.num!(args, 2, "unpack").to_i : len
        res = [] of LuaValue
        x = from
        while x <= to
          res << i2.getindex(t, x.to_f64)
          x += 1
        end
        res
      end

      i.native("assert") do |i2, args|
        v = args[0]?
        if Lua.truthy(v)
          args
        else
          msg = args[1]?
          raise LuaError.new(msg.nil? ? "assertion failed!" : msg)
        end
      end

      i.native("error") do |i2, args|
        v = args[0]?
        i2.arg_error(1, "error", "value expected") if args.empty?
        level = args.size > 1 ? (Lua.tonumber(args[1]) || 1) : 1.0
        if v.is_a?(String) && level > 0
          raise LuaError.new("#{i2.chunkname}:#{i2.line}: #{v}")
        else
          raise LuaError.new(v)
        end
      end

      i.native("pcall") do |i2, args|
        f = args[0]?
        unless f.is_a?(LuaClosure) || f.is_a?(LuaFunction) || f.is_a?(LuaTable) || f.is_a?(LuaUserData)
          i2.arg_error(1, "pcall", "value expected") if f.nil?
          i2.raise_lua("attempt to call a #{Lua.type_name(f)} value")
        end
        rest = args.size > 1 ? args[1..] : ([] of LuaValue)
        begin
          r = i2.call(f, rest)
          ([true] of LuaValue).concat(r)
        rescue e : LuaError
          [false, e.value] of LuaValue
        end
      end

      i.native("xpcall") do |i2, args|
        f = args[0]?
        h = args[1]?
        begin
          r = i2.call(f, [] of LuaValue)
          ([true] of LuaValue).concat(r)
        rescue e : LuaError
          hr = i2.call(h, [e.value])
          ([false] of LuaValue).concat(hr)
        end
      end

      i.native("setmetatable") do |i2, args|
        t = i2.table!(args, 0, "setmetatable")
        mt = args[1]?
        if mt && !mt.is_a?(LuaTable)
          i2.arg_error(2, "setmetatable", "nil or table expected")
        end
        existing = t.metatable
        unless (existing ? existing.raw_get("__metatable") : nil).nil?
          i2.raise_lua("cannot change a protected metatable")
        end
        t.metatable = mt.as?(LuaTable)
        [t] of LuaValue
      end

      i.native("getmetatable") do |i2, args|
        v = args[0]?
        mt = case v
             when LuaTable    then v.metatable
             when LuaUserData then v.metatable
             when String      then i2.string_meta
             else                  nil
             end
        if mt
          prot = mt.raw_get("__metatable")
          [prot || mt] of LuaValue
        else
          [nil] of LuaValue
        end
      end

      i.native("rawget") do |i2, args|
        t = i2.table!(args, 0, "rawget")
        [t.raw_get(args[1]?)] of LuaValue
      end

      i.native("rawset") do |i2, args|
        t = i2.table!(args, 0, "rawset")
        t.raw_set(args[1]?, args[2]?)
        [t] of LuaValue
      end

      i.native("rawequal") do |i2, args|
        [i2.raw_eq(args[0]?, args[1]?)] of LuaValue
      end

      i.native("rawlen") do |i2, args|
        t = args[0]?
        case t
        when LuaTable then [t.raw_length.to_f64] of LuaValue
        when String   then [t.bytesize.to_f64] of LuaValue
        else
          i2.arg_error(1, "rawlen", "table or string expected")
        end
      end

      i.native("loadstring") do |i2, args|
        s = args[0]?
        i2.arg_error(1, "loadstring", "string expected") unless s.is_a?(String) || s.is_a?(Float64)
        src = s.is_a?(String) ? s : Lua.fmt_num(s)
        name = args.size > 1 ? (args[1]?) : nil
        chunkname = name.is_a?(String) ? name : src[0, 20]
        begin
          [i2.compile(src, chunkname)] of LuaValue
        rescue e : SyntaxError
          [nil, e.message.not_nil!] of LuaValue
        end
      end

      i.native("collectgarbage") do |_i2, _args|
        [0.0] of LuaValue
      end

      i.globals.raw_set("_G", i.globals)
      i.globals.raw_set("_VERSION", "Lua 5.1")

      # Explicit, loud markers for not-yet-ported libraries (Phase 2/3).
      i.native("coroutine_not_ported") do |i2, _args|
        i2.raise_lua("coroutines are not implemented yet (Phase 3, see PLAN.md)")
      end
      stub = LuaFunction.new("stub", ->(i2 : Interp, _args : Array(LuaValue)) {
        i2.raise_lua("not implemented yet (see PLAN.md)")
        [] of LuaValue
      })
      coroutine = LuaTable.new
      %w[create resume yield status wrap].each do |n|
        coroutine.raw_set(n, stub)
      end
      i.globals.raw_set("coroutine", coroutine)
      i.globals.raw_set("require", stub)
      i.globals.raw_set("dofile", stub)
      i.globals.raw_set("load", stub)
    end
  end
end

module Lua
  class Interp
    # print goes through here so embedders can redirect output.
    property? quiet : Bool = false

    def puts_out(s : String)
      puts s unless quiet?
    end

    # io.write goes through here for the same reason.
    def write_out(s : String)
      print s unless quiet?
    end
  end
end
