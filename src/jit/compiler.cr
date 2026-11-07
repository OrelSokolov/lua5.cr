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
    # LuaClosure tag + field offsets, Proto field offsets (direct-call fast
    # path), Interp field offsets (inline hook/coroutine/depth checks and
    # value-stack re-sync) and the static weak_seen flag address.
    class_getter tag_closure : Int32 = -1
    class_getter cl_proto : Int32 = -1
    class_getter cl_compiled : Int32 = -1
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
      c = cl.probe_offsets
      @@cl_proto = c[:proto]
      @@cl_compiled = c[:compiled]
      @@cl_compiled_tag = c[:compiled_tag]
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
    @@tm : LLVM::TargetMachine? = nil
    # OSR entry points and block predecessor counts of the proto being
    # compiled (see compile)
    @@osr_heads = Set(Int32).new
    @@preds = [] of Int32
    # Keep-alives: ORC code and its context must outlive the closures
    # pointing into it; the Crystal GC would free them otherwise.
    @@keep = [] of LLVM::Orc::ThreadSafeContext

    # Compile `cl`; returns the machine-code entry or nil (unsupported).
    def self.compile(interp : Interp, cl : LuaClosure) : Pointer(Void)?
      Layout.probe!(interp, cl)
      p = cl.proto
      # `arg`-table protos bail: the implicit local is built by push_call at
      # frame entry, which the JIT entry does not do. A bare vararg flag is
      # fine as long as the body never executes VARARG (jit_deopt cannot
      # rebuild frame.varargs, so a mid-body VARARG must never enter JIT).
      return nil if p.needs_arg?
      p.packed.each do |w|
        return nil if (w & 0xFF).to_u8! == Op::VARARG.value
      end
      return nil if p.code.size > 4096 # M1 sanity cap

      # OSR points: targets of backward jumps (numeric-for bodies, while/
      # repeat loops). The entry function starts at blocks[start_pc] for
      # these, blocks[0] otherwise (see gen).
      heads = Set(Int32).new
      p.packed.each_with_index do |w, pc|
        op = (w & 0xFF).to_u8!.unsafe_as(Op)
        case op
        when .jmp?, .jmpf?, .jmpt?, .forloop?
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
        when .tailcall?, .tforcall?, .vararg?, .return?
          # terminal: machine code returns control
        else
          edge.call(pc + 1)
        end
      end
      edge.call(0) # function entry
      heads.each { |hpc| edge.call(hpc) }
      @@preds = preds

      @@sym += 1
      sym = "lua5jit#{@@sym}"
      ctx = LLVM::Context.new
      mod = ctx.new_module(sym)
      # Host layout/triple from the start: a bare context has no DataLayout,
      # so LLVM would size { i32, i64 } as 12 bytes (i64 payload at +4) —
      # ORC re-stamps the real arm64 layout (16 bytes, payload at +8) at
      # codegen, and any IR pass run before that would miscompile every
      # struct-typed load/store into wrong offsets (infinite loops).
      tm = target_machine
      mod.target = tm.triple
      mod.data_layout = tm.data_layout
      gen(cl, ctx, mod, sym)
      mod.verify
      if d = ENV["LUA5_JIT_DUMP"]?
        File.write("#{d}/#{@@sym}-pre.ll", mod.to_s)
      end
      optimize!(mod)
      if d = ENV["LUA5_JIT_DUMP"]?
        File.write("#{d}/#{@@sym}-post.ll", mod.to_s)
      end

      engine = lljit
      ts_ctx = LLVM::Orc::ThreadSafeContext.new(ctx)
      ts_mod = LLVM::Orc::ThreadSafeModule.new(mod, ts_ctx)
      engine.add_llvm_ir_module(engine.main_jit_dylib, ts_mod)
      @@keep << ts_ctx
      engine.lookup(sym)
    rescue e : CompileBail
      trace("bail: #{cl.proto.chunkname} #{e.message}")
      nil
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
        # optimizes before the engine exists must do it itself
        LLVMTgt.a64_info
        LLVMTgt.a64_target
        LLVMTgt.a64_mc
        LLVMTgt.a64_asm_p
        LLVMTgt.a64_asm_w
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

      # invalidate provenance of register r (both maps)
      private def kill(r : Int32) : Nil
        @nums.delete(r)
        @skeys.delete(r)
      end

      private def kill_all : Nil
        @nums.clear
        @skeys.clear
      end

      def initialize(@cl, @ctx : LLVM::Context, f : LLVM::Function,
                     @helpers : Hash(Symbol, LLVM::Function),
                     @helper_types : Hash(Symbol, LLVM::Type), @blocks,
                     entry : LLVM::BasicBlock, stack0 : LLVM::Value,
                     osr_heads : Set(Int32), @preds : Array(Int32))
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
          cases = osr_heads.map { |hpc| {@i32.const_int(hpc), @blocks[hpc]} }
          b.switch(f.params[6], @blocks[0], cases)
        end
      end

      def run : Nil
        n = @code.size
        pc = 0
        while pc < n
          @b.position_at_end(@blocks[pc])
          # numeric SSA survives linear chains; reset where control merges
          kill_all if (@preds[pc]? || 0) > 1
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
          b.store(load_slot(bb), slot(a))
          br_next(pc)
        when .add?, .sub?, .mul?, .div?, .mod?, .pow?
          l = guard_num(pc, bb)
          r = guard_num(pc, cc)
          res = case op
                when .add? then b.fadd(l, r)
                when .sub? then b.fsub(l, r)
                when .mul? then b.fmul(l, r)
                when .div? then b.fdiv(l, r)
                when .mod? then call_fp_pure(:mod_fn, [l, r])
                else            call_fp_pure(:pow, [l, r])
                end
          store_num(slot(a), res)
          @nums[a] = res
          @skeys.delete(a)
          br_next(pc)
        when .unm?
          v = guard_num(pc, bb)
          res = b.fneg(v)
          store_num(slot(a), res)
          @nums[a] = res
          @skeys.delete(a)
          br_next(pc)
        when .not?
          t = truthy(bb)
          store_bool(slot(a), b.not(t))
          kill(a)
          br_next(pc)
        when .eq?, .neq?, .lt?, .le?
          l = guard_num(pc, bb)
          r = guard_num(pc, cc)
          t = case op
              when .eq?  then b.fcmp(LLVM::RealPredicate::OEQ, l, r)
              when .neq? then b.fcmp(LLVM::RealPredicate::ONE, l, r)
              when .lt?  then b.fcmp(LLVM::RealPredicate::OLT, l, r)
              else            b.fcmp(LLVM::RealPredicate::OLE, l, r)
              end
          store_bool(slot(a), t)
          kill(a)
          br_next(pc)
        when .jmp?
          backedge(pc, bb)
          b.br(@blocks[dest(pc, bb)])
        when .jmpf?
          backedge(pc, bb)
          b.cond(truthy(a), @blocks[pc + 1], @blocks[dest(pc, bb)])
        when .jmpt?
          backedge(pc, bb)
          b.cond(truthy(a), @blocks[dest(pc, bb)], @blocks[pc + 1])
        when .getupval?
          call_fp(:getupval, [@clp, @i32.const_int(bb), @scratch])
          b.store(b.load(@lv, @scratch), slot(a))
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
        when .tailcall?, .tforcall?, .vararg?
          # deopt wholesale: the interpreter runs the rest of the function
          # (TAILCALL slides the frame; TFORCALL re-enters; VARARG can't
          # appear — vararg protos bail the compile)
          st = call_fp(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
          b.ret(st)
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

      private def emit_loadk(pc : Int32, a : Int32, kb : Int32) : Nil
        k = @consts[kb]?
        case k
        when Float64
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
        st = call_fp(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
        b.ret(st)
        b.position_at_end(cont)
        s0 = b.fsub(v0, v2)
        store_num(slot(a), s0)
        @nums[a] = s0
        store_num(slot(a + 1), v1)
        @nums[a + 1] = v1
        store_num(slot(a + 2), v2)
        @nums[a + 2] = v2
        b.br(@blocks[dest(pc, off)])
      end

      # FORLOOP: R[A..A+2] are numbers by FORPREP's invariant (the
      # interpreter also reads them unchecked). Back-edge freezes loop
      # upvalues via the helper; the gate is inlined: open upvalues below
      # the frame's window or any weak table ever seen (monotonic flag)
      # route to the helper, the common case skips the call entirely.
      private def emit_forloop(pc : Int32, a : Int32, off : Int32) : Nil
        b = @b
        ctrl0 = load_num_raw(a)
        lim = load_num_raw(a + 1)
        ste = load_num_raw(a + 2)
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
        # path (upvalue freezing + weak check live in jit_loopedge)
        need = if Compiler::INLINE_EDGE
                b.or(weak_seen(b), b.icmp(LLVM::IntPredicate::SGE,
                  b.load(@i32, tbl_fld(@interp, Layout.i_open_max)),
                  b.add(@base, @i32.const_int(a))))
              else
                @ctx.int1.const_int(1)
              end
        slow = new_block("forslow#{pc}")
        go = new_block("forgo#{pc}")
        b.cond(need, slow, go)
        b.position_at_end(slow)
        st = call_fp(:loopedge, [@interp, @base, @i32.const_int(a)])
        weak = new_block("forweak#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::NE, st, @i32.const_int(0)), weak, go)
        b.position_at_end(weak)
        d = call_fp(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
        b.ret(d)
        b.position_at_end(go)
        store_num(slot(a), ctrl)
        @nums[a] = ctrl
        b.br(@blocks[dest(pc, off)])
        b.position_at_end(exit_b)
        br_next(pc)
      end

      # unchecked number load (FORPREP guarantees the tag)
      def load_num_raw(r : Int32) : LLVM::Value
        v = load_slot(r)
        b.bit_cast(b.extract_value(v, 1), @f64)
      end

      private def emit_call(pc : Int32, a : Int32, bcount : Int32, want_v : Int32) : Nil        b = @b
        if bcount >= 0 && Compiler::FAST_CALL
          emit_call_fast(pc, a, bcount, want_v)
          return
        end
        argn = bcount == -1 ? b.sub(b.load(@i32, @cur_top), b.add(@base, @i32.const_int(a + 1))) : @i32.const_int(bcount)
        newstk = call_fp(:dispatch,
          [@interp, @base, @i32.const_int(a), argn, @i32.const_int(want_v), @status_p])
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
      # missing fixed results nil-filled here.
      private def emit_call_fast(pc : Int32, a : Int32, argn : Int32, want_v : Int32) : Nil
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
        kill_all
        br_next(pc)
        b.position_at_end(slow)
        newstk = call_fp(:dispatch,
          [@interp, @base, @i32.const_int(a), @i32.const_int(argn), @i32.const_int(want_v), @status_p])
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
        br_next(pc)
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
        if @nums[br]?
          # R[B] proven numeric — cannot be a table; getindex on a number
          # (error/metamethod) is the helper's job
          call_fp(:gettable, [@interp, @clp, @base, @i32.const_int(pc),
            @i32.const_int(a), @i32.const_int(br), @i32.const_int(cr), slot(a)])
          br_next(pc)
          return
        end
        slow = new_block("gtslow#{pc}")
        vb = load_slot(br)
        ok = new_block("gt#{pc}tab")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vb, 0),
          @i32.const_int(Layout.tag_table)), ok, slow)
        b.position_at_end(ok)
        tbl = payload_ptr(vb)
        mt = b.load(@i64, tbl_fld(tbl, Layout.tbl_mt))
        ok = new_block("gt#{pc}mt")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, mt, @i64.const_int(0)), ok, slow)
        b.position_at_end(ok)
        kf = if v = @nums[cr]?
               v # provenance guarantees the number tag
             else
               vc = load_slot(cr)
               ok = new_block("gt#{pc}num")
               b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vc, 0),
                 @i32.const_int(Layout.tag_num)), ok, slow)
               b.position_at_end(ok)
               b.bit_cast(b.extract_value(vc, 1), @f64)
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
        bufp = b.load(@lv_ptr, tbl_fld(tbl, Layout.tbl_buf))
        v = b.load(@lv, b.gep(@lv, bufp, b.sub(k32, ab)))
        # nil slot = hole, but the hash part may still hold the key → helper
        ok = new_block("gt#{pc}hit")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(v, 0), @i32.const_int(0)),
          slow, ok)
        b.position_at_end(ok)
        b.store(v, slot(a))
        br_next(pc)
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
        if @nums[a]?
          # R[A] proven numeric — cannot be a table (setindex on a number
          # raises or fires metamethods — helper)
          call_fp(:settable, [@interp, @clp, @base, @i32.const_int(pc),
            @i32.const_int(a), @i32.const_int(br), @i32.const_int(cr)])
          br_next(pc)
          return
        end
        slow = new_block("stslow#{pc}")
        vt = load_slot(a)
        ok = new_block("st#{pc}tab")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vt, 0),
          @i32.const_int(Layout.tag_table)), ok, slow)
        b.position_at_end(ok)
        tbl = payload_ptr(vt)
        mt = b.load(@i64, tbl_fld(tbl, Layout.tbl_mt))
        ok = new_block("st#{pc}mt")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, mt, @i64.const_int(0)), ok, slow)
        b.position_at_end(ok)
        kf = if v = @nums[br]?
               v
             else
               vb = load_slot(br)
               ok = new_block("st#{pc}num")
               b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vb, 0),
                 @i32.const_int(Layout.tag_num)), ok, slow)
               b.position_at_end(ok)
               b.bit_cast(b.extract_value(vb, 1), @f64)
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
        # nil store must update @len_cache (raw_set: k-1 if k <= cache) —
        # route it to the helper; nil writes are cold in hot loops
        vv = load_slot(cr)
        ok = new_block("st#{pc}nn")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vv, 0), @i32.const_int(0)),
          slow, ok)
        b.position_at_end(ok)
        bufp = b.load(@lv_ptr, tbl_fld(tbl, Layout.tbl_buf))
        b.store(vv, b.gep(@lv, bufp, b.sub(k32, ab)))
        br_next(pc)
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
        slow = new_block("sgtslow#{pc}")
        vb = load_slot(br)
        ok = new_block("sgt#{pc}tab")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vb, 0),
          @i32.const_int(Layout.tag_table)), ok, slow)
        b.position_at_end(ok)
        tbl = payload_ptr(vb)
        mt = b.load(@i64, tbl_fld(tbl, Layout.tbl_mt))
        ok = new_block("sgt#{pc}mt")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, mt, @i64.const_int(0)), ok, slow)
        b.position_at_end(ok)
        valp, miss = str_probe_begin(pc, tbl, kaddr, "sgt")
        v = b.load(@lv, valp)
        b.store(v, slot(a))
        br_next(pc)
        b.position_at_end(miss)
        b.br(slow)
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
        slow = new_block("sstslow#{pc}")
        vt = load_slot(a)
        ok = new_block("sst#{pc}tab")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(vt, 0),
          @i32.const_int(Layout.tag_table)), ok, slow)
        b.position_at_end(ok)
        tbl = payload_ptr(vt)
        mt = b.load(@i64, tbl_fld(tbl, Layout.tbl_mt))
        ok = new_block("sst#{pc}mt")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, mt, @i64.const_int(0)), ok, slow)
        b.position_at_end(ok)
        vv = load_slot(cr)
        ok = new_block("sst#{pc}nn")
        b.cond(b.icmp(LLVM::IntPredicate::NE, b.extract_value(vv, 0),
          @i32.const_int(0)), ok, slow)
        b.position_at_end(ok)
        valp, miss = str_probe_begin(pc, tbl, kaddr, "sst")
        b.store(vv, valp)
        br_next(pc)
        b.position_at_end(miss)
        b.br(slow)
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
        slow = new_block("slfslow#{pc}")
        obj = load_slot(bb)
        ok = new_block("slf#{pc}tab")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, b.extract_value(obj, 0),
          @i32.const_int(Layout.tag_table)), ok, slow)
        b.position_at_end(ok)
        tbl = payload_ptr(obj)
        mt = b.load(@i64, tbl_fld(tbl, Layout.tbl_mt))
        ok = new_block("slf#{pc}mt")
        b.cond(b.icmp(LLVM::IntPredicate::EQ, mt, @i64.const_int(0)), ok, slow)
        b.position_at_end(ok)
        valp, miss = str_probe_begin(pc, tbl, kaddr, "slf")
        b.store(obj, slot(a + 1))
        b.store(b.load(@lv, valp), slot(a))
        br_next(pc)
        b.position_at_end(miss)
        b.br(slow)
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
      # ((addr * 0x9E3779B97F4A7C15) >> 32) & mask; 3 slots probed inline,
      # misses/empties fall through to `miss`.
      private def str_probe_begin(pc : Int32, tbl : LLVM::Value, kaddr : UInt64,
                                  tag : String) : {LLVM::Value, LLVM::BasicBlock}
        b = @b
        smask = b.load(@i32, tbl_fld(tbl, Layout.tbl_smask))
        has = new_block("#{tag}#{pc}has")
        miss = new_block("#{tag}#{pc}miss")
        b.cond(b.icmp(LLVM::IntPredicate::NE, smask, @i32.const_int(0)), has, miss)
        b.position_at_end(has)
        sbuf = b.load(@ptr, tbl_fld(tbl, Layout.tbl_slots))
        home32 = ((kaddr &* 0x9E3779B97F4A7C15_u64) >> 32).to_i32!
        kptr = int2ptr(@i64.const_int(kaddr.to_i64!))
        hit = new_block("#{tag}#{pc}hit")
        blocks = [] of LLVM::BasicBlock
        slots = [] of LLVM::Value
        3.times do |t|
          idx = b.and(b.add(@i32.const_int(home32 + t), smask), smask)
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

      private def new_block(name : String) : LLVM::BasicBlock
        f = @blocks[0].parent.not_nil!
        f.basic_blocks.append(name)
      end

      private def br_next(pc : Int32) : Nil
        if pc + 1 < @blocks.size
          @b.br(@blocks[pc + 1])
        else
          @b.ret(@i32.const_int(0))
        end
      end

      # Backward jump (loop back-edge): with weak tables around, deopt —
      # the interpreter's back-edge handlers drive the Lua-graph GC, and a
      # loop can be *waiting* for a weak-table sweep that only gc_full
      # performs (repeat-until compiles to a backward JMPF, so all three
      # jump ops take this guard). The weak flag load is inlined: the
      # static byte is monotonic (never cleared), so flag==0 makes the
      # helper call unnecessary.
      private def backedge(pc : Int32, off : Int32) : Nil
        return if off >= 0
        b = @b
        weak = Compiler::INLINE_EDGE ? weak_seen(b) : @ctx.int1.const_int(1)
        slow = new_block("jmpweak#{pc}")
        go = new_block("jmpgo#{pc}")
        b.cond(weak, slow, go)
        b.position_at_end(slow)
        st = call_fp(:weakcheck, [@interp])
        still = new_block("jmpweak2#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::NE, st, @i32.const_int(0)), still, go)
        b.position_at_end(still)
        d = call_fp(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
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
        st = call_fp(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
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
        dispatch:   {[ptr, i32, i32, i32, i32, ptr.pointer], lv_ptr, "jit_dispatch_call"},
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
        weakcheck:  {[ptr], i32, "jit_weakcheck"},
        loopedge:   {[ptr, i32, i32], i32, "jit_loopedge"},
      }
      helpers = {} of Symbol => LLVM::Function
      helper_types = {} of Symbol => LLVM::Type
      sigs.each do |key, sig|
        helpers[key] = mod.functions.add(sig[2], sig[0], sig[1])
        helper_types[key] = LLVM::Type.function(sig[0], sig[1])
      end

      Gen.new(cl, ctx, f, helpers, helper_types, blocks, entry, f.params[1], @@osr_heads, @@preds).run
    end
  end
end
