# JIT phase 5 (see JIT.md): hotness counting and the tier-up trigger.
#
# The VM's CALL handler bumps a per-closure counter on every Lua-closure
# call; crossing THRESHOLD hands the closure to the compiler. A failed
# compile (unsupported opcodes, M1 subset) leaves it interpreted — the
# counter test is == so tier-up is attempted exactly once.

module Lua::JIT
  # Tier-up threshold in calls (JIT.md 1.2), overridable for tests/benches.
  THRESHOLD = (ENV["LUA5_JIT_THRESHOLD"]? || "500").to_i

  # JIT entry ABI (compiler.cr): C convention, never called through a
  # Crystal Proc boundary from machine code (jit_call_dispatch calls it
  # via raw_invoke to keep exceptions out of machine frames).
  alias EntryFn = (Interp, Pointer(LuaValue), LuaClosure, Int32, Int32, Int32) -> Int32

  # Closures handed to compile() since startup — lets specs observe tier-up
  # without touching VM internals.
  class_property compiled_count = 0

  # Bumped from the dispatch-loop CALL path on every Lua-closure call: one
  # increment + compare is the whole counting overhead (M0 criterion <=1%).
  def self.on_call(cl : LuaClosure) : Nil
    if (cl.hot += 1) == THRESHOLD
      compile(cl)
    end
  end

  # Tier-up: Proto -> LLVM IR -> ORC machine code. Installs cl.compiled;
  # nil leaves the closure interpreted.
  def self.compile(cl : LuaClosure) : Nil
    @@compiled_count += 1
    addr = Compiler.compile(cl)
    if addr
      cl.compiled = addr
      Compiler.trace("compiled #{cl.proto.chunkname}:#{cl.proto.linedefined}")
    end
  end

  # Machine-code entry without error translation — used from inside the
  # runtime helpers (jit_call_dispatch), where raising would unwind
  # through JIT frames. Status follows the compiler ABI (-1 = pending
  # LuaError in interp.jit_err).
  def self.raw_invoke(cp : Pointer(Void), interp : Interp, cl : LuaClosure,
                      base : Int32, argn : Int32, want : Int32) : Int32
    EntryFn.new(cp, Pointer(Void).null).call(interp, interp.stack.to_unsafe, cl, base, argn, want)
  end

  # Entry from the VM dispatch loop (Crystal frames above): translates a
  # negative status into the stashed LuaError. Results (count returned)
  # already sit at stack[base..].
  def self.invoke(cp : Pointer(Void), interp : Interp, cl : LuaClosure,
                  base : Int32, argn : Int32, want : Int32) : Int32
    n = raw_invoke(cp, interp, cl, base, argn, want)
    if n >= 0
      n
    else
      e = interp.jit_err
      interp.jit_err = nil
      raise(e || LuaError.new("lua5 jit: negative status without error"))
    end
  end
end
