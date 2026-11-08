# JIT compiler (JIT.md 1.6, M1): a whole Proto to LLVM IR to machine code
# via LLVM ORC (LLJIT). Helper funs (runtime.cr) are declared in the module
# and resolved against the host process symbols at link time, so the JIT
# never depends on Crystal's unstable ABI for calls back into the runtime.
#
# Entry ABI (see runtime.cr):
#   i32 entry(Interp* interp, LuaValue* stack, LuaClosure* cl,
#             i32 base, i32 argn, i32 want)
#   -> >=0: result count, results at stack[base..]
#      -1 : LuaError pending in interp.jit_err
#
# M1 opcode subset — anything else bails the whole compilation and the
# closure stays interpreted (the hotness counter fires once, so a bail is
# final for the closure): LOADK LOADNIL LOADBOOL MOVE ADD SUB MUL DIV MOD
# POW UNM NOT EQ NEQ LT LE JMP JMPF JMPT GETUPVAL CALL RETURN.
#
# Two invariants make this safe (JIT.md 1.3/3):
#   * every instruction loads operands from / stores results to stack
#     slots, so a deopt at any instruction boundary resumes the
#     interpreter with exact state;
#   * the value-stack pointer and the frame top are kept in allocas and
#     refreshed around CALL — the interpreter may reallocate @stack.

require "llvm"

# Target registration is not part of Crystal's LLVM bindings; ORC needs
# the native target + asm parser/printer initialized before first use.
@[Link("LLVM")]
private lib LLVMTgt
  fun a64_info = LLVMInitializeAArch64TargetInfo
  fun a64_target = LLVMInitializeAArch64Target
  fun a64_mc = LLVMInitializeAArch64TargetMC
  fun a64_asm_p = LLVMInitializeAArch64AsmParser
  fun a64_asm_w = LLVMInitializeAArch64AsmPrinter
  fun x86_info = LLVMInitializeX86TargetInfo
  fun x86_target = LLVMInitializeX86Target
  fun x86_mc = LLVMInitializeX86TargetMC
  fun x86_asm_p = LLVMInitializeX86AsmParser
  fun x86_asm_w = LLVMInitializeX86AsmPrinter
end

