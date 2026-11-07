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

module Lua
  class Interp
    # LuaError raised somewhere under a JIT invocation; re-raised by the
    # Crystal boundary (JIT.invoke), never unwound through machine frames.
    property jit_err : Exception? = nil

    def stack : Array(LuaValue)
      @stack
    end

    # CALL from machine code (see jit_dispatch_call above).
    def jit_call_dispatch(base : Int32, a : Int32, argn : Int32, want : Int32) : Int32
      fn = @stack[base + a]
      if fn.is_a?(LuaClosure) && (cp = fn.compiled) && !@current_co && @hook_on == 0 &&
         fn.proto.num_params == argn && !fn.proto.vararg? && @call_depth < 512
        # JIT->JIT: direct native call, guarded against runaway native
        # recursion (deep Lua recursion stays in the interpreter).
        begin
          @call_depth += 1
          n = JIT.raw_invoke(cp, self, fn, base + a, argn, want)
          # nil-fill missing fixed results (store_results analog)
          if want > 0
            i = n
            while i < want
              @stack[base + a + i] = nil
              i += 1
            end
          end
          n
        ensure
          @call_depth -= 1
        end
      else
        begin
          jit_slow_call(fn, base, a, argn, want)
        rescue e : LuaError
          @jit_err = e
          -1
        rescue e : Exception
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
        args = Array(LuaValue).new(argn) { |i| @stack[ra + 1 + i] }
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

    # Deopt (JIT.md 3): rebuild the interpreter frame at `pc` and run the
    # rest of the closure in the VM; same result/status contract as a
    # fresh JIT entry.
    def jit_deopt(cl : LuaClosure, base : Int32, pc : Int32, want : Int32) : Int32
      p = cl.proto
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
