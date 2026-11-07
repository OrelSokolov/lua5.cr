# Bytecode VM: AST → Proto compiler (port of lua's lparser/lcode emission
# stage) + the register-machine dispatch loop (port of MoonSharp Execution/Vm,
# which mirrors lvm.c). Semantics follow the tree interpreter it replaced:
# per-iteration loop variables, proper tail calls, upvalues closed at scope
# exit.

module Lua
  class Compiler
    @fs : FuncState? = nil
    # String pool: identical string constants across protos share one
    # instance, so runtime hash lookups hit String#=='s same? fast path
    # instead of memcmp (PUC Lua's short-string interning, compile-time).
    @strings = Hash(String, String).new

    def initialize(@chunkname : String, @src : String = "")
      @line = 0
    end

    class Scope
      property start_reg : Int32
      property? captured = false

      def initialize(@start_reg)
      end
    end

    class LocalVar
      getter name : String
      getter scope : Scope
      getter reg : Int32
      # Matching debug entry in Proto#loc_vars; end_pc patched at scope close.
      getter dbg : LocVar

      def initialize(@name, @scope, @reg, @dbg)
      end
    end

    class LoopInfo
      property breaks = [] of Int32
      getter min_reg : Int32
      getter captures0 : Int32

      def initialize(@min_reg, @captures0)
      end
    end

    class FuncState
      property proto : Proto
      property parent : FuncState?
      property scopes = [] of Scope
      property locals = [] of LocalVar
      property freereg : Int32 = 1
      property loops = [] of LoopInfo
      property n_captures : Int32 = 0
      # true when the body mentions `...` (clears the implicit `arg`)
      property? uses_vararg = false
      # true when a bare-local LOADNIL landed at pc==0; its line is
      # re-attributed at func close (see compile_func)
      property? nil0_patch = false

      def initialize(@parent, @proto)
      end

      def find_local(name : String) : LocalVar?
        i = @locals.size - 1
        while i >= 0
          return @locals[i] if @locals[i].name == name
          i -= 1
        end
        nil
      end
    end

    def compile_main(block : AST::Block) : Proto
      p = Proto.new(@chunkname)
      p.vararg = true
      p.linedefined = 0
      p.src = @src
      fs = FuncState.new(nil, p)
      @fs = fs
      block_scope(block)
      # 5.1 luaY_parser: the implicit RETURN of the main chunk carries the
      # line of its last token (activelines/line hooks see it)
      @line = block.end_line if block.end_line > 0
      emit(Op::RETURN, 0, 0)
      # re-attribute a first-instruction bare-local LOADNIL (see
      # compile_explist) to the next instruction's line
      p.lines[0] = p.lines[1] if fs.nil0_patch? && p.code.size > 1
      pack(p)
      p
    end

    # Execution encoding: op | a<<8 | b<<24 | c<<44 (a signed 16, b/c 20).
    private def pack(p : Proto) : Nil
      packed = Array(UInt64).new(p.code.size)
      p.code.each do |i|
        w = i.op.value.to_u64!
        w |= (i.a & 0xFFFF).to_u64! << 8
        w |= (i.b & 0xFFFFF).to_u64! << 24
        w |= (i.c & 0xFFFFF).to_u64! << 44
        packed << w
      end
      p.packed = packed
      p.protos.each { |child| pack(child) }
    end

    private def fs : FuncState
      @fs.not_nil!
    end

    private def emit(op : Op, a : Int32 = 0, b : Int32 = 0, c : Int32 = 0) : Int32
      p = fs.proto
      p.code << Inst.new(op, a, b, c)
      p.lines << @line
      p.code.size - 1
    end

    # Register bookkeeping: mark `r` (and everything below it) as in use.
    private def use_reg(r : Int32) : Nil
      f = fs
      f.freereg = r + 1 if r >= f.freereg
      ms = f.freereg
      f.proto.max_stack = ms if ms > f.proto.max_stack
    end

    private def push_scope : Scope
      s = Scope.new(fs.freereg)
      fs.scopes << s
      s
    end

    # End of a block: free its registers, drop its locals, and CLOSE its
    # captured locals so closures keep the value at this point (registers
    # are reused after the block).
    private def pop_scope : Nil
      f = fs
      s = f.scopes.pop
      emit(Op::CLOSE, s.start_reg) if s.captured?
      # Close the debug live ranges of the dropped locals (5.1 leaveblock).
      f.locals.each { |l| l.dbg.end_pc = f.proto.code.size if l.reg >= s.start_reg }
      f.locals.reject! { |l| l.reg >= s.start_reg }
      f.freereg = s.start_reg
    end

    private def block_scope(block : AST::Block) : Nil
      push_scope
      block.stats.each { |st| compile_stat(st) }
      pop_scope
    end

    # --- variable resolution ---

    private def add_local(name : String, reg : Int32) : Nil
      p = fs.proto
      if fs.locals.size >= 200
        syntax_err("function at line #{p.linedefined} has more than 200 local variables")
      end
      lv = LocVar.new(name, reg, p.code.size, p.code.size)
      p.loc_vars << lv
      fs.locals << LocalVar.new(name, fs.scopes.last, reg, lv)
    end

    # Resolve `name` as an upvalue of `f`, recursing through enclosing
    # functions and marking captured scopes (for CLOSE emission).
    private def resolve_upval(f : FuncState, name : String) : Int32?
      if parent = f.parent
        if l = parent.find_local(name)
          l.scope.captured = true
          parent.n_captures += 1
          return add_upval(f, name, true, l.reg)
        end
        if idx = resolve_upval(parent, name)
          return add_upval(f, name, false, idx)
        end
      end
      nil
    end

    private def add_upval(f : FuncState, name : String, from_stack : Bool, index : Int32) : Int32
      f.proto.upvals.each_with_index do |u, i|
        return i if u.name == name
      end
      if f.proto.upvals.size >= 60
        syntax_err("function at line #{f.proto.linedefined} has more than 60 upvalues")
      end
      f.proto.upvals << UpvalDesc.new(name, from_stack, index)
      f.proto.upvals.size - 1
    end

    private def konst(v : LuaValue) : Int32
      if v.is_a?(String)
        pooled = @strings[v]?
        if pooled.nil?
          @strings[v] = v
        else
          v = pooled
        end
      end
      p = fs.proto
      p.consts.each_with_index do |k, i|
        return i if k == v
      end
      p.consts << v
      p.consts.size - 1
    end

    private def emit_jump(op : Op, a : Int32 = 0) : Int32
      emit(op, a)
    end

    # Make the jump at `site` land on `target`.
    private def patch(site : Int32, target : Int32) : Nil
      code = fs.proto.code
      ins = code[site]
      ins.b = target - site - 1
      code[site] = ins
    end

    private def patch_to_here(site : Int32) : Nil
      patch(site, fs.proto.code.size)
    end

    private def syntax_err(msg : String)
      raise SyntaxError.new(@line, "#{@chunkname}:#{@line}: #{msg}")
    end

    # --- statements ---

    private def compile_stat(s : AST::Stat) : Nil
      @line = s.line
      case s
      when AST::LocalStat
        f = fs
        base = f.freereg
        compile_explist(s.exps, base, s.names.size)
        s.names.each_with_index do |n, i|
          add_local(n, base + i)
        end
        f.freereg = base + s.names.size
      when AST::AssignStat
        f = fs
        base = f.freereg
        n = s.targets.size
        compile_explist(s.exps, base, n)
        # pre-evaluate every index target's table/key before any store: a
        # simple-variable assignment earlier in the list must not change
        # how later index targets resolve (5.1 restassign)
        tgt = [] of {Int32, Int32}
        s.targets.each do |t|
          if t.is_a?(AST::IndexE)
            r = f.freereg
            use_reg(r)
            @line = t.line
            expr(t.obj, r)
            use_reg(r + 1)
            expr(t.key, r + 1)
            tgt << {r, r + 1}
          else
            tgt << {-1, -1}
          end
        end
        s.targets.each_with_index do |t, i|
          case t
          when AST::NameE then assign_name(t.name, base + i)
          when AST::IndexE
            r, kr = tgt[i]
            emit(Op::SETTABLE, r, kr, base + i)
          else
            syntax_err("internal: bad assignment target")
          end
        end
        f.freereg = base
      when AST::ExprStat
        base = fs.freereg
        expr(s.e, base, 0)
        fs.freereg = base
      when AST::DoStat
        block_scope(s.block)
      when AST::IfStat
        ends = [] of Int32
        s.clauses.each do |cond, blk|
          f = fs
          r = f.freereg
          use_reg(r)
          expr(cond, r)
          f.freereg = r
          jf = emit_jump(Op::JMPF, r)
          block_scope(blk)
          ends << emit_jump(Op::JMP)
          patch_to_here(jf)
        end
        if eb = s.else_block
          block_scope(eb)
        end
        ends.each { |j| patch_to_here(j) }
      when AST::WhileStat
        f = fs
        loop_start = f.proto.code.size
        cap0 = f.n_captures
        r = f.freereg
        use_reg(r)
        expr(s.cond, r)
        f.freereg = r
        jf = emit_jump(Op::JMPF, r)
        body = push_scope
        loop_info = LoopInfo.new(body.start_reg, cap0)
        f.loops << loop_info
        s.block.stats.each { |st| compile_stat(st) }
        pop_scope # back-edge CLOSE for captured body locals
        jb = emit_jump(Op::JMP)
        patch(jb, loop_start)
        exit_pos = maybe_close_loop(f, body.start_reg)
        patch_to_here(jf)
        loop_info.breaks.each { |br| patch(br, exit_pos) }
        f.loops.pop
      when AST::RepeatStat
        f = fs
        cap0 = f.n_captures
        scope = push_scope
        f.loops << LoopInfo.new(scope.start_reg, cap0)
        loop_start = f.proto.code.size
        s.block.stats.each { |st| compile_stat(st) }
        r = f.freereg
        use_reg(r)
        expr(s.cond, r)
        f.freereg = r
        emit(Op::CLOSE, scope.start_reg) if scope.captured? # back edge
        # repeat-until: loop again while the condition is FALSE
        jf = emit_jump(Op::JMPF, r)
        patch(jf, loop_start)
        pre_exit = f.proto.code.size
        pop_scope # exit-path CLOSE (break target) + scope teardown
        f.loops.last.breaks.each { |br| patch(br, pre_exit) }
        f.loops.pop
      when AST::NumForStat
        f = fs
        r = f.freereg
        use_reg(r)
        expr(s.start_e, r)
        use_reg(r + 1)
        expr(s.limit_e, r + 1)
        use_reg(r + 2)
        if step = s.step_e
          expr(step, r + 2)
        else
          emit(Op::LOADK, r + 2, konst(1.0))
        end
        f.freereg = r + 3
        push_scope
        add_local(s.name, r)
        cap0 = f.n_captures
        f.loops << LoopInfo.new(r, cap0)
        fp = emit(Op::FORPREP, r)
        body_start = f.proto.code.size
        block_scope(s.block)
        fl = emit(Op::FORLOOP, r)
        # 5.1 luaK_fixline: the loop-back op is attributed to the `for`
        # line ("pretend OP_FOR starts the loop") — line hooks expect it
        f.proto.lines[fl] = s.line
        patch(fl, body_start)
        exit_pos = maybe_close_loop(f, r)
        # 5.1: FORPREP jumps over the body TO the loop test (FORLOOP);
        # the first body entry is a backward jump, which line hooks fire
        patch(fp, fl)
        f.loops.last.breaks.each { |br| patch(br, exit_pos) }
        f.loops.pop
        pop_scope
      when AST::GenForStat
        f = fs
        r = f.freereg
        nvars = s.names.size
        compile_explist(s.exps, r, 3)
        # 5.1 luaK_fixline: the loop-control instruction is attributed to the
        # line of the iterator explist's last expression, not `end`
        for_line = @line
        use_reg(r + 3 + nvars - 1)
        push_scope
        s.names.each_with_index do |n, i|
          add_local(n, r + 3 + i)
        end
        cap0 = f.n_captures
        f.loops << LoopInfo.new(r, cap0)
        first = emit_jump(Op::JMP)
        body_start = f.proto.code.size
        block_scope(s.block)
        patch_to_here(first)
        tf = emit(Op::TFORCALL, r, 0, nvars)
        # the loop-control instruction runs "at" the `for` line (5.1
        # luaK_fixline), not at the end of the body where it is emitted
        f.proto.lines[tf] = for_line
        patch(tf, body_start)
        exit_pos = maybe_close_loop(f, r)
        f.loops.last.breaks.each { |br| patch(br, exit_pos) }
        f.loops.pop
        pop_scope
      when AST::FuncStat
        compile_funcstat(s)
      when AST::LocalFuncStat
        r = fs.freereg
        use_reg(r)
        add_local(s.name, r)
        pi = compile_func(s.func)
        emit(Op::CLOSURE, r, pi)
      when AST::ReturnStat
        compile_return(s)
      when AST::BreakStat
        if fs.loops.empty?
          syntax_err("break outside a loop")
        else
          fs.loops.last.breaks << emit_jump(Op::JMP)
        end
      else
        syntax_err("internal: unknown statement #{s.class}")
      end
    end

    # At a loop exit: emit CLOSE over the loop's registers iff any local
    # inside the loop was captured (break jumps out of scopes, skipping
    # their own CLOSE). Returns the instruction to jump to.
    private def maybe_close_loop(f : FuncState, min_reg : Int32) : Int32
      if f.n_captures > f.loops.last.captures0
        emit(Op::CLOSE, min_reg)
      else
        f.proto.code.size
      end
    end

    private def assign_name(name : String, src_reg : Int32) : Nil
      f = fs
      if l = f.find_local(name)
        emit(Op::MOVE, l.reg, src_reg) unless l.reg == src_reg
      elsif u = resolve_upval(f, name)
        emit(Op::SETUPVAL, src_reg, u)
      else
        emit(Op::SETGLOBAL, src_reg, konst(name))
      end
    end

    private def compile_funcstat(s : AST::FuncStat) : Nil
      f = fs
      pi = compile_func(s.func)
      r = f.freereg
      use_reg(r)
      emit(Op::CLOSURE, r, pi)
      target = s.target
      case target
      when AST::NameE
        assign_name(target.name, r)
        f.freereg = r
      when AST::IndexE
        # FuncStat line: IndexE itself carries no line, and compile_func
        # above has already clobbered @line with the body's
        @line = s.line
        keys = [] of AST::Expr
        o = target.as(AST::Expr)
        while o.is_a?(AST::IndexE)
          keys.unshift(o.key)
          o = o.obj
        end
        t = f.freereg
        use_reg(t)
        expr(o, t)
        keys[0..-2].each do |k|
          kr = f.freereg
          use_reg(kr)
          expr(k, kr)
          emit(Op::GETTABLE, t, t, kr)
          f.freereg = kr
        end
        kr = f.freereg
        use_reg(kr)
        expr(keys.last, kr)
        emit(Op::SETTABLE, t, kr, r)
        f.freereg = t
      else
        syntax_err("internal: bad function target")
      end
    end

    private def compile_return(s : AST::ReturnStat) : Nil
      if s.tail
        e = s.exps[0]
        base = fs.freereg
        if c = e.as?(AST::CallE)
          expr(c.fn, base)
          b = compile_args(c.args, base + 1)
          emit(Op::TAILCALL, base, b)
        else
          m = e.as(AST::MethodCallE)
          r = fs.freereg
          use_reg(r)
          expr(m.obj, r)
          emit(Op::SELF, base, r, konst(m.name))
          fs.freereg = r
          b = compile_args(m.args, base + 2)
          b = b == -1 ? -1 : b + 1
          emit(Op::TAILCALL, base, b)
        end
        fs.freereg = base
      elsif s.exps.empty?
        emit(Op::RETURN, fs.freereg, 0)
      else
        base = fs.freereg
        m = s.exps.size
        compile_explist(s.exps, base, -1)
        last = s.exps[m - 1]
        b = multi_expr?(last) ? -1 : m
        emit(Op::RETURN, base, b)
        fs.freereg = base
      end
    end

    # Compile an argument list at `base`; returns the CALL B operand:
    # -1 when the last argument expands to multiple values.
    private def compile_args(args : Array(AST::Expr), base : Int32) : Int32
      m = args.size
      args.each_with_index do |x, i|
        if i == m - 1 && multi_expr?(x)
          expr(x, base + i, -1)
          return -1
        end
        expr(x, base + i, 1)
      end
      m
    end

    # Compile an expression list at `base`. want == -1: keep all values
    # (a trailing multi-value expr extends top); want >= 0: exactly `want`
    # values (padded with nil / truncated).
    private def compile_explist(exps : Array(AST::Expr), base : Int32, want : Int32) : Nil
      m = exps.size
      if m == 0
        if want > 0
          use_reg(base + want - 1)
          # 5.1 luaK_nil skips a LOADNIL that would be the function's
          # very first instruction (the register window starts nil).
          # We always emit it (windows are not nil-filled at runtime)
          # but re-attribute its line to the next instruction so the
          # pc==0 line event matches 5.1's trace.
          fs.nil0_patch = true if fs.proto.code.empty?
          emit(Op::LOADNIL, base, want - 1)
        end
        return
      end
      exps.each_with_index do |x, i|
        if i == m - 1
          if multi_expr?(x)
            expr(x, base + i, want == -1 ? -1 : want - i)
          else
            expr(x, base + i, 1)
            if want >= 0 && want - i > 1
              emit(Op::LOADNIL, base + i + 1, want - i - 2)
            end
          end
        else
          expr(x, base + i, 1)
        end
      end
      fs.freereg = base + want if want >= 0
    end

    # Compile a nested function into a child Proto; returns its index in the
    # current function's protos. Called at the point of closure creation so
    # the enclosing scope state (visible locals) is exactly the lexical one.
    private def compile_func(e : AST::FuncE) : Int32
      parent = fs
      p = Proto.new(@chunkname)
      p.num_params = e.params.size
      p.vararg = e.vararg
      p.linedefined = e.line
      p.lastlinedefined = e.end_line
      p.src = @src
      nfs = FuncState.new(parent, p)
      nfs.freereg = 1
      save = @fs
      @fs = nfs
      @line = e.line
      push_scope # function scope: params live at R[1..np]
      e.params.each_with_index do |prm, i|
        add_local(prm, 1 + i)
      end
      use_reg(e.params.size)
      if e.vararg
        # 5.1 LUA_COMPAT_VARARG: implicit `arg` local right after the
        # params — but NOT if the body uses `...` (NEEDSARG is cleared)
        p.needs_arg = true
        add_local("arg", 1 + e.params.size)
        use_reg(1 + e.params.size)
      end
      block_scope(e.body)
      p.needs_arg = false if nfs.uses_vararg?
      pop_scope
      # 5.1 endfunc: the implicit RETURN is attributed to the `end` line
      # (activelines[lastlinedefined] must be set)
      @line = e.end_line
      emit(Op::RETURN, 0, 0)
      # re-attribute a first-instruction bare-local LOADNIL (see
      # compile_explist) to the next instruction's line
      p.lines[0] = p.lines[1] if nfs.nil0_patch? && p.code.size > 1
      @fs = save
      parent.proto.protos << p
      parent.proto.protos.size - 1
    end

    # --- expressions ---

    private def multi_expr?(e : AST::Expr) : Bool
      e.is_a?(AST::CallE) || e.is_a?(AST::MethodCallE) || e.is_a?(AST::VarargE)
    end

    # Compile `e` into register `dst`. nres: -1 = keep all values (only
    # meaningful for multi-value exprs, extends top), 0 = discard, n = exact.
    private def expr(e : AST::Expr, dst : Int32, nres : Int32 = 1) : Nil
      @line = e.line
      # Expressions that write a run of registers at dst.. need dst to be
      # at the top of the register window; compile via a temp + MOVE when
      # the caller reused an older register. A single-value call at
      # dst == freereg-1 is safe in place (the PUC layout), and BinopE
      # handles a reused dst itself (operands go to a temp).
      if dst < fs.freereg && ((multi_expr?(e) && (nres == -1 || dst < fs.freereg - 1)) || e.is_a?(AST::TableE))
        r = fs.freereg
        save = r
        expr(e, r, nres == -1 ? 1 : nres)
        fs.freereg = save
        emit(Op::MOVE, dst, r) unless dst == r
        return
      end
      use_reg(dst)
      case e
      when AST::NilE    then emit(Op::LOADNIL, dst, 0)
      when AST::TrueE   then emit(Op::LOADBOOL, dst, 1)
      when AST::FalseE  then emit(Op::LOADBOOL, dst, 0)
      when AST::NumE    then emit(Op::LOADK, dst, konst(e.val))
      when AST::StrE    then emit(Op::LOADK, dst, konst(e.val))
      when AST::ParenE  then expr(e.e, dst, nres == -1 ? 1 : nres)
      when AST::VarargE
        syntax_err("illegal use of '...'") unless fs.proto.vararg?
        fs.uses_vararg = true
        emit(Op::VARARG, dst, nres)
        fs.freereg = dst + 1
      when AST::NameE   then compile_name(e.name, dst)
      when AST::IndexE
        f = fs
        r = f.freereg
        use_reg(r)
        expr(e.obj, r)
        use_reg(r + 1)
        expr(e.key, r + 1)
        emit(Op::GETTABLE, dst, r, r + 1)
        f.freereg = r
      when AST::CallE, AST::MethodCallE then compile_call(e, dst, nres)
      when AST::BinopE then compile_binop(e, dst)
      when AST::UnopE  then compile_unop(e, dst)
      when AST::FuncE
        pi = compile_func(e)
        emit(Op::CLOSURE, dst, pi)
      when AST::TableE then compile_table(e, dst)
      else
        syntax_err("internal: unknown expression #{e.class}")
      end
    end

    private def compile_name(name : String, dst : Int32) : Nil
      if l = fs.find_local(name)
        emit(Op::MOVE, dst, l.reg) unless dst == l.reg
      elsif u = resolve_upval(fs, name)
        emit(Op::GETUPVAL, dst, u)
      else
        emit(Op::GETGLOBAL, dst, konst(name))
      end
    end

    private def compile_call(e : AST::CallE | AST::MethodCallE, dst : Int32, nres : Int32) : Nil
      if e.is_a?(AST::MethodCallE)
        r = fs.freereg
        use_reg(r)
        expr(e.obj, r)
        emit(Op::SELF, dst, r, konst(e.name))
        fs.freereg = r
        b = compile_args(e.args, dst + 2)
        b = b == -1 ? -1 : b + 1 # + self
      else
        expr(e.fn, dst)
        b = compile_args(e.args, dst + 1)
      end
      emit(Op::CALL, dst, b, nres)
      fs.freereg = dst + 1 # argument registers die at the call
    end

    private def compile_binop(e : AST::BinopE, dst : Int32) : Nil
      case e.op
      when "and"
        expr(e.lhs, dst)
        j = emit_jump(Op::JMPF, dst)
        expr(e.rhs, dst)
        patch_to_here(j)
      when "or"
        expr(e.lhs, dst)
        j = emit_jump(Op::JMPT, dst)
        expr(e.rhs, dst)
        patch_to_here(j)
      when ".."
        ops = [] of AST::Expr
        flatten_concat(e, ops)
        n = ops.size
        f = fs
        r = f.freereg
        use_reg(r + n - 1)
        ops.each_with_index { |x, i| expr(x, r + i) }
        emit(Op::CONCAT, r, r + n - 1)
        f.freereg = r
        emit(Op::MOVE, dst, r) unless dst == r
      when "==", "~=", "<", "<=", ">", ">="
        f = fs
        save = f.freereg
        # operands in place at dst when dst is the top free register
        # (statement level, the PUC luaK layout); a temp above the live
        # window when dst reuses an older register
        r = dst >= save - 1 ? dst : save
        expr(e.lhs, r)
        use_reg(r + 1)
        expr(e.rhs, r + 1)
        case e.op
        when "==" then emit(Op::EQ, dst, r, r + 1)
        when "~=" then emit(Op::NEQ, dst, r, r + 1)
        when "<"  then emit(Op::LT, dst, r, r + 1)
        when ">"  then emit(Op::LT, dst, r + 1, r)
        when "<=" then emit(Op::LE, dst, r, r + 1)
        when ">=" then emit(Op::LE, dst, r + 1, r)
        end
        f.freereg = {save, dst + 1}.max
      else
        # arithmetic, constant-folded when both sides are numeric literals
        if e.lhs.is_a?(AST::NumE) && e.rhs.is_a?(AST::NumE)
          a = e.lhs.as(AST::NumE).val
          b = e.rhs.as(AST::NumE).val
          v = case e.op
              when "+" then a + b
              when "-" then a - b
              when "*" then a * b
              when "/" then a / b
              when "%" then b == 0 ? Float64::NAN : a % b
              when "^" then a ** b
              else          syntax_err("internal: unknown arith op #{e.op}")
              end
          emit(Op::LOADK, dst, konst(v))
          return
        end
        f = fs
        save = f.freereg
        r = dst >= save - 1 ? dst : save
        expr(e.lhs, r)
        use_reg(r + 1)
        expr(e.rhs, r + 1)
        op = case e.op
             when "+" then Op::ADD
             when "-" then Op::SUB
             when "*" then Op::MUL
             when "/" then Op::DIV
             when "%" then Op::MOD
             when "^" then Op::POW
             else          syntax_err("internal: unknown arith op #{e.op}")
             end
        emit(op, dst, r, r + 1)
        f.freereg = {save, dst + 1}.max
      end
    end

    private def flatten_concat(e : AST::Expr, acc : Array(AST::Expr)) : Nil
      if e.is_a?(AST::BinopE) && e.op == ".."
        flatten_concat(e.lhs, acc)
        flatten_concat(e.rhs, acc)
      else
        acc << e
      end
    end

    private def compile_unop(e : AST::UnopE, dst : Int32) : Nil
      case e.op
      when "not"
        expr(e.e, dst)
        emit(Op::NOT, dst, dst)
      when "-"
        if n = e.e.as?(AST::NumE)
          emit(Op::LOADK, dst, konst(-n.val))
        else
          expr(e.e, dst)
          emit(Op::UNM, dst, dst)
        end
      when "#"
        expr(e.e, dst)
        emit(Op::LEN, dst, dst)
      else
        syntax_err("internal: unknown unop #{e.op}")
      end
    end

    private def compile_table(e : AST::TableE, dst : Int32) : Nil
      f = fs
      emit(Op::NEWTABLE, dst)
      narr = 0
      offset = 0
      last_idx = e.entries.size - 1
      e.entries.each_with_index do |en, idx|
        if k = en.key
          if narr > 0
            offset = flush_list(dst, narr, offset)
            narr = 0
          end
          r = f.freereg
          use_reg(r)
          expr(k, r)
          use_reg(r + 1)
          expr(en.val, r + 1)
          emit(Op::SETTABLE, dst, r, r + 1)
          f.freereg = r
        else
          v = en.val
          if idx == last_idx && multi_expr?(v)
            if narr > 0
              offset = flush_list(dst, narr, offset)
              narr = 0
            end
            # flushed array regs are dead: compile the multi-value field
            # directly at dst+1 (bypasses expr's temp+MOVE guard, which
            # would collapse it to one value)
            f.freereg = dst + 1
            expr(v, dst + 1, -1)
            emit(Op::SETLIST, dst, -1, offset)
          else
            narr += 1
            f.freereg = dst + narr # stored/freed array regs are dead too
            expr(v, dst + narr)
            if narr >= 50
              offset = flush_list(dst, narr, offset)
              narr = 0
            end
          end
        end
      end
      offset = flush_list(dst, narr, offset) if narr > 0
      f.freereg = dst + 1 # constructor registers die at the last SETLIST
    end

    private def flush_list(dst : Int32, n : Int32, offset : Int32) : Int32
      emit(Op::SETLIST, dst, n, offset)
      offset + n
    end
  end

  # --- execution (port of MoonSharp Execution/Vm / lua's lvm.c) ---

  class Interp
    # 5.1 LUAI_MAXSTACK: cap on the value stack; recursion past it raises
    # "stack overflow" instead of growing without bound
    MAX_STACK_SLOTS = 250_000
    # Call frames in a grow-only buffer with a logical size: call/return
    # never touches the Array (no push/pop churn) and slots above @fsize
    # are the reuse pool.
    @frames = [] of Frame
    @fsize = 0
    @stack = Array(LuaValue).new(4096, nil.as(LuaValue))
    @open_upvals = [] of UpValue
    # Highest stack index currently captured by an open upvalue; lets hot
    # paths skip close_upvals entirely when nothing this deep is captured.
    @open_max = -1
    # run_frames entry points (frame counts) — one per nested VM re-entry.
    # coroutine.yield is only legal at depth 1 of the running coroutine.
    @entry_stack = [] of Int32
    # The CALL/TAILCALL site that raised YieldSignal: frame, abs result
    # register (-1 for a tail call), CALL C operand, tail-call flag.
    @yield_call : {Frame, Int32, Int32, Bool}? = nil
    @suspending = false
    # loop back-edge counter for the weak-gated automatic GC
    @gc_tick = 0
    # Crystal-mediated Lua calls made from inside the current run_frames
    # session (pcall, comparators, metamethods). yield with this > 0 would
    # have to resume a Crystal frame — impossible without fibers.
    @call_depth = 0
    property current_co : LuaCoroutine? = nil

    # --- debug hooks (5.1 luaD_callhook / traceexec) ---

    # Run the hook function for `event` ("call"/"return"/"line"/"count"/
    # "tail return"). Events are suppressed while the hook itself runs
    # (5.1 allowhook); sethook inside a hook takes effect on return.
    # virt: a native (C) call the event is about — registered on the
    # C-frame stack for the event's duration so getinfo(2) sees it.
    def fire_hook(event : String, line : Int32?, virt : LuaValue? = nil) : Nil
      h = @hook_fn
      return if h.nil?
      if v = virt
        @native_stack.push({v, @fsize, Lua::EMPTY_VALS})
      end
      @in_hook = true
      @hook_on = 0
      begin
        call(h, [event.as(LuaValue), (line ? line.to_f64 : nil).as(LuaValue)])
      ensure
        @in_hook = false
        @hook_on = @hook_mask
        @native_stack.pop if virt
      end
    end

    # Per-instruction trace (5.1 traceexec), called from the dispatch loop
    # when hooks are active, `pc` being the index of the instruction about
    # to execute. Line events fire on entering a function, on backward
    # jumps (loops) and on line changes; the count event fires first.
    private def hook_step(frame : Frame, pc : Int32, lines : Array(Int32)) : Nil
      # 5.1 keeps L->savedpc per instruction; our frames only carry it at
      # call boundaries — publish the current position so getinfo/getlocal
      # from inside hooks see live locals ("pc is already incremented")
      frame.pc = pc + 1
      if (@hook_on & HOOK_COUNT) != 0
        if (@hook_countdown -= 1) <= 0
          @hook_countdown = @hook_count
          fire_hook("count", nil)
        end
      end
      if (@hook_on & HOOK_LINE) != 0
        old = frame.old_pc
        if pc == 0 || pc <= old || lines[pc]? != lines[old]?
          fire_hook("line", lines[pc]? || -1)
        end
        frame.old_pc = pc
      end
    end

    # The callable a __call dispatch would reach, for hook events about a
    # native call site (the event names the final function, 5.1 tryfuncTM).
    private def call_target(fn : LuaValue) : LuaValue?
      case fn
      when LuaFunction             then fn
      when LuaTable, LuaUserData   then metafield(fn, "__call")
      else                              nil
      end
    end

    private def ensure_stack(n : Int32) : Nil
      if n >= MAX_STACK_SLOTS
        # 5.1 LUAI_MAXSTACK: dynamic growth is capped; going past the cap
        # raises "stack overflow" (position info added by raise_lua)
        raise_lua("stack overflow")
      end
      while @stack.size <= n
        @stack << nil.as(LuaValue)
      end
    end

    # High-water mark of the value stack: where a fresh run_vm entry may
    # allocate its first frame. Uses both the floating multi-value top and
    # each frame's register window (base + max_stack), whichever is higher.
    private def stack_hi : Int32
      hi = 0
      i = 0
      while i < @fsize
        f = @frames[i]
        hi = f.top if f.top > hi
        w = f.base + f.closure.proto.max_stack
        hi = w if w > hi
        i += 1
      end
      hi
    end

    def close_upvals(min_idx : Int32) : Nil
      i = 0
      closed = false
      while i < @open_upvals.size
        u = @open_upvals[i]
        if (s = u.stack) && u.idx >= min_idx
          u.value = s[u.idx]
          u.stack = nil
          last = @open_upvals.size - 1
          @open_upvals.swap(i, last)
          @open_upvals.pop
          closed = true
        else
          i += 1
        end
      end
      if closed
        m = -1
        @open_upvals.each do |u|
          m = u.idx if u.idx > m
        end
        @open_max = m
      end
    end

    private def capture(abs : Int32) : UpValue
      @open_upvals.each do |u|
        return u if u.stack && u.idx == abs
      end
      u = UpValue.new(@stack, abs)
      @open_upvals << u
      @open_max = abs if abs > @open_max
      u
    end

    # 5.1 LUA_COMPAT_VARARG: the implicit `arg` table {n = #extras, ...}
    private def make_arg_table(vars : Array(LuaValue)) : LuaTable
      t = LuaTable.new
      t.raw_set("n", vars.size.to_f64)
      vars.each_with_index { |v, k| t.raw_set((k + 1).to_f64, v) }
      t
    end

    # Push a frame for a Lua-to-Lua call. The closure is already at
    # stack[newbase] and its arguments at newbase+1.. (in place — no copy).
    private def push_call(fn : LuaClosure, newbase : Int32, argn : Int32, want : Int32) : Nil
      p = fn.proto
      np = p.num_params
      stack = @stack
      i = argn + 1
      while i <= np
        stack[newbase + i] = nil
        i += 1
      end
      vars = Lua::EMPTY_VALS
      if p.vararg? && argn > np
        vars = Array(LuaValue).new(argn - np) { |j| stack[newbase + 1 + np + j] }
      end
      if p.vararg?
        # 5.1 compat: `arg' table — or plain nil when the body uses `...`
        stack[newbase + 1 + np] = p.needs_arg? ? make_arg_table(vars) : nil
      end
      top = newbase + {p.max_stack, argn + 1}.max
      ensure_stack(top + argn + 4)
      stack = @stack
      if @fsize < @frames.size
        nf = @frames[@fsize]
      else
        nf = Frame.new(fn, newbase, top, vars)
        @frames << nf
      end
      nf.closure = fn
      nf.base = newbase
      nf.top = top
      nf.varargs = vars
      nf.pc = 0
      nf.want = want
      nf.tail_calls = 0
      nf.old_pc = -1
      @fsize += 1
    end

    # Call a non-closure value from the VM (native / __call table), used by
    # CALL and TAILCALL. vreg: the function's register, for error naming.
    private def call_value(fn : LuaValue, ra : Int32, argn : Int32, vreg : Int32 = -1) : Array(LuaValue)
      args = Array(LuaValue).new(argn) { |i| @stack[ra + 1 + i] }
      case fn
      when LuaFunction
        call_native(fn, args)
      when LuaTable, LuaUserData
        if mm = metafield(fn, "__call")
          call(mm, ([fn] of LuaValue).concat(args))
        else
          typeerr("call", fn, vreg)
        end
      else
        typeerr("call", fn, vreg)
      end
    end

    # Pop the top frame: just shrink the logical size (the slot is reused).
    private def retire_frame : Nil
      @fsize -= 1
    end

    # Place call results at R[ra] according to the CALL C operand.
    private def store_results(frame : Frame, ra : Int32, c : Int32, r : Array(LuaValue)) : Nil
      stack = @stack
      if c == -1
        ensure_stack(ra + r.size + 4)
        i = 0
        while i < r.size
          stack[ra + i] = r[i]
          i += 1
        end
        frame.top = ra + r.size
      elsif c == 0
        frame.top = ra
      else
        i = 0
        while i < c
          stack[ra + i] = r[i]?
          i += 1
        end
        frame.top = ra + c
      end
    end

    # Transfer `res` from the top frame back to its caller and pop it.
    # Returns true if that was the entry frame of this run_vm (finish up).
    private def frame_return(frame : Frame, res : Array(LuaValue)) : Bool
      stack = @stack
      cf = @fsize >= 2 ? @frames[@fsize - 2] : nil
      if cf.nil?
        retire_frame
        return true
      end
      ra = frame.base
      ensure_stack(ra + {res.size, frame.want}.max + 4)
      i = 0
      while i < res.size
        stack[ra + i] = res[i]
        i += 1
      end
      case frame.want
      when -1
        cf.top = ra + res.size
      when 0
        cf.top = ra
      else
        i = res.size
        while i < frame.want
          stack[ra + i] = nil
          i += 1
        end
        cf.top = ra + frame.want
      end
      retire_frame
      false
    end

    # Execute a closure in the VM. Re-entrant: native functions called from
    # the loop enter here again with their own frame stack segment.
    def run_vm(cl0 : LuaClosure, args : Array(LuaValue)) : Array(LuaValue)
      entry_base = stack_hi
      base0 = entry_base
      p0 = cl0.proto
      np = p0.num_params
      ensure_stack(base0 + {p0.max_stack, args.size + 1}.max + args.size + 4)
      stack = @stack
      stack[base0] = cl0
      i = 1
      while i <= np
        stack[base0 + i] = args[i - 1]?
        i += 1
      end
      vars = Lua::EMPTY_VALS
      if p0.vararg? && args.size > np
        vars = Array(LuaValue).new(args.size - np) { |j| args[np + j] }
      end
      top0 = base0 + {p0.max_stack, args.size + 1}.max
      f0 = Frame.new(cl0, base0, top0, vars)
      f0.want = 0
      if @fsize < @frames.size
        @frames[@fsize] = f0
      else
        @frames << f0
      end
      @fsize += 1
      if (@hook_on & HOOK_CALL) != 0
        f0.pc = 1 # 5.1: "hooks assume 'pc' is already incremented"
        fire_hook("call", nil)
        f0.pc = 0 # execution still starts at the first instruction
      end
      # entry_frames: frame count EXCLUDING the entry frame (the loop
      # finishes when the frame at index entry_frames returns)
      run_frames(@fsize - 1, base0)
    end

    # The dispatch loop over the current frame stack; also the resume
    # entry for suspended coroutines (their frames continue from where
    # the yield call interrupted them).
    def run_frames(entry_frames : Int32, entry_base : Int32) : Array(LuaValue)
      results = Lua::EMPTY_VALS
      done = false
      @entry_stack << entry_frames
      d_call = @call_depth
      @call_depth = 0

      begin
      until done
        frame = @frames[@fsize - 1]
          cl = frame.closure
          proto = cl.proto
          cp = proto.packed.to_unsafe # frozen after compile: unchecked reads
          consts = proto.consts
          kp = consts.to_unsafe # same: consts are frozen after compile
          lines = proto.lines
          upvals = cl.upvals
          uv = upvals.to_unsafe # upvalue list is fixed at closure creation
          base = frame.base
          pc = frame.pc
          stack = @stack

          while true
            if @hook_on != 0
              hook_step(frame, pc, lines)
            end
            # sp refresh per iteration: the stack buffer may have been
            # reallocated (ensure_stack) by any op that re-entered the VM
            # (a hook run counts — refresh happens AFTER hook_step).
            sp = stack.to_unsafe
            w = cp[pc]
            pc += 1
            op = (w & 0xFF).to_u8!.unsafe_as(Op)
            a = ((w >> 8).to_i64! << 48 >> 48).to_i32!
            b = ((w >> 24).to_i64! << 44 >> 44).to_i32!
            c = ((w >> 44).to_i64! << 44 >> 44).to_i32!
            case op
            when .move?      then sp[base + a] = sp[base + b]
            when .loadnil?
              i = a
              while i <= a + b
                sp[base + i] = nil
                i += 1
              end
            when .loadbool?  then sp[base + a] = (b != 0)
            when .loadk?     then sp[base + a] = kp[b]
            when .getglobal?
              n = kp[b].as(String)
              # 5.1 environments: closures may carry their own env table
              # (setfenv); the metatable slow path stays for the rare
              # setmetatable(_G, ...) case
              if (g = cl.env) || @globals.metatable
                @line = lines[pc - 1]
                stack[base + a] = getindex(g || @globals, n)
              else
                sp[base + a] = @globals.raw_get(n)
              end
            when .setglobal?
              @line = lines[pc - 1]
              setindex(cl.env || @globals, kp[b].as(String), stack[base + a])
            when .getupval?
              u = uv[b]
              if s = u.stack
                sp[base + a] = s[u.idx]
              else
                sp[base + a] = u.value
              end
            when .setupval?
              u = uv[b]
              if s = u.stack
                s[u.idx] = sp[base + a]
              else
                u.value = sp[base + a]
              end
            when .gettable?
              o = sp[base + b]
              k = sp[base + c]
              if o.is_a?(LuaTable) && o.metatable.nil?
                sp[base + a] = o.raw_get(k)
              else
                @line = lines[pc - 1]
                @vi_pc = pc - 1
                stack[base + a] = getindex(o, k, b)
              end
            when .settable?
              t = sp[base + a]
              k = sp[base + b]
              if t.is_a?(LuaTable) && t.metatable.nil?
                t.raw_set(k, sp[base + c])
              else
                @line = lines[pc - 1]
                @vi_pc = pc - 1
                setindex(t, k, stack[base + c], a)
              end
            when .self?
              obj = sp[base + b]
              sp[base + a + 1] = obj
              if obj.is_a?(LuaTable) && obj.metatable.nil?
                sp[base + a] = obj.raw_get(kp[c].as(String))
              else
                @line = lines[pc - 1]
                @vi_pc = pc - 1
                stack[base + a] = getindex(obj, kp[c].as(String), b)
              end
            when .newtable?  then sp[base + a] = LuaTable.new
            when .setlist?
              t = stack[base + a].as(LuaTable)
              # 0-value multi feeds can leave top at the table slot
              n = b == -1 ? {frame.top - (base + a + 1), 0}.max : b
              vals = Array(LuaValue).new(n) { |i| stack[base + a + 1 + i] }
              t.raw_fill(c + 1, vals)
            when .add?, .sub?, .mul?, .div?, .mod?, .pow?
              # fast path: both numbers → no metatable dispatch, no line fetch
              l = sp[base + b]
              r = sp[base + c]
              if l.is_a?(Float64) && r.is_a?(Float64)
                sp[base + a] =
                  case op
                  when .add? then l + r
                  when .sub? then l - r
                  when .mul? then l * r
                  when .div? then l / r
                  when .mod? then r == 0 ? Float64::NAN : l % r
                  else             l ** r
                  end
              else
                @line = lines[pc - 1]
                @vi_pc = pc - 1
                o = case op
                    when .add? then "+"
                    when .sub? then "-"
                    when .mul? then "*"
                    when .div? then "/"
                    when .mod? then "%"
                    else             "^"
                    end
                stack[base + a] = arith(o, l, r, b, c)
              end
            when .unm?
              @line = lines[pc - 1]
              @vi_pc = pc - 1
              stack[base + a] = negate(stack[base + b], b)
            when .not?       then sp[base + a] = !Lua.truthy(sp[base + b])
            when .len?
              @line = lines[pc - 1]
              @vi_pc = pc - 1
              stack[base + a] = lua_len(stack[base + b], b)
            when .concat?
              @line = lines[pc - 1]
              @vi_pc = pc - 1
              v = stack[base + b]
              i = b - 1
              while i >= a
                v = lua_concat(stack[base + i], v, i, i + 1)
                i -= 1
              end
              stack[base + a] = v
            when .eq?
              @line = lines[pc - 1]
              stack[base + a] = lua_eq(stack[base + b], stack[base + c])
            when .neq?
              @line = lines[pc - 1]
              stack[base + a] = !lua_eq(stack[base + b], stack[base + c])
            when .lt?
              l = sp[base + b]
              r = sp[base + c]
              if l.is_a?(Float64) && r.is_a?(Float64)
                sp[base + a] = l < r
              elsif l.is_a?(String) && r.is_a?(String)
                sp[base + a] = Lua.strcmp(l, r) < 0
              else
                @line = lines[pc - 1]
                @vi_pc = pc - 1
                stack[base + a] = lua_compare(l, r, "<")
              end
            when .le?
              l = sp[base + b]
              r = sp[base + c]
              if l.is_a?(Float64) && r.is_a?(Float64)
                sp[base + a] = l <= r
              elsif l.is_a?(String) && r.is_a?(String)
                sp[base + a] = Lua.strcmp(l, r) <= 0
              else
                @line = lines[pc - 1]
                @vi_pc = pc - 1
                stack[base + a] = lua_compare(l, r, "<=")
              end
            when .jmp?
              pc += b
              # backward jump = loop back-edge: with weak tables around,
              # drive the Lua-graph GC (PUC's automatic collections) —
              # clear stale registers and periodically mark/sweep, so
              # weak entries settle without an explicit collectgarbage
              if b < 0 && Lua.weak_active?
                @gc_tick &+= 1
                if (@gc_tick & 31) == 0
                  gc_clear_stale(false)
                  Lua.gc_full(self)
                end
              end
            when .jmpf? then pc += b unless Lua.truthy(sp[base + a])
            when .jmpt? then pc += b if Lua.truthy(sp[base + a])
            when .vararg?
              vars = frame.varargs
              if b == -1
                ensure_stack(base + a + vars.size + 1)
                stack = @stack
                i = 0
                while i < vars.size
                  stack[base + a + i] = vars[i]
                  i += 1
                end
                frame.top = base + a + vars.size
              elsif b > 0
                i = 0
                while i < b
                  stack[base + a + i] = vars[i]?
                  i += 1
                end
              end
            when .closure?
              pr = proto.protos[b]
              ups = Array(UpValue).new(pr.upvals.size)
              pr.upvals.each do |d|
                ups << (d.from_stack? ? capture(base + d.index) : upvals[d.index])
              end
              nc = LuaClosure.new(pr, ups)
              nc.env = cl.env # 5.1: closures inherit the enclosing env
              stack[base + a] = nc
            when .close? then close_upvals(base + a)
            when .forprep?
              @line = lines[pc - 1]
              v0 = Lua.tonumber(sp[base + a])
              v1 = Lua.tonumber(sp[base + a + 1])
              v2 = Lua.tonumber(sp[base + a + 2])
              raise_lua("'for' initial value must be a number") unless v0
              raise_lua("'for' limit value must be a number") unless v1
              raise_lua("'for' step value must be a number") unless v2
              init = v0.not_nil!
              lim = v1.not_nil!
              ste = v2.not_nil!
              raise_lua("'for' step is zero") if ste == 0
              # 5.1: normalize the controls, pre-subtract the step and
              # jump to the loop test unconditionally — FORLOOP's first
              # add restores the initial value
              sp[base + a] = init - ste
              sp[base + a + 1] = lim
              sp[base + a + 2] = ste
              pc += b
            when .forloop?
              ctrl = sp[base + a].as(Float64)
              lim = sp[base + a + 1].as(Float64)
              ste = sp[base + a + 2].as(Float64)
              ctrl += ste
              if ste > 0 ? ctrl <= lim : ctrl >= lim
                close_upvals(base + a) if @open_max >= base + a # freeze this iteration's loop var
                sp[base + a] = ctrl
                pc += b
                if Lua.weak_active? # loop back-edge GC (see .jmp?)
                  @gc_tick &+= 1
                  if (@gc_tick & 31) == 0
                    gc_clear_stale(false)
                    Lua.gc_full(self)
                  end
                end
              end
            when .tforcall?
              @line = lines[pc - 1]
              rets = call(stack[base + a], [stack[base + a + 1], stack[base + a + 2]] of LuaValue)
              first = rets[0]?
              unless first.nil?
                close_upvals(base + a + 3) # freeze this iteration's vars
                i = 0
                while i < c
                  stack[base + a + 3 + i] = rets[i]?
                  i += 1
                end
                stack[base + a + 2] = first
                pc += b
              end
            when .call?
              fn = sp[base + a]
              argn = b == -1 ? {frame.top - (base + a + 1), 0}.max : b # 0-value multi feeds: top can sit on the closure slot
              if fn.is_a?(LuaClosure)
                JIT.on_call(fn) # M0 hotness (JIT.md 1.2): bump + threshold check
                frame.pc = pc
                p = fn.proto
                # fast path: exact args, no varargs, stack already sized —
                # push the frame inline and switch without leaving the loop
                if p.num_params == argn && !p.vararg?
                  newbase = base + a
                  top2 = newbase + {p.max_stack, argn + 1}.max
                  if top2 + argn + 4 < @stack.size
                    # JIT entry (JIT.md 1.2): machine code runs the callee,
                    # results land at R[a] — adjust top like store_results.
                    # Hooks and coroutines keep the interpreter (M1).
                    if (jcp = fn.compiled) && !@current_co && @hook_on == 0
                      n = JIT.invoke(jcp, self, fn, newbase, argn, c)
                      if c == -1
                        frame.top = newbase + n
                      elsif c == 0
                        frame.top = newbase
                      else
                        stack = @stack
                        sp2 = stack.to_unsafe
                        i = n
                        while i < c
                          sp2[newbase + i] = nil
                          i += 1
                        end
                        frame.top = newbase + c
                      end
                      next
                    end
                    fp = @frames.to_unsafe
                    if @fsize < @frames.size
                      nf = fp[@fsize]
                    else
                      nf = Frame.new(fn, newbase, top2, Lua::EMPTY_VALS)
                      @frames << nf
                    end
                    nf.closure = fn
                    nf.base = newbase
                    nf.top = top2
                    nf.varargs = Lua::EMPTY_VALS
                    nf.pc = 0
                    nf.want = c
                    nf.tail_calls = 0
                    nf.old_pc = -1
                    @fsize += 1
                    if (@hook_on & HOOK_CALL) != 0
                      nf.pc = 1 # 5.1: "hooks assume 'pc' is already incremented"
                      fire_hook("call", nil)
                    end
                    frame = nf
                    cl = fn
                    proto = p
                    cp = p.packed.to_unsafe
                    consts = p.consts
                    kp = consts.to_unsafe
                    lines = p.lines
                    upvals = fn.upvals
                    uv = upvals.to_unsafe
                    base = newbase
                    pc = 0
                    next
                  end
                end
                push_call(fn, base + a, argn, c)
                if (@hook_on & HOOK_CALL) != 0
                  nf = @frames[@fsize - 1]
                  nf.pc = 1 # "pc already incremented"
                  fire_hook("call", nil)
                  nf.pc = 0
                end
                break # re-fetch frame
              else
                @line = lines[pc - 1]
                @vi_pc = pc - 1
                frame.pc = pc # call position while the native runs (getinfo)
                if (vf = call_target(fn)) && (@hook_on & HOOK_CALL) != 0
                  fire_hook("call", nil, vf)
                end
                r = begin
                  call_value(fn, base + a, argn, a)
                rescue e : YieldSignal
                  # coroutine.yield: the CALL resumes later with the
                  # yielded values as its results
                  @yield_call = {frame, base + a, c, false}
                  raise e
                end
                frame.pc = pc
                if vf && (@hook_on & HOOK_RET) != 0
                  fire_hook("return", nil, vf)
                end
                store_results(frame, base + a, c, r)
              end
            when .tailcall?
              @line = lines[pc - 1]
              fn = stack[base + a]
              argn = b == -1 ? {frame.top - (base + a + 1), 0}.max : b # 0-value multi feeds: top can sit on the closure slot
              close_upvals(base) if @open_max >= base
              if fn.is_a?(LuaClosure)
                # slide fn + args down over the current frame and reuse it
                i = 0
                while i < argn
                  stack[base + 1 + i] = stack[base + a + 1 + i]
                  i += 1
                end
                stack[base] = fn
                p = fn.proto
                np2 = p.num_params
                i = argn + 1
                while i <= np2
                  stack[base + i] = nil
                  i += 1
                end
                vars = Lua::EMPTY_VALS
                if p.vararg? && argn > np2
                  vars = Array(LuaValue).new(argn - np2) { |j| stack[base + 1 + np2 + j] }
                end
                if p.vararg?
                  stack[base + 1 + np2] = p.needs_arg? ? make_arg_table(vars) : nil
                end
                frame.closure = fn
                frame.varargs = vars
                frame.pc = 0
                frame.top = base + {p.max_stack, argn + 1}.max
                ensure_stack(frame.top + argn + 4)
                # 5.1 OP_TAILCALL: luaD_precall fires CALL for the callee,
                # then the frame collapses onto the previous one — each
                # collapse is a lost tail-call level ("tail return" event).
                if (@hook_on & HOOK_CALL) != 0
                  frame.pc = 1 # "pc already incremented"
                  fire_hook("call", nil)
                  frame.pc = 0
                end
                frame.tail_calls += 1
                frame.old_pc = -1
                break # re-fetch frame
              else
                @line = lines[pc - 1]
                @vi_pc = pc - 1
                frame.pc = pc # call position while the native runs
                if (vf = call_target(fn)) && (@hook_on & HOOK_CALL) != 0
                  fire_hook("call", nil, vf)
                end
                r = begin
                  call_value(fn, base + a, argn, a)
                rescue e : YieldSignal
                  # tail call to yield: completes as this frame's return
                  @yield_call = {frame, -1, 0, true}
                  raise e
                end
                if vf && (@hook_on & HOOK_RET) != 0
                  fire_hook("return", nil, vf)
                end
                if @fsize == entry_frames + 1 || frame_return(frame, r)
                  results = r
                  done = true
                  break
                end
                break
              end
            when .return?
              if (@hook_on & HOOK_RET) != 0
                # 5.1 callrethooks: RET for the returning function, then
                # one TAILRET per lost tail call, while the frame is still
                # up (getinfo(2) names it).
                frame.pc = pc
                fire_hook("return", nil)
                tleft = frame.tail_calls
                while tleft > 0
                  tleft -= 1
                  fire_hook("tail return", nil)
                end
              end
              nres = b == -1 ? {frame.top - (base + a), 0}.max : b
              if @fsize == entry_frames + 1
                results = Array(LuaValue).new(nres) { |j| stack[base + a + j] }
                done = true
                break
              end
              close_upvals(base) if @open_max >= base
              # inline frame return: shift results down, switch to the
              # caller's frame without leaving the dispatch loop
              fp = @frames.to_unsafe
              cf = fp[@fsize - 2]
              if a > 0 && nres > 0
                st = @stack
                i = 0
                while i < nres
                  st[base + i] = st[base + a + i]
                  i += 1
                end
              end
              case frame.want
              when -1 then cf.top = base + nres
              when 0  then cf.top = base
              else
                st = @stack
                i = nres
                while i < frame.want
                  st[base + i] = nil
                  i += 1
                end
                cf.top = base + frame.want
              end
              @fsize -= 1
              frame = cf
              cl = cf.closure
              proto = cl.proto
              cp = proto.packed.to_unsafe
              consts = proto.consts
              kp = consts.to_unsafe
              lines = proto.lines
              upvals = cl.upvals
              uv = upvals.to_unsafe
              base = cf.base
              pc = cf.pc
              stack = @stack
              next
            end
          end
        end
        results
      rescue e : LuaError
        # frame count at the raise, before the ensure below truncates —
        # a coroutine dying with an error keeps its frames for
        # debug.traceback(co) and needs the original count
        @err_fsize = @fsize
        # 5.1 luaD_errormsg: an xpcall message handler runs here, before any
        # unwinding, so debug.traceback sees the frames that raised. A
        # handler that itself errors aborts with "error in error handling".
        if (h = @err_handler) && !e.msgh_done?
          e.msgh_done = true
          # one shot: an error raised by the handler itself must not
          # re-enter it (recursion); it becomes "error in error handling"
          save = @err_handler
          @err_handler = nil
          begin
            e.value = call(h, [e.value] of LuaValue)[0]?
          rescue e2 : LuaError
            err = LuaError.new("error in error handling")
            err.msgh_done = true
            raise err
          ensure
            @err_handler = save
          end
        end
        raise e
      ensure
        @call_depth = d_call
        @entry_stack.pop
        unless @suspending
          @fsize = entry_frames if @fsize > entry_frames
          close_upvals(entry_base) if @open_max >= entry_base
        end
      end
    end

    # --- coroutines ---

    # coroutine.yield: unwind to the resume boundary via YieldSignal. Legal
    # only in the running coroutine's own bytecode — no deeper run_frames
    # entry (a sort comparator, pcall'ed closure, metamethod) and no
    # Crystal-mediated call in between (pcall/native chains); Lua 5.1
    # rejects those the same way.
    def yield_co(args : Array(LuaValue)) : Array(LuaValue)
      raise_lua("attempt to yield from outside a coroutine") if @current_co.nil?
      if @entry_stack.size > 1 || @call_depth > 0
        raise_lua("attempt to yield across a Crystal call boundary (not supported)")
      end
      @suspending = true
      raise YieldSignal.new(args)
      [] of LuaValue # unreachable: keeps the return type non-NoReturn
    end

    # Resume a coroutine: swap its saved stacks in, run its body (first
    # resume) or continue from the suspended CALL/TAILCALL site, and swap
    # the caller's state back on the way out. Returns 5.1-style
    # [true, yields/returns...] / [false, err].
    def resume_co(co : LuaCoroutine, args : Array(LuaValue)) : Array(LuaValue)
      # 5.1: bad resumes return [false, msg] like a body error, not raise
      case co.status
      when .dead?    then return [false, "cannot resume dead coroutine"] of LuaValue
      when .running? then return [false, "cannot resume running coroutine"] of LuaValue
      when .normal?  then return [false, "cannot resume non-suspended coroutine"] of LuaValue
      end

      s_stack  = @stack
      s_frames = @frames
      s_fsize  = @fsize
      s_entry  = @entry_stack
      prev_co  = @current_co
      prev_co.status = LuaCoroutine::Status::Normal if prev_co
      @stack, @frames, @fsize = co.stack, co.frames, co.fsize
      @entry_stack = co.entries
      s_upvals = @open_upvals
      s_open_max = @open_max
      @open_upvals = co.open_upvals
      @open_max = co.open_max
      # native calls of the resumed state, not the resumer's
      s_natives = @native_stack
      @native_stack = co.native_stack
      # per-state hooks (5.1 lua_sethook): swap with the stacks
      s_hook_fn, s_hook_mask, s_hook_count, s_hook_countdown = @hook_fn, @hook_mask, @hook_count, @hook_countdown
      s_in_hook = @in_hook
      @hook_fn, @hook_mask, @hook_count, @hook_countdown = co.hook, co.hook_mask, co.hook_count, co.hook_countdown
      @in_hook = false # a fresh state always allows hooks
      @hook_on = @hook_mask
      @current_co = co
      co.status = LuaCoroutine::Status::Running
      # thread env (debug.setfenv): the interpreter default for this resume
      s_env = @default_env
      @default_env = co.env

      begin
        if co.first_resume?
          co.first_resume = false
          res = call(co.fn, args)
          co.status = LuaCoroutine::Status::Dead
          co.release
          ([true] of LuaValue).concat(res)
        else
          yf, yra, yc, _tail = co.yield_call.not_nil!
          co.yield_call = nil
          @suspending = false
          if yra == -1
            # the yield was a tail call: its values are the frame's results
            if @fsize == 1
              co.status = LuaCoroutine::Status::Dead
              co.release
              return ([true] of LuaValue).concat(args)
            end
            frame_return(yf, args)
          else
            store_results(yf, yra, yc, args)
          end
          # run to the next yield or the end of the coroutine BODY (frame 0):
          # frames above (e.g. the function the yield happened in) must
          # return into the body, not end the resume
          res = run_frames(0, @frames[0].base)
          co.status = LuaCoroutine::Status::Dead
          co.release
          ([true] of LuaValue).concat(res)
        end
      rescue e : YieldSignal
        @suspending = false
        co.status = LuaCoroutine::Status::Suspended
        co.stack, co.frames, co.fsize = @stack, @frames, @fsize
        co.entries = @entry_stack
        co.open_upvals = @open_upvals
        co.open_max = @open_max
        co.native_stack = @native_stack
        co.hook, co.hook_mask, co.hook_count, co.hook_countdown = @hook_fn, @hook_mask, @hook_count, @hook_countdown
        co.yield_call = @yield_call
        @yield_call = nil
        ([true] of LuaValue).concat(e.values)
      rescue e : LuaError
        co.status = LuaCoroutine::Status::Dead
        # 5.1 abandons the ci's of an erroring coroutine: keep the frames
        # (with the count from the raise) so debug.traceback(co) can still
        # walk them — the innermost level is the failed call itself
        co.err_death = true
        co.stack, co.frames = @stack, @frames
        co.fsize = @err_fsize
        co.entries = @entry_stack
        co.open_upvals = @open_upvals
        co.open_max = @open_max
        co.native_stack = @native_stack
        co.hook, co.hook_mask, co.hook_count, co.hook_countdown = @hook_fn, @hook_mask, @hook_count, @hook_countdown
        co.yield_call = nil
        [false, e.value] of LuaValue
      rescue e : Exception
        # Crystal-level failure inside the coroutine: no silent degradation
        co.status = LuaCoroutine::Status::Dead
        co.release
        raise e
      ensure
        @stack, @frames, @fsize = s_stack, s_frames, s_fsize
        @entry_stack = s_entry
        @open_upvals = s_upvals
        @open_max = s_open_max
        @native_stack = s_natives
        @hook_fn, @hook_mask, @hook_count, @hook_countdown = s_hook_fn, s_hook_mask, s_hook_count, s_hook_countdown
        @in_hook = s_in_hook
        @hook_on = @in_hook ? 0 : @hook_mask
        # the body may have replaced its thread env (setfenv(0)): persist
        co.env = @default_env if co.env != @default_env
        @default_env = s_env
        @current_co = prev_co
        prev_co.status = LuaCoroutine::Status::Running if prev_co && prev_co.status.normal?
      end
    end
  end
end
