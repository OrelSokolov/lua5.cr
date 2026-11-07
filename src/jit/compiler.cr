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

    @@probed = false

    def self.probe! : Nil
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
      o = tbl.probe_offsets
      @@tbl_mt = o[:mt]
      @@tbl_buf = o[:buf]
      @@tbl_base = o[:base]
      @@tbl_len = o[:len]
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
    # OSR entry points and block predecessor counts of the proto being
    # compiled (see compile)
    @@osr_heads = Set(Int32).new
    @@preds = [] of Int32
    # Keep-alives: ORC code and its context must outlive the closures
    # pointing into it; the Crystal GC would free them otherwise.
    @@keep = [] of LLVM::Orc::ThreadSafeContext

    # Compile `cl`; returns the machine-code entry or nil (unsupported).
    def self.compile(cl : LuaClosure) : Pointer(Void)?
      Layout.probe!
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
      gen(cl, ctx, mod, sym)
      mod.verify

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
          @nums.clear if (@preds[pc]? || 0) > 1
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
            @nums.delete(r)
            r += 1
          end
          br_next(pc)
        when .loadbool?
          store_scalar(slot(a), @i32.const_int(Layout.tag_bool), @i64.const_int(bb != 0 ? 1 : 0))
          @nums.delete(a)
          br_next(pc)
        when .move?
          # numeric provenance travels with the value
          if v = @nums[bb]?
            @nums[a] = v
          else
            @nums.delete(a)
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
          br_next(pc)
        when .unm?
          v = guard_num(pc, bb)
          res = b.fneg(v)
          store_num(slot(a), res)
          @nums[a] = res
          br_next(pc)
        when .not?
          t = truthy(bb)
          store_bool(slot(a), b.not(t))
          @nums.delete(a)
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
          @nums.delete(a)
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
          emit_gettable(pc, a, bb, cc)
        when .settable?
          emit_settable(pc, a, bb, cc)
        when .self?
          call_fp(:self, [@interp, @clp, @base, @i32.const_int(pc),
            @i32.const_int(a), @i32.const_int(bb), @i32.const_int(cc), slot(a)])
          br_next(pc)
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
          @nums.delete(a)
        when String
          # proto.consts keeps the string alive (closure -> proto -> consts);
          # Boehm is non-moving, so the object pointer is stable. NOTE: the
          # union payload holds the String OBJECT address, not char*.
          store_scalar(slot(a), @i32.const_int(Layout.tag_str), @i64.const_int(k.as(Void*).address.to_i64!))
          @nums.delete(a)
        else
          store_scalar(slot(a), @i32.const_int(0), @i64.const_int(0))
          @nums.delete(a)
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
      # upvalues via the helper; weak tables active -> deopt so the
      # interpreter drives its loop-edge GC (ctrl not yet stored, the
      # re-run is exact).
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
        st = call_fp(:loopedge, [@interp, @base, @i32.const_int(a)])
        weak = new_block("forweak#{pc}")
        go = new_block("forgo#{pc}")
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
        @nums.clear
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
        @nums.clear
      end

      # --- building blocks ---

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
      # jump ops take this guard).
      private def backedge(pc : Int32, off : Int32) : Nil
        return if off >= 0
        b = @b
        st = call_fp(:weakcheck, [@interp])
        weak = new_block("jmpweak#{pc}")
        go = new_block("jmpgo#{pc}")
        b.cond(b.icmp(LLVM::IntPredicate::NE, st, @i32.const_int(0)), weak, go)
        b.position_at_end(weak)
        d = call_fp(:deopt, [@interp, @clp, @base, @i32.const_int(pc), @want])
        b.ret(d)
        b.position_at_end(go)
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
        @nums.clear
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
