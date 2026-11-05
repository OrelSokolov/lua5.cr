# Tree-walking interpreter. Port of MoonSharp Tree/ + Runtime/
# (AST evaluation + metatable dispatch) — MoonSharp's own first stage;
# the bytecode VM comes in Phase 3 of PLAN.md.
module Lua
  class Interp
    property globals : LuaTable
    getter string_lib : LuaTable
    getter string_meta : LuaTable
    property rng : Random = Random.new
    property chunkname : String = "chunk"
    property line : Int32 = 0

    def initialize
      @globals = LuaTable.new
      @string_lib = LuaTable.new
      @string_meta = LuaTable.new
      @string_meta.raw_set("__index", @string_lib)
      Stdlib::Base.install(self)
      Stdlib::MathLib.install(self)
      Stdlib::TableLib.install(self)
      Stdlib::StringLib.install(self)
      Stdlib::OsLib.install(self)
      Stdlib::IoLib.install(self)
    end

    # --- entry points ---

    def load(src : String, chunkname : String = "chunk") : AST::FuncE
      @chunkname = chunkname
      block = Parser.new(Lexer.new(src, chunkname).tokens, chunkname).parse_chunk
      f = AST::FuncE.new
      f.body = block
      f
    end

    def compile(src : String, chunkname : String = "chunk") : LuaClosure
      env = Env.new(nil, func_env: true)
      env.varargs = [] of LuaValue
      LuaClosure.new(load(src, chunkname), env)
    end

    # Run a chunk; returns its `return` values.
    def run(src : String, chunkname : String = "chunk") : Array(LuaValue)
      f = load(src, chunkname)
      env = Env.new(nil, func_env: true)
      env.varargs = [] of LuaValue
      exec_block(f.body, env)
      [] of LuaValue
    rescue e : ReturnSignal
      e.values
    rescue e : TailCallSignal
      # top-level `return f()` is a tail call out of the main chunk
      call(e.fn, e.args)
    end

    # Convenience for specs/tools: evaluate a single expression.
    def self.eval(src : String) : LuaValue
      new.run("return #{src}")[0]?
    end

    def native(name : String, &fn : NativeFn)
      @globals.raw_set(name, LuaFunction.new(name, fn))
    end

    # --- error helpers ---

    def raise_lua(msg : String)
      raise LuaError.new("#{@chunkname}:#{@line}: #{msg}")
    end

    def arg_error(idx : Int32, fname : String, expected : String)
      raise_lua("bad argument ##{idx} to '#{fname}' (#{expected})")
    end

    # --- argument coercion helpers for native libs ---

    def num!(args : Array(LuaValue), idx : Int32, fname : String) : Float64
      v = args[idx]?
      if n = Lua.tonumber(v)
        n
      else
        arg_error(idx + 1, fname, "number expected, got #{Lua.type_name(v)}")
      end
    end

    def str!(args : Array(LuaValue), idx : Int32, fname : String) : String
      v = args[idx]?
      case v
      when String  then v
      when Float64 then Lua.fmt_num(v)
      else
        arg_error(idx + 1, fname, "string expected, got #{Lua.type_name(v)}")
      end
    end

    def table!(args : Array(LuaValue), idx : Int32, fname : String) : LuaTable
      v = args[idx]?
      if v.is_a?(LuaTable)
        v
      else
        arg_error(idx + 1, fname, "table expected, got #{Lua.type_name(v)}")
      end
    end

    def func!(args : Array(LuaValue), idx : Int32, fname : String) : LuaValue
      v = args[idx]?
      if v.is_a?(LuaClosure) || v.is_a?(LuaFunction) || (v.is_a?(LuaTable) && metafield(v, "__call")) || (v.is_a?(LuaUserData) && metafield(v, "__call"))
        v
      else
        arg_error(idx + 1, fname, "function expected, got #{Lua.type_name(v)}")
      end
    end

    # --- number parsing/formatting (5.1: numbers are doubles) ---

    def lua_tostring(v : LuaValue) : String
      case v
      when String  then v
      when Float64 then Lua.fmt_num(v)
      when Nil     then "nil"
      when Bool    then v.to_s
      when LuaTable, LuaUserData
        if mm = metafield(v, "__tostring")
          r = call(mm, [v] of LuaValue)[0]?
          unless r.is_a?(String)
            raise_lua("'__tostring' must return a string")
          end
          r
        else
          Lua.repr_addr(v)
        end
      else
        Lua.repr_addr(v)
      end
    end

    # --- calls ---

    # Call any callable value; returns all results.
    def call(f : LuaValue, args : Array(LuaValue)) : Array(LuaValue)
      case f
      when LuaFunction
        f.fn.call(self, args)
      when LuaClosure
        cur : LuaValue = f
        cur_args = args
        while cur.is_a?(LuaClosure)
          c = cur
          env = Env.new(c.env, func_env: true)
          proto = c.proto
          proto.params.each_with_index do |p, i|
            env.define(p, cur_args[i]?)
          end
          env.varargs = cur_args.size > proto.params.size ? cur_args[proto.params.size..] : [] of LuaValue
          @line = proto.line
          begin
            exec_block(proto.body, env)
            return [] of LuaValue
          rescue e : ReturnSignal
            return e.values
          rescue e : TailCallSignal
            cur = e.fn
            cur_args = e.args
          end
        end
        # tail-called into a native / callable value
        call(cur, cur_args)
      when LuaTable
        if mm = metafield(f, "__call")
          call(mm, ([f] of LuaValue).concat(args))
        else
          raise_lua("attempt to call a table value")
        end
      when LuaUserData
        if mm = metafield(f, "__call")
          call(mm, ([f] of LuaValue).concat(args))
        else
          raise_lua("attempt to call a userdata value")
        end
      when Nil
        raise_lua("attempt to call a nil value")
      else
        raise_lua("attempt to call a #{Lua.type_name(f)} value")
      end
    end

    # --- indexing with metatables ---

    def metafield(v : LuaValue, name : String) : LuaValue
      case v
      when LuaTable
        mt = v.metatable
        mt ? mt.raw_get(name) : nil
      when String
        @string_meta.raw_get(name)
      when LuaUserData
        mt = v.metatable
        mt ? mt.raw_get(name) : nil
      else
        nil
      end
    end

    def getindex(obj : LuaValue, key : LuaValue) : LuaValue
      case obj
      when LuaTable
        v = obj.raw_get(key)
        return v unless v.nil?
        if idx = metafield(obj, "__index")
          case idx
          when LuaTable then getindex(idx, key)
          else               call(idx, [obj, key] of LuaValue)[0]?
          end
        else
          nil
        end
      when String
        # strings have no raw fields; their metatable's __index is the
        # string library table
        getindex(@string_lib, key)
      when LuaUserData
        if idx = metafield(obj, "__index")
          case idx
          when LuaTable then getindex(idx, key)
          else               call(idx, [obj, key] of LuaValue)[0]?
          end
        else
          nil
        end
      when Nil
        raise_lua("attempt to index a nil value")
      else
        raise_lua("attempt to index a #{Lua.type_name(obj)} value")
      end
    end

    def setindex(obj : LuaValue, key : LuaValue, val : LuaValue) : Nil
      cur = obj
      while cur.is_a?(LuaTable)
        if cur.has_key?(key)
          cur.raw_set(key, val)
          return
        end
        ni = metafield(cur, "__newindex")
        case ni
        when Nil
          cur.raw_set(key, val)
          return
        when LuaTable
          cur = ni
        else
          call(ni, [cur, key, val] of LuaValue)
          return
        end
      end
      if cur.is_a?(LuaUserData)
        ni = metafield(cur, "__newindex")
        if ni
          call(ni, [cur, key, val] of LuaValue)
          return
        end
      end
      if cur.nil?
        raise_lua("attempt to index a nil value")
      else
        raise_lua("attempt to index a #{Lua.type_name(cur)} value")
      end
    end

    # --- equality / comparison / arithmetic (Runtime/ metatable dispatch) ---

    def lua_eq(l : LuaValue, r : LuaValue) : Bool
      if l.is_a?(Float64) && r.is_a?(Float64)
        l == r
      elsif l.is_a?(String) && r.is_a?(String)
        l == r
      elsif l.is_a?(Bool) && r.is_a?(Bool)
        l == r
      elsif l.class != r.class
        false
      else
        return true if Lua.ref_same(l, r)
        if (l.is_a?(LuaTable) && r.is_a?(LuaTable)) || (l.is_a?(LuaUserData) && r.is_a?(LuaUserData))
          mm = metafield(l, "__eq")
          mm = metafield(r, "__eq") if mm.nil?
          if mm
            return Lua.truthy(call(mm, [l, r] of LuaValue)[0]?)
          end
        end
        false
      end
    end

    def raw_eq(l : LuaValue, r : LuaValue) : Bool
      if l.is_a?(Float64) && r.is_a?(Float64)
        l == r
      elsif l.is_a?(String) && r.is_a?(String)
        l == r
      elsif l.is_a?(Bool) && r.is_a?(Bool)
        l == r
      elsif l.class != r.class
        false
      else
        Lua.ref_same(l, r)
      end
    end

    ARITH_MM = {"+" => "__add", "-" => "__sub", "*" => "__mul", "/" => "__div", "%" => "__mod", "^" => "__pow"}

    def arith(op : String, l : LuaValue, r : LuaValue) : LuaValue
      a = Lua.tonumber(l)
      b = Lua.tonumber(r)
      if a && b
        case op
        when "+" then a + b
        when "-" then a - b
        when "*" then a * b
        when "/" then a / b
        when "%" then b == 0 ? Float64::NAN : a % b
        when "^" then a ** b
        else          raise_lua("unknown arith op #{op}")
        end
      else
        mm = metafield(l, ARITH_MM[op])
        mm = metafield(r, ARITH_MM[op]) if mm.nil?
        if mm
          call(mm, [l, r] of LuaValue)[0]?
        else
          bad = a.nil? ? l : r
          raise_lua("attempt to perform arithmetic on a #{Lua.type_name(bad)} value")
        end
      end
    end

    def negate(v : LuaValue) : LuaValue
      if n = Lua.tonumber(v)
        -n
      elsif mm = metafield(v, "__unm")
        call(mm, [v, v] of LuaValue)[0]?
      else
        raise_lua("attempt to perform arithmetic on a #{Lua.type_name(v)} value")
      end
    end

    def lua_len(v : LuaValue) : LuaValue
      case v
      when String then v.bytesize.to_f64
      when LuaTable, LuaUserData
        if mm = metafield(v, "__len")
          call(mm, [v] of LuaValue)[0]?
        elsif v.is_a?(LuaTable)
          v.raw_length.to_f64
        else
          raise_lua("attempt to get length of a userdata value")
        end
      else
        raise_lua("attempt to get length of a #{Lua.type_name(v)} value")
      end
    end

    def lua_concat(l : LuaValue, r : LuaValue) : LuaValue
      lok = l.is_a?(String) || l.is_a?(Float64)
      rok = r.is_a?(String) || r.is_a?(Float64)
      if lok && rok
        to_concat_str(l) + to_concat_str(r)
      else
        mm = metafield(l, "__concat")
        mm = metafield(r, "__concat") if mm.nil?
        if mm
          call(mm, [l, r] of LuaValue)[0]?
        else
          bad = lok ? r : l
          raise_lua("attempt to concatenate a #{Lua.type_name(bad)} value")
        end
      end
    end

    private def to_concat_str(v : LuaValue) : String
      case v
      when String  then v
      when Float64 then Lua.fmt_num(v)
      else              raise_lua("attempt to concatenate a #{Lua.type_name(v)} value")
      end
    end

    # op is "<" or "<="
    def lua_compare(l : LuaValue, r : LuaValue, op : String) : Bool
      a = Lua.tonumber(l)
      b = Lua.tonumber(r)
      if a && b
        op == "<" ? a < b : a <= b
      elsif l.is_a?(String) && r.is_a?(String)
        c = l <=> r
        op == "<" ? c < 0 : c <= 0
      else
        mm = metafield(l, op == "<" ? "__lt" : "__le")
        mm = metafield(r, op == "<" ? "__lt" : "__le") if mm.nil?
        if mm
          return Lua.truthy(call(mm, [l, r] of LuaValue)[0]?)
        elsif op == "<="
          # 5.1 fallback: a <= b  as  not (b < a)
          ltm = metafield(l, "__lt")
          ltm = metafield(r, "__lt") if ltm.nil?
          if ltm
            return !Lua.truthy(call(ltm, [r, l] of LuaValue)[0]?)
          end
        end
        raise_lua("attempt to compare #{Lua.type_name(l)} with #{Lua.type_name(r)}")
      end
    end

    # --- evaluation ---

    def eval(e : AST::Expr, env : Env) : LuaValue
      @line = e.line
      case e
      when AST::NilE     then nil
      when AST::TrueE    then true
      when AST::FalseE   then false
      when AST::NumE     then e.val
      when AST::StrE     then e.val
      when AST::ParenE   then eval(e.e, env)
      when AST::VarargE
        vars = env.find_varargs
        raise_lua("illegal use of '...'") unless vars
        vars.not_nil![0]?
      when AST::NameE
        if cell = env.find(e.name)
          cell.value
        else
          getindex(@globals, e.name)
        end
      when AST::IndexE
        obj = eval(e.obj, env)
        key = eval(e.key, env)
        getindex(obj, key)
      when AST::CallE
        f = eval(e.fn, env)
        args = eval_args(e.args, env)
        call(f, args)[0]?
      when AST::MethodCallE
        obj = eval(e.obj, env)
        f = getindex(obj, e.name)
        args = [obj] of LuaValue
        args.concat(eval_args(e.args, env))
        call(f, args)[0]?
      when AST::BinopE then eval_binop(e, env)
      when AST::UnopE  then eval_unop(e, env)
      when AST::FuncE  then LuaClosure.new(e, env)
      when AST::TableE then build_table(e, env)
      else
        raise_lua("internal: unknown expression #{e.class}")
      end
    end

    # Evaluate an expression in "multiple values" position (last of a list).
    def eval_multi(e : AST::Expr, env : Env) : Array(LuaValue)
      case e
      when AST::CallE
        f = eval(e.fn, env)
        call(f, eval_args(e.args, env))
      when AST::MethodCallE
        obj = eval(e.obj, env)
        f = getindex(obj, e.name)
        args = [obj] of LuaValue
        args.concat(eval_args(e.args, env))
        call(f, args)
      when AST::VarargE
        vars = env.find_varargs
        raise_lua("illegal use of '...'") unless vars
        vars.not_nil!.dup
      else
        [eval(e, env)] of LuaValue
      end
    end

    def eval_args(exprs : Array(AST::Expr), env : Env) : Array(LuaValue)
      return [] of LuaValue if exprs.empty?
      res = [] of LuaValue
      exprs.each_with_index do |a, i|
        if i == exprs.size - 1
          res.concat(eval_multi(a, env))
        else
          res << eval(a, env)
        end
      end
      res
    end

    # Evaluate an expression list, adjusting to `want` (-1 = no adjust).
    def eval_list(exprs : Array(AST::Expr), env : Env, want : Int32) : Array(LuaValue)
      vals = eval_args(exprs, env)
      if want >= 0
        while vals.size < want
          vals << nil
        end
        vals = vals[0, want] if vals.size > want
      end
      vals
    end

    private def eval_binop(e : AST::BinopE, env : Env) : LuaValue
      case e.op
      when "and"
        l = eval(e.lhs, env)
        Lua.truthy(l) ? eval(e.rhs, env) : l
      when "or"
        l = eval(e.lhs, env)
        Lua.truthy(l) ? l : eval(e.rhs, env)
      when "=="
        lua_eq(eval(e.lhs, env), eval(e.rhs, env))
      when "~="
        !lua_eq(eval(e.lhs, env), eval(e.rhs, env))
      when "<", "<=", ">", ">="
        l = eval(e.lhs, env)
        r = eval(e.rhs, env)
        case e.op
        when "<"  then lua_compare(l, r, "<")
        when "<=" then lua_compare(l, r, "<=")
        when ">"  then lua_compare(r, l, "<")
        when ">=" then lua_compare(r, l, "<=")
        else           raise_lua("internal")
        end
      when ".."
        lua_concat(eval(e.lhs, env), eval(e.rhs, env))
      else
        arith(e.op, eval(e.lhs, env), eval(e.rhs, env))
      end
    end

    private def eval_unop(e : AST::UnopE, env : Env) : LuaValue
      case e.op
      when "not" then !Lua.truthy(eval(e.e, env))
      when "-"   then negate(eval(e.e, env))
      when "#"   then lua_len(eval(e.e, env))
      else            raise_lua("internal: unknown unop #{e.op}")
      end
    end

    private def build_table(e : AST::TableE, env : Env) : LuaTable
      t = LuaTable.new
      next_arr = 1
      e.entries.each do |entry|
        if k = entry.key
          key = eval(k, env)
          val = eval(entry.val, env)
          t.raw_set(key, val)
        else
          val = eval(entry.val, env)
          t.raw_set(next_arr.to_f64, val)
          next_arr += 1
        end
      end
      t
    end

    # --- statement execution ---

    def exec_block(block : AST::Block, env : Env) : Nil
      block.stats.each do |s|
        exec_stat(s, env)
      end
    end

    def exec_stat(s : AST::Stat, env : Env) : Nil
      @line = s.line
      case s
      when AST::LocalStat
        vals = eval_list(s.exps, env, s.names.size)
        s.names.each_with_index do |n, i|
          env.define(n, vals[i]?)
        end
      when AST::AssignStat
        vals = eval_list(s.exps, env, s.targets.size)
        s.targets.each_with_index do |t, i|
          assign_to(t, vals[i]?, env)
        end
      when AST::ExprStat
        eval_multi(s.e, env)
        nil
      when AST::DoStat
        exec_block(s.block, Env.new(env))
      when AST::IfStat
        s.clauses.each do |cond, blk|
          if Lua.truthy(eval(cond, env))
            exec_block(blk, Env.new(env))
            return
          end
        end
        if eb = s.else_block
          exec_block(eb, Env.new(env))
        end
      when AST::WhileStat
        while Lua.truthy(eval(s.cond, env))
          begin
            exec_block(s.block, Env.new(env))
          rescue e : BreakSignal
            break
          end
        end
      when AST::RepeatStat
        loop do
          benv = Env.new(env)
          begin
            exec_block(s.block, benv)
          rescue e : BreakSignal
            break
          end
          break if Lua.truthy(eval(s.cond, benv))
        end
      when AST::NumForStat
        start = for_num(s.start_e, env, "initial")
        limit = for_num(s.limit_e, env, "limit")
        step = s.step_e ? for_num(s.step_e.not_nil!, env, "step") : 1.0
        raise_lua("'for' step is zero") if step == 0
        i = start
        while step > 0 ? i <= limit : i >= limit
          iter_env = Env.new(env)
          iter_env.define(s.name, i)
          begin
            exec_block(s.block, iter_env)
          rescue e : BreakSignal
            break
          end
          i += step
        end
      when AST::GenForStat
        rets = eval_list(s.exps, env, 3)
        f = rets[0]?
        st = rets[1]?
        ctl = rets[2]?
        loop do
          r = call(f, [st, ctl] of LuaValue)
          break if (r[0]?).nil?
          ctl = r[0]
          iter_env = Env.new(env)
          s.names.each_with_index do |n, idx|
            iter_env.define(n, r[idx]?)
          end
          begin
            exec_block(s.block, iter_env)
          rescue e : BreakSignal
            break
          end
        end
      when AST::FuncStat
        fn = LuaClosure.new(s.func, env)
        assign_to(s.target, fn, env)
      when AST::LocalFuncStat
        env.define(s.name, nil)
        fn = LuaClosure.new(s.func, env)
        env.find(s.name).not_nil!.value = fn
      when AST::ReturnStat
        if s.tail
          e = s.exps[0]
          fn, args =
            if c = e.as?(AST::CallE)
              {eval(c.fn, env), eval_args(c.args, env)}
            else
              m = e.as(AST::MethodCallE)
              obj = eval(m.obj, env)
              f = getindex(obj, m.name)
              a = [obj] of LuaValue
              a.concat(eval_args(m.args, env))
              {f, a}
            end
          tc = TailCallSignal.new(fn, args)
          raise tc
        end
        rs = ReturnSignal.new
        rs.values = eval_list(s.exps, env, -1)
        raise rs
      when AST::BreakStat
        raise BreakSignal.new
      else
        raise_lua("internal: unknown statement #{s.class}")
      end
    end

    private def for_num(e : AST::Expr, env : Env, what : String) : Float64
      v = eval(e, env)
      n = Lua.tonumber(v)
      n || raise_lua("'for' #{what} value must be a number")
    end

    private def assign_to(t : AST::Expr, val : LuaValue, env : Env) : Nil
      case t
      when AST::NameE
        if cell = env.find(t.name)
          cell.value = val
        else
          setindex(@globals, t.name, val)
        end
      when AST::IndexE
        obj = eval(t.obj, env)
        key = eval(t.key, env)
        setindex(obj, key, val)
      else
        raise_lua("internal: bad assignment target")
      end
    end
  end
end
