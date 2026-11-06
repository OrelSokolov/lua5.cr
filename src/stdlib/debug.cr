# debug library (port of ldblib.c) + the level machinery of ldebug.c.
#
# Levels follow 5.1 lua_getstack: native (C) calls interleave with Lua
# frames by their entry frame count (db.lua's `pcall(getfenv, 3)` relies
# on pcall's C frame being counted), and a frame reused by tail calls
# contributes one extra "tail" level per lost call (what="tail").

module Lua
  # One resolved level of a state walk.
  enum LevelKind
    LuaF # frames[frame]
    CF   # a native call (real or virtual — a suspended yield, a failed call)
    Tail # a lost tail call of frames[frame]
  end

  record Level, kind : LevelKind, frame : Int32 = -1,
    fn : LuaValue? = nil, args : Array(LuaValue)? = nil, caller : Int32 = -1

  class Interp
    # 5.1 lua_getstack: resolve `level` (0 = innermost, usually the asking
    # native itself) against a state — its Lua frames, the running native
    # calls and an optional virtual innermost native (a coroutine
    # suspended at / killed by a native call). Tail levels sit above
    # their frame's real level.
    def walk_level(level : Int32, frames : Array(Frame), fsize : Int32,
                   natives : Array(NativeEntry),
                   extra : {LuaValue, Array(LuaValue)}?) : Level?
      l = level
      f = fsize
      while f >= 0
        if f == fsize && (x = extra)
          return Level.new(LevelKind::CF, fn: x[0], args: x[1], caller: f - 1) if l == 0
          l -= 1
        end
        i = natives.size - 1
        while i >= 0
          fn, fs, args = natives[i]
          if fs == f
            return Level.new(LevelKind::CF, fn: fn, args: args, caller: f - 1) if l == 0
            l -= 1
          end
          i -= 1
        end
        if f > 0
          fr = frames[f - 1]
          return Level.new(LevelKind::LuaF, frame: f - 1) if l == 0
          l -= 1
          if l < fr.tail_calls
            return Level.new(LevelKind::Tail, frame: f - 1)
          end
          l -= fr.tail_calls
        end
        f -= 1
      end
      nil
    end

    # Level of the current state (the interpreter or the running
    # coroutine — their frames/stacks are swapped in).
    def walk_level(level : Int32) : Level?
      walk_level(level, @frames, @fsize, @native_stack, nil)
    end

    # Level of another state: a suspended coroutine (innermost level is
    # the interrupted call) or one that died with an error (frames kept).
    def walk_level(co : LuaCoroutine, level : Int32) : Level?
      extra = co_pending_native(co)
      walk_level(level, co.frames, co.fsize, co.native_stack, extra)
    end

    # Total levels of the current state (or a coroutine's).
    def count_levels(co : LuaCoroutine?) : Int32
      if co
        count_levels(co.frames, co.fsize, co.native_stack, !co_pending_native(co).nil?)
      else
        count_levels(@frames, @fsize, @native_stack, false)
      end
    end

    private EMPTY_NATIVES = [] of NativeEntry

    # Total number of levels a state walk yields — one pass (natives by
    # entry-frame groups, then each Lua frame + its lost tail calls).
    # Lets traceback skip to the tail arithmetically instead of probing
    # walk_level repeatedly (O(n) vs O(n^2) on overflow-deep stacks).
    def count_levels(frames : Array(Frame), fsize : Int32,
                     natives : Array(NativeEntry), extra : Bool) : Int32
      n = 0
      n += 1 if extra
      n += natives.size
      f = 0
      while f < fsize
        n += 1 + frames[f].tail_calls
        f += 1
      end
      n
    end

    # The native call a coroutine is suspended at (yield/resume boundary)
    # or died inside — reconstructed from the top frame's pending CALL
    # instruction, exactly the ci 5.1 leaves on the coroutine's stack.
    private def co_pending_native(co : LuaCoroutine) : {LuaValue, Array(LuaValue)}?
      return nil unless co.fsize > 0 && (co.yield_call || co.err_death?)
      fr = co.frames[co.fsize - 1]
      pc = fr.pc - 1
      return nil if pc < 0
      ins = fr.closure.proto.code[pc]?
      return nil unless ins && (ins.op.call? || ins.op.tailcall?)
      if fn = co.stack[fr.base + ins.a]?
        {fn, Lua::EMPTY_VALS}
      end
    end

    # 5.1 lua_getstack level → {frames, fsize} of the state it resolved
    # in, so callers can read frame data with consistent indexing.
    def level_state(co : LuaCoroutine?) : {Array(Frame), Int32}
      co ? {co.frames, co.fsize} : {@frames, @fsize}
    end

    # --- frame accessors (5.1 findlocal/luaF_getlocalname) ---

    def frame_line(fr : Frame) : Int32
      fr.closure.proto.lines[{fr.pc - 1, 0}.max]? || -1
    end

    # The n-th local of frame `fr_idx`: a declared local live at the
    # frame's current pc, or "(*temporary)" for a live register.
    def find_local(frames : Array(Frame), fsize : Int32, fr_idx : Int32, n : Int32) : {String, Int32}?
      if lv = frame_local(frames, fr_idx, n)
        {lv.name, lv.reg}
      elsif n >= 1 && frame_live_reg?(frames, fsize, fr_idx, n)
        {"(*temporary)", n}
      end
    end

    # luaF_getlocalname: the n-th local live at the frame's current pc
    # (start_pc <= pc < end_pc), counted in declaration order.
    def frame_local(frames : Array(Frame), fr_idx : Int32, n : Int32) : LocVar?
      return nil if n < 1
      fr = frames[fr_idx]
      pc = fr.pc - 1
      count = 0
      fr.closure.proto.loc_vars.each do |lv|
        next unless lv.start_pc <= pc && pc < lv.end_pc
        count += 1
        return lv if count == n
      end
      nil
    end

    # Is register `reg` of the frame inside its live window? R[0] is the
    # closure slot, so local #n lives at register n. A frame suspended in
    # a call is live up to the callee's base; the top frame up to its top.
    def frame_live_reg?(frames : Array(Frame), fsize : Int32, fr_idx : Int32, reg : Int32) : Bool
      fr = frames[fr_idx]
      limit = fr_idx < fsize - 1 ? frames[fr_idx + 1].base : fr.top
      reg >= 0 && fr.base + reg < limit
    end

    # How the function running in frame `fr_idx` was called: 5.1
    # getfuncname — the pending CALL/TAILCALL/TFORCALL in the caller
    # frame names the callee through getobjname.
    def funcname(frames : Array(Frame), fsize : Int32, fr_idx : Int32) : {String, String}?
      pending_callee_name(frames, fr_idx - 1)
    end

    # The name of the function frame `fr_idx` is in the middle of calling
    # (its pending CALL instruction): how 5.1 getfuncname names C frames
    # and virtual levels (a suspended yield, a failed call).
    def pending_callee_name(frames : Array(Frame), fr_idx : Int32) : {String, String}?
      return nil if fr_idx < 0
      fr = frames[fr_idx]
      p = fr.closure.proto
      pc = fr.pc
      return nil if pc < 1 || pc > p.code.size
      ins = p.code[pc - 1]?
      return nil if ins.nil?
      return nil unless ins.op.call? || ins.op.tailcall? || ins.op.tforcall?
      objname(p, pc - 1, ins.op.tforcall? ? ins.a + 3 : ins.a)
    end

    # Fill a getinfo-style table for a resolved level (ldebug.c
    # auxgetinfo). `frames` is the level's state, for currentline/name.
    def fill_level_info(t : LuaTable, lv : Level, frames : Array(Frame), fsize : Int32, what : String) : Nil
      case lv.kind
      when .lua_f?
        fr = frames[lv.frame]
        cl = fr.closure
        p = cl.proto
        t.raw_set("source", p.chunkname)
        t.raw_set("short_src", Lua.short_src(p.chunkname))
        t.raw_set("linedefined", p.linedefined.to_f64)
        t.raw_set("lastlinedefined", p.lastlinedefined.to_f64)
        t.raw_set("what", p.linedefined == 0 ? "main" : "Lua")
        t.raw_set("nups", p.upvals.size.to_f64)
        t.raw_set("func", cl)
        t.raw_set("currentline", frame_line(fr).to_f64)
        if what.includes?('n')
          nm = funcname(frames, fsize, lv.frame)
          t.raw_set("name", nm ? nm[1] : nil)
          t.raw_set("namewhat", nm ? nm[0] : "")
        end
        if what.includes?('L')
          lines = LuaTable.new
          p.lines.each { |l| lines.raw_set(l.to_f64, true) }
          t.raw_set("activelines", lines)
        end
      when .cf?
        t.raw_set("source", "=[C]")
        t.raw_set("short_src", "[C]")
        t.raw_set("what", "C")
        t.raw_set("linedefined", -1.0)
        t.raw_set("lastlinedefined", -1.0)
        t.raw_set("currentline", -1.0)
        t.raw_set("nups", 0.0)
        t.raw_set("func", lv.fn)
        if what.includes?('n') && lv.caller >= 0
          nm = pending_callee_name(frames, lv.caller)
          t.raw_set("name", nm ? nm[1] : nil)
          t.raw_set("namewhat", nm ? nm[0] : "")
        end
      when .tail?
        # info_tailcall: no debug information at all
        t.raw_set("name", "")
        t.raw_set("namewhat", "")
        t.raw_set("what", "tail")
        t.raw_set("lastlinedefined", -1.0)
        t.raw_set("linedefined", -1.0)
        t.raw_set("currentline", -1.0)
        t.raw_set("source", "=(tail call)")
        t.raw_set("short_src", "(tail call)")
        t.raw_set("nups", 0.0)
        t.raw_set("func", nil)
      end
    end
  end
