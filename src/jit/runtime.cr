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
# writes the status through `status`. `cl`/`pc` identify the CALLING
# closure and its CALL instruction: the call-site feedback for hot-call
# inlining (M5) is recorded here too — calls from JIT code never pass
# through the interpreter's CALL handler, and without this record a
# caller that tiered up before its first call would never inline.
fun jit_dispatch_call(interp : Void*, cl : Void*, base : Int32, pc : Int32,
                      a : Int32, argn : Int32,
                      want : Int32, status : Int32*) : Void*
  Lua.dispatch_count += 1 if Lua::DEBUG_COUNT
  it = interp.as(Lua::Interp)
  ccl = cl.as(Lua::LuaClosure)
  if pc >= 0 && pc < ccl.proto.packed.size
    case (fnv = it.stack[base + a]?)
    when Lua::LuaClosure   then ccl.proto.call_record(pc, fnv.proto)
    when Lua::LuaFunction
      # record ANY native (M4): the generic identity-guarded native call
      # (emit_call_native) specializes on this, fast1 natives on fast1
      ccl.proto.fast1_record(pc, fnv)
    end
  end
  n = it.jit_call_dispatch(base, a, argn, want)
  status.value = n
  it.stack.to_unsafe.as(Void*)
end

# Guard failure / unsupported path inside machine code: re-establish the
# interpreter frame at `pc` (slots already mirror the state — every
# instruction stores its results) and run the rest of the function in the
# VM. Returns the same status convention as the JIT entry.
fun jit_deopt(interp : Void*, cl : Void*, base : Int32,
              pc : Int32, want : Int32) : Int32
  interp.as(Lua::Interp).jit_deopt(cl.as(Lua::LuaClosure), base, pc, want)
end

# Single-argument numeric builtin (math.* with fast1) called from inlined
# machine code: one C-ABI hop instead of the full dispatch (the fast1 proc
# itself is pure math by construction — no Lua, no allocation — so the
# caller's provenance survives, see emit_call_fast1).
fun jit_fast1(fn : Void*, x : Float64) : Float64
  fn.as(Lua::LuaFunction).fast1.not_nil!.call(x)
end

# Guarded native builtin call from machine code (M4): the caller proved
# tag + object identity + hooks off in a couple of inline loads, so this
# is one C-ABI hop straight into the native — args staged from the value
# stack, results stored per want. Same contract as jit_dispatch_call:
# returns the CURRENT value-stack pointer, status through `status`.
fun jit_call_native(interp : Void*, fn : Void*, base : Int32, a : Int32,
                    argn : Int32, want : Int32, status : Int32*) : Void*
  it = interp.as(Lua::Interp)
  status.value = begin
    it.jit_native_call(fn.as(Lua::LuaFunction), base, a, argn, want)
  rescue e : Lua::LuaError
    it.jit_err = e
    -1
  rescue e : Exception
    e.inspect_with_backtrace(STDERR) if ENV["LUA5_JIT_DEBUG"]?
    it.jit_err = Lua::LuaError.new("(crystal) jit call: #{e.class}: #{e.message || "error"}")
    -1
  end
  it.stack.to_unsafe.as(Void*)
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

# --- M3 remainder: polymorphic fallbacks for arithmetic / compare. The
# JIT's inline fast paths take number operands only; these run the exact
# interpreter semantics (string coercion, metamethods, errors) for every
# other shape observed in the type feedback. ---

# opid: 0 = +, 1 = -, 2 = *, 3 = /, 4 = %, 5 = ^
fun jit_arith(interp : Void*, cl : Void*, base : Int32, pc : Int32,
              opid : Int32, b : Int32, c : Int32, dst : Void*) : Void
  interp.as(Lua::Interp).jit_arith(cl.as(Lua::LuaClosure), base, pc, opid, b, c,
    dst.as(Pointer(Lua::LuaValue)))
end

fun jit_unm(interp : Void*, cl : Void*, base : Int32, pc : Int32,
            b : Int32, dst : Void*) : Void
  interp.as(Lua::Interp).jit_unm(cl.as(Lua::LuaClosure), base, pc, b,
    dst.as(Pointer(Lua::LuaValue)))
end

# opid: 0 = ==, 1 = <, 2 = <=, 3 = ~=
fun jit_cmp(interp : Void*, cl : Void*, base : Int32, pc : Int32,
            opid : Int32, b : Int32, c : Int32, dst : Void*) : Void
  interp.as(Lua::Interp).jit_cmp(cl.as(Lua::LuaClosure), base, pc, opid, b, c,
    dst.as(Pointer(Lua::LuaValue)))
