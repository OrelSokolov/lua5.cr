# Tokens produced by `Lua::Lexer`.
module Lua
  enum Tk
    And; Break; Do; Else; Elseif; End; False; For; Function; If
    In; Local; Nil; Not; Or; Repeat; Return; Then; True; Until; While
    Plus; Minus; Star; Slash; Percent; Caret; Hash; Eq; Ne; Le; Ge; Lt; Gt
    Assign; LParen; RParen; LBrace; RBrace; LBracket; RBracket
    Semi; Colon; Comma; Dot; DDot; Dots
    Name; Num; Str; Eof
  end

  struct Token
    getter kind : Tk
    getter line : Int32
    # Literal text (name / symbol / number source text), used in error messages.
    getter text : String
    # Numeric value when kind == Num.
    getter num : Float64

    def initialize(@kind : Tk, @line : Int32, @text : String = "", @num : Float64 = 0.0)
    end

    # Lua-style description for "near '...'" messages.
    def describe : String
      case @kind
      when Tk::Eof    then "<eof>"
      when Tk::Num    then @text
      when Tk::Str    then "string"
      else                 "'#{@text}'"
      end
    end
  end
end
