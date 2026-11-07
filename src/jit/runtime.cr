# JIT runtime (JIT.md 1.4/1.5): the only way JIT-compiled machine code
# reaches Crystal — a fixed set of `fun`s with a stable C ABI, plus the
# Interp methods they delegate to.
#
# Invariants (JIT.md 1.3): Lua references live only in Interp@stack slots
# at helper-call boundaries (JIT registers hold none across a call), so the
# conservative Boehm scan sees every root. Crystal exceptions (LuaError)
# never unwind through machine frames: helpers catch them, stash the error
# on Interp#@jit_err and return a negative status; the Crystal boundary
# (JIT.invoke from the VM loop) re-raises.
#
# Status convention shared with the compiler: >= 0 is a result count with
# the results sitting at the callee's base (its closure slot); -1 is a
# pending error in @jit_err.

# --- helpers callable from machine code (absolute addresses, no symbol
# resolution: the compiler embeds them as int2ptr constants) ---

# Dispatch a CALL: JIT->JIT when the callee is compiled (and hooks and
# coroutines are off), the interpreter otherwise. Results end up at
# stack[base+a] per `want` (missing ones nil-filled); returns the CURRENT
# value-stack pointer — the interpreter may have reallocated it — and
# writes the status through `status`.
fun jit_dispatch_call(interp : Void*, base : Int32, a : Int32, argn : Int32,
                      want : Int32, status : Int32*) : Void*
  i = interp.as(Lua::Interp)
  n = i.jit_call_dispatch(base, a, argn, want)
  status.value = n
  i.stack.to_unsafe.as(Void*)
end

# Guard failure / unsupported path inside machine code: re-establish the
# interpreter frame at `pc` (slots already mirror the state — every
# instruction stores its results) and run the rest of the function in the
# VM. Returns the same status convention as the JIT entry.
fun jit_deopt(interp : Void*, cl : Void*, base : Int32,
              pc : Int32, want : Int32) : Int32
  interp.as(Lua::Interp).jit_deopt(cl.as(Lua::LuaClosure), base, pc, want)
end

# GETUPVAL: open upvalues read through the stack, closed ones the cached
# value. The 16-byte result is written to `dst` (a scratch slot in the JIT
# frame — on the native stack, so the GC scan sees any pointer payload).
fun jit_getupval(cl : Void*, idx : Int32, dst : Void*) : Void
  u = cl.as(Lua::LuaClosure).upvals[idx]
  d = dst.as(Pointer(Lua::LuaValue))
  if s = u.stack
    d.value = s[u.idx]
  else
    d.value = u.value
  end
end

# Arithmetic the LLVM builder cannot express directly (no frem in our
# bindings; `**` is a libm call) — kept as tiny `fun`s with the exact
# interpreter semantics (vm.cr ADD..POW fast path).
fun jit_mod(a : Float64, b : Float64) : Float64
  b == 0 ? Float64::NAN : a % b
end

fun jit_pow(a : Float64, b : Float64) : Float64
  a ** b
end

# --- M2: full opcode coverage (JIT.md 2). All mirror the dispatch-loop
# handlers exactly, including @line/@vi_pc for error naming; Array (@stack)
# indexing instead of raw pointers — these can re-enter the VM and
# reallocate the value stack. Results go to `dst` scratch slots. ---

fun jit_getglobal(interp : Void*, cl : Void*, kidx : Int32, pc : Int32, dst : Void*) : Void
  interp.as(Lua::Interp).jit_getglobal(cl.as(Lua::LuaClosure), kidx, pc, dst.as(Pointer(Lua::LuaValue)))
end

fun jit_setglobal(interp : Void*, cl : Void*, kidx : Int32, pc : Int32, src : Void*) : Void
  interp.as(Lua::Interp).jit_setglobal(cl.as(Lua::LuaClosure), kidx, pc, src.as(Pointer(Lua::LuaValue)))
end

fun jit_setupval(cl : Void*, idx : Int32, src : Void*) : Void
  u = cl.as(Lua::LuaClosure).upvals[idx]
  v = src.as(Pointer(Lua::LuaValue)).value
  if s = u.stack
    s[u.idx] = v
  else
    u.value = v
  end
end

fun jit_gettable(interp : Void*, cl : Void*, base : Int32, pc : Int32, a : Int32, b : Int32, c : Int32, dst : Void*) : Void
  interp.as(Lua::Interp).jit_gettable(cl.as(Lua::LuaClosure), base, pc, a, b, c, dst.as(Pointer(Lua::LuaValue)))