end

# Bytewise string order (Lua.strcmp) for the inlined str/str compare
# path — arguments are String object pointers from LuaValue payloads.
fun jit_strcmp(a : Void*, b : Void*) : Int32
  Lua.strcmp(a.as(String), b.as(String))
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

# FORLOOP back-edge: freeze loop-body upvalues, then the weak-GC tick
# (status contract as jit_weakcheck: 0 stay, 1 deopt — captured slots the
# finalizer may write, -1 pending error)
fun jit_loopedge(interp : Void*, cl : Void*, base : Int32, a : Int32) : Int32
  interp.as(Lua::Interp).jit_loopedge(cl.as(Lua::LuaClosure), base, a)
end

# RETURN: close upvalues at or above this frame's base before the frame
# dies — a compiled closure factory's captured locals must be frozen into
# their UpValue cells before the stack slots are reused (the interpreter
# RETURN handler does the same, guarded the same way).
fun jit_ret(interp : Void*, base : Int32) : Void
  i = interp.as(Lua::Interp)
  i.close_upvals(base) if i.open_max >= base
end

# Backward JMP (while/repeat back-edge): runs the weak-GC tick (same as
# the interpreter's back-edge handler) and returns 0 to stay in machine
# code. 1 = weak tables active and this frame's proto creates closures —
# a __gc finalizer could write captured slots behind machine code's back
# (stale loop-carried phis), so the caller deopts (M2.1 semantics);
# -1 = pending error in interp.jit_err (a finalizer raised).
fun jit_weakcheck(interp : Void*, cl : Void*) : Int32
  interp.as(Lua::Interp).jit_weakcheck(cl.as(Lua::LuaClosure))
end

