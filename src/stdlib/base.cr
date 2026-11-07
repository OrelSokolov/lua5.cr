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
        i2.arg_error(1, "tostring", "value expected") if args.empty?
        [i2.tostring_value(v)] of LuaValue
      end

      i.native("tonumber") do |i2, args|
        v = args[0]?
        i2.arg_error(1, "tonumber", "value expected") if args.empty?
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
          if found.nil?
            # erased current key? resume from the recorded position (the
            # following key now occupies that slot after removal; >= size
            # just means the traversal is done)
            if !t.next_hint_key.nil? && i2.lua_eq(t.next_hint_key, k) && t.next_hint_idx >= 0
              idx = t.next_hint_idx
            else
              i2.raise_lua("invalid key to 'next'")
            end
          else
            idx = found.not_nil! + 1
          end
        end
        while idx < keys.size
          key = keys[idx]
          val = t.raw_get(key)
          unless val.nil?
            t.next_hint_key = key
            t.next_hint_idx = idx
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
        from = args.size > 1 && !args[1].nil? ? i2.num!(args, 1, "unpack").to_i : 1
        # 5.1 luaL_optnumber: an explicitly passed nil j still defaults
        # to the table length
        to = args.size > 2 && !args[2].nil? ? i2.num!(args, 2, "unpack").to_i : len
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
          # 5.1 luaB_assert: luaL_error → position-prefixed message
          if msg.is_a?(String)
            raise LuaError.new("#{Lua.short_src(i2.cur_chunkname)}:#{i2.err_line(1)}: #{msg}")
          elsif msg.nil?
            raise LuaError.new("#{Lua.short_src(i2.cur_chunkname)}:#{i2.err_line(1)}: assertion failed!")
          else
            i2.arg_error(2, "assert", "string expected")
          end
        end
      end

      i.native("error") do |i2, args|
        v = args[0]?
        level = args.size > 1 ? (Lua.tonumber(args[1]) || 1) : 1.0
        if v.is_a?(String) && level > 0
          raise LuaError.new("#{Lua.short_src(i2.cur_chunkname)}:#{i2.err_line(level.to_i)}: #{v}")
        else
          raise LuaError.new(v)
        end
      end

      i.native("pcall") do |i2, args|
        f = args[0]?
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
        save = i2.err_handler
        i2.err_handler = h
        begin
          r = i2.call(f, [] of LuaValue)
          ([true] of LuaValue).concat(r)
        rescue e : LuaError
          # message handlers normally run at the raise point (run_frames
          # rescue); errors raised by natives under xpcall surface here, so
          # this is the innermost handler spot for them
          unless e.msgh_done?
            e.msgh_done = true
            i2.err_handler = nil
            begin
              e.value = i2.call(h, [e.value] of LuaValue)[0]?
            rescue e2 : LuaError
              # handler itself failed: LUA_ERRERR — xpcall returns it as
              # the error value (5.1 luaD_pcall catches LUA_ERRERR)
              e2.msgh_done = true
              e.value = "error in error handling"
            ensure
              i2.err_handler = save
            end
          end
          [false, e.value] of LuaValue
        ensure
          i2.err_handler = save
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
             when String      then i2.string_meta.metatable || i2.string_meta
             else
               # debug.setmetatable may have given this type a metatable
               i2.type_mts[Lua.type_name(v)]?
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
        chunkname = name.is_a?(String) ? name : src
        begin
          [i2.compile(src, chunkname)] of LuaValue
        rescue e : SyntaxError
          [nil, e.message.not_nil!] of LuaValue
        end
      end

      # load(chunkreader [, chunkname]): pieces from repeated calls to f
      i.native("load") do |i2, args|
        f = args[0]?
        unless f.is_a?(LuaClosure) || f.is_a?(LuaFunction) || (f.is_a?(LuaTable) && i2.metafield(f, "__call"))
          i2.arg_error(1, "load", "function expected")
        end
        buf = IO::Memory.new
        loop do
          r = i2.call(f, [] of LuaValue)
          piece = r[0]?
          break if piece.nil?
          unless piece.is_a?(String)
            i2.raise_lua("bad argument #1 to 'load' (reader must return a string)")
          end
          break if piece.empty?
          buf << piece
        end
        name = args.size > 1 ? (args[1]?) : nil
        chunkname = name.is_a?(String) ? name : "=(load)"
        begin
          [i2.compile(buf.to_s, chunkname)] of LuaValue
        rescue e : SyntaxError
          [nil, e.message.not_nil!] of LuaValue
        end
      end

      i.native("loadfile") do |i2, args|
        fname = args[0]?
        src = if fname.is_a?(String)
                begin
                  File.read(fname)
                rescue e
                  next [nil, "cannot open #{fname}: No such file or directory"] of LuaValue
                end
              else
                i2.raise_lua("loadfile: reading stdin is not supported")
              end
        begin
          [i2.compile(src, "@#{fname.as(String)}")] of LuaValue
        rescue e : SyntaxError
          [nil, e.message.not_nil!] of LuaValue
        end
      end

      i.native("dofile") do |i2, args|
        fname = args[0]?
        i2.raise_lua("dofile: file name expected") unless fname.is_a?(String)
        f = i2.call(i2.globals.raw_get("loadfile"), [fname] of LuaValue)
        cl = f[0]?
        i2.raise_lua(f[1]?.to_s) unless cl.is_a?(LuaClosure)
        i2.call(cl, [] of LuaValue)
      end

      # 5.1 luaB_collectgarbage. Memory work is Boehm's (Crystal GC);
      # "collect" runs the Lua-graph mark/sweep (weak tables, __gc
      # finalizers) plus a full Boehm collection, "count"/gcinfo report
      # heap stats, "stop"/"restart" map to GC.disable/enable, and the
      # incremental options are quiet stubs (a fake step counter) —
      # scripts keep working, exact step semantics are not emulated.
      i.native("collectgarbage") do |i2, args|
        opt = args[0]?
        unless opt.nil? || (opt.is_a?(String) &&
                            {"collect", "count", "step", "setpause", "setstepmul", "stop", "restart"}.includes?(opt))
          i2.raise_lua("invalid option '#{i2.lua_tostring(opt)}' to 'collectgarbage'")
        end
        case opt
        when nil, "collect"
          i2.gc_clear_stale(true)
          Lua.gc_full(i2)
          GC.collect
          i2.gc_close_files
          [0.0] of LuaValue
        when "count"
          kb, rem = Lua.gc_count
          [kb, rem] of LuaValue
        when "step"
          siz = args.size > 1 && (n = Lua.tonumber(args[1])) ? n.to_i : 0
          [Lua.gc_step(siz)] of LuaValue
        when "stop"     then GC.disable; [0.0] of LuaValue
        when "restart"  then GC.enable; [0.0] of LuaValue
        when "setpause"
          v = args.size > 1 && (n = Lua.tonumber(args[1])) ? n.to_i : 200
          [Lua.gc_set_pause(v).to_f64] of LuaValue
        else # "setstepmul"
          v = args.size > 1 && (n = Lua.tonumber(args[1])) ? n.to_i : 200
          [Lua.gc_set_stepmul(v).to_f64] of LuaValue
        end
      end

      # 5.1 gcinfo(): same results as collectgarbage("count")
      i.native("gcinfo") do |_i2, _args|
        kb, rem = Lua.gc_count
        [kb, rem] of LuaValue
      end

      i.globals.raw_set("_G", i.globals)
      i.globals.raw_set("_VERSION", "Lua 5.1")

      # LuaJIT registers a `jit` table as part of the baseline stdlib; xray
      # scripts branch on its existence (`if jit == nil then ... end`, see
      # _g.script). Data fields match LuaJIT 2.1.0-beta3 on x64 Linux; the
      # members are stubs unless a corpus case exercises them.
      jit_tab = LuaTable.new
      jit_tab.raw_set("version", "LuaJIT 2.1.0-beta3")
      jit_tab.raw_set("version_num", 20100)
      jit_tab.raw_set("arch", "x64")
      jit_tab.raw_set("os", "Linux")
      {"on", "off", "flush"}.each do |fn|
        jit_tab.raw_set(fn, LuaFunction.new("jit.#{fn}", ->(_i : Interp, _args : Array(LuaValue)) { [] of LuaValue }))
      end
      i.globals.raw_set("jit", jit_tab)

      # 5.1 function environments (luaB_setfenv/luaB_getfenv)
      i.native("setfenv") do |i2, args|
        t = args[1]?
        i2.arg_error(2, "setfenv", "table expected") unless t.is_a?(LuaTable)
        env = t.as(LuaTable)
        case v = args[0]?
        when Float64
          level = v.to_i
          if level == 0
            # thread-global env: inside a coroutine it is the thread's own
            # env (debug.setfenv(co, t) / setfenv(0, t) there); during a
            # resume the interpreter default IS the thread env, and
            # resume_co persists it back to the coroutine
            if i2.current_co
              i2.default_env = env == i2.globals ? nil : env
            else
              i2.default_env = env == i2.globals ? nil : env
            end
            [i2.globals] of LuaValue
          elsif cl = i2.closure_of_level(level)
            cl.env = env
            [cl] of LuaValue
          else
            # C function (or non-function value): no settable environment
            i2.raise_lua("setfenv cannot change environment of given object")
          end
        when LuaClosure
          v.env = env
          [v] of LuaValue
        else
          i2.raise_lua("setfenv cannot change environment of given object")
        end
      end

      # 5.1 newproxy: bare userdata, optionally with a fresh metatable, or
      # sharing another proxy's metatable
      i.native("newproxy") do |i2, args|
        case a = args[0]?
        when Nil
          [LuaUserData.new(ProxyMarker.new)] of LuaValue
        when Bool
          u = LuaUserData.new(ProxyMarker.new)
          u.metatable = LuaTable.new if a
          [u] of LuaValue
        when LuaUserData
          u = LuaUserData.new(ProxyMarker.new)
          u.metatable = a.metatable
          [u] of LuaValue
        else
          i2.arg_error(1, "newproxy", "nil, boolean or userdata expected")
        end
      end

      i.native("getfenv") do |i2, args|
        case v = args[0]?
        when nil, Float64
          level = v.is_a?(Float64) ? v.to_i : 1
          env = if level == 0
                 (co = i2.current_co) ? co.env : i2.default_env
               else
                 # 5.1 getfunc: level walk — tail levels are a loud error,
                 # C frames run in the globals
                 i2.env_of_level(level)
               end
          [env || i2.globals] of LuaValue
        when LuaClosure
          [v.env || i2.globals] of LuaValue
        else
          # C functions always run in the global environment
          [i2.default_env || i2.globals] of LuaValue
        end
      end
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