end

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
        # 5.1 db_getfenv = lua_getfenv: functions and threads carry an
        # environment, everything else runs in the globals
        case args[0]?
        when LuaClosure
          [args[0].as(LuaClosure).env || i2.globals] of LuaValue
        when LuaCoroutine
          [args[0].as(LuaCoroutine).env || i2.globals] of LuaValue
        else
          [i2.default_env || i2.globals] of LuaValue
        end
      }))

      dbg.raw_set("setfenv", LuaFunction.new("debug.setfenv", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        f = args[0]?
        env = args[1]?
        i2.arg_error(2, "setfenv", "table expected") unless env.is_a?(LuaTable)
        case f
        when LuaClosure
          f.env = env
          [f] of LuaValue
        when LuaCoroutine
          f.env = env
          [f] of LuaValue
        else
          i2.raise_lua("setfenv cannot change environment of given object")
        end
      }))

      dbg.raw_set("getregistry", LuaFunction.new("debug.getregistry", ->(_i2 : Interp, _args : Array(Lua::LuaValue)) {
        reg = Lua::LuaTable.new
        reg.raw_set("_LOADED", _i2.globals.raw_get("package").as(Lua::LuaTable).raw_get("loaded"))
        [reg] of LuaValue
      }))

      # debug.sethook([thread,] hook, mask [, count]) — 5.1 makemask:
      # 'c'/'r'/'l' chars plus COUNT when count > 0. Per-state storage;
      # the VM fires the events (vm.cr fire_hook/hook_step).
      dbg.raw_set("sethook", LuaFunction.new("debug.sethook", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        co = args[0]?.as?(LuaCoroutine)
        base = co ? 1 : 0
        hook = args[base]?
        if hook.nil?
          if co
            co.hook = nil
            co.hook_mask = 0
            co.hook_count = 0
          else
            i2.set_hook(nil, 0, 0)
          end
        else
          unless hook.is_a?(LuaClosure) || hook.is_a?(LuaFunction)
            i2.arg_error(base + 1, "sethook", "function expected")
          end
          smask = args[base + 1]?
          i2.arg_error(base + 2, "sethook", "string expected") unless smask.is_a?(String)
          count = args[base + 2]?.is_a?(Float64) ? args[base + 2].as(Float64).to_i : 0
          mask = 0
          mask |= Interp::HOOK_CALL if smask.as(String).includes?('c')
          mask |= Interp::HOOK_RET if smask.as(String).includes?('r')
          mask |= Interp::HOOK_LINE if smask.as(String).includes?('l')
          mask |= Interp::HOOK_COUNT if count > 0
          if co
            co.hook = hook
            co.hook_mask = mask
            co.hook_count = count
            co.hook_countdown = count
          else
            i2.set_hook(hook, mask, count)
          end
        end
        [] of LuaValue
      }))

      # debug.gethook([thread]) → hook, mask string ("crl"), count — or
      # nil when hooks are off.
      dbg.raw_set("gethook", LuaFunction.new("debug.gethook", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        if co = args[0]?.as?(LuaCoroutine)
          f, m, c = co.hook, co.hook_mask, co.hook_count
        else
          f, m, c = i2.hook_state
        end
        return [nil] of LuaValue if f.nil?
        s = String.build do |b|
          b << 'c' if m & Interp::HOOK_CALL != 0
          b << 'r' if m & Interp::HOOK_RET != 0
          b << 'l' if m & Interp::HOOK_LINE != 0
        end
        [f, s, c.to_f64] of LuaValue
      }))

      # debug.getinfo([thread,] function | level [, what])
      dbg.raw_set("getinfo", LuaFunction.new("debug.getinfo", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        co = args[0]?.as?(LuaCoroutine)
        base = co ? 1 : 0
        target = args[base]?
        what = (w = args[base + 1]?).is_a?(String) ? w : "flnSu"
        case target
        when LuaClosure
          # a function argument: no running frame, so no name and no line
          t = Lua::LuaTable.new
          i2.fill_level_info(t, Level.new(LevelKind::LuaF, frame: -1), i2.static_frame(target), 0, what)
          t.raw_set("currentline", -1.0)
          [t] of LuaValue
        when LuaFunction
          t = Lua::LuaTable.new
          i2.fill_level_info(t, Level.new(LevelKind::CF, fn: target), i2.static_frame(target), 0, what)
          [t] of LuaValue
        when Float64
          lvl = target.to_i
          lv = co ? i2.walk_level(co, lvl) : i2.walk_level(lvl)
          return [nil] of LuaValue unless lv
          frames, fsize = i2.level_state(co)
          t = Lua::LuaTable.new
          i2.fill_level_info(t, lv, frames, fsize, what)
          [t] of LuaValue
        else
          i2.arg_error(base + 1, "getinfo", "function or level expected")
        end
      }))

      # debug.traceback([thread,] [message [, level]]) — port of
      # db_errorfb: first LEVELS1 levels, "...", last LEVELS2 levels.
      dbg.raw_set("traceback", LuaFunction.new("debug.traceback", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        co = args[0]?.as?(LuaCoroutine)
        base = co ? 1 : 0
        msg = args[base]?
        level = (n = args[base + 1]?.as?(Float64)) ? n.to_i : (co ? 0 : 1)
        if msg && !msg.is_a?(String) && !msg.is_a?(Float64)
          # 5.1: a non-string message is returned untouched
          [msg] of LuaValue
        else
          frames, fsize = i2.level_state(co)
          out = String.build do |b|
            b << (msg.nil? ? "" : "#{i2.lua_tostring(msg)}\n") << "stack traceback:"
            walk = ->(l : Int32) { co ? i2.walk_level(co, l) : i2.walk_level(l) }
            # total levels in one pass — the ellipsis skip is arithmetic
            # (5.1 probes lua_getstack per step, which is cheap over its
            # ci list; ours would be O(n^2) on overflow-deep stacks)
            total = i2.count_levels(co)
            lvl = level
            firstpart = true
            loop do
              break if lvl >= total
              lv = walk.call(lvl)
              break if lv.nil?
              lvl += 1
              if lvl > 12 && firstpart
                firstpart = false
                if lvl + 10 >= total
                  lvl -= 1 # fewer than LEVELS2 left: keep going
                else
                  b << "\n\t..."
                  lvl = total - 10
                end
                next
              end
              t = Lua::LuaTable.new
              i2.fill_level_info(t, lv, frames, fsize, "Snl")
              b << "\n\t" << t.raw_get("short_src").as(String) << ':'
              if (cl = t.raw_get("currentline").as?(Float64)) && cl > 0
                b << cl.to_i << ':'
              end
              nw = t.raw_get("namewhat").as?(String) || ""
              if !nw.empty?
                b << " in function '" << (t.raw_get("name").as?(String) || "?") << "'"
              else
                case (w = t.raw_get("what").as?(String) || "")
                when .starts_with?("m") then b << " in main chunk"
                when "C", "tail"       then b << " ?"
                else
                  ld = t.raw_get("linedefined").as?(Float64).try(&.to_i) || -1
                  b << " in function <" << t.raw_get("short_src").as(String) << ':' << ld << '>'
                end
              end
            end
          end
          [out] of LuaValue
        end
      }))

      # upvalues: names live in Proto#upvals
      dbg.raw_set("getupvalue", LuaFunction.new("debug.getupvalue", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        f = args[0]?
        n = args.size > 1 ? i2.num!(args, 1, "getupvalue").to_i : 1
        if f.is_a?(Lua::LuaClosure) && n >= 1 && (d = f.proto.upvals[n - 1]?)
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
        if f.is_a?(Lua::LuaClosure) && n >= 1 && (d = f.proto.upvals[n - 1]?)
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

      # debug.getlocal([thread,] level, n) / setlocal([thread,] level, n,
      # value): 5.1 lua_getlocal/lua_setlocal over the level walk. C-frame
      # locals are the native's arguments ("(*temporary)"); a tail level
      # has none.
      dbg.raw_set("getlocal", LuaFunction.new("debug.getlocal", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        co = args[0]?.as?(LuaCoroutine)
        base = co ? 1 : 0
        lvl = i2.num!(args, base, "getlocal").to_i
        n = i2.num!(args, base + 1, "getlocal").to_i
        lv = co ? i2.walk_level(co, lvl) : i2.walk_level(lvl)
        i2.arg_error(base + 1, "getlocal", "level out of range") unless lv
        frames, fsize = i2.level_state(co)
        case lv.kind
        when .lua_f?
          if fl = i2.find_local(frames, fsize, lv.frame, n)
            stack = co ? co.stack : i2.vm_stack
            [fl[0], stack[frames[lv.frame].base + fl[1]]] of LuaValue
          else
            [nil] of LuaValue
          end
        when .cf?
          a = lv.args || Lua::EMPTY_VALS
          n >= 1 && n <= a.size ? ["(*temporary)", a[n - 1]] of LuaValue : [nil] of LuaValue
        else
          [nil] of LuaValue
        end
      }))

      dbg.raw_set("setlocal", LuaFunction.new("debug.setlocal", ->(i2 : Interp, args : Array(Lua::LuaValue)) {
        co = args[0]?.as?(LuaCoroutine)
        base = co ? 1 : 0
        lvl = i2.num!(args, base, "setlocal").to_i
        n = i2.num!(args, base + 1, "setlocal").to_i
        lv = co ? i2.walk_level(co, lvl) : i2.walk_level(lvl)
        i2.arg_error(base + 1, "setlocal", "level out of range") unless lv
        frames, fsize = i2.level_state(co)
        case lv.kind
        when .lua_f?
          if fl = i2.find_local(frames, fsize, lv.frame, n)
            stack = co ? co.stack : i2.vm_stack
            stack[frames[lv.frame].base + fl[1]] = args[base + 2]?
            [fl[0]] of LuaValue
          else
            [nil] of LuaValue
          end
        when .cf?
          if (a = lv.args) && n >= 1 && n <= a.size
            a[n - 1] = args[base + 2]?
            ["(*temporary)"] of LuaValue
          else
            [nil] of LuaValue
          end
        else
          [nil] of LuaValue
        end
      }))

      i.globals.raw_set("debug", dbg)
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
    # Install/replace the hook on the current state (5.1 lua_sethook):
    # resets the countdown so the count hook starts fresh. The line hook
    # seeds the running frame's old_pc from its pending call — without it,
    # the first traced instruction after sethook would fire spuriously
    # (5.1 compares against the real savedpc).
    def set_hook(fn : LuaValue?, mask : Int32, count : Int32) : Nil
      @hook_fn = fn
      @hook_mask = mask
      @hook_count = count
      @hook_countdown = count
      @hook_on = @in_hook ? 0 : mask
      if (mask & HOOK_LINE) != 0 && @fsize > 0
        fr = @frames[@fsize - 1]
        fr.old_pc = fr.pc - 1
      end
    end

    def hook_state : {LuaValue?, Int32, Int32}
      {@hook_fn, @hook_mask, @hook_count}
    end

    def vm_stack : Array(LuaValue)
      @stack
    end

    # Function environment of a stack level (5.1 getfunc + luaB_getfenv):
    # a Lua frame's closure env, the globals for a C frame, a loud error
    # for a tail level ("no function environment for tail call").
    def env_of_level(level : Int32) : LuaTable?
      lv = walk_level(level)
      case lv.try &.kind
      when LevelKind::LuaF
        @frames[lv.not_nil!.frame].closure.env
      when LevelKind::CF
        @default_env
      else
        if lv.nil?
          raise_lua("invalid level")
        else
          raise_lua("no function environment for tail call at level #{level}")
        end
      end
    end

    # 5.1 getfunc for setfenv: the closure at a level; nil for a C frame
    # ("cannot change environment"), a loud error for a tail level.
    def closure_of_level(level : Int32) : LuaClosure?
      lv = walk_level(level)
      case lv.try &.kind
      when LevelKind::LuaF
        @frames[lv.not_nil!.frame].closure
      when LevelKind::CF
        nil
      else
        if lv.nil?
          raise_lua("setfenv: invalid level")
        else
          raise_lua("no function environment for tail call at level #{level}")
        end
      end
    end

    # A frame array for fill_level_info when the target is a bare
    # function (no running frame): currentline comes out as -1.
    def static_frame(cl : LuaClosure) : Array(Frame)
      [Frame.new(cl, 0, 0, Lua::EMPTY_VALS)]
    end

    def static_frame(f : LuaFunction) : Array(Frame)
      [] of Frame
    end
  end
end
