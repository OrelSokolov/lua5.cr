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
  # (interp, stack, cl, base, argn, want, start_pc, top0) — start_pc > 0
  # is an OSR entry (resume block; top0 = live frame top).
  alias EntryFn = (Interp, Pointer(LuaValue), LuaClosure, Int32, Int32, Int32, Int32, Int32) -> Int32

  # Closures handed to compile() since startup — lets specs observe tier-up
  # without touching VM internals.
  class_property compiled_count = 0

  # Bumped from the dispatch-loop CALL path on every Lua-closure call: one
  # increment + compare is the whole counting overhead (M0 criterion <=1%).
  def self.on_call(interp : Interp, cl : LuaClosure) : Nil
    if (cl.hot += 1) == THRESHOLD
      compile(interp, cl)
    end
  end

  # Tier-up: Proto -> LLVM IR -> ORC machine code. Installs cl.compiled;
  # nil leaves the closure interpreted (or keeps the previous machine code
  # on a recompile). A successful compile snapshots the proto's feedback
  # mask it specialized on (deopt drift detection, see on_deopt) and bumps
  # the compile generation. Returns the machine-code entry (nil = failed).
  def self.compile(interp : Interp, cl : LuaClosure) : Pointer(Void)?
    @@compiled_count += 1
    addr = Compiler.compile(interp, cl)
    if addr
      cl.compiled = addr
      cl.fb_snap = cl.proto.feedback.try(&.dup)
      cl.fb_gen += 1
      Compiler.trace("compiled #{cl.proto.chunkname}:#{cl.proto.linedefined}")
    end
    addr
  end

  # True when the proto's feedback table has bits the compile this closure
  # is running never saw (the mask is monotone, so this converges).
  def self.feedback_widened?(cl : LuaClosure) : Bool
    fb = cl.proto.feedback
    return false if fb.nil?
    snap = cl.fb_snap
    if snap.nil?
      fb.any? { |m| m != 0 }
    else
      fb.each_with_index.any? { |m, i| (m & ~(snap[i]? || 0_u8)) != 0 }
    end
  end

  # Speculation drift check after a deopt (JIT.md §2): the deopt recorded
  # the rejected shape into the proto's feedback table (jit_deopt), and the
  # interpreter re-ran the frame from the deopt pc, sampling any further
  # shapes. If the table has bits this compile never saw, recompile — the
  # new code is polymorphic where the mask says so. The mask is monotone
  # and recompiles are capped (fb_gen), so this converges; a failed
  # recompile leaves the previous machine code live. Returns true when
  # fresh machine code was installed.
  def self.recompile_widened(interp : Interp, cl : LuaClosure) : Bool
    return false if cl.fb_gen >= 3
    return false unless feedback_widened?(cl)
    Compiler.trace("recompile: feedback widened #{cl.proto.chunkname}:#{cl.proto.linedefined}")
    !compile(interp, cl).nil?
  end

  # Post-deopt drift check for interpreted continuations that finish the
  # frame before anything can re-enter it (the non-OSR jit_deopt path).
  def self.on_deopt(interp : Interp, cl : LuaClosure) : Nil
    recompile_widened(interp, cl)
  end

  # Machine-code entry without error translation — used from inside the
  # runtime helpers (jit_call_dispatch), where raising would unwind
  # through JIT frames. Status follows the compiler ABI (-1 = pending
  # LuaError in interp.jit_err).
  def self.raw_invoke(cp : Pointer(Void), interp : Interp, cl : LuaClosure,
                      base : Int32, argn : Int32, want : Int32,
                      start_pc : Int32 = 0, top0 : Int32 = 0) : Int32
    top0 = base + argn + 1 if start_pc <= 0 && top0 <= 0
    EntryFn.new(cp, Pointer(Void).null).call(interp, interp.stack.to_unsafe, cl, base, argn, want, start_pc, top0)
  end

  # Entry from the VM dispatch loop (Crystal frames above): translates a
  # negative status into the stashed LuaError. Results (count returned)
  # already sit at stack[base..].
  def self.invoke(cp : Pointer(Void), interp : Interp, cl : LuaClosure,
                  base : Int32, argn : Int32, want : Int32,
                  start_pc : Int32 = 0, top0 : Int32 = 0) : Int32
    n = raw_invoke(cp, interp, cl, base, argn, want, start_pc, top0)
    if n >= 0
      n
    else
      e = interp.jit_err
      interp.jit_err = nil
      raise(e || LuaError.new("lua5 jit: negative status without error"))
    end
  end
end