module Lua
  # Debug counter (LUA5_JIT_DEBUG=count): how many CALLs took the dispatch
  # helper — measures whether the inline fast paths actually engage.
  # Resolved ONCE: an ENV lookup in jit_dispatch_call cost ~70ns per call
  # (16M dispatches on series = +1.1s — found by bisection after the fact)
  DEBUG_COUNT = ENV["LUA5_JIT_DEBUG"]? == "count"
  class_property dispatch_count = 0

  # Opcodes whose mono-numeric guard failure records an operand-shape
  # feedback bit in jit_deopt (mirrors the interpreter slow-path sampling
  # that runs a moment later on the very same instruction).
  OPC_ARITH = [Op::ADD, Op::SUB, Op::MUL, Op::DIV, Op::MOD, Op::POW,
               Op::UNM].map(&.value)
  OPC_CMP = [Op::EQ, Op::NEQ, Op::LT, Op::LE].map(&.value)

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

    # Byte offsets of the fields JIT machine code reads inline (probe once
    # per process — Crystal class layout is fixed per build). The JIT uses
    # these to check hook/coroutine/jit_depth state and re-sync the value
    # stack pointer without a helper call.
    def jit_probe_offsets : NamedTuple(open_max: Int32, current_co: Int32,
                                       hook_on: Int32, jit_depth: Int32,
                                       jit_stack_hi: Int32, jit_stack_buf: Int32,
                                       jit_stack_cap: Int32, globals: Int32)
      p = self.as(Void*).address
      {open_max:      (pointerof(@open_max).address - p).to_i32!,
       current_co:    (pointerof(@current_co).address - p).to_i32!,
       hook_on:       (pointerof(@hook_on).address - p).to_i32!,
       jit_depth:     (pointerof(@jit_depth).address - p).to_i32!,
       jit_stack_hi:  (pointerof(@jit_stack_hi).address - p).to_i32!,
       jit_stack_buf: (pointerof(@jit_stack_buf).address - p).to_i32!,
       jit_stack_cap: (pointerof(@jit_stack_cap).address - p).to_i32!,
       globals:       (pointerof(@globals).address - p).to_i32!}
    end

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
        # Callee tier-up from a JIT caller: without this bump an OSR'd
        # caller would keep its callees one call short of the threshold
        # forever (the interpreter's FORLOOP bumps the caller BEFORE the
        # body, so the caller always wins the race).
        JIT.on_call(self, fn) if fn.is_a?(LuaClosure)
        # Allocation-free numeric builtin call (math.sqrt-style): the
        # helper-crossing itself is the only cost left — no args/result
        # arrays, no call_native frame. Non-number arguments and every
        # other shape take the full slow path with exact error semantics.
        if fn.is_a?(LuaFunction) && (g = fn.fast1) && argn == 1 &&
           (x = @stack[base + a + 1].as?(Float64))
          @stack[base + a] = g.call(x)
          return 1
        end
        begin
          if fn.is_a?(LuaFunction)
            # M4: collapse the native path — the generic jit_slow_call
            # routes through call_value + a separate result-array copy
            jit_native_call(fn, base, a, argn, want)
          else
            jit_slow_call(fn, base, a, argn, want)
          end
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

    # M4: native (LuaFunction) call from machine code without the generic
    # call_value dispatch and result-array detour — args are staged from
    # the value stack into the pooled per-depth buffer, call_native keeps
    # the exact native semantics (C-frame registration for level walks,
    # error wrapping), results are stored straight into the caller's
    # window per `want` (nil-filling missing fixed results, like
    # jit_store_results).
    def jit_native_call(fn : LuaFunction, base : Int32, a : Int32, argn : Int32, want : Int32) : Int32
      ra = base + a
      r = call_native(fn, arg_buf(ra, argn))
      if want == -1
        n = r.size
        ensure_stack(ra + n + 4)
        i = 0
        while i < n
          @stack[ra + i] = r[i]
          i += 1
        end
        n
      elsif want == 0
        0
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

    def jit_loopedge(cl : LuaClosure, base : Int32, a : Int32) : Int32
      close_upvals(base + a) if @open_max >= base + a
      weak_edge(cl)
    end

    # Weak-GC tick the interpreter's back-edge handlers run (vm.cr .jmp? /
    # FORLOOP): bump @gc_tick while any weak table is alive and every 32nd
    # edge clear stale registers + sweep weak tables/finalizers. Doing this
    # here — instead of deopting the whole loop to the interpreter — keeps
    # the loop in machine code. EXCEPTION: a proto that creates closures
    # can have captured slots, and a __gc finalizer run by the sweep may
    # write them behind machine code's back (loop-carried phis would go
    # stale) — such frames deopt (1) and the interpreter drives the tick,
    # exactly the pre-tick M2.1 semantics. A finalizer may run Lua code
    # (i.call), so an escaping exception is stashed as @jit_err and
    # reported as -1 (never unwound through machine frames).
    def jit_weakcheck(cl : LuaClosure) : Int32
      weak_edge(cl)
    end

    private def weak_edge(cl : LuaClosure) : Int32
      return 0 unless Lua.weak_active?
      return 1 if cl.proto.captures_slots?
      @gc_tick &+= 1
      if (@gc_tick & 31) == 0
        begin
          gc_clear_stale(false)
          Lua.gc_full(self)
        rescue e : Exception
          @jit_err = e
          return -1
        end
      end
      0
    end

    # Polymorphic arithmetic fallback (see jit_arith above): the exact
    # interpreter slow path — tonumber coercion, then metamethods/error.
    def jit_arith(cl : LuaClosure, base : Int32, pc : Int32, opid : Int32,
                  b : Int32, c : Int32, dst : Pointer(LuaValue)) : Nil
      jit_line(cl, pc)
      op = case opid
           when 0 then "+"
           when 1 then "-"
           when 2 then "*"
           when 3 then "/"
           when 4 then "%"
           else        "^"
           end
      dst.value = arith(op, @stack[base + b], @stack[base + c], b, c)
    end

    def jit_unm(cl : LuaClosure, base : Int32, pc : Int32, b : Int32,
                dst : Pointer(LuaValue)) : Nil
      jit_line(cl, pc)
      dst.value = negate(@stack[base + b], b)
    end

    # Polymorphic compare fallback (see jit_cmp above): string order,
    # metamethods and the comparison error — the interpreter semantics.
    def jit_cmp(cl : LuaClosure, base : Int32, pc : Int32, opid : Int32,
                b : Int32, c : Int32, dst : Pointer(LuaValue)) : Nil
      jit_line(cl, pc)
      l = @stack[base + b]
      r = @stack[base + c]
      dst.value = case opid
                  when 0 then lua_eq(l, r)
                  when 1 then lua_compare(l, r, "<")
                  when 2 then lua_compare(l, r, "<=")
                  else        !lua_eq(l, r)
                  end
    end

    # Deopt (JIT.md 3): rebuild the interpreter frame at `pc` and run the
    # rest of the closure in the VM; same result/status contract as a
    # fresh JIT entry. An OSR entry (vm.cr back-edge tier-up) left the very
    # same frame live at the top of @frames — reuse it instead of pushing
    # a duplicate.
    def jit_deopt(cl : LuaClosure, base : Int32, pc : Int32, want : Int32) : Int32
      p = cl.proto
      if ENV["LUA5_JIT"]? == "trace"
        osr = @fsize > 0 && (tf = @frames[@fsize - 1]) && tf.closure.same?(cl) && tf.base == base
        STDERR.puts "lua5-jit: deopt #{p.chunkname}:#{p.linedefined} pc=#{pc} " \
                    "op=#{(w = p.packed[pc]?) ? ((w & 0xFF).to_u8!) : 'x'} gen=#{cl.fb_gen} osr=#{osr}"
      end
      # A deopt IS the feedback sample (M3.6): record the shape the guards
      # rejected at this pc so the next compile specializes for it. Table
      # ops record FB_TMISS (polymorphic helper fallback); mono-numeric
      # arith/unm/cmp record the operand shape exactly as the interpreter
      # slow path would a moment later (it re-runs this very instruction).
      if (w = p.packed[pc]?) && (opc = (w & 0xFF).to_u8!)
        if opc == Op::GETTABLE.value || opc == Op::SETTABLE.value ||
           opc == Op::SELF.value
          p.fb_record(pc, Lua::FB_TMISS)
        elsif Lua::OPC_ARITH.includes?(opc) || Lua::OPC_CMP.includes?(opc)
          br = ((w >> 24).to_i64! << 44 >> 44).to_i32!
          cr = ((w >> 44).to_i64! << 44 >> 44).to_i32!
          l = @stack[base + br]?
          r = @stack[base + cr]?
          str = Lua::OPC_ARITH.includes?(opc) ?
              (l.is_a?(String) || r.is_a?(String)) :
              (l.is_a?(String) && r.is_a?(String))
          p.fb_record(pc, str ? Lua::FB_STR : Lua::FB_OTH)
        end
      end
      if @fsize > 0 && (tf = @frames[@fsize - 1]) && tf.closure.same?(cl) && tf.base == base
        # OSR continuation: keep the frame — the machine-code caller
        # (osr_run in vm.cr) completes its return when we hand control back.
        # Drift-recompile BEFORE the interpreted continuation: with fresh
        # machine code installed the frame may re-OSR at its next back-edge
        # (osr_blocked cleared), so a once-called frame (main chunk) does
        # not crawl in the interpreter for the rest of the loop after a
        # single speculative miss. Without a recompile the block stays —
        # re-entering the same code would deopt-loop forever.
        tf.pc = pc
        # OSR futility (JIT::FUTILE_*): a generation that died faster than
        # a compile costs more than it saved — the widening chain on
        # late-arriving shapes pays full compile price per deopt forever.
        # FUTILE_MAX consecutive short-lived generations plus a cumulative
        # compile spend over the budget means the JIT is not paying off:
        # the frame stays interpreted for good (osr_dead). A long-lived
        # generation resets the run.
        if (t0 = cl.osr_at) &&
           (Time.instant - t0).total_milliseconds < JIT::FUTILE_GEN_MS
          cl.futile_osr += 1
        else
          cl.futile_osr = 0
        end
        cl.osr_at = nil
        tf.osr_wait = 0
        if JIT::FUTILE_MAX > 0 && cl.futile_osr >= JIT::FUTILE_MAX &&
           cl.compile_ms >= JIT::FUTILE_BUDGET_MS
          tf.osr_blocked = true
          tf.osr_dead = true
        else
          # Lap-batching: do NOT recompile here — the interpreted
          # continuation runs JIT::OSR_LAP_EDGES back-edges first (the
          # interpreter samples every polymorphic site of the loop body),
          # then osr_lap_wait fires ONE widening recompile that absorbs
          # the whole lap. Immediate recompiles discovered shapes one
          # deopt per generation (veclib: 11 gens/605ms compile).
          tf.osr_blocked = true
          tf.osr_dead = false
        end
        vals = run_frames(@fsize - 1, base)
        @fsize += 1 # run_frames' ensure retired the entry frame; restore it
        # the JIT entry contract wants results at stack[base..]
        i = 0
        while i < vals.size
          @stack[base + i] = vals[i]
          i += 1
        end
        return vals.size
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
        res = jit_store_results(base, want, run_frames(@fsize - 1, base))
      rescue e : LuaError
        @jit_err = e
        res = -1
      end
      # the frame just re-ran interpreted from the deopt pc, so any new
      # operand shape was sampled into the proto's feedback table —
      # recompile when the compile never saw these bits (JIT.md §2)
      JIT.on_deopt(self, cl)
      res
    end
  end
end
