# AST nodes. Mirrors MoonSharp Parsing/ tree (which mirrors lua's lparser
# structurally, but as plain expression tree instead of code emission).
module Lua::AST
  abstract class Node
    property line : Int32 = 0

    def at(l : Int32)
      @line = l
      self
    end
  end

  abstract class Expr < Node
  end

  abstract class Stat < Node
  end

  class Block < Stat
    property stats = [] of Stat
  end

  # --- expressions ---

  class NilE < Expr; end

  class TrueE < Expr; end

  class FalseE < Expr; end

  class NumE < Expr
    property val : Float64

    def initialize(@val); end
  end

  class StrE < Expr
    property val : String

    def initialize(@val); end
  end

  class VarargE < Expr; end

  # (e): parenthesized expression, single value
  class ParenE < Expr
    property e : Expr

    def initialize(@e); end
  end

  class NameE < Expr
    property name : String

    def initialize(@name); end
  end

  class IndexE < Expr
    property obj : Expr
    property key : Expr

    def initialize(@obj, @key); end
  end

  class CallE < Expr
    property fn : Expr
    property args = [] of Expr

    def initialize(@fn, @args); end
  end

  class MethodCallE < Expr
    property obj : Expr
    property name : String
    property args = [] of Expr

    def initialize(@obj, @name, @args); end
  end

  class BinopE < Expr
    property op : String
    property lhs : Expr
    property rhs : Expr

    def initialize(@op, @lhs, @rhs); end
  end

  class UnopE < Expr
    property op : String
    property e : Expr

    def initialize(@op, @e); end
  end

  class FuncE < Expr
    property params = [] of String
    property vararg = false
    property body = Block.new
    # line of the closing 'end' (5.1 lastlinedefined)
    property end_line : Int32 = 0
  end

  class Entry < Node
    # nil key = positional field
    property key : Expr?
    property val : Expr

    def initialize(@key, @val); end
  end

  class TableE < Expr
    property entries = [] of Entry
  end

  # --- statements ---

  class LocalStat < Stat
    property names = [] of String
    property exps = [] of Expr
  end

  class AssignStat < Stat
    property targets = [] of Expr
    property exps = [] of Expr

    def initialize(@targets, @exps); end
  end

  class ExprStat < Stat
    property e : Expr

    def initialize(@e); end
  end

  class DoStat < Stat
    property block : Block = Block.new

    def initialize(@block); end
  end

  class WhileStat < Stat
    property cond : Expr
    property block : Block = Block.new

    def initialize(@cond, @block); end
  end

  class RepeatStat < Stat
    property block : Block = Block.new
    property cond : Expr

    def initialize(@block, @cond); end
  end

  class IfStat < Stat
    property clauses = [] of Tuple(Expr, Block)
    property else_block : Block?
  end

  class NumForStat < Stat
    property name : String
    property start_e : Expr
    property limit_e : Expr
    property step_e : Expr?
    property block : Block = Block.new

    def initialize(@name, @start_e, @limit_e, @step_e, @block); end
  end

  class GenForStat < Stat
    property names = [] of String
    property exps = [] of Expr
    property block : Block = Block.new
  end

  class FuncStat < Stat
    # Assignment target: a.b.c or a.b.c:d (self is added to params by parser)
    property target : Expr
    property func : FuncE

    def initialize(@target, @func); end
  end

  class LocalFuncStat < Stat
    property name : String
    property func : FuncE

    def initialize(@name, @func); end
  end

  class ReturnStat < Stat
    property exps = [] of Expr
    # true when exps is exactly one call/method-call (proper tail call)
    property tail = false
  end

  class BreakStat < Stat; end
end
