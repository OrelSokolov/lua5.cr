# debug library (port of ldblib.c). Level-based introspection works over the
# VM frame stack (@frames); hooks and local-variable access need compiler
# debug info (Proto#loc_vars) and dispatch-loop support (vm.cr).
module Lua::Stdlib
  module DebugLib
    def self.install(i : Interp)
      dbg = LuaTable.new

      # debug.setmetatable(value, mt): metatable for a whole type. The
      # registry is consulted by Interp#metafield (numbers, nil, booleans,
      # functions, threads become indexable through it).
      dbg.raw_set("setmetatable", LuaFunction.new("debug.setmetatable", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        v = args[0]?
        mt = args[1]?
        i2.arg_error(1, "setmetatable", "value expected") if v.nil? && args.empty?
        case v
        when LuaTable    then v.metatable = mt.as?(LuaTable); [v] of LuaValue
        when LuaUserData then v.metatable = mt.as?(LuaTable); [v] of LuaValue
        when String      then i2.string_meta.metatable = mt.as?(LuaTable); [v] of LuaValue
        else
          # primitive types share one metatable slot per type
          i2.type_mts[Lua.type_name(v)] = mt.as?(LuaTable)
          [v] of LuaValue
        end
      }))

      dbg.raw_set("getmetatable", LuaFunction.new("debug.getmetatable", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        v = args[0]?
        mt = case v
             when LuaTable    then v.metatable
             when LuaUserData then v.metatable
             when String      then i2.string_meta.metatable
             else
               i2.type_mts[Lua.type_name(v)]?
             end
        [mt] of LuaValue
      }))

      dbg.raw_set("getfenv", LuaFunction.new("debug.getfenv", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        case v = args[0]?
        when nil, Float64
          level = v.is_a?(Float64) ? v.to_i : 1
          env = if level == 0
                 (co = i2.current_co) ? co.env : i2.default_env
               else
                 i2.caller_closure(level).try &.env
               end
          [env || i2.globals] of LuaValue
        when Lua::LuaClosure
          [v.env || i2.globals] of LuaValue
        when Lua::LuaCoroutine
          [v.env || i2.globals] of LuaValue
        else
          [i2.default_env || i2.globals] of LuaValue
        end
      }))

      dbg.raw_set("setfenv", LuaFunction.new("debug.setfenv", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        f = args[0]?
        env = args[1]?
        i2.arg_error(1, "setfenv", "function expected") unless f.is_a?(LuaClosure) || f.is_a?(LuaCoroutine)
        i2.arg_error(2, "setfenv", "table expected") unless env.is_a?(LuaTable)
        case f
        when LuaClosure   then f.env = env
        when LuaCoroutine then f.env = env
        end
        [f] of LuaValue
      }))

      dbg.raw_set("getregistry", LuaFunction.new("debug.getregistry", ->(_i2 : Interp, _args : Array(Lua::LuaValue)) {
        reg = Lua::LuaTable.new
        reg.raw_set("_LOADED", _i2.globals.raw_get("package").as(Lua::LuaTable).raw_get("loaded"))
        [reg] of LuaValue
      }))

      # debug.getinfo([level|function] [, what])
      dbg.raw_set("getinfo", LuaFunction.new("debug.getinfo", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        target : LuaValue = args[0]? || 1.0
        what = args[1]?.is_a?(String) ? args[1].as(String) : "flnS"
        if target.is_a?(Lua::LuaClosure)
          build_info(i2, target, nil, what)
        elsif target.is_a?(Lua::LuaFunction)
          # C function: no lines, no source (5.1 funcinfo for isC)
          t = Lua::LuaTable.new
          t.raw_set("source", "=[C]")
          t.raw_set("short_src", "[C]")
          t.raw_set("what", "C")
          t.raw_set("linedefined", -1.0)
          t.raw_set("lastlinedefined", -1.0)
          t.raw_set("currentline", -1.0)
          t.raw_set("nups", 0.0)
          t.raw_set("func", target)
          [t] of LuaValue
        elsif target.is_a?(Float64)
          lvl = target.to_i
          if lvl == 0
            # the C function itself: no lines, no source
            t = Lua::LuaTable.new
            t.raw_set("what", "C")
            [t] of LuaValue
          elsif (idx = i2.frame_index(lvl))
            fr = i2.frame_at(idx)
            build_info(i2, fr.closure, idx, what)
          else
            [nil] of LuaValue
          end
        else
          i2.arg_error(1, "getinfo", "function or level expected")
        end
      }))

      # debug.traceback([message [, level]])
      dbg.raw_set("traceback", LuaFunction.new("debug.traceback", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        msg = args[0]?
        lvl = args.size > 1 && args[1]?.is_a?(Float64) ? args[1].as(Float64).to_i : 1
        out = String.build do |b|
          b << (msg.nil? ? "stack traceback:" : "#{i2.lua_tostring(msg)}\nstack traceback:")
          # from the level's frame (1 = caller of traceback) down to the
          # bottom; nil level (too deep) shows no frames
          if idx = i2.frame_index({lvl, 1}.max)
            while idx >= 0
              fr = i2.frame_at(idx)
              p = fr.closure.proto
              line = (p.lines[{fr.pc - 1, 0}.max]? || 0)
              src = Lua.short_src(p.chunkname)
              nm = i2.funcname(idx)
              what = idx == 0 ? "main chunk" : "function #{nm ? "'#{nm[1]}'" : Lua.repr_addr(fr.closure)}"
              b << "\n\t" << src << ':' << line << ": in " << what
              idx -= 1
            end
          end
        end
        [out] of LuaValue
      }))

      # upvalues: names live in Proto#upvals
      dbg.raw_set("getupvalue", LuaFunction.new("debug.getupvalue", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        f = args[0]?
        n = args.size > 1 ? i2.num!(args, 1, "getupvalue").to_i : 1
        if f.is_a?(Lua::LuaClosure) && (d = f.proto.upvals[n - 1]?)
          u = f.upvals[n - 1]
          v = u.stack ? u.stack.not_nil![u.idx] : u.value
          [d.name, v] of LuaValue
        else
          [nil] of LuaValue
        end
      }))

      dbg.raw_set("setupvalue", LuaFunction.new("debug.setupvalue", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        f = args[0]?
        n = args.size > 1 ? i2.num!(args, 1, "setupvalue").to_i : 1
        if f.is_a?(Lua::LuaClosure) && (d = f.proto.upvals[n - 1]?)
          u = f.upvals[n - 1]
          v = args[2]?
          if s = u.stack
            s[u.idx] = v
          else
            u.value = v
          end
          [d.name] of LuaValue
        else
          [nil] of LuaValue
        end
      }))

      # debug.getlocal(level, n) / setlocal(level, n, value): 5.1
      # lua_getlocal/lua_setlocal. Level 0 is the C function itself (its
      # own arguments, named "(*temporary)"); level N is the Lua frame
      # N-1 above — named locals come from Proto#loc_vars live at the
      # frame's current pc, live unnamed registers are "(*temporary)".
      dbg.raw_set("getlocal", LuaFunction.new("debug.getlocal", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        lvl = i2.num!(args, 0, "getlocal").to_i
        n = i2.num!(args, 1, "getlocal").to_i
        if lvl == 0
          # the C function's arguments are its only locals
          if n >= 1 && n <= args.size
            ["(*temporary)", args[n - 1]] of LuaValue
          else
            [nil] of LuaValue
          end
        elsif idx = i2.frame_index(lvl)
          if fl = i2.find_local(idx, n)
            [fl[0], i2.frame_reg(idx, fl[1])] of LuaValue
          else
            [nil] of LuaValue
          end
        else
          i2.arg_error(1, "getlocal", "level out of range")
        end
      }))

      dbg.raw_set("setlocal", LuaFunction.new("debug.setlocal", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        lvl = i2.num!(args, 0, "setlocal").to_i
        n = i2.num!(args, 1, "setlocal").to_i
        if lvl > 0 && (idx = i2.frame_index(lvl)) && (fl = i2.find_local(idx, n))
          i2.set_frame_reg(idx, fl[1], args[2]?)
          [fl[0]] of LuaValue
        else
          [nil] of LuaValue
        end
      }))

      i.globals.raw_set("debug", dbg)
    end

    # Shared getinfo table builder (closure + its frame index, if running)
    def self.build_info(i2 : Interp, cl : Lua::LuaClosure, fr_idx : Int32?, what : String) : Array(Lua::LuaValue)
      p = cl.proto
      t = Lua::LuaTable.new
      t.raw_set("source", p.chunkname)
      t.raw_set("short_src", Lua.short_src(p.chunkname))
      t.raw_set("linedefined", p.linedefined.to_f64)
      t.raw_set("lastlinedefined", p.lastlinedefined.to_f64)
      t.raw_set("what", "Lua")
      t.raw_set("nups", p.upvals.size.to_f64)
      t.raw_set("func", cl)
      if fr_idx
        fr = i2.frame_at(fr_idx)
        pc = {fr.pc - 1, 0}.max
        t.raw_set("currentline", (p.lines[pc]? || -1).to_f64)
      else
        t.raw_set("currentline", -1.0)
      end
      if what.includes?('n')
        # a function argument (no running frame) has no name (5.1: "")
        nm = fr_idx ? i2.funcname(fr_idx) : nil
        t.raw_set("name", nm ? nm[1] : nil)
        t.raw_set("namewhat", nm ? nm[0] : "")
      end
      if what.includes?('L')
        lines = Lua::LuaTable.new
        p.lines.each { |l| lines.raw_set(l.to_f64, true) }
        t.raw_set("activelines", lines)
      end
      [t] of LuaValue
    end
  end