end

fun jit_settable(interp : Void*, cl : Void*, base : Int32, pc : Int32, a : Int32, b : Int32, c : Int32) : Void
  interp.as(Lua::Interp).jit_settable(cl.as(Lua::LuaClosure), base, pc, a, b, c)
end

fun jit_self(interp : Void*, cl : Void*, base : Int32, pc : Int32, a : Int32, b : Int32, kidx : Int32, dst : Void*) : Void
  interp.as(Lua::Interp).jit_self(cl.as(Lua::LuaClosure), base, pc, a, b, kidx, dst.as(Pointer(Lua::LuaValue)))
end

fun jit_newtable(dst : Void*) : Void
  dst.as(Pointer(Lua::LuaValue)).value = Lua::LuaTable.new
end

fun jit_setlist(interp : Void*, base : Int32, a : Int32, bcount : Int32, c : Int32, top : Int32) : Void
  interp.as(Lua::Interp).jit_setlist(base, a, bcount, c, top)
end

fun jit_len(interp : Void*, cl : Void*, base : Int32, pc : Int32, b : Int32, dst : Void*) : Void
  interp.as(Lua::Interp).jit_len(cl.as(Lua::LuaClosure), base, pc, b, dst.as(Pointer(Lua::LuaValue)))
end

fun jit_concat(interp : Void*, cl : Void*, base : Int32, pc : Int32, a : Int32, b : Int32) : Void
  interp.as(Lua::Interp).jit_concat(cl.as(Lua::LuaClosure), base, pc, a, b)
end

fun jit_closure(interp : Void*, cl : Void*, base : Int32, pidx : Int32, dst : Void*) : Void
  interp.as(Lua::Interp).jit_closure(cl.as(Lua::LuaClosure), base, pidx, dst.as(Pointer(Lua::LuaValue)))
end

fun jit_close(interp : Void*, base : Int32, a : Int32) : Void
  interp.as(Lua::Interp).close_upvals(base + a)
end

# FORLOOP back-edge: freeze loop-body upvalues; 1 = weak tables active —
# the caller deopts so the interpreter drives its loop-edge GC (a JIT
# frame has no CallInfo, gc_clear_stale cannot see its live window)
fun jit_loopedge(interp : Void*, base : Int32, a : Int32) : Int32
  interp.as(Lua::Interp).jit_loopedge(base, a)
end

# RETURN: close upvalues at or above this frame's base before the frame
# dies — a compiled closure factory's captured locals must be frozen into
# their UpValue cells before the stack slots are reused (the interpreter
# RETURN handler does the same, guarded the same way).
fun jit_ret(interp : Void*, base : Int32) : Void
  i = interp.as(Lua::Interp)
  i.close_upvals(base) if i.open_max >= base
end

# Backward JMP (while/repeat back-edge): 1 = weak tables active — the
# caller deopts so the interpreter drives its loop-edge GC (the loop may
# be *waiting* for a weak-table sweep to finish, which only gc_full does)
fun jit_weakcheck(interp : Void*) : Int32
  Lua.weak_active? ? 1 : 0
end

