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

    @@probed = false

    def self.probe! : Nil
      return if @@probed
      buf = Pointer(LuaValue).malloc(4)
      buf[0] = 1.5
      buf[1] = true
      buf[3] = "x"
      tags = buf.as(Pointer(Int32))
      @@tag_num = tags[0]
      @@tag_bool = tags[4]
      @@tag_str = tags[12]
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
    # Keep-alives: ORC code and its context must outlive the closures
    # pointing into it; the Crystal GC would free them otherwise.
    @@keep = [] of LLVM::Orc::ThreadSafeContext

    # Compile `cl`; returns the machine-code entry or nil (unsupported).
    def self.compile(cl : LuaClosure) : Pointer(Void)?
      Layout.probe!
      p = cl.proto
      return nil if p.vararg? || p.needs_arg?
      return nil if p.code.size > 4096 # M1 sanity cap

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

      def initialize(@cl, @ctx : LLVM::Context, f : LLVM::Function,
                     @helpers : Hash(Symbol, LLVM::Function),
                     @helper_types : Hash(Symbol, LLVM::Type), @blocks,
                     entry : LLVM::BasicBlock, stack0 : LLVM::Value)
        @b = @ctx.new_builder
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
        b.store(b.add(@base, b.add(f.params[4], @i32.const_int(1))), @cur_top)
        b.br(@blocks[0])
      end

      def run : Nil
        n = @code.size
        pc = 0
        while pc < n
          @b.position_at_end(@blocks[pc])
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
            r += 1
          end
          br_next(pc)
        when .loadbool?
          store_scalar(slot(a), @i32.const_int(Layout.tag_bool), @i64.const_int(bb != 0 ? 1 : 0))
          br_next(pc)
        when .move?
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
                when .mod? then call_fp(:mod_fn, [l, r])
                else            call_fp(:pow, [l, r])
                end
          store_num(slot(a), res)
          br_next(pc)
        when .unm?
          v = guard_num(pc, bb)
          store_num(slot(a), b.fneg(v))
          br_next(pc)
        when .not?
          t = truthy(bb)
          store_bool(slot(a), b.not(t))
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
          br_next(pc)
        when .jmp?
          b.br(@blocks[dest(pc, bb)])
        when .jmpf?
          b.cond(truthy(a), @blocks[pc + 1], @blocks[dest(pc, bb)])
        when .jmpt?
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
          call_fp(:gettable, [@interp, @clp, @base, @i32.const_int(pc),
            @i32.const_int(a), @i32.const_int(bb), @i32.const_int(cc), slot(a)])
          br_next(pc)
        when .settable?
          call_fp(:settable, [@interp, @clp, @base, @i32.const_int(pc),
            @i32.const_int(a), @i32.const_int(bb), @i32.const_int(cc)])
          br_next(pc)
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
        when Bool
          store_scalar(slot(a), @i32.const_int(Layout.tag_bool), @i64.const_int(k ? 1 : 0))
        when String
          # proto.consts keeps the string alive (closure -> proto -> consts);
          # Boehm is non-moving, so the object pointer is stable. NOTE: the
          # union payload holds the String OBJECT address, not char*.
          store_scalar(slot(a), @i32.const_int(Layout.tag_str), @i64.const_int(k.as(Void*).address.to_i64!))
        else
          store_scalar(slot(a), @i32.const_int(0), @i64.const_int(0))
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
        store_num(slot(a), b.fsub(v0, v2))
        store_num(slot(a + 1), v1)
        store_num(slot(a + 2), v2)
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

      # truthiness of register r (nil tag 0 / bool with payload 0)
      def truthy(r : Int32) : LLVM::Value
        b = @b
        v = load_slot(r)
        tag = b.extract_value(v, 0)
        isnil = b.icmp(LLVM::IntPredicate::EQ, tag, @i32.const_int(0))
        isbool = b.icmp(LLVM::IntPredicate::EQ, tag, @i32.const_int(Layout.tag_bool))
        isfalse = b.icmp(LLVM::IntPredicate::EQ, b.extract_value(v, 1), @i64.const_int(0))
        b.not(b.or(isnil, b.and(isbool, isfalse)))
      end

      # load register r as f64; on a non-number tag deopt at `pc` (the
      # interpreter runs the rest of the function, results already placed)
      def guard_num(pc : Int32, r : Int32) : LLVM::Value
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
        b.bit_cast(b.extract_value(v, 1), @f64)
      end

      def call_fp(key : Symbol, args : Array(LLVM::Value)) : LLVM::Value
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

      f = mod.functions.add(sym, [ptr, lv_ptr, ptr, i32, i32, i32], i32)
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
        loopedge:   {[ptr, i32, i32], i32, "jit_loopedge"},
      }
      helpers = {} of Symbol => LLVM::Function
      helper_types = {} of Symbol => LLVM::Type
      sigs.each do |key, sig|
        helpers[key] = mod.functions.add(sig[2], sig[0], sig[1])
        helper_types[key] = LLVM::Type.function(sig[0], sig[1])
      end

      Gen.new(cl, ctx, f, helpers, helper_types, blocks, entry, f.params[1]).run
    end
  end
end