module Lua::JIT
  # Crystal union layout for LuaValue, probed once per process (type ids
  # are per-build values): { i32 tag @0, i64 payload @8 }, 16 bytes.
  # Doubles live in the payload; Bool payload is 0/1; Nil's tag is 0.
  module Layout
    class_getter tag_num : Int32 = -1
    class_getter tag_bool : Int32 = -1
    class_getter tag_str : Int32 = -1
    class_getter tag_table : Int32 = -1
    # LuaTable field byte offsets (LuaTable#probe_offsets) for the inlined
    # GETTABLE/SETTABLE array-part fast path
    class_getter tbl_mt : Int32 = -1
    class_getter tbl_buf : Int32 = -1
    class_getter tbl_base : Int32 = -1
    class_getter tbl_len : Int32 = -1
    # flat string-key store (SSlot array): buffer/mask fields of LuaTable
    # and SSlot size/field offsets for the inlined identity probe
    class_getter tbl_slots : Int32 = -1
    class_getter tbl_smask : Int32 = -1
    class_getter slot_size : Int32 = -1
    class_getter slot_key : Int32 = -1
    class_getter slot_val : Int32 = -1
    # unboxed array part (M7): f64 buffer + flag byte — the numeric fast
    # paths branch on the flag and load bare doubles (no tag check)
    class_getter tbl_fbuf : Int32 = -1
    class_getter tbl_unboxed : Int32 = -1
    # LuaClosure tag + field offsets, Proto field offsets (direct-call fast
    # path), Interp field offsets (inline hook/coroutine/depth checks and
    # value-stack re-sync) and the static weak_seen flag address.
    class_getter tag_closure : Int32 = -1
    class_getter tag_fun : Int32 = -1
    class_getter cl_proto : Int32 = -1
    class_getter cl_compiled : Int32 = -1
    # GETUPVAL inline (M5.1): @upvals buffer offset on LuaClosure, the
    # byte offset of an Array's @buffer field (identical for every Array(T):
    # fields are i32 size/capacity + pointer buffer), and the UpValue cell
    # field offsets
    class_getter cl_upvs : Int32 = -1
    class_getter arr_buf : Int32 = -1
    class_getter uv_stack : Int32 = -1
    class_getter uv_idx : Int32 = -1
    class_getter uv_value : Int32 = -1
    # Pointer(Void) type id: @compiled is a 16-byte nilable-pointer union
    # { i32 tag, ptr payload } — the tag gates the payload load
    class_getter cl_compiled_tag : Int32 = -1
    class_getter pr_params : Int32 = -1
    class_getter pr_vararg : Int32 = -1
    class_getter pr_maxstack : Int32 = -1
    class_getter i_open_max : Int32 = -1
    class_getter i_current_co : Int32 = -1
    class_getter i_hook_on : Int32 = -1
    class_getter i_jit_depth : Int32 = -1
    class_getter i_jit_hi : Int32 = -1
    class_getter i_stack_buf : Int32 = -1
    class_getter i_stack_cap : Int32 = -1
    class_getter weak_seen : UInt64 = 0

    @@probed = false

    def self.probe!(interp : Interp, cl : LuaClosure) : Nil
      return if @@probed
      buf = Pointer(LuaValue).malloc(4)
      buf[0] = 1.5
      buf[1] = true
      buf[3] = "x"
      tbl = LuaTable.new
      buf[2] = tbl
      tags = buf.as(Pointer(Int32))
      @@tag_num = tags[0]
      @@tag_bool = tags[4]
      @@tag_str = tags[12]
      @@tag_table = tags[8]
      # reuse slot 0 for the closure tag (after the numeric tag was read!)
      buf[0] = cl
      @@tag_closure = tags[0]
      f1 = LuaFunction.new("probe", ->(i2 : Interp, xs : Array(LuaValue)) { xs })
      buf[0] = f1
      @@tag_fun = tags[0]
      o = tbl.probe_offsets
      @@tbl_mt = o[:mt]
      @@tbl_buf = o[:buf]
      @@tbl_base = o[:base]
      @@tbl_len = o[:len]
      @@tbl_slots = o[:slots]
      @@tbl_smask = o[:smask]
      @@slot_size = o[:slot_size]
      @@slot_key = o[:slot_key]
      @@slot_val = o[:slot_val]
      @@tbl_fbuf = o[:fbuf]
      @@tbl_unboxed = o[:unboxed]
      c = cl.probe_offsets
      @@cl_proto = c[:proto]
      @@cl_compiled = c[:compiled]
      @@cl_compiled_tag = c[:compiled_tag]
      @@cl_upvs = c[:upvals]
      # Array @buffer field offset: identical for every Array(T)
      # instantiation (i32 size/capacity + pointer buffer). Match by VALUE
      # (arr.to_unsafe) — no candidate pointer is ever dereferenced: the
      # object is only ~24 bytes, so reads past its fields hit the next
      # heap object's header (a false positive there segfaulted the scan).
      u1 = UpValue.new(nil, 0)
      u2 = UpValue.new(nil, 1)
      arr = [u1, u2] of UpValue
      abase = arr.as(UInt8*)
      bufp = arr.to_unsafe.address
      {8, 16, 24}.each do |off|
        @@arr_buf = off if (abase + off).as(Pointer(UInt64)).value == bufp
      end
      raise "JIT layout probe: Array @buffer not found" if @@arr_buf < 0
      uo = u1.probe_offsets
      @@uv_stack = uo[:stack]
      @@uv_idx = uo[:idx]
      @@uv_value = uo[:value]
      pr = cl.proto.probe_offsets
      @@pr_params = pr[:num_params]
      @@pr_vararg = pr[:vararg]
      @@pr_maxstack = pr[:max_stack]
      i = interp.jit_probe_offsets
      @@i_open_max = i[:open_max]
      @@i_current_co = i[:current_co]
      @@i_hook_on = i[:hook_on]
      @@i_jit_depth = i[:jit_depth]
      @@i_jit_hi = i[:jit_stack_hi]
      @@i_stack_buf = i[:jit_stack_buf]
      @@i_stack_cap = i[:jit_stack_cap]
      @@weak_seen = Lua.weak_seen_addr
      @@probed = true
    end
  end

  # Raised when a proto uses something outside the M1 subset; compile()
  # turns it into "leave the closure interpreted".
  class CompileBail < Exception
  end

  module Compiler
    @@lljit : LLVM::Orc::LLJIT? = nil
    @@sym = 0
    # New-PM pipeline over the generated IR before ORC links it. Without
    # this the default IRTransformLayer is a no-op: the scratch/cur_stack/
    # cur_top allocas stay in memory (no mem2reg/GVN/LICM) and every value
    # reloads from the value stack. Overridable for experiments.
    PIPELINE = ENV["LUA5_JIT_PIPELINE"]? || "default<O2>"
    # kill-switches for bisection: direct JIT->JIT calls and inlined
    # back-edge gates can each be disabled from the environment
    FAST_CALL = ENV["LUA5_JIT_FASTCALL"]? != "0"
    INLINE_EDGE = ENV["LUA5_JIT_EDGE"]? != "0"
    # cross-block numeric SSA (merge phis) — M3.7
    PHIMERGE = ENV["LUA5_JIT_PHIMERGE"]? != "0"
    # hot-call inlining (M5); INLINE_MAX_OPS bounds the callee body
    INLINE_CALL = ENV["LUA5_JIT_INLINE"]? != "0"
    INLINE_MAX_OPS = 64
    # inline fast1 builtin calls (M5.1) — kill-switch for bisection
    FAST1_CALL = ENV["LUA5_JIT_FAST1"]? != "0"
    # callee feedback snapshots of the last compile (M5): populated by gen,
    # consumed by JIT.compile for the closure's drift detection
    class_property last_inline_snaps = [] of {Proto, Array(UInt8)}
    @@tm : LLVM::TargetMachine? = nil
    # OSR entry points and block predecessor counts of the proto being
    # compiled (see compile)
    @@osr_heads = Set(Int32).new
    @@preds = [] of Int32
    # numeric-for loop regions (FORLOOP pc -> {head, A}) for loop phis
    @@forloops = Hash(Int32, {Int32, Int32}).new
    # true when the proto being compiled has no CLOSURE opcode (see compile)
    class_getter? no_upvs = false
    # Keep-alives: ORC code and its context must outlive the closures
    # pointing into it; the Crystal GC would free them otherwise.
    @@keep = [] of LLVM::Orc::ThreadSafeContext

    # Compile `cl`; returns the machine-code entry or nil (unsupported).
    def self.compile(interp : Interp, cl : LuaClosure) : Pointer(Void)?
      t0 = Time.monotonic if ENV["LUA5_JIT"]? == "trace"
      Layout.probe!(interp, cl)
      p = cl.proto
      # `arg`-table protos bail: the implicit local is built by push_call at
      # frame entry, which the JIT entry does not do. A bare vararg flag is
      # fine: vararg frames are always entered through push_call (direct
      # JIT entries exclude vararg protos), so the interpreter Frame with
      # its varargs array exists for any deopt — and the VARARG opcode
      # itself deopts wholesale (like TAILCALL), which re-runs the frame
      # interpreted from that pc with varargs intact (fasta's loadstring'd
      # chunks are all vararg; before this they never tiered up at all).
      return nil if p.needs_arg?
      return nil if p.code.size > 4096 # M1 sanity cap

      # OSR points: targets of backward jumps (numeric-for bodies, while/
      # repeat loops, generic-for tests). The entry function starts at
      # blocks[start_pc] for these, blocks[0] otherwise (see gen).
      heads = Set(Int32).new
      p.packed.each_with_index do |w, pc|
        op = (w & 0xFF).to_u8!.unsafe_as(Op)
        case op
        when .jmp?, .jmpf?, .jmpt?, .forloop?, .tforcall?
          off = ((w >> 24).to_i64! << 44 >> 44).to_i32!
          heads << (pc + 1 + off) if off < 0
        end
      end
      @@osr_heads = heads

      # Control-flow predecessors of each pc-block (fallthrough + jump
      # targets + OSR switch edges). The numeric SSA map survives a linear
      # single-predecessor chain and must reset where states merge.
      preds = Array(Int32).new(p.packed.size + 1, 0)
      edge = ->(t : Int32) { preds[t] += 1 if t < preds.size }
      p.packed.each_with_index do |w, pc|
        op = (w & 0xFF).to_u8!.unsafe_as(Op)
        off = ((w >> 24).to_i64! << 44 >> 44).to_i32!
        case op
        when .jmp?        then edge.call(pc + 1 + off)
        when .jmpf?, .jmpt?
          edge.call(pc + 1 + off)
          edge.call(pc + 1)
        when .forprep?    then edge.call(pc + 1 + off)
        when .forloop?
          edge.call(pc + 1 + off)
          edge.call(pc + 1)
        when .tforcall?
          edge.call(pc + 1 + off)
          edge.call(pc + 1)
        when .tailcall?, .vararg?, .return?
          # terminal: machine code returns control
        else
          edge.call(pc + 1)
        end
      end
      edge.call(0) # function entry
      heads.each { |hpc| edge.call(hpc) }
      @@preds = preds

      # Numeric-for loop regions for loop-carried SSA (phi) values:
      # FORLOOP pc -> {head pc, control base A}. The FORPREP must jump to
      # the FORLOOP (codegen invariant) — that edge bypasses the head, so
      # the phi pattern is two-level (see emit_forloop/emit_forprep).
      # INNERMOST loops only: a phi in the head block dominates its uses
      # only while no other loop head sits inside the body — an OSR entry
      # into a nested loop head bypasses this head, and the phi register
      # would read garbage there (module verification rejects the
      # dominance violation; the outer loop then keeps its slot loads).
      forloops = Hash(Int32, {Int32, Int32}).new
      prep_at = Hash(Int32, Int32).new # FORLOOP pc -> FORPREP's A
      back_tgts = Set(Int32).new
      p.packed.each_with_index do |w, pc|
        op = (w & 0xFF).to_u8!.unsafe_as(Op)
        off = ((w >> 24).to_i64! << 44 >> 44).to_i32!
        case op
        when .jmp?, .jmpf?, .jmpt?, .forloop?
          back_tgts << (pc + 1 + off) if off < 0
        end
      end
      p.packed.each_with_index do |w, pc|
        op = (w & 0xFF).to_u8!.unsafe_as(Op)
        a = ((w >> 8).to_i64! << 48 >> 48).to_i32!
        off = ((w >> 24).to_i64! << 44 >> 44).to_i32!
        case op
        when .forprep? then prep_at[pc + 1 + off] = a
        when .forloop?
          if off < 0 && prep_at[pc]? == a
            head = pc + 1 + off
            inner = back_tgts.any? { |t| t > head && t < pc }
            forloops[pc] = {head, a} unless inner
          end
        end
      end
      @@forloops = forloops

      # Upvalue-free protos: no CLOSURE opcode anywhere means nothing can
      # ever capture this frame's slots, so the FORLOOP back-edge
      # close_upvals check (open_max >= base+A) is dead — only the weak
      # gate remains (JIT.md 1.3 invariants).
      @@no_upvs = !p.packed.any? { |w| (w & 0xFF).to_u8! == Op::CLOSURE.value }

      @@sym += 1
      sym = "lua5jit#{@@sym}"
      # See module_context: LLVM 21+ and older LLVM differ in how a module's
      # context can be wrapped for ORC.
      ctx, ts_ctx = module_context
      mod = ctx.new_module(sym)
      # Host layout/triple from the start: a bare context has no DataLayout,
      # so LLVM would size { i32, i64 } as 12 bytes (i64 payload at +4) —
      # ORC re-stamps the real arm64 layout (16 bytes, payload at +8) at
      # codegen, and any IR pass run before that would miscompile every
      # struct-typed load/store into wrong offsets (infinite loops).
      tm = target_machine
      mod.target = tm.triple
      mod.data_layout = tm.data_layout
      @@last_inline_snaps = [] of {Proto, Array(UInt8)}
      gen(cl, ctx, mod, sym)
      unless @@last_inline_snaps.empty?
        trace("inline: #{@@last_inline_snaps.size} call site(s) in " \
              "#{cl.proto.chunkname}:#{cl.proto.linedefined}: " \
              "#{@@last_inline_snaps.map { |cp2, _| "#{cp2.chunkname}:#{cp2.linedefined}" }.join(",")}")
      end
      if d = ENV["LUA5_JIT_DUMP"]?
        File.write("#{d}/#{@@sym}-pre.ll", mod.to_s)
      end
      begin
        mod.verify
      rescue e : Exception
        raise CompileBail.new("verify: #{e.message}")
      end
      optimize!(mod)
      if d = ENV["LUA5_JIT_DUMP"]?
        File.write("#{d}/#{@@sym}-post.ll", mod.to_s)
      end

      engine = lljit
      ts_mod = LLVM::Orc::ThreadSafeModule.new(mod, ts_ctx)
      engine.add_llvm_ir_module(engine.main_jit_dylib, ts_mod)
      @@keep << ts_ctx
      if t0
        trace("compile-time: #{cl.proto.chunkname}:#{cl.proto.linedefined} " \
              "#{(Time.monotonic - t0.not_nil!).total_milliseconds.round(1)}ms")
      end
      engine.lookup(sym)
    rescue e : CompileBail
      trace("bail: #{cl.proto.chunkname}:#{cl.proto.linedefined} #{e.message} " \
            "(#{(Time.monotonic - t0.not_nil!).total_milliseconds.round(1)}ms)") if t0
      nil
    end

    # Context the module is generated in, paired with the ThreadSafeContext
    # ORC will receive it in. Wrapping an existing Context needs the
    # LLVMOrcCreateNewThreadSafeContextFromLLVMContext C entry point (LLVM
    # 21+; the Crystal bindings stub ThreadSafeContext#new(Context) with
    # NotImplementedError on older LLVM). There the ThreadSafeContext must
    # own its context up front — so create it first and hand out the
    # context it owns. The C entry point takes ownership of the ContextRef:
    # the wrapper must not also dispose it on finalize (double free — the
    # GC'd wrapper would free the context out from under the kept
    # ThreadSafeContext, crashing ~LLVMContextImpl later).
    private def self.module_context : {LLVM::Context, LLVM::Orc::ThreadSafeContext}
      {% if LibLLVM.has_method?(:orc_create_new_thread_safe_context_from_llvm_context) %}
      ctx = LLVM::Context.new(dispose_on_finalize: false)
      {ctx, LLVM::Orc::ThreadSafeContext.new(ctx)}
      {% else %}
      ts_ctx = LLVM::Orc::ThreadSafeContext.new
      {ts_ctx.context, ts_ctx}
      {% end %}
    end

    def self.trace(msg : String) : Nil
      STDERR.puts "lua5-jit: #{msg}" if ENV["LUA5_JIT"]? == "trace"
    end

    # TargetMachine for the host (LLVMRunPasses wants TTI for the
    # pipeline's vectorizer/inline cost decisions). The ORC session's own
    # TM is not exposed by the bindings, so keep a separate one.
    private def self.target_machine : LLVM::TargetMachine
      @@tm ||= begin
        # target registration normally happens in lljit; a compile that
        # optimizes before the engine exists must do it itself. Both native
        # targets are registered unconditionally — registration is
        # idempotent, and the X86 backend must be live before the first
        # compile on an Intel/AMD host (triple comes from the host below).
        LLVMTgt.a64_info
        LLVMTgt.a64_target
        LLVMTgt.a64_mc
        LLVMTgt.a64_asm_p
        LLVMTgt.a64_asm_w
        LLVMTgt.x86_info
        LLVMTgt.x86_target
        LLVMTgt.x86_mc
        LLVMTgt.x86_asm_p
        LLVMTgt.x86_asm_w
        triple = LLVM.default_target_triple
        LLVM::Target.from_triple(triple).create_target_machine(
          triple, opt_level: LLVM::CodeGenOptLevel::Aggressive)
      end
    end

    # Run the new-PM optimization pipeline over the freshly generated IR.
    # LLVMGetErrorMessage consumes the error, LLVMDisposeErrorMessage frees
    # the string.
    private def self.optimize!(mod : LLVM::Module) : Nil
      return if PIPELINE.empty? || PIPELINE == "none"
      LLVM::PassBuilderOptions.new do |opts|
        err = LibLLVM.run_passes(mod, PIPELINE, target_machine, opts)
        if err
          msg = LibLLVM.get_error_message(err)
          s = String.new(msg)
          LibLLVM.dispose_error_message(msg)
          raise CompileBail.new("pipeline '#{PIPELINE}': #{s}")
        end
      end
    end

    private def self.lljit : LLVM::Orc::LLJIT
      @@lljit ||= begin
        LLVMTgt.a64_info
        LLVMTgt.a64_target
        LLVMTgt.a64_mc
        LLVMTgt.a64_asm_p
        LLVMTgt.a64_asm_w
        engine = LLVM::Orc::LLJIT.new(LLVM::Orc::LLJITBuilder.new)
        # resolve jit_* helper declarations against this process
        engine.main_jit_dylib.link_symbols_from_current_process(engine.global_prefix)
        engine
      end
    end

    # --- IR generation ---

    private class Gen
      getter b : LLVM::Builder
      getter i8 : LLVM::Type
      getter i32 : LLVM::Type
      getter i64 : LLVM::Type
      getter f64 : LLVM::Type
      getter lv : LLVM::Type           # { i32, i64 } = LuaValue
      getter lv_ptr : LLVM::Type
      getter ptr : LLVM::Type
      getter entry_ty : LLVM::Type     # JIT entry function type (direct calls)
      getter nil_const : LLVM::Value   # constant { i32 0, i64 0 } (nil slot fill)
      getter interp : LLVM::Value
      getter clp : LLVM::Value
      getter base : LLVM::Value
      getter want : LLVM::Value
      getter blocks : Array(LLVM::BasicBlock)
      getter scratch : LLVM::Value     # alloca LuaValue (staging)
      getter status_p : LLVM::Value    # alloca i32 (CALL out-param)
      getter ret_i : LLVM::Value       # alloca i32 (RETURN copy loop)
      getter cur_stack : LLVM::Value   # alloca LuaValue*
      getter cur_top : LLVM::Value     # alloca i32 (frame top index)
      getter cl : LuaClosure
      getter code : Array(UInt64)
      getter consts : Array(LuaValue)
      # M5: callee protos inlined so far this compile + their feedback
      # snapshots (drift detection, see JIT.feedback_widened?)
      getter inline_snaps = [] of {Proto, Array(UInt8)}
      # Numeric SSA: register -> f64 SSA value proven to equal the slot's
      # current content, valid within the current block only (cleared at
      # block boundaries and around any runtime call). Slots still receive
      # every store — this only removes redundant loads and tag guards
      # (the deopt-anywhere invariant is untouched).
      @nums = Hash(Int32, LLVM::Value).new
      # String-key provenance: register -> address of the CANONICAL
      # (interned) instance of the constant string the register holds
      # (LOADK/LOADK+MOVE chains). Enables the inlined identity probe for
      # GETTABLE/SETTABLE. Same lifetime rules as @nums.
      @skeys = Hash(Int32, UInt64).new
      # Table provenance: register -> table payload pointer whose tag and
      # nil metatable were already checked in this block. Field accesses
      # (GETTABLE/SETTABLE/SELF) on the same register skip both guards.
      # Same lifetime rules as @nums.
      @tabs = Hash(Int32, LLVM::Value).new
      # Type feedback per-pc mask (JIT.md §2): nil/0 = numbers only seen
      # → mono-numeric code with deopt guards; set bits → polymorphic
      # code with the helper fallback (coercion/metamethods/str compares)
      @fb : Array(UInt8)?
      # Cross-block numeric SSA (M3.7): real-CFG predecessors per pc (no
      # OSR switch edges), per-pc numeric-fact sets from the dataflow, and
      # the f64 phis created at blocks with >1 LLVM predecessor
      @real_preds = [] of Array(Int32)
      @in_nums = [] of Set(Int32)
      @merge_phi = Hash(Int32, Hash(Int32, LLVM::Value)).new

      # invalidate provenance of register r (all maps)
      private def kill(r : Int32) : Nil
        @nums.delete(r)
        @skeys.delete(r)
        @tabs.delete(r)
      end

      private def kill_all : Nil
        @nums.clear
        @skeys.clear
        @tabs.clear
      end

      def initialize(@cl, @ctx : LLVM::Context, f : LLVM::Function,
                     @helpers : Hash(Symbol, LLVM::Function),
                     @helper_types : Hash(Symbol, LLVM::Type), @blocks,
                     entry : LLVM::BasicBlock, stack0 : LLVM::Value,
                     osr_heads : Set(Int32), @preds : Array(Int32),
                     @forloops : Hash(Int32, {Int32, Int32}),
                     @fb : Array(UInt8)?)
        @b = @ctx.new_builder
        @i8 = @ctx.int8
        @i32 = @ctx.int32
        @i64 = @ctx.int64
        @f64 = @ctx.double
        @lv = @ctx.struct([@i32, @i64])
        @lv_ptr = @lv.pointer
        @ptr = @ctx.void_pointer
        # entry signature (see gen) — the direct-call fast path needs the
        # function type explicitly with opaque pointers
        @entry_ty = LLVM::Type.function([@ptr, @lv_ptr, @ptr, @i32, @i32, @i32, @i32, @i32], @i32)
        @nil_const = @ctx.const_struct([@i32.const_int(0), @i64.const_int(0)])
        @interp = f.params[0]
        @clp = f.params[2]
        @base = f.params[3]
        want = f.params[5]
        @want = want
        @code = @cl.proto.packed
        @consts = @cl.proto.consts
        # Loop-carried SSA (phi) values for numeric-for controls, by block:
        # FORLOOP pc -> {ctrl, limit, step} phis; head pc -> same. The
        # head phis carry values into the body, the FORLOOP phis merge the
        # FORPREP entry values with the back-edge values (see
        # emit_forprep/emit_forloop/br_next).
        @phi_fl = Hash(Int32, {LLVM::Value, LLVM::Value, LLVM::Value}).new
        @phi_head = Hash(Int32, {LLVM::Value, LLVM::Value, LLVM::Value}).new
        # head pc -> {FORLOOP pc, A} (reverse of @forloops)
        @for_by_head = Hash(Int32, {Int32, Int32}).new
        @forloops.each do |flpc, ha|
          @for_by_head[ha[0]] = {flpc, ha[1]}
        end
        # OSR for-head load blocks (see the switch below)
        @osr_ldr = Hash(Int32, {LLVM::BasicBlock, LLVM::Value, LLVM::Value, LLVM::Value}).new
        # Cross-block numeric SSA (M3.7): static dataflow facts per pc and
        # the merge phis built from them (see analyze_num_flow). phis are
        # created for every block with >1 LLVM predecessor — including OSR
        # heads, whose entry edges route through guard blocks below.
        @real_preds, @in_nums = analyze_num_flow
        if Compiler::PHIMERGE
          @in_nums.each_with_index do |st, pc|
            # A block whose single real predecessor is a NON-ADJACENT jump
            # (JMPF arm, forward JMP) needs phis just like a merge: the
            # emitter is linear, so by the time it emits this pc its maps
            # describe the fallthrough chain's state, not the jump edge's
            # (LLVM dominance is fine — one predecessor — the maps are the
            # problem). A single-incoming phi carries the edge state over.
            single_jump = (rp = @real_preds[pc]?) && rp.size == 1 && rp[0] != pc - 1
            next if (@preds[pc]? || 0) <= 1 && !single_jump
            next if st.empty?
            # for-controls at head/FORLOOP blocks already live in the
            # M3.3 phis — never double-source a register
            ca = @for_by_head[pc]?.try(&.[1]) || @forloops[pc]?.try(&.[1])
            b.position_at_end(@blocks[pc])
            m = Hash(Int32, LLVM::Value).new
            st.each do |r|
              next if ca && r >= ca && r <= ca + 2
              m[r] = LLVM::Value.new LibLLVM.build_phi(@b, @f64, "mp#{pc}r#{r}")
            end
            @merge_phi[pc] = m unless m.empty?
          end
        end
        # Create ALL for-loop phis up front (FORPREP is emitted before its
        # FORLOOP block, so phis must exist before any block is filled).
        # Blocks are still empty — the phis land first, as LLVM requires.
        @forloops.each do |flpc, ha|
          head, a = ha
          b.position_at_end(@blocks[head])
          @phi_head[head] = new_phi3("lh#{head}r#{a}")
          b.position_at_end(@blocks[flpc])
          @phi_fl[flpc] = new_phi3("lf#{flpc}r#{a}")
        end

        b.position_at_end(entry)
        @scratch = b.alloca(@lv, "scratch")
        @status_p = b.alloca(@i32, "status")
        @ret_i = b.alloca(@i32, "ret_i")
        @cur_stack = b.alloca(@lv_ptr, "cur_stack")
        @cur_top = b.alloca(@i32, "cur_top")
        b.store(stack0, @cur_stack)
        # frame top: normal entries compute it from argn; OSR entries carry
        # the live frame's top (multi-value feeds may sit above max_stack)
        b.store(b.select(b.icmp(LLVM::IntPredicate::SGT, f.params[6], @i32.const_int(0)),
          f.params[7], b.add(@base, b.add(f.params[4], @i32.const_int(1)))), @cur_top)
        if osr_heads.empty?
          b.br(@blocks[0])
        else
          # OSR targets route through a load block: for-heads load the
          # controls raw (the interpreter's FORLOOP guarantees the tags);
          # general merge phis (M3.7) load each register behind a tag
          # guard — the analysis facts hold for the interpreter's state
          # too, so the guard is insurance, deopt on a bug only.
          cases = osr_heads.map do |hpc|
            fa = @for_by_head[hpc]?
            mp = @merge_phi[hpc]?
            next {@i32.const_int(hpc), @blocks[hpc]} if !fa && (mp.nil? || mp.empty?)
            ldb = new_block("osrf#{hpc}")
            b.position_at_end(ldb)
            if (a = fa.try(&.[1]))
              cv = load_num_raw(a)
              lv = load_num_raw(a + 1)
              sv = load_num_raw(a + 2)
              @osr_ldr[hpc] = {ldb, cv, lv, sv}
            end
            unless mp.nil? || mp.empty?
              # guard chain: every phi's tag check funnels into ONE block
              # that branches to the head — phi incomings must all cite
              # that block (citing each guard's own ok-block leaves them
              # non-predecessors: "PHI node entries do not match
              # predecessors" on verify)
              bad = new_block("osrbad#{hpc}")
              pend = [] of {LLVM::Value, LLVM::Value}
              mp.each do |r, phi|
                v = load_slot(r)
                okb = new_block("osrok#{hpc}r#{r}")
                b.cond(tag_is(v, Layout.tag_num), okb, bad)
                b.position_at_end(okb)
                pend << {phi, f64_of(v)}
              end
              done = new_block("osrdone#{hpc}")
              b.br(done)
              b.position_at_end(done)
              pend.each { |phi, v| phi_add(phi, v, done) }
              if (a2 = fa.try(&.[1])) && (hp = @phi_head[hpc]?)
                phi_add(hp[0], cv.not_nil!, done)
                phi_add(hp[1], lv.not_nil!, done)
                phi_add(hp[2], sv.not_nil!, done)
              end
              b.br(@blocks[hpc])
              b.position_at_end(bad)
              st = b.call(@helper_types[:deopt], @helpers[:deopt],
                [@interp, @clp, @base, @i32.const_int(hpc), @want], "st")
              b.ret(st)
            else
              # no general phis: controls (if any) feed the head phis from
              # the load block, which branches to the head directly
              if (a2 = fa.try(&.[1])) && (hp = @phi_head[hpc]?)
                phi_add(hp[0], cv.not_nil!, ldb)
                phi_add(hp[1], lv.not_nil!, ldb)
                phi_add(hp[2], sv.not_nil!, ldb)
              end
              b.br(@blocks[hpc])
            end
            {@i32.const_int(hpc), ldb}
          end
          b.position_at_end(entry)
          b.switch(f.params[6], @blocks[0], cases)
        end
      end

      def run : Nil
        n = @code.size
        pc = 0
        while pc < n
          @b.position_at_end(@blocks[pc])
          if (@preds[pc]? || 0) > 1 ||
             ((rp = @real_preds[pc]?) && rp.size == 1 && rp[0]? != pc - 1 && (@preds[pc]? || 0) > 0)
            # control merges — and single-predecessor blocks entered by a
            # non-adjacent jump (see initialize) — take their provenance
            # from the merge phis (M3.7); registers without a phi are
            # reloaded/re-guarded
            kill_all
            @merge_phi[pc]?.try &.each { |r, phi| @nums[r] = phi }
          elsif pc > 0 && (@real_preds[pc]? || [-2]) != [pc - 1]
            # single predecessor reached by a JUMP: the emitter's maps are
            # leftovers from the previous instruction's emission, which
            # describe the state on ITS outgoing edge, not this block's
            # incoming one — drop them (fallthrough keeps linear flow)
            kill_all
          end
          if (fa = @for_by_head[pc]?) && (a = fa[1])
            # loop head: the phis (created up front in initialize) are the
            # live ctrl/limit/step values for the body; OSR entry loads
            # were wired when the switch was built
            hp = @phi_head[pc].not_nil!
            @nums[a], @nums[a + 1], @nums[a + 2] = hp
          end
          if ENV["LUA5_JIT"]? == "trace" && (dbg = ENV["LUA5_JIT_DBGPC"]?)
            dlo, dhi = dbg.split('-').map(&.to_i)
            if pc >= dlo && pc <= dhi
              puts "emit pc#{pc} preds=#{@preds[pc]?} rp=#{@real_preds[pc]?.try(&.inspect)} mp=#{@merge_phi[pc]?.try(&.keys)} nums=#{@nums.keys.sort} tabs=#{@tabs.keys.sort}"
            end
          end
          emit(pc)
          pc += 1
        end
      end

      private def emit(pc : Int32) : Nil
        b = @b
        w = @code[pc]
        op = (w & 0xFF).to_u8!.unsafe_as(Op)
        a = ((w >> 8).to_i64! << 48 >> 48).to_i32!
        bb = ((w >> 24).to_i64! << 44 >> 44).to_i32!
        cc = ((w >> 44).to_i64! << 44 >> 44).to_i32!

        case op
        when .loadk?     then emit_loadk(pc, a, bb)
        when .loadnil?
          r = a
          while r <= a + bb
            store_scalar(slot(r), @i32.const_int(0), @i64.const_int(0))
            kill(r)
            r += 1
          end
          br_next(pc)
        when .loadbool?
          store_scalar(slot(a), @i32.const_int(Layout.tag_bool), @i64.const_int(bb != 0 ? 1 : 0))
          kill(a)
          br_next(pc)
        when .move?
          # numeric provenance travels with the value
          if v = @nums[bb]?
            @nums[a] = v
          else
            kill(a)
          end
          if sk = @skeys[bb]?
            @skeys[a] = sk
          else
            @skeys.delete(a)
          end
          if tb = @tabs[bb]?
            @tabs[a] = tb
          else
            @tabs.delete(a)
          end
          b.store(load_slot(bb), slot(a))
          br_next(pc)
        when .add?, .sub?, .mul?, .div?, .mod?, .pow?
          emit_arith(pc, a, bb, cc, op)
        when .unm?
          emit_unm(pc, a, bb)
        when .not?
          t = truthy(bb)
          store_bool(slot(a), b.not(t))
          kill(a)
          br_next(pc)
        when .eq?, .neq?, .lt?, .le?
          emit_cmp(pc, a, bb, cc, op)
        when .jmp?
          backedge(pc, bb)
          wire_forloop_edge(dest(pc, bb))
          wire_gen_edge(dest(pc, bb))
          b.br(@blocks[dest(pc, bb)])
        when .jmpf?
          backedge(pc, bb)
          wire_forloop_edge(pc + 1)
          wire_forloop_edge(dest(pc, bb))
          wire_gen_edge(pc + 1)
          wire_gen_edge(dest(pc, bb))
          b.cond(truthy(a), @blocks[pc + 1], @blocks[dest(pc, bb)])
        when .jmpt?
          backedge(pc, bb)
          wire_forloop_edge(pc + 1)
          wire_forloop_edge(dest(pc, bb))
          wire_gen_edge(pc + 1)
          wire_gen_edge(dest(pc, bb))
          b.cond(truthy(a), @blocks[dest(pc, bb)], @blocks[pc + 1])
        when .getupval?
          emit_getupval(pc, a, bb, @clp)
          br_next(pc)
        when .getglobal?
          call_fp(:getglobal, [@interp, @clp, @i32.const_int(bb), @i32.const_int(pc), slot(a)])
          br_next(pc)
        when .setglobal?
          call_fp(:setglobal, [@interp, @clp, @i32.const_int(bb), @i32.const_int(pc), slot(a)])
          br_next(pc)
        when .setupval?
          call_fp(:setupval, [@clp, @i32.const_int(bb), slot(a)])
          br_next(pc)
        when .gettable?
          if kaddr = @skeys[cc]?
            emit_str_gettable(pc, a, bb, cc, kaddr)
          else
            emit_gettable(pc, a, bb, cc)
          end
        when .settable?
          if kaddr = @skeys[bb]?
            emit_str_settable(pc, a, bb, cc, kaddr)
          else
            emit_settable(pc, a, bb, cc)
          end
        when .self?
          emit_str_self(pc, a, bb, cc)
        when .newtable?
          call_fp(:newtable, [slot(a)])
          br_next(pc)
        when .setlist?
          call_fp(:setlist, [@interp, @base, @i32.const_int(a), @i32.const_int(bb),
            @i32.const_int(cc), b.load(@i32, @cur_top)])
          br_next(pc)
        when .len?
          call_fp(:len, [@interp, @clp, @base, @i32.const_int(pc), @i32.const_int(bb), slot(a)])
          br_next(pc)
        when .concat?
          call_fp(:concat, [@interp, @clp, @base, @i32.const_int(pc), @i32.const_int(a), @i32.const_int(bb)])
          br_next(pc)
        when .closure?
          call_fp(:closure, [@interp, @clp, @base, @i32.const_int(bb), slot(a)])
          br_next(pc)
        when .close?
          call_fp(:close, [@interp, @base, @i32.const_int(a)])
          br_next(pc)
        when .forprep?
          emit_forprep(pc, a, bb)
        when .forloop?
          emit_forloop(pc, a, bb)
        when .tailcall?, .vararg?
          # deopt wholesale: the interpreter runs the rest of the function
          # (TAILCALL slides the frame; VARARG re-runs with frame.varargs)
          st = call_fp(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
          b.ret(st)
        when .tforcall?
          emit_tforcall(pc, a, bb, cc)
        when .call?     then emit_call(pc, a, bb, cc)
        when .return?
          # Contract: results must end at stack[base..] (the closure slot).
          # The interpreter does this shift in frame_return; the JIT copies
          # here — unrolled for a fixed count, a loop for `return ...`
          # multi-feeds (b == -1: everything up to the frame top).
          # Close this frame's open upvalues first: a compiled closure
          # factory's captures must freeze before the slots are reused.
          call_fp(:retclose, [@interp, @base])
          if bb == 0
            b.ret(@i32.const_int(0))
          elsif bb > 0
            j = 0
            while j < bb
              b.store(load_slot(a + j), slot(j))
              j += 1
            end
            b.ret(@i32.const_int(bb))
          else
            cnt = b.sub(b.load(@i32, @cur_top), b.add(@base, @i32.const_int(a)))
            b.store(@i32.const_int(0), @ret_i)
            loop_b = new_block("retloop#{pc}")
            body_b = new_block("retbody#{pc}")
            done_b = new_block("retdone#{pc}")
            b.br(loop_b)
            b.position_at_end(loop_b)
            iv = b.load(@i32, @ret_i)
            b.cond(b.icmp(LLVM::IntPredicate::SLT, iv, cnt), body_b, done_b)
            b.position_at_end(body_b)
            stk = b.load(@lv_ptr, @cur_stack)
            src = b.gep(@lv, stk, b.add(b.add(@base, @i32.const_int(a)), iv))
            dst = b.gep(@lv, stk, b.add(@base, iv))
            b.store(b.load(@lv, src), dst)
            b.store(b.add(iv, @i32.const_int(1)), @ret_i)
            b.br(loop_b)
            b.position_at_end(done_b)
            b.ret(cnt)
          end
        else
          raise CompileBail.new("unsupported op #{op} at pc #{pc}")
        end
      end

      # TFORCALL A B C: generic-for step — call the iterator R[A] with
      # (state R[A+1], control R[A+2]), place C results at R[A+3..]; a
      # non-nil FIRST result updates the control R[A+2] and jumps B to the
      # loop test, nil falls through (loop done). Emitted as a dispatch
      # CALL on a staging window at A+3 (the interpreter's fast-path
      # shape), so for-in hot loops stay in machine code — TFORCALL used
      # to deopt wholesale, leaving every generic-for loop interpreted
      # (array3d: 27M iterator calls through call_value per run).
      private def emit_tforcall(pc : Int32, a : Int32, off : Int32, cnt : Int32) : Nil
        b = @b
        # stage func/state/control at a+3 (the results window — func and
        # args sit exactly where the callee frame expects them)
        3.times { |i| b.store(load_slot(a + i), slot(a + 3 + i)) }
        if Compiler::FAST_CALL
          # direct JIT->JIT for a compiled iterator (the guard chain),
          # dispatch helper otherwise — 27M-iteration for-in loops pay the
          # helper hop otherwise
          emit_call_fast_to(pc, a + 3, 2, cnt) do
            emit_tforcall_next(pc, a, off)
          end
        else
          newstk = call_fp(:dispatch, [@interp, @clp, @base, @i32.const_int(pc),
            @i32.const_int(a + 3), @i32.const_int(2), @i32.const_int(cnt), @status_p])
          b.store(newstk, @cur_stack)
          st = b.load(@i32, @status_p)
          bad = new_block("tfcbad#{pc}")
          cont = new_block("tfccont#{pc}")
          b.cond(b.icmp(LLVM::IntPredicate::SLT, st, @i32.const_int(0)), bad, cont)
          b.position_at_end(bad)
          b.ret(st)
          b.position_at_end(cont)
          kill_all
          # dispatch nil-fills missing results to `want`; top sits past them
          b.store(b.add(@base, @i32.const_int(a + 3 + {cnt, 0}.max)), @cur_top)
          emit_tforcall_next(pc, a, off)
        end
      end

      # TFORCALL continuation: a non-nil first result updates the control
      # R[A+2] and jumps to the loop test; nil falls through (loop done)
      private def emit_tforcall_next(pc : Int32, a : Int32, off : Int32) : Nil
        b = @b
        first = load_slot(a + 3)
        go = new_block("tfcgo#{pc}")
        done = new_block("tfcdone#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::NE, b.extract_value(first, 0),
          @i32.const_int(0)), go, done)
        b.position_at_end(go)
        b.store(first, slot(a + 2))
        wire_forloop_edge(dest(pc, off))
        wire_gen_edge(dest(pc, off))
        b.br(@blocks[dest(pc, off)])
        b.position_at_end(done)
        br_next(pc)
      end

      private def emit_loadk(pc : Int32, a : Int32, kb : Int32) : Nil
        k = @consts[kb]?
        case k
        when Float64
          kill(a) # stale string-key/table provenance must not survive
          store_num(slot(a), @f64.const_double(k))
          @nums[a] = @f64.const_double(k)
        when Bool
          store_scalar(slot(a), @i32.const_int(Layout.tag_bool), @i64.const_int(k ? 1 : 0))
          kill(a)
        when String
          # proto.consts keeps the string alive (closure -> proto -> consts);
          # Boehm is non-moving, so the object pointer is stable. NOTE: the
          # union payload holds the String OBJECT address, not char*. Short
          # strings also register their canonical (interned) instance for
          # the inlined string-key probe.
          store_scalar(slot(a), @i32.const_int(Layout.tag_str), @i64.const_int(k.as(Void*).address.to_i64!))
          kill(a)
          if k.bytesize <= Lua::SHORT_STR_MAX
            @skeys[a] = Lua.intern(k).as(Void*).address
          end
        else
          store_scalar(slot(a), @i32.const_int(0), @i64.const_int(0))
          kill(a)
        end
        br_next(pc)
      end

      # feedback mask byte at pc (0 = numbers only ever seen / no table)
      private def fb_bits(pc : Int32) : UInt8
        f = @fb
        f ? (f[pc]? || 0_u8) : 0_u8
      end

      # Speculative table ops (M3.6): a clean FB_TMISS bit at this pc means
      # the fast-path shape always held so far — emit guards that DEOPT on
      # any miss instead of falling back to the helper. The deopt edge
      # terminates (no merge block), so the fast path keeps its provenance
      # maps: repeated accesses to the same table in a block skip the
      # tag/metatable guards, and numeric locals stop being reloaded. A
      # miss deopt records FB_TMISS (jit_deopt) and on_deopt recompiles
      # with the polymorphic helper-fallback variant (the code below the
      # `spec` branches).
      private def spec_clean?(pc : Int32) : Bool
        (fb_bits(pc) & Lua::FB_TMISS) == 0
      end

      # A terminated block that deopts at `pc` (guard-failure target of the
      # speculative table ops). Emits the call directly — call_fp would
      # kill the provenance maps the fast path still needs.
      private def deopt_at(pc : Int32, tag : String) : LLVM::BasicBlock
        blk = new_block("#{tag}#{pc}dopt")
        prev = current_block
        @b.position_at_end(blk)
        st = @b.call(@helper_types[:deopt], @helpers[:deopt],
          [@interp, @clp, @base, @i32.const_int(pc), @want], "st")
        @b.ret(st)
        @b.position_at_end(prev)
        blk
      end

      # Arithmetic (type feedback, JIT.md §2): a clean feedback byte at
      # this pc means only numbers were ever seen — mono-numeric code
      # with deopt guards (a wrong guess deopts, the interpreter samples
      # the new shape and on_deopt recompiles). With bits set the code is
      # polymorphic: number operands inline, everything else through the
      # jit_arith helper (coercion/metamethods — the interpreter's exact
      # semantics, no deopt churn).
      private def emit_arith(pc : Int32, a : Int32, br : Int32, cr : Int32,
                             op : Op) : Nil
        b = @b
        if fb_bits(pc) == 0
          l = guard_num(pc, br)
          r = guard_num(pc, cr)
          res = arith_fop(op, l, r)
          store_num(slot(a), res)
          kill(a) # stale string-key/table provenance must not survive
          @nums[a] = res
          br_next(pc)
          return
        end
        slow = new_block("arslow#{pc}")
        lv = if v = @nums[br]?
               v
             else
               vb = load_slot(br)
               okb = new_block("arnl#{pc}")
               b.cond(tag_is(vb, Layout.tag_num), okb, slow)
               b.position_at_end(okb)
               f64_of(vb)
             end
        rv = if v = @nums[cr]?
               v
             else
               vc = load_slot(cr)
               okc = new_block("arnr#{pc}")
               b.cond(tag_is(vc, Layout.tag_num), okc, slow)
               b.position_at_end(okc)
               f64_of(vc)
             end
        res = arith_fop(op, lv, rv)
        store_num(slot(a), res)
        kill(a) # stale string-key/table provenance must not survive
        @nums[a] = res
        br_next(pc)
        b.position_at_end(slow)
        call_fp(:arith, [@interp, @clp, @base, @i32.const_int(pc),
          @i32.const_int(arith_id(op)), @i32.const_int(br), @i32.const_int(cr),
          slot(a)])
        br_next(pc)
      end

      # Unary minus — same feedback split as emit_arith.
      private def emit_unm(pc : Int32, a : Int32, br : Int32) : Nil
        b = @b
        if fb_bits(pc) == 0
          v = guard_num(pc, br)
          res = b.fneg(v)
          store_num(slot(a), res)
          kill(a) # stale string-key/table provenance must not survive
          @nums[a] = res
          br_next(pc)
          return
        end
        if v = @nums[br]?
          res = b.fneg(v)
          store_num(slot(a), res)
          kill(a)
          @nums[a] = res
          br_next(pc)
          return
        end
        slow = new_block("unmslow#{pc}")
        vb = load_slot(br)
        fast = new_block("unm#{pc}")
        b.cond(tag_is(vb, Layout.tag_num), fast, slow)
        b.position_at_end(fast)
        res = b.fneg(f64_of(vb))
        store_num(slot(a), res)
        kill(a)
        @nums[a] = res
        @skeys.delete(a)
        br_next(pc)
        b.position_at_end(slow)
        call_fp(:unmf, [@interp, @clp, @base, @i32.const_int(pc),
          @i32.const_int(br), slot(a)])
        br_next(pc)
      end

      # Comparisons — same feedback split. Polymorphic: num/num inline
      # fcmp; str/str (FB_STR) inline bytewise strcmp; anything else
      # through the jit_cmp helper (metamethods, errors — no deopt).
      private def emit_cmp(pc : Int32, a : Int32, br : Int32, cr : Int32,
                           op : Op) : Nil
        b = @b
        fb = fb_bits(pc)
        if fb == 0
          l = guard_num(pc, br)
          r = guard_num(pc, cr)
          t = case op
              when .eq?  then b.fcmp(LLVM::RealPredicate::OEQ, l, r)
              when .neq? then b.fcmp(LLVM::RealPredicate::UNE, l, r) # Lua ~= is !(==): NaN ~= NaN is true; ONE would give false
              when .lt?  then b.fcmp(LLVM::RealPredicate::OLT, l, r)
              else            b.fcmp(LLVM::RealPredicate::OLE, l, r)
              end
          store_bool(slot(a), t)
          kill(a)
          br_next(pc)
          return
        end
        slow = new_block("cmpslow#{pc}")
        vb = load_slot(br)
        numl = new_block("cmpnl#{pc}")
        strl = (fb & Lua::FB_STR) != 0 ? new_block("cmpsl#{pc}") : nil
        b.cond(tag_is(vb, Layout.tag_num), numl, strl || slow)
        b.position_at_end(numl)
        vc = load_slot(cr)
        fast = new_block("cmpn#{pc}")
        b.cond(tag_is(vc, Layout.tag_num), fast, slow)
        b.position_at_end(fast)
        t = case op
            when .eq?  then b.fcmp(LLVM::RealPredicate::OEQ, f64_of(vb), f64_of(vc))
            when .neq? then b.fcmp(LLVM::RealPredicate::UNE, f64_of(vb), f64_of(vc))
            when .lt?  then b.fcmp(LLVM::RealPredicate::OLT, f64_of(vb), f64_of(vc))
            else            b.fcmp(LLVM::RealPredicate::OLE, f64_of(vb), f64_of(vc))
            end
        store_bool(slot(a), t)
        kill(a)
        br_next(pc)
        if strl
          b.position_at_end(strl)
          strl2 = new_block("cmpsl2#{pc}")
          b.cond(tag_is(vb, Layout.tag_str), strl2, slow)
          b.position_at_end(strl2)
          vc2 = load_slot(cr)
          strs = new_block("cmps#{pc}")
          b.cond(tag_is(vc2, Layout.tag_str), strs, slow)
          b.position_at_end(strs)
          # pure C call — no runtime re-entry, provenance survives
          k = call_fp_pure(:strcmp, [payload_ptr(vb), payload_ptr(vc2)])
          t2 = case op
               when .eq?  then b.icmp(LLVM::IntPredicate::EQ, k, @i32.const_int(0))
               when .neq? then b.icmp(LLVM::IntPredicate::NE, k, @i32.const_int(0))
               when .lt?  then b.icmp(LLVM::IntPredicate::SLT, k, @i32.const_int(0))
               else            b.icmp(LLVM::IntPredicate::SLE, k, @i32.const_int(0))
               end
          store_bool(slot(a), t2)
          kill(a)
          br_next(pc)
        end
        b.position_at_end(slow)
        opid = case op
               when .eq?  then 0
               when .lt?  then 1
               when .le?  then 2
               else            3 # neq
               end
        call_fp(:cmp, [@interp, @clp, @base, @i32.const_int(pc),
          @i32.const_int(opid), @i32.const_int(br), @i32.const_int(cr), slot(a)])
        br_next(pc)
      end

      private def arith_fop(op : Op, l : LLVM::Value, r : LLVM::Value) : LLVM::Value
        case op
        when .add? then @b.fadd(l, r)
        when .sub? then @b.fsub(l, r)
        when .mul? then @b.fmul(l, r)
        when .div? then @b.fdiv(l, r)
        when .mod? then call_fp_pure(:mod_fn, [l, r])
        else            call_fp_pure(:pow, [l, r])
        end
      end

      # jit_arith helper opid (see runtime.cr)
      private def arith_id(op : Op) : Int32
        case op
        when .add? then 0
        when .sub? then 1
        when .mul? then 2
        when .div? then 3
        when .mod? then 4
        else            5
        end
      end

      # LuaValue tag compare / payload extraction
      private def tag_is(v : LLVM::Value, tag : Int32) : LLVM::Value
        @b.icmp(LLVM::IntPredicate::EQ, @b.extract_value(v, 0), @i32.const_int(tag))
      end

      private def f64_of(v : LLVM::Value) : LLVM::Value
        @b.bit_cast(@b.extract_value(v, 1), @f64)
      end

      # FORPREP: all three controls must be numbers (guards deopt — the
      # interpreter re-runs FORPREP and raises the proper 'for' errors or
      # coerces numeric strings); step==0 also deopts (interp raises).
      # Then normalize: R[A] -= step and jump to the loop test.
      private def emit_forprep(pc : Int32, a : Int32, off : Int32) : Nil
        b = @b
        v0 = guard_num(pc, a)
        v1 = guard_num(pc, a + 1)
        v2 = guard_num(pc, a + 2)
        zero = b.fcmp(LLVM::RealPredicate::OEQ, v2, @f64.const_double(0.0))
        cont = new_block("fornz#{pc}")
        bad = new_block("forz#{pc}")
        b.cond(zero, bad, cont)
        b.position_at_end(bad)
        st = call_fp_exit(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
        b.ret(st)
        b.position_at_end(cont)
        s0 = b.fsub(v0, v2)
        # loop controls become plain numbers — stale string-key/table
        # provenance on these registers must not survive
        3.times { |i| @skeys.delete(a + i); @tabs.delete(a + i) }
        store_num(slot(a), s0)
        @nums[a] = s0
        store_num(slot(a + 1), v1)
        @nums[a + 1] = v1
        store_num(slot(a + 2), v2)
        @nums[a + 2] = v2
        # feed the FORLOOP-merge phis on the loop-entry edge
        if (flpc = dest(pc, off); phis = @phi_fl[flpc]?)
          phi_add(phis[0], s0, cont)
          phi_add(phis[1], v1, cont)
          phi_add(phis[2], v2, cont)
        end
        wire_gen_edge(dest(pc, off))
        b.br(@blocks[dest(pc, off)])
      end

      # FORLOOP: R[A..A+2] are numbers by FORPREP's invariant (the
      # interpreter also reads them unchecked). Back-edge freezes loop
      # upvalues via the helper; the gate is inlined: open upvalues below
      # the frame's window or any weak table ever seen (monotonic flag)
      # route to the helper, the common case skips the call entirely.
      private def emit_forloop(pc : Int32, a : Int32, off : Int32) : Nil
        b = @b
        # loop-carried SSA: the FORLOOP-block phis merge the FORPREP entry
        # values with the head phis arriving through the body end (both
        # edges are wired elsewhere) — the per-iteration slot reloads of
        # ctrl/limit/step disappear; slots still receive every store
        # (deopt-anywhere invariant untouched)
        ctrl0, lim, ste = if (phis = @phi_fl[pc]?)
                            phis
                          else
                            {load_num_raw(a), load_num_raw(a + 1), load_num_raw(a + 2)}
                          end
        ctrl = b.fadd(ctrl0, ste)
        pos = b.fcmp(LLVM::RealPredicate::OGT, ste, @f64.const_double(0.0))
        t_pos = b.fcmp(LLVM::RealPredicate::OLE, ctrl, lim)
        t_neg = b.fcmp(LLVM::RealPredicate::OGE, ctrl, lim)
        cond_v = b.select(pos, t_pos, t_neg)
        body = new_block("forbody#{pc}")
        exit_b = new_block("forexit#{pc}")
        b.cond(cond_v, body, exit_b)
        b.position_at_end(body)
        # INLINE_EDGE=0 restores the M2.1 behavior: always take the helper
        # path (upvalue freezing + weak check live in jit_loopedge).
        # Upvalue-free protos drop the open_max load: nothing can capture
        # this frame's slots, the back-edge close_upvals is dead.
        need = if Compiler::INLINE_EDGE
                w = weak_seen(b)
                Compiler.no_upvs? ? w : b.or(w, b.icmp(LLVM::IntPredicate::SGE,
                  b.load(@i32, tbl_fld(@interp, Layout.i_open_max)),
                  b.add(@base, @i32.const_int(a))))
              else
                @ctx.int1.const_int(1)
              end
        slow = new_block("forslow#{pc}")
        go = new_block("forgo#{pc}")
        b.cond(need, slow, go)
        b.position_at_end(slow)
        st = call_fp_exit(:loopedge, [@interp, @clp, @base, @i32.const_int(a)])
        weak = new_block("forweak#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::NE, st, @i32.const_int(0)), weak, go)
        b.position_at_end(weak)
        # 1 = deopt (captured slots a __gc finalizer may write), -1 =
        # pending error from the tick — split before any slot store
        werr = new_block("forwerr#{pc}")
        wdpt = new_block("forwdpt#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::SLT, st, @i32.const_int(0)), werr, wdpt)
        b.position_at_end(werr)
        b.ret(st)
        b.position_at_end(wdpt)
        d = call_fp_exit(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
        b.ret(d)
        b.position_at_end(go)
        store_num(slot(a), ctrl)
        @skeys.delete(a)
        @tabs.delete(a)
        @nums[a] = ctrl
        # back-edge: the head phis take the incremented control (limit and
        # step are loop-invariant — their FORLOOP phis flow straight back)
        if (head = dest(pc, off); hphis = @phi_head[head]?)
          phi_add(hphis[0], ctrl, go)
          phi_add(hphis[1], lim, go)
          phi_add(hphis[2], ste, go)
        end
        wire_gen_edge(dest(pc, off))
        b.br(@blocks[dest(pc, off)])
        b.position_at_end(exit_b)
        # the exit edge leaves R[A] at its LAST EXECUTED value — the go
        # block's store + @nums update (incremented ctrl) only run on the
        # continue edge, so drop the register's provenance here
        @nums.delete(a)
        br_next(pc)
      end

      # unchecked number load (FORPREP guarantees the tag)
      def load_num_raw(r : Int32) : LLVM::Value
        v = load_slot(r)
        b.bit_cast(b.extract_value(v, 1), @f64)
      end

      private def emit_call(pc : Int32, a : Int32, bcount : Int32, want_v : Int32) : Nil        b = @b
        if bcount >= 0 && want_v >= 0 && Compiler::INLINE_CALL &&
           (ctp = inline_target(pc, bcount))
          emit_call_inline(pc, a, bcount, want_v, ctp)
          return
        end
        if bcount == 1 && want_v == 1 && Compiler::FAST1_CALL &&
           (f1 = fast1_target(pc))
          emit_call_fast1(pc, a, f1)
          return
        end
        if bcount >= 0 && Compiler::FAST_CALL
          emit_call_fast(pc, a, bcount, want_v)
          return
        end
        argn = bcount == -1 ? b.sub(b.load(@i32, @cur_top), b.add(@base, @i32.const_int(a + 1))) : @i32.const_int(bcount)
        newstk = call_fp(:dispatch,
          [@interp, @clp, @base, @i32.const_int(pc), @i32.const_int(a), argn, @i32.const_int(want_v), @status_p])
        b.store(newstk, @cur_stack) # @stack may have been reallocated
        st = b.load(@i32, @status_p)
        bad = new_block("callbad#{pc}")
        cont = new_block("callcont#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::SLT, st, @i32.const_int(0)), bad, cont)
        b.position_at_end(bad)
        b.ret(st)
        b.position_at_end(cont)
        if want_v == -1
          b.store(b.add(b.add(@base, @i32.const_int(a)), st), @cur_top)
        else
          b.store(b.add(@base, @i32.const_int(a + {want_v, 0}.max)), @cur_top)
        end
        br_next(pc)
      end

      # Direct JIT->JIT call: every condition jit_call_dispatch checks
      # (closure with machine code, arity match, no coroutine/hooks, depth
      # budget, stack window) becomes cheap inline loads; the helper stays
      # as the slow path for everything else. Results follow the same
      # contract: count in the return value, slots at stack[base+a..],
      # missing fixed results nil-filled here. The block yields with the
      # builder positioned at the shared continuation — callers emit their
      # own next-edge (CALL falls through; TFORCALL branches on the first
      # result).
      private def emit_call_fast(pc : Int32, a : Int32, argn : Int32, want_v : Int32) : Nil
        emit_call_fast_to(pc, a, argn, want_v) { br_next(pc) }
      end

      private def emit_call_fast_to(pc : Int32, a : Int32, argn : Int32, want_v : Int32, & : -> Nil) : Nil
        b = @b
        slow = new_block("cslow#{pc}")
        vf = load_slot(a)
        fast = new_block("cfast#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vf, 0),
          @i32.const_int(Layout.tag_closure)), fast, slow)
        b.position_at_end(fast)
        clp2 = payload_ptr(vf)
        # @compiled is a nilable-pointer union: tag check first, then the
        # payload next to it is the machine-code entry
        ctag = b.load(@i32, tbl_fld(clp2, Layout.cl_compiled - 8))
        ok = b.icmp(LLVM::IntPredicate::EQ, ctag, @i32.const_int(Layout.cl_compiled_tag))
        cp = b.load(@ptr, tbl_fld(clp2, Layout.cl_compiled))
        ok = b.and(ok, b.icmp(LLVM::IntPredicate::NE, cp, null_ptr))
        proto = b.load(@ptr, tbl_fld(clp2, Layout.cl_proto))
        np = b.load(@i32, tbl_fld(proto, Layout.pr_params))
        ok = b.and(ok, b.icmp(LLVM::IntPredicate::EQ, np, @i32.const_int(argn)))
        va = b.load(@i8, tbl_fld(proto, Layout.pr_vararg))
        ok = b.and(ok, b.icmp(LLVM::IntPredicate::EQ, va, @i8.const_int(0)))
        co = b.load(@ptr, tbl_fld(@interp, Layout.i_current_co))
        ok = b.and(ok, b.icmp(LLVM::IntPredicate::EQ, co, null_ptr))
        ho = b.load(@i32, tbl_fld(@interp, Layout.i_hook_on))
        ok = b.and(ok, b.icmp(LLVM::IntPredicate::EQ, ho, @i32.const_int(0)))
        depth = b.load(@i32, tbl_fld(@interp, Layout.i_jit_depth))
        ok = b.and(ok, b.icmp(LLVM::IntPredicate::SLT, depth, @i32.const_int(512)))
        ms = b.load(@i32, tbl_fld(proto, Layout.pr_maxstack))
        ra = b.add(@base, @i32.const_int(a))
        # ensure_stack(ra + {max_stack, argn+1}.max + argn + 4): the
        # helper guarantees size > n, so fast requires cap > n
        need = b.add(ra, b.add(b.select(
          b.icmp(LLVM::IntPredicate::SGT, ms, @i32.const_int(argn + 1)),
          ms, @i32.const_int(argn + 1)), @i32.const_int(argn + 4)))
        cap = b.load(@i32, tbl_fld(@interp, Layout.i_stack_cap))
        ok = b.and(ok, b.icmp(LLVM::IntPredicate::UGT, cap, need))
        go = new_block("cgo#{pc}")
        b.cond(ok, go, slow)
        b.position_at_end(go)
        # window bookkeeping, exactly as jit_call_dispatch does
        b.store(b.add(depth, @i32.const_int(1)), tbl_fld(@interp, Layout.i_jit_depth))
        old_hi = b.load(@i32, tbl_fld(@interp, Layout.i_jit_hi))
        win = b.add(ra, ms)
        hi_b = new_block("chi#{pc}")
        hi_done = new_block("chid#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::SGT, win, old_hi), hi_b, hi_done)
        b.position_at_end(hi_b)
        b.store(win, tbl_fld(@interp, Layout.i_jit_hi))
        b.br(hi_done)
        b.position_at_end(hi_done)
        stk = b.load(@lv_ptr, tbl_fld(@interp, Layout.i_stack_buf))
        cargs = [@interp, stk, clp2, ra, @i32.const_int(argn), @i32.const_int(want_v),
                 @i32.const_int(0), @i32.const_int(0)] of LLVM::Value
        st = LLVM::Value.new LibLLVM.build_call2(b, @entry_ty, cp,
          (cargs.to_unsafe.as(LibLLVM::ValueRef*)), cargs.size, "cst")
        b.store(depth, tbl_fld(@interp, Layout.i_jit_depth))
        b.store(old_hi, tbl_fld(@interp, Layout.i_jit_hi))
        # the callee's nested calls may have reallocated the buffer
        b.store(b.load(@lv_ptr, tbl_fld(@interp, Layout.i_stack_buf)), @cur_stack)
        bad = new_block("cbad#{pc}")
        cont = new_block("ccont#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::SLT, st, @i32.const_int(0)), bad, cont)
        b.position_at_end(bad)
        b.ret(st)
        b.position_at_end(cont)
        if want_v > 0
          # nil-fill missing fixed results (store_results analog): slot
          # gets nil when the callee returned fewer than wanted
          j = 0
          while j < want_v
            cur = load_slot(a + j)
            pick = b.select(b.icmp(LLVM::IntPredicate::SLE, st, @i32.const_int(j)), @nil_const, cur)
            b.store(pick, slot(a + j))
            j += 1
          end
        end
        if want_v == -1
          b.store(b.add(b.add(@base, @i32.const_int(a)), st), @cur_top)
        else
          b.store(b.add(@base, @i32.const_int(a + {want_v, 0}.max)), @cur_top)
        end
        join = new_block("cjoin#{pc}")
        b.br(join)
        b.position_at_end(slow)
        newstk = call_fp(:dispatch,
          [@interp, @clp, @base, @i32.const_int(pc), @i32.const_int(a), @i32.const_int(argn), @i32.const_int(want_v), @status_p])
        b.store(newstk, @cur_stack)
        st2 = b.load(@i32, @status_p)
        bad2 = new_block("callbad#{pc}")
        cont2 = new_block("callcont#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::SLT, st2, @i32.const_int(0)), bad2, cont2)
        b.position_at_end(bad2)
        b.ret(st2)
        b.position_at_end(cont2)
        if want_v == -1
          b.store(b.add(b.add(@base, @i32.const_int(a)), st2), @cur_top)
        else
          b.store(b.add(@base, @i32.const_int(a + {want_v, 0}.max)), @cur_top)
        end
        b.br(join)
        b.position_at_end(join)
        kill_all
        yield
      end

      # Recorded single-arg numeric builtin at this pc (M5.1): an identity
      # guard replaces the whole dispatch for math.*-style calls
      private def fast1_target(pc : Int32) : LuaFunction?
        f = @cl.proto.fast1_fb.try(&.[pc]?) || return nil
        f.fast1 ? f : nil
      end

      # CALL of a recorded fast1 builtin (math.* style): guard the LuaValue
      # tag + object identity, prove the single argument numeric (a miss
      # deopts at the CALL pc — the interpreter re-runs the call with the
      # exact error semantics), then one C-ABI hop to the pure fast1 proc.
      # No Lua runs and nothing allocates, so the caller's provenance
      # survives; the result register becomes numeric.
      private def emit_call_fast1(pc : Int32, a : Int32, fn1 : LuaFunction) : Nil
        b = @b
        slow = new_block("f1slow#{pc}")
        cont = new_block("f1cont#{pc}")
        vf = load_slot(a)
        ok = b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vf, 0),
          @i32.const_int(Layout.tag_fun))
        ok = b.and(ok, b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vf, 1),
          @i64.const_int(fn1.as(Void*).address.to_i64!)))
        go = new_block("f1go#{pc}")
        b.cond(ok, go, slow)
        b.position_at_end(go)
        v = guard_num(pc, a + 1) # deopt re-runs the CALL: exact errors
        r = LLVM::Value.new LibLLVM.build_call2(b, @helper_types[:fast1],
          @helpers[:fast1],
          ([int2ptr(@i64.const_int(fn1.as(Void*).address.to_i64!)),
            v] of LLVM::Value).to_unsafe.as(LibLLVM::ValueRef*), 2, "f1r")
        store_num(slot(a), r)
        kill(a)
        @nums[a] = r
        b.store(b.add(@base, @i32.const_int(a + 1)), @cur_top)
        b.br(cont)
        b.position_at_end(slow)
        newstk = call_fp(:dispatch,
          [@interp, @clp, @base, @i32.const_int(pc), @i32.const_int(a),
           @i32.const_int(1), @i32.const_int(1), @status_p])
        b.store(newstk, @cur_stack)
        st2 = b.load(@i32, @status_p)
        bad2 = new_block("f1bad#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::SLT, st2, @i32.const_int(0)), bad2, cont)
        b.position_at_end(bad2)
        b.ret(st2)
        b.position_at_end(cont)
        kill_all # the slow merge ran arbitrary Lua
        br_next(pc)
      end

      # Candidate callee for hot-call inlining (M5): the call-site feedback
      # recorded a monomorphic LuaClosure target at this pc, its arity
      # matches the fixed call, and the body is small, loop-free, purely
      # register-numeric (no table/global/call ops — the inlined region
      # runs no helpers except GETUPVAL, so no Lua and no allocation can
      # happen between the CALL's arguments and its results; a guard deopt
      # mid-region can therefore simply re-run the whole call) and has
      # clean type feedback (mono-numeric with deopt guards only).
      private def inline_target(pc : Int32, argn : Int32) : Proto?
        cp = @cl.proto.call_fb.try(&.[pc]?)
        if ENV["LUA5_JIT"]? == "trace" && !cp
          Compiler.trace("inline-reject pc=#{pc}: no call_fb (size #{@cl.proto.call_fb.try(&.size)})")
        end
        return nil unless cp
        return nil if cp.same?(@cl.proto) # direct recursion: body has CALLs anyway
        return nil unless cp.num_params == argn
        return nil if cp.needs_arg? || cp.vararg?
        return nil if cp.packed.size > Compiler::INLINE_MAX_OPS
        if (fb = cp.feedback) && fb.any? { |m| m != 0 }
          return nil # callee went polymorphic somewhere — no mono-only inline
        end
        n = cp.packed.size
        cp.packed.each_with_index do |w, pc2|
          op = (w & 0xFF).to_u8!.unsafe_as(Op)
          off = ((w >> 24).to_i64! << 44 >> 44).to_i32!
          case op
          when .loadk?, .loadnil?, .loadbool?, .move?, .add?, .sub?, .mul?,
               .div?, .mod?, .pow?, .unm?, .not?, .eq?, .neq?, .lt?, .le?,
               .getupval?
            # pure register code
          when .jmp?, .jmpf?, .jmpt?
            return nil if off < 0 # loops stay out: no back-edge gates inline
            t = pc2 + 1 + off
            return nil if t < 0 || t >= n
          when .return?
            return nil if off < 0 # multi-feed return: frame-top semantics
          else
            return nil # table/global/call/allocation ops — normal call
          end
        end
        cp
      end

      # Hot-call inlining (M5): emit the recorded callee body straight into
      # the caller. Register convention: a callee frame's R0 is its closure
      # slot and params start at R1, so the call's args at a+1..a+argn are
      # already the callee's params. The inline region works in a SHADOW
      # copy at w0 = a + max(argn, 1) (args copied up front) because the
      # body may write its param registers — a guard deopt must find the
      # call's arguments intact to re-run the CALL interpreted (the region
      # cannot have side effects: it runs no Lua, and the slots it writes
      # sit exactly where a real callee frame's window would). Results come
      # back to a..a+want-1. Guard misses (other proto, hooks on, stack
      # capacity) take the dispatch slow path, which is always-correct.
      private def emit_call_inline(pc : Int32, a : Int32, argn : Int32,
                                   want : Int32, cp : Proto) : Nil
        b = @b
        # callee R0 -> caller slot base + w0; args (R1..Rargn) shadow-copied
        w0 = a + {argn, 1}.max
        slow = new_block("icslow#{pc}")
        cont = new_block("iccont#{pc}")
        # guard: closure with the recorded proto, hooks off, window fits
        vf = load_slot(a)
        clb = new_block("iccl#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vf, 0),
          @i32.const_int(Layout.tag_closure)), clb, slow)
        b.position_at_end(clb)
        clp2 = payload_ptr(vf)
        proto2 = b.load(@ptr, tbl_fld(clp2, Layout.cl_proto))
        ok = b.icmp(LLVM::IntPredicate::EQ, proto2,
          int2ptr(@i64.const_int(cp.as(Void*).address.to_i64!)))
        ho = b.load(@i32, tbl_fld(@interp, Layout.i_hook_on))
        ok = b.and(ok, b.icmp(LLVM::IntPredicate::EQ, ho, @i32.const_int(0)))
        cap = b.load(@i32, tbl_fld(@interp, Layout.i_stack_cap))
        # ensure_stack(n) guarantees size > n; the window needs
        # base + w0 + callee max_stack + headroom for the deopt rebuild
        need = b.add(@base, @i32.const_int(w0 + cp.max_stack + 4))
        ok = b.and(ok, b.icmp(LLVM::IntPredicate::UGT, cap, need))
        go = new_block("icgo#{pc}")
        b.cond(ok, go, slow)
        b.position_at_end(go)
        # shadow-copy the args (callee params R1..Rargn) into the region
        # window; numeric provenance travels with the value
        i = 1
        while i <= argn
          b.store(load_slot(a + i), slot(w0 + i))
          if v = @nums[a + i]?
            @nums[w0 + i] = v
          else
            @nums.delete(w0 + i)
          end
          @skeys.delete(w0 + i)
          @tabs.delete(w0 + i)
          i += 1
        end
        # region blocks: one per callee pc (plus the merge `cont` above)
        n2 = cp.packed.size
        rblocks = Array(LLVM::BasicBlock).new(n2) { |i| new_block("ic#{pc}b#{i}") }
        # region-local provenance discipline: kill at merge blocks and jump
        # entries (the emitter is linear; see run for the caller analogue)
        rp = Array(Int32).new(n2, 0)
        jt = Set(Int32).new
        cp.packed.each_with_index do |w, i|
          op = (w & 0xFF).to_u8!.unsafe_as(Op)
          off = ((w >> 24).to_i64! << 44 >> 44).to_i32!
          case op
          when .jmp?
            jt << i + 1 + off
            rp[i + 1 + off] += 1
          when .jmpf?, .jmpt?
            jt << i + 1 + off
            rp[i + 1 + off] += 1
            rp[i + 1] += 1
          when .return? then # terminal
          else
            rp[i + 1] += 1 if i + 1 < n2
          end
        end
        b.br(rblocks[0])
        cconsts = cp.consts
        pc2 = 0
        while pc2 < n2
          b.position_at_end(rblocks[pc2])
          kill_all if pc2 > 0 && (rp[pc2] > 1 || jt.includes?(pc2))
          w = cp.packed[pc2]
          op = (w & 0xFF).to_u8!.unsafe_as(Op)
          a2 = ((w >> 8).to_i64! << 48 >> 48).to_i32!
          b2 = ((w >> 24).to_i64! << 44 >> 44).to_i32!
          c2 = ((w >> 44).to_i64! << 44 >> 44).to_i32!
          fall = pc2 + 1 < n2 ? rblocks[pc2 + 1] : cont
          case op
          when .loadk?
            k = cconsts[b2]?
            case k
            when Float64
              kill(w0 + a2)
              store_num(slot(w0 + a2), @f64.const_double(k))
              @nums[w0 + a2] = @f64.const_double(k)
            when Bool
              store_scalar(slot(w0 + a2), @i32.const_int(Layout.tag_bool),
                @i64.const_int(k ? 1 : 0))
              kill(w0 + a2)
            when String
              store_scalar(slot(w0 + a2), @i32.const_int(Layout.tag_str),
                @i64.const_int(k.as(Void*).address.to_i64!))
              kill(w0 + a2)
            else
              b.store(@nil_const, slot(w0 + a2))
              kill(w0 + a2)
            end
            b.br(fall)
          when .loadnil?
            r = w0 + a2
            while r <= w0 + a2 + b2
              b.store(@nil_const, slot(r))
              kill(r)
              r += 1
            end
            b.br(fall)
          when .loadbool?
            store_scalar(slot(w0 + a2), @i32.const_int(Layout.tag_bool),
              @i64.const_int(b2 != 0 ? 1 : 0))
            kill(w0 + a2)
            b.br(fall)
          when .move?
            if v = @nums[w0 + b2]?
              @nums[w0 + a2] = v
            else
              @nums.delete(w0 + a2)
            end
            @skeys.delete(w0 + a2)
            @tabs.delete(w0 + a2)
            b.store(load_slot(w0 + b2), slot(w0 + a2))
            b.br(fall)
          when .add?, .sub?, .mul?, .div?, .mod?, .pow?
            # mono-numeric only (callee feedback is clean by precondition):
            # guard misses deopt at the CALL pc — the interpreter re-runs
            # the call, sampling the callee's own feedback, and the drift
            # check recompiles here without the inline
            l = guard_num(pc, w0 + b2)
            r = guard_num(pc, w0 + c2)
            res = arith_fop(op, l, r)
            store_num(slot(w0 + a2), res)
            kill(w0 + a2)
            @nums[w0 + a2] = res
            b.br(fall)
          when .unm?
            v = guard_num(pc, w0 + b2)
            res = b.fneg(v)
            store_num(slot(w0 + a2), res)
            kill(w0 + a2)
            @nums[w0 + a2] = res
            b.br(fall)
          when .not?
            store_bool(slot(w0 + a2), b.not(truthy(w0 + b2)))
            kill(w0 + a2)
            b.br(fall)
          when .eq?, .neq?, .lt?, .le?
            l = guard_num(pc, w0 + b2)
            r = guard_num(pc, w0 + c2)
            t = case op
                when .eq?  then b.fcmp(LLVM::RealPredicate::OEQ, l, r)
                when .neq? then b.fcmp(LLVM::RealPredicate::UNE, l, r) # NaN ~= NaN is true
                when .lt?  then b.fcmp(LLVM::RealPredicate::OLT, l, r)
                else            b.fcmp(LLVM::RealPredicate::OLE, l, r)
                end
            store_bool(slot(w0 + a2), t)
            kill(w0 + a2)
            b.br(fall)
          when .jmp?     then b.br(rblocks[pc2 + 1 + b2])
          when .jmpf?    then b.cond(truthy(w0 + a2), fall, rblocks[pc2 + 1 + b2])
          when .jmpt?    then b.cond(truthy(w0 + a2), rblocks[pc2 + 1 + b2], fall)
          when .getupval?
            # reads the actual closure's upvalue cell, fully inlined (see
            # emit_getupval) — pure loads, no Lua runs, no map kills
            emit_getupval(pc, w0 + a2, b2, clp2)
            b.br(fall)
          when .return?
            # results to the caller's window per `want`, nil-filled; fixed
            # counts only (multi-feeds were rejected in inline_target)
            j = 0
            while j < want
              if j < b2
                b.store(load_slot(w0 + a2 + j), slot(a + j))
              else
                b.store(@nil_const, slot(a + j))
              end
              kill(a + j)
              j += 1
            end
            b.br(cont)
          else
            raise CompileBail.new("inline op #{op} at pc #{pc2}")
          end
          pc2 += 1
        end
        # slow path: the plain dispatch call (same contract as emit_call)
        b.position_at_end(slow)
        newstk = call_fp(:dispatch,
          [@interp, @clp, @base, @i32.const_int(pc), @i32.const_int(a),
           @i32.const_int(argn), @i32.const_int(want), @status_p])
        b.store(newstk, @cur_stack)
        st2 = b.load(@i32, @status_p)
        bad2 = new_block("icbad#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::SLT, st2, @i32.const_int(0)), bad2, cont)
        b.position_at_end(bad2)
        b.ret(st2)
        b.position_at_end(cont)
        b.store(b.add(@base, @i32.const_int(a + {want, 0}.max)), @cur_top)
        kill_all
        br_next(pc)
        @inline_snaps << {cp, cp.feedback.try(&.dup) ||
          Array(UInt8).new(cp.packed.size, 0_u8)}
      end


      # GETUPVAL A B: R[A] := U[B] of closure `clp` — inlined to three
      # dependent loads (closure -> upvals buffer -> cell) plus either the
      # shared value-stack slot (open cell; nilable-reference @stack is a
      # plain pointer, nil = 0) or the cell's cached value (closed). The
      # two loads MUST stay on separate branches: a select would evaluate
      # the open-path load through a null pointer when the cell is closed.
      # Pure — no runtime call, so provenance of other registers survives
      # (the old helper path killed everything; num_transfer mirrors this).
      private def emit_getupval(pc : Int32, a : Int32, idx : Int32,
                                clp : LLVM::Value) : Nil
        b = @b
        ups = b.load(@ptr, tbl_fld(clp, Layout.cl_upvs))
        cells = b.load(@ptr, tbl_fld(ups, Layout.arr_buf))
        # the buffer holds POINTERS to UpValue cells — load the element,
        # then read its fields through it
        cell = b.load(@ptr, tbl_fld(cells, idx &* 8))
        stk = b.load(@ptr, tbl_fld(cell, Layout.uv_stack))
        ob = new_block("uvop#{pc}#{a}")
        cb = new_block("uvcl#{pc}#{a}")
        mb = new_block("uvdn#{pc}#{a}")
        b.cond(b.icmp(LLVM::IntPredicate::NE, stk, null_ptr), ob, cb)
        b.position_at_end(ob)
        lbuf = b.load(@lv_ptr, tbl_fld(stk, Layout.arr_buf))
        iv = b.load(@i32, tbl_fld(cell, Layout.uv_idx))
        ov = b.load(@lv, b.gep(@lv, lbuf, iv))
        b.br(mb)
        b.position_at_end(cb)
        cv = b.load(@lv, tbl_fld(cell, Layout.uv_value))
        b.br(mb)
        b.position_at_end(mb)
        v = b.phi(@lv, [ob, cb], [ov, cv])
        b.store(v, slot(a))
        kill(a)
      end

      # GETTABLE A B C: R[A] := R[B][R[C]] — numeric-key fast path. R[B] a
      # plain table (nil metatable: no metamethods, not weak), R[C] a
      # number whose integral value lands in the array part and hits a
      # non-hole slot → one 16-byte load; no runtime call, so numeric
      # provenance of OTHER registers stays valid on this path. Anything
      # else (string keys, non-integral keys, hash-part keys, holes,
      # metamethods, non-tables) takes the helper — a non-number key or
      # non-table object is legal Lua, not a deopt.
      private def emit_gettable(pc : Int32, a : Int32, br : Int32, cr : Int32) : Nil
        b = @b
        spec = spec_clean?(pc)
        if @nums[br]? && !spec
          # R[B] proven numeric (poly mode): cannot be a table; getindex on
          # a number (error/metamethod) is the helper's job — the helper
          # merge kills the maps, which the poly transfer models. In SPEC
          # mode this early exit is skipped on purpose: the generic guard
          # chain reaches the same runtime deopt (the tag check cannot
          # pass) while the fast-path maps keep flowing, exactly as the
          # M3.7 dataflow models them (an unconditional terminal here
          # desynced emitter maps from the analysis: "merge phi hole").
          call_fp(:gettable, [@interp, @clp, @base, @i32.const_int(pc),
            @i32.const_int(a), @i32.const_int(br), @i32.const_int(cr), slot(a)])
          br_next(pc)
          return
        end
        slow = spec ? deopt_at(pc, "gt") : new_block("gtslow#{pc}")
        # R[B]: plain table with nil metatable (cached per block — the
        # tag/mt guards run once per register, see @tabs)
        tbl = guard_table(pc, br, "gt", slow)
        kf = if v = @nums[cr]?
               v # provenance guarantees the number tag
             else
               vc = load_slot(cr)
               ok = new_block("gt#{pc}num")
               b.cond(tag_is(vc, Layout.tag_num), ok, slow)
               b.position_at_end(ok)
               f64_of(vc)
             end
        # integrality: int32 range first (fptosi of out-of-range/NaN is
        # poison), then trunc == value
        inr = b.and(b.fcmp(LLVM::RealPredicate::OGE, kf, @f64.const_double(-2147483648.0)),
          b.fcmp(LLVM::RealPredicate::OLT, kf, @f64.const_double(2147483648.0)))
        ok = new_block("gt#{pc}ir")
        b.cond(inr, ok, slow)
        b.position_at_end(ok)
        k32 = fp_to_si(kf, @i32)
        ok = new_block("gt#{pc}ic")
        b.cond(b.fcmp(LLVM::RealPredicate::OEQ, si_to_fp(k32, @f64), kf), ok, slow)
        b.position_at_end(ok)
        ab = b.load(@i32, tbl_fld(tbl, Layout.tbl_base))
        al = b.load(@i32, tbl_fld(tbl, Layout.tbl_len))
        ok = new_block("gt#{pc}b")
        b.cond(b.and(b.icmp(LLVM::IntPredicate::SGE, k32, ab),
          b.icmp(LLVM::IntPredicate::SLT, k32, b.add(ab, al))), ok, slow)
        b.position_at_end(ok)
        # unboxed array part (M7): bare f64 buffer — no tag check, and the
        # loaded value is a number by construction (numeric fact)
        unf = new_block("gt#{pc}u")
        bxf = new_block("gt#{pc}bx")
        b.cond(b.icmp(LLVM::IntPredicate::NE,
          b.load(@i8, tbl_fld(tbl, Layout.tbl_unboxed)), @i8.const_int(0)),
          unf, bxf)
        b.position_at_end(unf)
        fbuf = b.load(@ptr, tbl_fld(tbl, Layout.tbl_fbuf))
        fv = b.load(@f64, b.gep(@f64, fbuf, b.sub(k32, ab)))
        store_num(slot(a), fv)
        kill(a)
        br_next(pc)
        b.position_at_end(bxf)
        bufp = b.load(@lv_ptr, tbl_fld(tbl, Layout.tbl_buf))
        v = b.load(@lv, b.gep(@lv, bufp, b.sub(k32, ab)))
        # nil slot = hole, but the hash part may still hold the key → helper
        ok = new_block("gt#{pc}hit")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(v, 0), @i32.const_int(0)),
          slow, ok)
        b.position_at_end(ok)
        b.store(v, slot(a))
        kill(a)
        br_next(pc)
        return if spec # the miss edge deopts — no merge, provenance survives
        b.position_at_end(slow)
        call_fp(:gettable, [@interp, @clp, @base, @i32.const_int(pc),
          @i32.const_int(a), @i32.const_int(br), @i32.const_int(cr), slot(a)])
        br_next(pc)
        # merge: the slow path ran arbitrary Lua (provenance void), so the
        # map cannot be trusted past this instruction
        kill_all
      end

      # SETTABLE A B C: R[A][R[B]] := R[C] — same fast-path shape as
      # emit_gettable. In-bounds stores of any value (nil = hole) match
      # raw_set's array branch; @len_cache needs no update (a hint only —
      # raw_length re-derives past stale values). Appends, hash-part keys
      # and metamethods take the helper.
      private def emit_settable(pc : Int32, a : Int32, br : Int32, cr : Int32) : Nil
        b = @b
        spec = spec_clean?(pc)
        if @nums[a]? && !spec
          # R[A] proven numeric (poly mode): cannot be a table (setindex
          # on a number raises or fires metamethods — helper; the merge
          # kills the maps as the poly transfer models). SPEC mode takes
          # the generic guard chain instead — see emit_gettable.
          call_fp(:settable, [@interp, @clp, @base, @i32.const_int(pc),
            @i32.const_int(a), @i32.const_int(br), @i32.const_int(cr)])
          br_next(pc)
          return
        end
        slow = spec ? deopt_at(pc, "st") : new_block("stslow#{pc}")
        # R[A]: plain table with nil metatable (cached per block, @tabs)
        tbl = guard_table(pc, a, "st", slow)
        kf = if v = @nums[br]?
               v
             else
               vb = load_slot(br)
               ok = new_block("st#{pc}num")
               b.cond(tag_is(vb, Layout.tag_num), ok, slow)
               b.position_at_end(ok)
               f64_of(vb)
             end
        inr = b.and(b.fcmp(LLVM::RealPredicate::OGE, kf, @f64.const_double(-2147483648.0)),
          b.fcmp(LLVM::RealPredicate::OLT, kf, @f64.const_double(2147483648.0)))
        ok = new_block("st#{pc}ir")
        b.cond(inr, ok, slow)
        b.position_at_end(ok)
        k32 = fp_to_si(kf, @i32)
        ok = new_block("st#{pc}ic")
        b.cond(b.fcmp(LLVM::RealPredicate::OEQ, si_to_fp(k32, @f64), kf), ok, slow)
        b.position_at_end(ok)
        ab = b.load(@i32, tbl_fld(tbl, Layout.tbl_base))
        al = b.load(@i32, tbl_fld(tbl, Layout.tbl_len))
        ok = new_block("st#{pc}b")
        b.cond(b.and(b.icmp(LLVM::IntPredicate::SGE, k32, ab),
          b.icmp(LLVM::IntPredicate::SLT, k32, b.add(ab, al))), ok, slow)
        b.position_at_end(ok)
        vv = load_slot(cr)
        # unboxed array part (M7): only number values fit — anything else
        # (string/table/nil) must flip the table, the helper's job
        unf = new_block("st#{pc}u")
        bxf = new_block("st#{pc}bx")
        b.cond(b.icmp(LLVM::IntPredicate::NE,
          b.load(@i8, tbl_fld(tbl, Layout.tbl_unboxed)), @i8.const_int(0)),
          unf, bxf)
        b.position_at_end(unf)
        okn = new_block("st#{pc}un")
        b.cond(tag_is(vv, Layout.tag_num), okn, slow)
        b.position_at_end(okn)
        fbuf = b.load(@ptr, tbl_fld(tbl, Layout.tbl_fbuf))
        b.store(b.extract_value(vv, 1), b.gep(@f64, fbuf, b.sub(k32, ab)))
        br_next(pc)
        b.position_at_end(bxf)
        # nil store must update @len_cache (raw_set: k-1 if k <= cache) —
        # route it to the helper; nil writes are cold in hot loops
        ok = new_block("st#{pc}nn")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vv, 0), @i32.const_int(0)),
          slow, ok)
        b.position_at_end(ok)
        bufp = b.load(@lv_ptr, tbl_fld(tbl, Layout.tbl_buf))
        b.store(vv, b.gep(@lv, bufp, b.sub(k32, ab)))
        br_next(pc)
        return if spec # miss edge deopts — no merge, provenance survives
        b.position_at_end(slow)
        call_fp(:settable, [@interp, @clp, @base, @i32.const_int(pc),
          @i32.const_int(a), @i32.const_int(br), @i32.const_int(cr)])
        br_next(pc)
        kill_all
      end

      # GETTABLE with a known constant string key: inlined identity probe
      # over the flat string-key table (no runtime call — numeric
      # provenance of other registers survives). Anything but a plain
      # hit (metatables, non-tables, long strings, probe miss) takes the
      # helper.
      private def emit_str_gettable(pc : Int32, a : Int32, br : Int32, cr : Int32,
                                    kaddr : UInt64) : Nil
        b = @b
        spec = spec_clean?(pc)
        slow = spec ? deopt_at(pc, "sgt") : new_block("sgtslow#{pc}")
        # R[B]: plain table with nil metatable (cached per block, @tabs)
        tbl = guard_table(pc, br, "sgt", slow)
        valp, miss = str_probe_begin(pc, tbl, kaddr, "sgt")
        v = b.load(@lv, valp)
        b.store(v, slot(a))
        kill(a)
        br_next(pc)
        b.position_at_end(miss)
        b.br(slow) # the deopt block in spec mode
        return if spec
        b.position_at_end(slow)
        call_fp(:gettable, [@interp, @clp, @base, @i32.const_int(pc),
          @i32.const_int(a), @i32.const_int(br), @i32.const_int(cr), slot(a)])
        br_next(pc)
        kill_all
      end

      # SETTABLE with a known constant string key: inlined probe; an
      # overwrite of an EXISTING slot with a non-nil value is inline (no
      # runtime call, provenance of other registers survives). Fresh
      # inserts (no slot), nil stores (delete + backward shift) and any
      # non-plain-table shape take the helper.
      private def emit_str_settable(pc : Int32, a : Int32, br : Int32, cr : Int32,
                                    kaddr : UInt64) : Nil
        b = @b
        spec = spec_clean?(pc)
        slow = spec ? deopt_at(pc, "sst") : new_block("sstslow#{pc}")
        # R[A]: plain table with nil metatable (cached per block, @tabs)
        tbl = guard_table(pc, a, "sst", slow)
        vv = load_slot(cr)
        ok = new_block("sst#{pc}nn")
        b.cond(b.icmp(LLVM::IntPredicate::NE, b.extract_value(vv, 0),
          @i32.const_int(0)), ok, slow)
        b.position_at_end(ok)
        valp, miss = str_probe_begin(pc, tbl, kaddr, "sst")
        b.store(vv, valp)
        br_next(pc)
        b.position_at_end(miss)
        b.br(slow) # the deopt block in spec mode
        return if spec
        b.position_at_end(slow)
        call_fp(:settable, [@interp, @clp, @base, @i32.const_int(pc),
          @i32.const_int(a), @i32.const_int(br), @i32.const_int(cr)])
        br_next(pc)
        kill_all
      end

      # SELF A B K: R[A+1] := R[B]; R[A] := R[B][const K] — method-call
      # sugar. The constant key goes through the same inlined probe when
      # short; the helper handles everything else (metamethods, strings…).
      private def emit_str_self(pc : Int32, a : Int32, bb : Int32, kidx : Int32) : Nil
        b = @b
        k = @consts[kidx]?
        unless k.is_a?(String) && k.bytesize <= Lua::SHORT_STR_MAX
          call_fp(:self, [@interp, @clp, @base, @i32.const_int(pc),
            @i32.const_int(a), @i32.const_int(bb), @i32.const_int(kidx), slot(a)])
          br_next(pc)
          return
        end
        kaddr = Lua.intern(k).as(Void*).address
        spec = spec_clean?(pc)
        slow = spec ? deopt_at(pc, "slf") : new_block("slfslow#{pc}")
        obj = load_slot(bb)
        # R[B]: plain table with nil metatable (cached per block, @tabs)
        tbl = guard_table(pc, bb, "slf", slow)
        valp, miss = str_probe_begin(pc, tbl, kaddr, "slf")
        b.store(obj, slot(a + 1))
        b.store(b.load(@lv, valp), slot(a))
        kill(a)
        kill(a + 1)
        br_next(pc)
        b.position_at_end(miss)
        b.br(slow) # the deopt block in spec mode
        return if spec
        b.position_at_end(slow)
        call_fp(:self, [@interp, @clp, @base, @i32.const_int(pc),
          @i32.const_int(a), @i32.const_int(bb), @i32.const_int(kidx), slot(a)])
        br_next(pc)
        kill_all
      end

      # Emits the probe for canonical key `kaddr` in table `tbl` (i8*);
      # positions the builder in the HIT block and returns the address of
      # the slot's val field plus the MISS block (caller falls back to the
      # helper there). Home index mirrors LuaTable#slot_idx:
      # Lua.slot_hash(kaddr) & mask (murmur finalizer — a Fibonacci hash
      # clusters adjacent interned-string addresses); kaddr is a compile-
      # time constant, so the mix costs nothing in the emitted code;
      # 3 slots probed inline, misses/empties fall through to `miss`.
      private def str_probe_begin(pc : Int32, tbl : LLVM::Value, kaddr : UInt64,
                                  tag : String) : {LLVM::Value, LLVM::BasicBlock}
        b = @b
        smask = b.load(@i32, tbl_fld(tbl, Layout.tbl_smask))
        has = new_block("#{tag}#{pc}has")
        miss = new_block("#{tag}#{pc}miss")
        b.cond(b.icmp(LLVM::IntPredicate::NE, smask, @i32.const_int(0)), has, miss)
        b.position_at_end(has)
        sbuf = b.load(@ptr, tbl_fld(tbl, Layout.tbl_slots))
        home32 = (Lua.slot_hash(kaddr) & 0xFFFFFFFF_u64).to_i32!
        kptr = int2ptr(@i64.const_int(kaddr.to_i64!))
        hit = new_block("#{tag}#{pc}hit")
        blocks = [] of LLVM::BasicBlock
        slots = [] of LLVM::Value
        3.times do |t|
          # NB: (home32 + t) & smask — NOT (home32 + t + smask) & smask:
          # adding the mask first shifts the whole window to home-1, and
          # an empty home-1 slot aborts the linear probe before the key
          # at home is ever compared (every probe missed since M3.2; the
          # old clustered hash masked it, the murmur mixer exposed it)
          idx = b.and(@i32.const_int(home32 &+ t), smask)
          slot = b.gep(@i8, sbuf, b.mul(b.zext(idx, @i64), @i64.const_int(Layout.slot_size)))
          kp = b.load(@ptr, b.gep(@i8, slot, @i64.const_int(Layout.slot_key)))
          not_hit = new_block("#{tag}#{pc}nh#{t}")
          nxt = t == 2 ? miss : new_block("#{tag}#{pc}n#{t}")
          here = current_block
          b.cond(b.icmp(LLVM::IntPredicate::EQ, kp, kptr), hit, not_hit)
          blocks << here
          slots << slot
          b.position_at_end(not_hit)
          b.cond(b.icmp(LLVM::IntPredicate::EQ, kp, null_ptr), miss, nxt)
          b.position_at_end(nxt) unless t == 2
        end
        b.position_at_end(hit)
        valp = b.gep(@i8, b.phi(@ptr, blocks, slots), @i64.const_int(Layout.slot_val))
        {valp, miss}
      end

      # current basic block of the builder
      private def current_block : LLVM::BasicBlock
        @b.insert_block
      end

      # R[r] as a metatable-free table: per-block provenance cache first
      # (tag + nil-mt already checked on this register — see @tabs), else
      # fresh guards with a miss into `slow`. Returns the table payload
      # pointer with the builder positioned in the OK block, and caches
      # the result.
      private def guard_table(pc : Int32, r : Int32, tag : String,
                              slow : LLVM::BasicBlock) : LLVM::Value
        if t = @tabs[r]?
          return t
        end
        b = @b
        vb = load_slot(r)
        ok = new_block("#{tag}#{pc}tab")
        b.cond(tag_is(vb, Layout.tag_table), ok, slow)
        b.position_at_end(ok)
        tbl = payload_ptr(vb)
        mt = b.load(@i64, tbl_fld(tbl, Layout.tbl_mt))
        ok = new_block("#{tag}#{pc}mt")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, mt, @i64.const_int(0)), ok, slow)
        b.position_at_end(ok)
        @tabs[r] = tbl
        tbl
      end

      # empty f64 phi trio at the current insert point (block must be
      # empty or the phos precede all instructions — both hold here)
      private def new_phi3(name : String) : {LLVM::Value, LLVM::Value, LLVM::Value}
        p0 = LLVM::Value.new LibLLVM.build_phi(@b, @f64, "#{name}c")
        p1 = LLVM::Value.new LibLLVM.build_phi(@b, @f64, "#{name}l")
        p2 = LLVM::Value.new LibLLVM.build_phi(@b, @f64, "#{name}s")
        {p0, p1, p2}
      end

      # add one incoming edge to a phi
      private def phi_add(phi : LLVM::Value, v : LLVM::Value, blk : LLVM::BasicBlock) : Nil
        vals = uninitialized LibLLVM::ValueRef[1]
        blks = uninitialized LibLLVM::BasicBlockRef[1]
        vals[0] = v.to_unsafe
        blks[0] = blk.to_unsafe
        LibLLVM.add_incoming(phi, vals.to_unsafe, blks.to_unsafe, 1)
      end

      # Static numeric-provenance dataflow over the proto's real CFG
      # (M3.7). Facts only — no speculation: registers become numeric via
      # LOADK-num, mono-arith results, MOVE copies and for-controls, and
      # the interpreter guarantees the same on every path (guards/deopts
      # never establish a fact here, so an OSR entry can always re-prove
      # them). Helper-op pcs kill everything (the emitter's kill_all after
      # the helper merge); speculative table ops keep everything but their
      # destination; polymorphic arith merges with a slow path that may
      # store any Lua value → kills. Returns per-pc real predecessors
      # (fallthrough + jump edges, NO OSR switch edges) and IN sets.
      private def analyze_num_flow : {Array(Array(Int32)), Array(Set(Int32))}
        n = @code.size
        preds = Array(Array(Int32)).new(n + 1) { [] of Int32 }
        @code.each_with_index do |w, pc|
          op = (w & 0xFF).to_u8!.unsafe_as(Op)
          off = ((w >> 24).to_i64! << 44 >> 44).to_i32!
          tgts = case op
                 when .jmp?        then {pc + 1 + off}
                 when .jmpf?, .jmpt?, .forloop?
                   {pc + 1 + off, pc + 1}
                 when .forprep?    then {pc + 1 + off}
                 when .tforcall?   then {pc + 1 + off, pc + 1} # jumps only on non-nil
                 when .tailcall?, .vararg?, .return?
                   {-1} # terminal
                 else                  {pc + 1}
                 end
          tgts.each do |t|
            preds[t] << pc if t >= 0 && t < n
          end
        end
        preds[0] << -1 # function entry: the maps start empty

        bottom = Set(Int32).new
        outs = Array(Set(Int32) | Nil).new(n, nil) # nil = TOP
        ins = Array(Set(Int32)).new(n) { bottom.dup }
        changed = true
        while changed
          changed = false
          pc = 0
          while pc < n
            acc = nil
            preds[pc].each do |p|
              o = nil
              if p < 0
                o = bottom # function entry: empty state
              elsif (t = outs[p])
                o = t # not yet assigned = TOP: no constraint this round
              end
              next if o.nil?
              acc = acc.nil? ? o.dup : (acc & o)
            end
            acc = bottom.dup if acc.nil? # unreachable pc: no facts
            ins[pc] = acc
            o = num_transfer(pc, acc)
            if outs[pc].nil? || o != outs[pc]
              outs[pc] = o
              changed = true
            end
            pc += 1
          end
        end
        {preds, ins}
      end

      # OUT state of the instruction at pc, given its IN (see
      # analyze_num_flow for the modeling rules)
      private def num_transfer(pc : Int32, st : Set(Int32)) : Set(Int32)
        w = @code[pc]
        op = (w & 0xFF).to_u8!.unsafe_as(Op)
        a = ((w >> 8).to_i64! << 48 >> 48).to_i32!
        bb = ((w >> 24).to_i64! << 44 >> 44).to_i32!
        s = st.dup
        case op
        when .move?      then s.includes?(bb) ? (s << a) : s.delete(a)
        when .loadk?     then @consts[bb]?.is_a?(Float64) ? (s << a) : s.delete(a)
        when .loadnil?   then (a..a + bb).each { |r| s.delete(r) }
        when .loadbool? then s.delete(a)
        when .not?      then s.delete(a)
        when .eq?, .neq?, .lt?, .le?
          # mono compare keeps the other registers; the polymorphic slow
          # path (call_fp: cmp) kills the emitter's maps — mirror exactly
          fb_bits(pc) == 0 ? s.delete(a) : s.clear
        when .add?, .sub?, .mul?, .div?, .mod?, .pow?, .unm?
          fb_bits(pc) == 0 ? (s << a) : s.clear
        when .forprep?   then s << a << a + 1 << a + 2
        when .forloop?, .jmp?, .jmpf?, .jmpt? then s
        when .gettable?
          spec_clean?(pc) ? s.delete(a) : s.clear
        when .settable?
          spec_clean?(pc) ? s : s.clear
        when .self?
          spec_clean?(pc) ? (s.delete(a); s.delete(a + 1)) : s.clear
        when .getupval? then s.delete(a) # inlined: pure loads, no kill (M5.1)
        else s.clear # every helper-backed op: kill_all after the merge
        end
        s
      end

      # Feed the general merge phis at `tgt` from the current edge. The
      # dataflow guarantees the register is proven on every incoming edge
      # and the emitter state is a superset of the analysis along linear
      # flow — a miss is a static/emitter mismatch: bail loudly (the
      # closure stays interpreted) instead of emitting broken IR.
      private def wire_gen_edge(tgt : Int32) : Nil
        return unless Compiler::PHIMERGE
        mp = @merge_phi[tgt]? || return
        mp.each do |r, phi|
          if v = @nums[r]?
            phi_add(phi, v, current_block)
          else
            in_s = @in_nums[tgt]?
            raise CompileBail.new("merge phi hole: pc#{tgt} r#{r} src=#{current_block.name} nums=#{@nums.keys.sort} in=#{in_s.try(&.to_a).try(&.sort)} preds=#{@real_preds[tgt]?.try(&.inspect)} fb=#{@fb.inspect}")
          end
        end
      end

      private def new_block(name : String) : LLVM::BasicBlock
        f = @blocks[0].parent.not_nil!
        f.basic_blocks.append(name)
      end

      private def br_next(pc : Int32) : Nil
        if pc + 1 < @blocks.size
          wire_forloop_edge(pc + 1)
          wire_gen_edge(pc + 1)
          @b.br(@blocks[pc + 1])
        else
          @b.ret(@i32.const_int(0))
        end
      end

      # Any branch edge into a FORLOOP pc-block must feed its merge phis:
      # the values arriving from inside the loop are the head phis (the
      # body cannot write the for-controls). Called for every jump /
      # fallthrough target — forward jumps onto a FORLOOP (loop bodies
      # with while/if tails) are common. Missing incomings would fail
      # module verification (the closure then stays interpreted).
      private def wire_forloop_edge(tgt : Int32) : Nil
        if (ha = @forloops[tgt]?) && (hphis = @phi_head[ha[0]]?) &&
           (flphis = @phi_fl[tgt]?)
          here = current_block
          phi_add(flphis[0], hphis[0], here)
          phi_add(flphis[1], hphis[1], here)
          phi_add(flphis[2], hphis[2], here)
        end
      end

      # Backward jump (loop back-edge): with weak tables around, run the
      # weak-GC tick (jit_weakcheck mirrors the interpreter's back-edge
      # handler — stale-register clearing + weak sweep every 32nd edge, so
      # a loop *waiting* for a weak-table sweep still makes progress) and
      # stay in machine code. The weak flag load is inlined: the static
      # byte is monotonic (never cleared), so flag==0 skips the helper.
      private def backedge(pc : Int32, off : Int32) : Nil
        return if off >= 0
        b = @b
        weak = Compiler::INLINE_EDGE ? weak_seen(b) : @ctx.int1.const_int(1)
        slow = new_block("jmpweak#{pc}")
        go = new_block("jmpgo#{pc}")
        b.cond(weak, slow, go)
        b.position_at_end(slow)
        st = call_fp_exit(:weakcheck, [@interp, @clp])
        bad = new_block("jmpweak2#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::NE, st, @i32.const_int(0)), bad, go)
        b.position_at_end(bad)
        # 1 = deopt (captured slots a __gc finalizer may write), -1 =
        # pending error from the tick
        werr = new_block("jmpwerr#{pc}")
        wdpt = new_block("jmpwdpt#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::SLT, st, @i32.const_int(0)), werr, wdpt)
        b.position_at_end(werr)
        b.ret(st)
        b.position_at_end(wdpt)
        d = call_fp_exit(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
        b.ret(d)
        b.position_at_end(go)
      end

      # load of the static Lua.weak_seen flag as i1 (see Layout.probe!)
      private def weak_seen(b : LLVM::Builder) : LLVM::Value
        p = int2ptr(@i64.const_int(Layout.weak_seen.to_i64!))
        b.icmp(LLVM::IntPredicate::NE, b.load(@i8, p), @i8.const_int(0))
      end

      private def dest(pc : Int32, off : Int32) : Int32
        d = pc + 1 + off
        raise CompileBail.new("jump out of range") if d < 0 || d >= @blocks.size
        d
      end

      def slot(r : Int32) : LLVM::Value
        @b.gep(@lv, @b.load(@lv_ptr, @cur_stack), @b.add(@base, @i32.const_int(r)))
      end

      def load_slot(r : Int32) : LLVM::Value
        @b.load(@lv, slot(r))
      end

      # object pointer (i8*) from a LuaValue payload — reference payloads
      # hold the object address
      private def payload_ptr(v : LLVM::Value) : LLVM::Value
        LLVM::Value.new LibLLVM.build_int2ptr(@b, @b.extract_value(v, 1), @i8.pointer, "")
      end

      # i64 -> raw pointer (call targets, flag addresses)
      private def int2ptr(v : LLVM::Value) : LLVM::Value
        LLVM::Value.new LibLLVM.build_int2ptr(@b, v, @ptr, "")
      end

      private def null_ptr : LLVM::Value
        int2ptr(@i64.const_int(0))
      end

      # i8 pointer `off` bytes into the object at `tbl`
      private def tbl_fld(tbl : LLVM::Value, off : Int32) : LLVM::Value
        @b.gep(@i8, tbl, @i64.const_int(off))
      end

      private def fp_to_si(v : LLVM::Value, ty : LLVM::Type) : LLVM::Value
        LLVM::Value.new LibLLVM.build_fp2si(@b, v, ty, "")
      end

      private def si_to_fp(v : LLVM::Value, ty : LLVM::Type) : LLVM::Value
        LLVM::Value.new LibLLVM.build_si2fp(@b, v, ty, "")
      end

      private def store_scalar(dst : LLVM::Value, tag : LLVM::Value, payload : LLVM::Value) : Nil
        b = @b
        b.store(tag, b.gep(@i32, @scratch, @i32.const_int(0)))
        b.store(payload, b.gep(@i64, @scratch, @i32.const_int(1)))
        b.store(b.load(@lv, @scratch), dst)
      end

      def store_num(dst : LLVM::Value, v : LLVM::Value) : Nil
        b = @b
        b.store(@i32.const_int(Layout.tag_num), b.gep(@i32, @scratch, @i32.const_int(0)))
        b.store(b.bit_cast(v, @i64), b.gep(@i64, @scratch, @i32.const_int(1)))
        b.store(b.load(@lv, @scratch), dst)
      end

      def store_bool(dst : LLVM::Value, i1 : LLVM::Value) : Nil
        b = @b
        b.store(@i32.const_int(Layout.tag_bool), b.gep(@i32, @scratch, @i32.const_int(0)))
        b.store(b.zext(i1, @i64), b.gep(@i64, @scratch, @i32.const_int(1)))
        b.store(b.load(@lv, @scratch), dst)
      end

      # truthiness of register r (nil tag 0 / bool with payload 0); a
      # register with numeric provenance is always truthy (0 is truthy)
      def truthy(r : Int32) : LLVM::Value
        return @ctx.int1.const_int(1) if @nums[r]?
        b = @b
        v = load_slot(r)
        tag = b.extract_value(v, 0)
        isnil = b.icmp(LLVM::IntPredicate::EQ, tag, @i32.const_int(0))
        isbool = b.icmp(LLVM::IntPredicate::EQ, tag, @i32.const_int(Layout.tag_bool))
        isfalse = b.icmp(LLVM::IntPredicate::EQ, b.extract_value(v, 1), @i64.const_int(0))
        b.not(b.or(isnil, b.and(isbool, isfalse)))
      end

      # load register r as f64; on a non-number tag deopt at `pc` (the
      # interpreter runs the rest of the function, results already placed).
      # Numeric provenance from earlier in the block skips both the load
      # and the guard (we wrote the slot ourselves; nothing external ran)
      def guard_num(pc : Int32, r : Int32) : LLVM::Value
        if v = @nums[r]?
          return v
        end
        b = @b
        v = load_slot(r)
        tag = b.extract_value(v, 0)
        ok = b.icmp(LLVM::IntPredicate::EQ, tag, @i32.const_int(Layout.tag_num))
        okb = new_block("numok#{pc}_r#{r}")
        bad = new_block("numbad#{pc}_r#{r}")
        b.cond(ok, okb, bad)
        b.position_at_end(bad)
        st = call_fp_exit(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
        b.ret(st)
        b.position_at_end(okb)
        d = b.bit_cast(b.extract_value(v, 1), @f64)
        @nums[r] = d
        d
      end

      def call_fp(key : Symbol, args : Array(LLVM::Value)) : LLVM::Value
        name = @helper_types[key].return_type.kind.void? ? "" : "r"
        r = @b.call(@helper_types[key], @helpers[key], args, name)
        # runtime helpers may read/write any stack slot (metamethods run
        # Lua, calls move registers, the stack may reallocate) — numeric
        # provenance is void past this point
        kill_all
        r
      end

      # pure math helpers (no runtime re-entry, no slot writes): provenance
      # survives (JIT.md 1.4 — only funs that can run Lua invalidate)
      def call_fp_pure(key : Symbol, args : Array(LLVM::Value)) : LLVM::Value
        name = @helper_types[key].return_type.kind.void? ? "" : "r"
        @b.call(@helper_types[key], @helpers[key], args, name)
      end

      # EXIT-only helper call (deopt / loop-edge gates): the edge never
      # rejoins the fast path, and the helper itself runs no Lua and
      # writes no register slot (jit_deopt READS slots to rebuild the
      # interpreter frame; jit_loopedge only closes upvalue cells) — so
      # the provenance maps must stay live: the fast path continues to be
      # emitted after these. Routing them through call_fp wiped @skeys/
      # @nums mid-block (guard_num's deopt block sits INSIDE ordinary
      # arith), silently degrading every string-key SETTABLE whose key
      # LOADK preceded an unproven arith into the numeric-key path
      # (nbody's b.vx stores: spec deopt on a string key, then a
      # helper fallback forever).
      def call_fp_exit(key : Symbol, args : Array(LLVM::Value)) : LLVM::Value
        @b.call(@helper_types[key], @helpers[key], args, "st")
      end
    end

    private def self.gen(cl : LuaClosure, ctx : LLVM::Context, mod : LLVM::Module, sym : String) : Nil
      i32 = ctx.int32
      i64 = ctx.int64
      f64 = ctx.double
      ptr = ctx.void_pointer
      lv = ctx.struct([i32, i64])
      lv_ptr = lv.pointer

      # params: interp, stack, cl, base, argn, want, start_pc, top0 — the
      # last two carry the OSR entry (resume block and frame top); normal
      # calls pass 0 and the caller-computed top
      f = mod.functions.add(sym, [ptr, lv_ptr, ptr, i32, i32, i32, i32, i32], i32)
      entry = f.basic_blocks.append("entry")
      n = cl.proto.packed.size
      blocks = Array(LLVM::BasicBlock).new(n) { |i| f.basic_blocks.append("pc#{i}") }

      # one signature table drives the declarations AND the call-site types
      # (LLVM 15+ opaque pointers need the function type passed explicitly;
      # Function#function_type is broken there)
      void = ctx.void
      sigs = {
        deopt:      {[ptr, ptr, i32, i32, i32], i32, "jit_deopt"},
        dispatch:   {[ptr, ptr, i32, i32, i32, i32, i32, ptr.pointer], lv_ptr, "jit_dispatch_call"},
        getupval:   {[ptr, i32, lv_ptr], void, "jit_getupval"},
        mod_fn:     {[f64, f64], f64, "jit_mod"},
        pow:        {[f64, f64], f64, "jit_pow"},
        getglobal:  {[ptr, ptr, i32, i32, lv_ptr], void, "jit_getglobal"},
        setglobal:  {[ptr, ptr, i32, i32, lv_ptr], void, "jit_setglobal"},
        setupval:   {[ptr, i32, lv_ptr], void, "jit_setupval"},
        gettable:   {[ptr, ptr, i32, i32, i32, i32, i32, lv_ptr], void, "jit_gettable"},
        settable:   {[ptr, ptr, i32, i32, i32, i32, i32], void, "jit_settable"},
        self:       {[ptr, ptr, i32, i32, i32, i32, i32, lv_ptr], void, "jit_self"},
        newtable:   {[lv_ptr], void, "jit_newtable"},
        setlist:    {[ptr, i32, i32, i32, i32, i32], void, "jit_setlist"},
        len:        {[ptr, ptr, i32, i32, i32, lv_ptr], void, "jit_len"},
        concat:     {[ptr, ptr, i32, i32, i32, i32], void, "jit_concat"},
        closure:    {[ptr, ptr, i32, i32, lv_ptr], void, "jit_closure"},
        close:      {[ptr, i32, i32], void, "jit_close"},
        retclose:   {[ptr, i32], void, "jit_ret"},
        fast1:      {[ptr, f64], f64, "jit_fast1"},
        weakcheck:  {[ptr, ptr], i32, "jit_weakcheck"},
        loopedge:   {[ptr, ptr, i32, i32], i32, "jit_loopedge"},
        arith:      {[ptr, ptr, i32, i32, i32, i32, i32, lv_ptr], void, "jit_arith"},
        unmf:       {[ptr, ptr, i32, i32, i32, lv_ptr], void, "jit_unm"},
        cmp:        {[ptr, ptr, i32, i32, i32, i32, i32, lv_ptr], void, "jit_cmp"},
        strcmp:     {[ptr, ptr], i32, "jit_strcmp"},
      }
      helpers = {} of Symbol => LLVM::Function
      helper_types = {} of Symbol => LLVM::Type
      sigs.each do |key, sig|
        helpers[key] = mod.functions.add(sig[2], sig[0], sig[1])
        helper_types[key] = LLVM::Type.function(sig[0], sig[1])
      end

      g = Gen.new(cl, ctx, f, helpers, helper_types, blocks, entry, f.params[1],
        @@osr_heads, @@preds, @@forloops, cl.proto.feedback)
      g.run
      Compiler.last_inline_snaps = g.inline_snaps
    end
  end
end
