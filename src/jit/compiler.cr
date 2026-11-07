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
          # Boehm is non-moving, so the raw pointer is stable
          store_scalar(slot(a), @i32.const_int(Layout.tag_str), @i64.const_int(k.to_unsafe.as(Void*).address.to_i64!))
        else
          store_scalar(slot(a), @i32.const_int(0), @i64.const_int(0))
        end
        br_next(pc)
      end

      private def emit_call(pc : Int32, a : Int32, bcount : Int32, want_v : Int32) : Nil
        b = @b
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

      helpers = {} of Symbol => LLVM::Function
      helpers[:deopt] = mod.functions.add("jit_deopt", [ptr, ptr, i32, i32, i32], i32)
      helpers[:dispatch] = mod.functions.add("jit_dispatch_call", [ptr, i32, i32, i32, i32, ptr.pointer], lv_ptr)
      helpers[:getupval] = mod.functions.add("jit_getupval", [ptr, i32, lv_ptr], ctx.void)
      helpers[:mod_fn] = mod.functions.add("jit_mod", [f64, f64], f64)
      helpers[:pow] = mod.functions.add("jit_pow", [f64, f64], f64)
      # LLVM 15+ opaque pointers: call sites must pass the function type
      # explicitly (Function#function_type is broken), so keep it alongside
      helper_types = {} of Symbol => LLVM::Type
      { {:deopt,    [ptr, ptr, i32, i32, i32], i32},
        {:dispatch, [ptr, i32, i32, i32, i32, ptr.pointer], lv_ptr},
        {:getupval, [ptr, i32, lv_ptr], ctx.void},
        {:mod_fn,   [f64, f64], f64},
        {:pow,      [f64, f64], f64},
      }.each do |key, argts, rett|
        helper_types[key] = LLVM::Type.function(argts, rett)
      end

      Gen.new(cl, ctx, f, helpers, helper_types, blocks, entry, f.params[1]).run
    end
  end
end