module Lua
  class Interp
    # LuaError raised somewhere under a JIT invocation; re-raised by the
    # Crystal boundary (JIT.invoke), never unwound through machine frames.
    property jit_err : Exception? = nil

    # Native nesting of JIT entries. NOT reset by run_frames (unlike
    # @call_depth) — a reset would let deep recursion rebuild JIT chains
    # inside every interpreter continuation until the C stack dies.
    # Past the limit, recursion runs flat in the interpreter until
    # ensure_stack raises "stack overflow" (250k slots) — same observable
    # behavior as without the JIT.
    property jit_depth : Int32 = 0

    # High-water mark of live JIT register windows: JIT frames have no
    # CallInfo, so gc_clear_stale (which clears everything above the top
    # interpreter frame's window) must not clear into an active JIT
    # closure's registers — e.g. collectgarbage() called from JITed code.
    # Maintained as max(base+max_stack) around every JIT invocation.
    property jit_stack_hi : Int32 = -1

    def stack : Array(LuaValue)
      @stack
    end

    # CALL from machine code (see jit_dispatch_call above).
    def jit_call_dispatch(base : Int32, a : Int32, argn : Int32, want : Int32) : Int32
      fn = @stack[base + a]
      if fn.is_a?(LuaClosure) && (cp = fn.compiled) && !@current_co && @hook_on == 0 &&
         fn.proto.num_params == argn && !fn.proto.vararg? && @jit_depth < 512
        # JIT->JIT: direct native call, guarded against runaway native
        # recursion (deep Lua recursion stays in the interpreter). The
        # callee window must be ensured first — the VM fast path does the
        # same check before its entry, and ensure_stack raising here is
        # what turns deep recursion into "stack overflow" (250k slots).
        ra = base + a
        ensure_stack(ra + {fn.proto.max_stack, argn + 1}.max + argn + 4)
        prev_hi = @jit_stack_hi
        win = ra + fn.proto.max_stack
        @jit_stack_hi = win if win > prev_hi
        begin
          @jit_depth += 1
          n = JIT.raw_invoke(cp, self, fn, ra, argn, want)
          # nil-fill missing fixed results (store_results analog)
          if want > 0
            i = n
            while i < want
              @stack[ra + i] = nil
              i += 1
            end
          end
          n
        ensure
          @jit_depth -= 1
          @jit_stack_hi = prev_hi
        end
      else
        begin
          jit_slow_call(fn, base, a, argn, want)
        rescue e : LuaError
          @jit_err = e
          -1
        rescue e : Exception
          e.inspect_with_backtrace(STDERR) if ENV["LUA5_JIT_DEBUG"]?
          @jit_err = LuaError.new("(crystal) jit call: #{e.class}: #{e.message || "error"}")
          -1
        end
      end
    end

    # Interpreter fallback for a CALL from machine code (mirrors the VM's
    # CALL slow path and native dispatch).
    private def jit_slow_call(fn : LuaValue, base : Int32, a : Int32, argn : Int32, want : Int32) : Int32
      ra = base + a
      case fn
      when LuaClosure
        ensure_stack(ra + fn.proto.max_stack + argn + 4)
        push_call(fn, ra, argn, want)
        if (@hook_on & HOOK_CALL) != 0
          nf = @frames[@fsize - 1]
          nf.pc = 1 # "pc already incremented"
          fire_hook("call", nil)
          nf.pc = 0
        end
        jit_store_results(ra, want, run_frames(@fsize - 1, ra))
      else
        r = call_value(fn, ra, argn, a)
        jit_store_results(ra, want, r)
      end
    end

    # Move an interpreter result array into the slot window per `want`
    # (store_results analog); returns the count the JIT caller sees.
    private def jit_store_results(ra : Int32, want : Int32, r : Array(LuaValue)) : Int32
      if want == -1
        n = r.size
        ensure_stack(ra + n + 4)
        i = 0
        while i < n
          @stack[ra + i] = r[i]
          i += 1
        end
        n
      else
        ensure_stack(ra + want + 4)
        i = 0
        while i < want
          @stack[ra + i] = r[i]?
          i += 1
        end
        want
      end
    end

    # --- M2 helper bodies (see the fun wrappers above): exact mirrors of
    # the dispatch-loop handlers, @stack-indexed because they can re-enter
    # the VM (metamethods) and reallocate the value stack ---

    # position info for errors raised by the ops below (pc = instruction
    # index, the loop's pc-1)
    def jit_line(cl : LuaClosure, pc : Int32) : Nil
      @line = cl.proto.lines[pc]? || @line
      @vi_pc = pc
    end

    def jit_getglobal(cl : LuaClosure, kidx : Int32, pc : Int32, dst : Pointer(LuaValue)) : Nil
      jit_line(cl, pc)
      n = cl.proto.consts[kidx].as(String)
      dst.value = if (g = cl.env) || @globals.metatable
                    getindex(g || @globals, n)
                  else
                    @globals.raw_get(n)
                  end
    end

    def jit_setglobal(cl : LuaClosure, kidx : Int32, pc : Int32, src : Pointer(LuaValue)) : Nil
      jit_line(cl, pc)
      setindex(cl.env || @globals, cl.proto.consts[kidx].as(String), src.value)
    end

    def jit_gettable(cl : LuaClosure, base : Int32, pc : Int32, a : Int32, b : Int32,
                     c : Int32, dst : Pointer(LuaValue)) : Nil
      jit_line(cl, pc)
      o = @stack[base + b]
      k = @stack[base + c]
      dst.value = if o.is_a?(LuaTable) && o.metatable.nil?
                    o.raw_get(k)
                  else
                    getindex(o, k, b)
                  end
    end

    def jit_settable(cl : LuaClosure, base : Int32, pc : Int32, a : Int32, b : Int32, c : Int32) : Nil
      jit_line(cl, pc)
      t = @stack[base + a]
      k = @stack[base + b]
      if t.is_a?(LuaTable) && t.metatable.nil?
        t.raw_set(k, @stack[base + c])
      else
        setindex(t, k, @stack[base + c], a)
      end
    end

    def jit_self(cl : LuaClosure, base : Int32, pc : Int32, a : Int32, b : Int32,
                 kidx : Int32, dst : Pointer(LuaValue)) : Nil
      jit_line(cl, pc)
      obj = @stack[base + b]
      @stack[base + a + 1] = obj
      key = cl.proto.consts[kidx].as(String)
      dst.value = if obj.is_a?(LuaTable) && obj.metatable.nil?
                    obj.raw_get(key)
                  else
                    getindex(obj, key, b)
                  end
    end

    def jit_setlist(base : Int32, a : Int32, bcount : Int32, c : Int32, top : Int32) : Nil
      t = @stack[base + a].as(LuaTable)
      # 0-value multi feeds can leave top at the table slot
      n = bcount == -1 ? {top - (base + a + 1), 0}.max : bcount
      vals = Array(LuaValue).new(n) { |i| @stack[base + a + 1 + i] }
      t.raw_fill(c + 1, vals)
    end

    def jit_len(cl : LuaClosure, base : Int32, pc : Int32, b : Int32, dst : Pointer(LuaValue)) : Nil
      jit_line(cl, pc)
      dst.value = lua_len(@stack[base + b], b)
    end

    def jit_concat(cl : LuaClosure, base : Int32, pc : Int32, a : Int32, b : Int32) : Nil
      jit_line(cl, pc)
      v = @stack[base + b]
      i = b - 1
      while i >= a
        v = lua_concat(@stack[base + i], v, i, i + 1)
        i -= 1
      end
      @stack[base + a] = v
    end

    def jit_closure(cl : LuaClosure, base : Int32, pidx : Int32,
                    dst : Pointer(LuaValue)) : Nil
      pr = cl.proto.protos[pidx]
      ups = Array(UpValue).new(pr.upvals.size)
      pr.upvals.each do |d|
        ups << (d.from_stack? ? capture(base + d.index) : cl.upvals[d.index])
      end
      nc = LuaClosure.new(pr, ups)
      nc.env = cl.env # 5.1: closures inherit the enclosing env
      dst.value = nc
    end

    def jit_loopedge(base : Int32, a : Int32) : Int32
      close_upvals(base + a) if @open_max >= base + a
      Lua.weak_active? ? 1 : 0
    end

    # Deopt (JIT.md 3): rebuild the interpreter frame at `pc` and run the
    # rest of the closure in the VM; same result/status contract as a
    # fresh JIT entry. An OSR entry (vm.cr back-edge tier-up) left the very
    # same frame live at the top of @frames — reuse it instead of pushing
    # a duplicate.
    def jit_deopt(cl : LuaClosure, base : Int32, pc : Int32, want : Int32) : Int32
      p = cl.proto
      if @fsize > 0 && (tf = @frames[@fsize - 1]) && tf.closure.same?(cl) && tf.base == base
        # OSR continuation: keep the frame — the machine-code caller
        # (osr_run in vm.cr) completes its return when we hand control back
        tf.pc = pc
        tf.osr_blocked = true
        res = run_frames(@fsize - 1, base)
        @fsize += 1 # run_frames' ensure retired the entry frame; restore it
        # the JIT entry contract wants results at stack[base..]
        i = 0
        while i < res.size
          @stack[base + i] = res[i]
          i += 1
        end
        return res.size
      end
      ensure_stack(base + p.max_stack + 4)
      top = base + p.max_stack
      f = Frame.new(cl, base, top, Lua::EMPTY_VALS)
      if @fsize < @frames.size
        @frames[@fsize] = f
      else
        @frames << f
      end
      f.want = want
      f.pc = pc
      @fsize += 1
      begin
        jit_store_results(base, want, run_frames(@fsize - 1, base))
      rescue e : LuaError
        @jit_err = e
        -1
      end
    end
  end
end