end

module Lua
  # luaO_chunkid: source → short_src
  def self.short_src(source : String) : String
    if source.starts_with?('=')
      src = source[1..]
      src.size > 59 ? src[0, 59] : src
    elsif source.starts_with?('@')
      src = source[1..]
      if src.size > 54 # bufflen 60 - " '...' " overhead
        "..." + src[(src.size - 54)..]
      else
        src
      end
    else
      head = source.split('\n').first
      head = head.split('\r').first
      if head.size > 40
        "[string \"#{head[0, 40]}...\"]"
      elsif head.size < source.size
        "[string \"#{head}...\"]"
      else
        "[string \"#{head}\"]"
      end
    end
  end

  class Interp
    # Frame index for a getinfo-style level (1 = direct caller of the
    # running native), or nil past the bottom.
    def frame_index(level : Int32) : Int32?
      return nil if level < 1
      idx = @fsize - level
      (idx >= 0 && idx < @fsize) ? idx : nil
    end

    def frame_at(idx : Int32) : Frame
      @frames[idx]
    end

    def frame_count : Int32
      @fsize
    end

    # 5.1 findlocal: the n-th local of the frame — a declared local live
    # at the current pc, or "(*temporary)" for a register inside the
    # frame's live window. R[0] is the closure slot, so local #n lives at
    # register n. Returns {name, reg} or nil.
    def find_local(fr_idx : Int32, n : Int32) : {String, Int32}?
      if lv = frame_local(fr_idx, n)
        {lv.name, lv.reg}
      elsif n >= 1 && frame_live_reg?(fr_idx, n)
        {"(*temporary)", n}
      else
        nil
      end
    end

    # 5.1 luaF_getlocalname: the n-th local live at the frame's current pc
    # (start_pc <= pc < end_pc), counted in declaration order.
    def frame_local(fr_idx : Int32, n : Int32) : LocVar?
      return nil if n < 1
      fr = @frames[fr_idx]
      pc = fr.pc - 1
      count = 0
      fr.closure.proto.loc_vars.each do |lv|
        next unless lv.start_pc <= pc && pc < lv.end_pc
        count += 1
        return lv if count == n
      end
      nil
    end

    def frame_reg(fr_idx : Int32, reg : Int32) : LuaValue
      @stack[@frames[fr_idx].base + reg]
    end

    def set_frame_reg(fr_idx : Int32, reg : Int32, v : LuaValue) : Nil
      @stack[@frames[fr_idx].base + reg] = v
    end

    # Is register `reg` of the frame inside its live window? R[0] is the
    # closure slot, so local #n lives at register n. A frame suspended in
    # a call is live up to the callee's base (the closure slot of the
    # pending CALL); the top frame reports its full register window.
    def frame_live_reg?(fr_idx : Int32, reg : Int32) : Bool
      fr = @frames[fr_idx]
      limit = fr_idx < @fsize - 1 ? @frames[fr_idx + 1].base : fr.top
      reg >= 0 && fr.base + reg < limit
    end

    # How the function running in frame `fr_idx` was called: 5.1 getfuncname —
    # the instruction at the caller's pc (the pending CALL/TAILCALL/TFORCALL)
    # names the callee through getobjname.
    def funcname(fr_idx : Int32) : {String, String}?
      caller_idx = fr_idx - 1
      return nil if caller_idx < 0
      caller = @frames[caller_idx]
      p = caller.closure.proto
      pc = caller.pc
      return nil if pc < 1 || pc > p.code.size
      ins = p.code[pc - 1]?
      return nil if ins.nil?
      return nil unless ins.op.call? || ins.op.tailcall? || ins.op.tforcall?
      objname(p, pc - 1, ins.op.tforcall? ? ins.a + 3 : ins.a)
    end
  end
end
