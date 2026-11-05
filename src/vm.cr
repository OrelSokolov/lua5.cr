# Bytecode VM: AST → Proto compiler (port of lua's lparser/lcode emission
# stage) + the register-machine dispatch loop (port of MoonSharp Execution/Vm,
# which mirrors lvm.c). Semantics follow the tree interpreter it replaced:
# per-iteration loop variables, proper tail calls, upvalues closed at scope
# exit.

module Lua
  class Compiler
    @fs : FuncState? = nil

    def initialize(@chunkname : String)
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

      def initialize(@name, @scope, @reg)
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
      fs = FuncState.new(nil, p)
      @fs = fs
      block_scope(block)
      emit(Op::RETURN, 0, 0)
      p
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
      fs.locals << LocalVar.new(name, fs.scopes.last, reg)
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
      f.proto.upvals << UpvalDesc.new(name, from_stack, index)
      f.proto.upvals.size - 1
    end

    private def konst(v : LuaValue) : Int32
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
        s.targets.each_with_index do |t, i|
          case t
          when AST::NameE then assign_name(t.name, base + i)
          when AST::IndexE
            r = f.freereg
            use_reg(r)
            @line = t.line
            expr(t.obj, r)
            use_reg(r + 1)
            expr(t.key, r + 1)
            emit(Op::SETTABLE, r, r + 1, base + i)
            f.freereg = r
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
        patch(fl, body_start)
        exit_pos = maybe_close_loop(f, r)
        patch(fp, exit_pos)
        f.loops.last.breaks.each { |br| patch(br, exit_pos) }
        f.loops.pop
        pop_scope
      when AST::GenForStat
        f = fs
        r = f.freereg
        nvars = s.names.size
        compile_explist(s.exps, r, 3)
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
        @line = target.line
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
      block_scope(e.body)
      pop_scope
      emit(Op::RETURN, 0, 0)
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
      # the caller reused an older register.
      if dst < fs.freereg && (multi_expr?(e) || e.is_a?(AST::TableE) || e.is_a?(AST::BinopE))
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
        r = f.freereg
        use_reg(r)
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
        f.freereg = r
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
        r = f.freereg
        use_reg(r)
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
        f.freereg = r
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
            expr(v, dst + 1, -1)
            emit(Op::SETLIST, dst, -1, offset)
          else
            narr += 1
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

    private def ensure_stack(n : Int32) : Nil
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
      top = newbase + {p.max_stack, argn + 1}.max
      ensure_stack(top + argn + 4)
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
      @fsize += 1
    end

    # Call a non-closure value from the VM (native / __call table), used by
    # CALL and TAILCALL.
    private def call_value(fn : LuaValue, ra : Int32, argn : Int32) : Array(LuaValue)
      args = Array(LuaValue).new(argn) { |i| @stack[ra + 1 + i] }
      case fn
      when LuaFunction
        fn.fn.call(self, args)
      when LuaTable, LuaUserData
        if mm = metafield(fn, "__call")
          call(mm, ([fn] of LuaValue).concat(args))
        else
          raise_lua("attempt to call a #{Lua.type_name(fn)} value")
        end
      else
        raise_lua("attempt to call a #{Lua.type_name(fn)} value")
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
      entry_frames = @fsize
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
      f0 = Frame.new(cl0, base0, base0 + {p0.max_stack, args.size + 1}.max, vars)
      f0.want = 0
      if @fsize < @frames.size
        @frames[@fsize] = f0
      else
        @frames << f0
      end
      @fsize += 1
      results = Lua::EMPTY_VALS
      done = false

      begin
      until done
        frame = @frames[@fsize - 1]
          cl = frame.closure
          proto = cl.proto
          code = proto.code
          cp = code.to_unsafe # code never changes after compile: unchecked reads
          consts = proto.consts
          kp = consts.to_unsafe # same: consts are frozen after compile
          lines = proto.lines
          upvals = cl.upvals
          uv = upvals.to_unsafe # upvalue list is fixed at closure creation
          base = frame.base
          pc = frame.pc
          stack = @stack

          while true
            # sp refresh per iteration: the stack buffer may have been
            # reallocated (ensure_stack) by any op that re-entered the VM.
            sp = stack.to_unsafe
            inst = cp[pc]
            pc += 1
            op = inst.op
            a = inst.a
            b = inst.b
            c = inst.c
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
              # globals normally have no metatable; keep the general path for
              # the rare setmetatable(_G, ...) case
              if @globals.metatable
                @line = lines[pc - 1]
                stack[base + a] = getindex(@globals, n)
              else
                sp[base + a] = @globals.raw_get(n)
              end
            when .setglobal?
              @line = lines[pc - 1]
              setindex(@globals, kp[b].as(String), stack[base + a])
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
                stack[base + a] = getindex(o, k)
              end
            when .settable?
              t = sp[base + a]
              k = sp[base + b]
              if t.is_a?(LuaTable) && t.metatable.nil?
                t.raw_set(k, sp[base + c])
              else
                @line = lines[pc - 1]
                setindex(t, k, stack[base + c])
              end
            when .self?
              obj = sp[base + b]
              sp[base + a + 1] = obj
              if obj.is_a?(LuaTable) && obj.metatable.nil?
                sp[base + a] = obj.raw_get(kp[c].as(String))
              else
                @line = lines[pc - 1]
                stack[base + a] = getindex(obj, kp[c].as(String))
              end
            when .newtable?  then sp[base + a] = LuaTable.new
            when .setlist?
              t = stack[base + a].as(LuaTable)
              n = b == -1 ? frame.top - (base + a + 1) : b
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
                o = case op
                    when .add? then "+"
                    when .sub? then "-"
                    when .mul? then "*"
                    when .div? then "/"
                    when .mod? then "%"
                    else             "^"
                    end
                stack[base + a] = arith(o, l, r)
              end
            when .unm?
              @line = lines[pc - 1]
              stack[base + a] = negate(stack[base + b])
            when .not?       then sp[base + a] = !Lua.truthy(sp[base + b])
            when .len?
              @line = lines[pc - 1]
              stack[base + a] = lua_len(stack[base + b])
            when .concat?
              @line = lines[pc - 1]
              v = stack[base + b]
              i = b - 1
              while i >= a
                v = lua_concat(stack[base + i], v)
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
                sp[base + a] = (l <=> r) < 0
              else
                @line = lines[pc - 1]
                stack[base + a] = lua_compare(l, r, "<")
              end
            when .le?
              l = sp[base + b]
              r = sp[base + c]
              if l.is_a?(Float64) && r.is_a?(Float64)
                sp[base + a] = l <= r
              elsif l.is_a?(String) && r.is_a?(String)
                sp[base + a] = (l <=> r) <= 0
              else
                @line = lines[pc - 1]
                stack[base + a] = lua_compare(l, r, "<=")
              end
            when .jmp?  then pc += b
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
              stack[base + a] = LuaClosure.new(pr, ups)
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
              sp[base + a] = init
              sp[base + a + 1] = lim
              sp[base + a + 2] = ste
              unless ste > 0 ? init <= lim : init >= lim
                pc += b
              end
            when .forloop?
              ctrl = sp[base + a].as(Float64)
              lim = sp[base + a + 1].as(Float64)
              ste = sp[base + a + 2].as(Float64)
              ctrl += ste
              if ste > 0 ? ctrl <= lim : ctrl >= lim
                close_upvals(base + a) if @open_max >= base + a # freeze this iteration's loop var
                sp[base + a] = ctrl
                pc += b
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
              argn = b == -1 ? frame.top - (base + a + 1) : b
              if fn.is_a?(LuaClosure)
                frame.pc = pc
                p = fn.proto
                # fast path: exact args, no varargs, stack already sized —
                # push the frame inline and switch without leaving the loop
                if p.num_params == argn && !p.vararg?
                  newbase = base + a
                  top2 = newbase + {p.max_stack, argn + 1}.max
                  if top2 + argn + 4 < @stack.size
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
                    @fsize += 1
                    frame = nf
                    cl = fn
                    proto = p
                    code = p.code
                    cp = code.to_unsafe
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
                break # re-fetch frame
              else
                @line = lines[pc - 1]
                r = call_value(fn, base + a, argn)
                frame.pc = pc
                store_results(frame, base + a, c, r)
              end
            when .tailcall?
              @line = lines[pc - 1]
              fn = stack[base + a]
              argn = b == -1 ? frame.top - (base + a + 1) : b
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
                frame.closure = fn
                frame.varargs = vars
                frame.pc = 0
                frame.top = base + {p.max_stack, argn + 1}.max
                ensure_stack(frame.top + argn + 4)
                break # re-fetch frame
              else
                r = call_value(fn, base + a, argn)
                if @fsize == entry_frames + 1 || frame_return(frame, r)
                  results = r
                  done = true
                  break
                end
                break
              end
            when .return?
              nres = b == -1 ? frame.top - (base + a) : b
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
              code = proto.code
              cp = code.to_unsafe
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
      ensure
        @fsize = entry_frames if @fsize > entry_frames
        close_upvals(entry_base) if @open_max >= entry_base
      end
    end
  end
end
