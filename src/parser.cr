# Recursive-descent parser for Lua 5.1, a port of MoonSharp Parsing/
# (hand-written, mirrors lua's lparser.c grammar).
module Lua
  class Parser
    # operator name => binary precedence (higher binds tighter)
    BINPREC = {
      "or" => 1, "and" => 2,
      "<" => 3, ">" => 3, "<=" => 3, ">=" => 3, "~=" => 3, "==" => 3,
      ".." => 4,
      "+" => 5, "-" => 5,
      "*" => 6, "/" => 6, "%" => 6,
      "^" => 9,
    }
    RIGHT_ASSOC = {"..", "^"}
    UNARY_PREC = 8

    # Parse-time emulation of the 5.1 per-function limits (LUAI_MAXVARS=200,
    # LUAI_MAXUPVALUES=60): our pipeline parses the whole chunk before
    # compiling, so these must fire during parsing for chunks that never
    # reach codegen (the errors.lua limit tests build such chunks).
    class FnScope
      getter line : Int32
      getter locals = Set(String).new
      getter upvals = Set(String).new

      def initialize(@line)
      end
    end

    def initialize(@toks : Array(Token), @chunkname : String = "chunk")
      @pos = 0
      @last_line = 1
      @fnscopes = [FnScope.new(0)]
    end

    # A name reference: if it resolves to a local of an enclosing function,
    # every function between it and the owner routes it through its upvalue
    # list (5.1 singlevaraux) — each may not exceed 60 distinct upvalues.
    private def note_ref(name : String) : Nil
      scopes = @fnscopes
      owner = -1
      i = scopes.size - 1
      while i >= 0
        if scopes[i].locals.includes?(name)
          owner = i
          break
        end
        i -= 1
      end
      return if owner < 0 # resolves to a global: no chain
      i = scopes.size - 1
      while i > owner
        s = scopes[i]
        if s.upvals.add?(name) && s.upvals.size > 60
          err("function at line #{s.line} has more than 60 upvalues")
        end
        i -= 1
      end
    end

    private def add_locals(names : Array(String)) : Nil
      s = @fnscopes.last
      names.each { |n| s.locals << n }
      if s.locals.size > 200
        err("function at line #{s.line} has more than 200 local variables")
      end
    end

    def parse_chunk : AST::Block
      b = parse_block
      unless cur.kind.eof?
        err("unexpected symbol near '#{cur.describe}'")
      end
      # the main chunk's last token line: luaY_parser emits the implicit
      # return standing at the end of the chunk
      b.end_line = (@toks[@pos - 1]?.try(&.line) || 0)
      b
    end

    private def cur : Token
      @toks[@pos]
    end

    private def peek : Token
      @toks[@pos + 1]? || @toks.last
    end

    private def adv : Token
      t = @toks[@pos]
      @last_line = t.line
      @pos += 1 unless t.kind.eof?
      t
    end

    private def check(k : Tk) : Bool
      cur.kind == k
    end

    private def accept(k : Tk) : Bool
      if check(k)
        adv
        true
      else
        false
      end
    end

    private def expect(k : Tk, what : String? = nil)
      unless check(k)
        err("'#{what || describe_kind(k)}' expected near '#{cur.describe}'")
      end
      adv
    end

    private def describe_kind(k : Tk) : String
      k.to_s.downcase
    end

    private def err(msg)
      raise SyntaxError.new(cur.line, "#{Lua.short_src(@chunkname)}:#{cur.line}: #{msg}")
    end

    # 5.1 LUAI_MAXCCALLS: nesting limit for blocks and expressions ("chunk
    # has too many syntax levels"); also bounds parser recursion
    MAX_LEVELS = 200
    @depth = 0

    private def level_up
      err("chunk has too many syntax levels") if @depth >= MAX_LEVELS
      @depth += 1
      begin
        yield
      ensure
        @depth -= 1
      end
    end

    private def expect_name : String
      err("<name> expected near '#{cur.describe}'") unless check(Tk::Name)
      adv.text
    end

    # --- blocks ---

    private def block_follow? : Bool
      case cur.kind
      when .end?, .else?, .elseif?, .until?, .eof?
        true
      else
        false
      end
    end

    private def parse_block : AST::Block
      level_up do
        block = AST::Block.new
        until block_follow?
          break if check(Tk::Return) || check(Tk::Break)
          block.stats << parse_stat
          accept(Tk::Semi) # 5.1 grammar: stat [';'] — one optional ';'
        end
        if check(Tk::Return)
          line = cur.line
          adv
          exps = [] of AST::Expr
          unless block_follow? || check(Tk::Semi)
            exps = parse_explist
          end
          accept(Tk::Semi)
          rs = AST::ReturnStat.new
          rs.exps = exps
          # proper tail call: exactly one call expression
          rs.tail = exps.size == 1 && (exps[0].is_a?(AST::CallE) || exps[0].is_a?(AST::MethodCallE))
          rs.at(line)
          block.stats << rs
        elsif check(Tk::Break)
          line = cur.line
          adv
          accept(Tk::Semi)
          block.stats << AST::BreakStat.new.at(line)
        end
        block
      end
    end

    # --- statements ---

    private def parse_stat : AST::Stat
      line = cur.line
      case cur.kind
      when .do?
        adv
        b = parse_block
        expect(Tk::End)
        AST::DoStat.new(b).at(line)
      when .while?
        adv
        cond = parse_expr
        expect(Tk::Do)
        b = parse_block
        expect(Tk::End)
        AST::WhileStat.new(cond, b).at(line)
      when .repeat?
        adv
        b = parse_block
        expect(Tk::Until)
        cond = parse_expr
        AST::RepeatStat.new(b, cond).at(line)
      when .if?
        parse_if(line)
      when .for?
        parse_for(line)
      when .function?
        parse_funcstat(line)
      when .local?
        adv
        if check(Tk::Function)
          adv
          name = expect_name
          # visible inside its own body (recursion)
          @fnscopes.last.locals << name
          fn = parse_funcbody
          AST::LocalFuncStat.new(name, fn).at(line)
        else
          st = AST::LocalStat.new
          st.names << expect_name
          while accept(Tk::Comma)
            st.names << expect_name
          end
          if accept(Tk::Assign)
            st.exps = parse_explist
          end
          # declared only after the initializer list is parsed
          # (`local x = x` sees the outer x)
          add_locals(st.names)
          st.at(line)
        end
      else
        # expression statement: only a call is valid
        e = parse_suffixed
        if check(Tk::Assign) || check(Tk::Comma)
          targets = [e] of AST::Expr
          while accept(Tk::Comma)
            targets << parse_suffixed
          end
          expect(Tk::Assign)
          exps = parse_explist
          targets.each do |t|
            unless t.is_a?(AST::NameE) || t.is_a?(AST::IndexE)
              err("syntax error near '#{cur.describe}'")
            end
          end
          AST::AssignStat.new(targets, exps).at(line)
        elsif e.is_a?(AST::CallE) || e.is_a?(AST::MethodCallE)
          AST::ExprStat.new(e).at(line)
        else
          err("syntax error near '#{cur.describe}'")
        end
      end
    end

    private def parse_if(line : Int32) : AST::Stat
      adv # if
      st = AST::IfStat.new
      cond = parse_expr
      expect(Tk::Then)
      st.clauses << {cond, parse_block}
      while check(Tk::Elseif)
        adv
        c2 = parse_expr
        expect(Tk::Then)
        st.clauses << {c2, parse_block}
      end
      if check(Tk::Else)
        adv
        st.else_block = parse_block
      end
      expect(Tk::End)
      st.at(line)
    end

    private def parse_for(line : Int32) : AST::Stat
      adv # for
      name1 = expect_name
      if check(Tk::Assign)
        adv
        start_e = parse_expr
        expect(Tk::Comma)
        limit_e = parse_expr
        step_e = accept(Tk::Comma) ? parse_expr : nil
        expect(Tk::Do)
        @fnscopes.last.locals << name1
        b = parse_block
        expect(Tk::End)
        AST::NumForStat.new(name1, start_e, limit_e, step_e, b).at(line)
      elsif check(Tk::Comma) || check(Tk::In)
        st = AST::GenForStat.new
        st.names << name1
        while accept(Tk::Comma)
          st.names << expect_name
        end
        expect(Tk::In)
        st.exps = parse_explist
        expect(Tk::Do)
        @fnscopes.last.locals.concat(st.names)
        st.block = parse_block
        expect(Tk::End)
        st.at(line)
      else
        err("'=' or 'in' expected near '#{cur.describe}'")
      end
    end

    private def parse_funcstat(line : Int32) : AST::Stat
      adv # function
      names = [expect_name]
      while check(Tk::Dot) || check(Tk::Colon)
        if accept(Tk::Dot)
          names << expect_name
        else # colon
          adv
          names << expect_name
          fn = parse_funcbody
          fn.params.unshift("self")
          return AST::FuncStat.new(names_to_target(names, line), fn).at(line)
        end
      end
      fn = parse_funcbody
      AST::FuncStat.new(names_to_target(names, line), fn).at(line)
    end

    # a.b.c -> IndexE(IndexE(NameE(a), StrE(b)), StrE(c))
    private def names_to_target(names : Array(String), line : Int32) : AST::Expr
      e = AST::NameE.new(names[0]).at(line).as(AST::Expr)
      names[1..].each do |n|
        e = AST::IndexE.new(e, AST::StrE.new(n).at(line)).at(line)
      end
      e
    end

    private def parse_funcbody : AST::FuncE
      line = cur.line
      expect(Tk::LParen)
      f = AST::FuncE.new
      unless check(Tk::RParen)
        loop do
          if check(Tk::Name)
            f.params << adv.text
          elsif check(Tk::Dots)
            adv
            f.vararg = true
            break
          else
            err("<name> or '...' expected near '#{cur.describe}'")
          end
          break unless accept(Tk::Comma)
        end
      end
      expect(Tk::RParen)
      @fnscopes.push(FnScope.new(line))
      @fnscopes.last.locals.concat(f.params)
      f.body = parse_block
      f.end_line = cur.line # the closing 'end': 5.1 lastlinedefined
      expect(Tk::End)
      @fnscopes.pop
      f.at(line)
    end

    # --- expressions ---

    private def parse_explist : Array(AST::Expr)
      exps = [parse_expr] of AST::Expr
      while accept(Tk::Comma)
        exps << parse_expr
      end
      exps
    end

    private def parse_expr : AST::Expr
      subexp(0)
    end

    private def unop?(t : Token) : String?
      case t.kind
      when .not? then "not"
      when .minus? then "-"
      when .hash? then "#"
      else nil
      end
    end

    private def binop?(t : Token) : {String, Int32}?
      case t.kind
      when .or?       then {"or", 1}
      when .and?      then {"and", 2}
      when .lt?       then {"<", 3}
      when .gt?       then {">", 3}
      when .le?       then {"<=", 3}
      when .ge?       then {">=", 3}
      when .ne?       then {"~=", 3}
      when .eq?       then {"==", 3}
      when .d_dot?    then {"..", 4}
      when .plus?     then {"+", 5}
      when .minus?    then {"-", 5}
      when .star?     then {"*", 6}
      when .slash?    then {"/", 6}
      when .percent?  then {"%", 6}
      when .caret?    then {"^", 9}
      else nil
      end
    end

    private def subexp(limit : Int32) : AST::Expr
      level_up do
        left : AST::Expr
        if u = unop?(cur)
          line = cur.line
          adv
          operand = subexp(UNARY_PREC)
          left = AST::UnopE.new(u, operand).at(line)
        else
          left = parse_simple
        end
        loop do
          info = binop?(cur)
          break if info.nil?
          op, prec = info
          break unless prec > limit
          line = cur.line
          adv
          rprec = RIGHT_ASSOC.includes?(op) ? prec - 1 : prec
          right = subexp(rprec)
          left = AST::BinopE.new(op, left, right).at(line)
        end
        left
      end
    end

    private def parse_simple : AST::Expr
      line = cur.line
      case cur.kind
      when Tk::Nil   then adv; AST::NilE.new.at(line)
      when .true?    then adv; AST::TrueE.new.at(line)
      when .false?   then adv; AST::FalseE.new.at(line)
      when .num?     then t = adv; AST::NumE.new(t.num).at(line)
      when .str?     then t = adv; AST::StrE.new(t.text).at(line)
      when .dots?    then adv; AST::VarargE.new.at(line)
      when .function?
        adv
        parse_funcbody
      when .l_brace?
        parse_table
      else
        parse_suffixed
      end
    end

    private def parse_primary : AST::Expr
      line = cur.line
      if check(Tk::Name)
        name = adv.text
        note_ref(name)
        AST::NameE.new(name).at(line)
      elsif check(Tk::LParen)
        adv
        e = parse_expr
        expect(Tk::RParen)
        AST::ParenE.new(e).at(line)
      else
        err("unexpected symbol near '#{cur.describe}'")
      end
    end

    private def parse_suffixed : AST::Expr
      e = parse_primary
      loop do
        line = cur.line
        case cur.kind
        when .dot?
          adv
          e = AST::IndexE.new(e, AST::StrE.new(expect_name).at(line)).at(line)
        when .l_bracket?
          adv
          k = parse_expr
          expect(Tk::RBracket)
          e = AST::IndexE.new(e, k).at(line)
        when .colon?
          adv
          name = expect_name
          args = parse_args
          e = AST::MethodCallE.new(e, name, args).at(line)
        when .l_paren?, .l_brace?, .str?
          args = parse_args
          e = AST::CallE.new(e, args).at(line)
        else
          break
        end
      end
      e
    end

    private def parse_args : Array(AST::Expr)
      if check(Tk::LParen)
        # lparser.c funcargs: '(' args on a different line than the called
        # expression are ambiguous with a new statement — reject like 5.1
        if cur.line != @last_line
          err("ambiguous syntax (function call x new statement)")
        end
        adv
        exps = check(Tk::RParen) ? [] of AST::Expr : parse_explist
        expect(Tk::RParen)
        exps
      elsif check(Tk::LBrace)
        [parse_table] of AST::Expr
      elsif check(Tk::Str)
        t = adv
        [AST::StrE.new(t.text).at(t.line)] of AST::Expr
      else
        err("function arguments expected near '#{cur.describe}'")
      end
    end

    private def parse_table : AST::Expr
      line = cur.line
      expect(Tk::LBrace)
      t = AST::TableE.new
      until check(Tk::RBrace)
        if accept(Tk::LBracket)
          k = parse_expr
          expect(Tk::RBracket)
          expect(Tk::Assign)
          t.entries << AST::Entry.new(k, parse_expr)
        elsif check(Tk::Name) && peek.kind.assign?
          name = adv.text
          adv # '='
          t.entries << AST::Entry.new(AST::StrE.new(name).at(line), parse_expr)
        else
          t.entries << AST::Entry.new(nil, parse_expr)
        end
        break unless accept(Tk::Comma) || accept(Tk::Semi)
      end
      expect(Tk::RBrace)
      t.at(line)
    end
  end
end
