module Lua
  # Error raised for lexical/syntactic problems (mirrors MoonSharp
  # Errors/SyntaxErrorException).
  class SyntaxError < Exception
    getter line : Int32

    def initialize(@line : Int32, msg : String)
      super(msg)
    end
  end

  # Lua tokenizer, a port of MoonSharp Lexer/ (which in turn mirrors
  # lua's llex.c). Byte-oriented: Lua strings are byte arrays, not UTF-8.
  class Lexer
    KEYWORDS = {
      "and" => Tk::And, "break" => Tk::Break, "do" => Tk::Do,
      "else" => Tk::Else, "elseif" => Tk::Elseif, "end" => Tk::End,
      "false" => Tk::False, "for" => Tk::For, "function" => Tk::Function,
      "if" => Tk::If, "in" => Tk::In, "local" => Tk::Local, "nil" => Tk::Nil,
      "not" => Tk::Not, "or" => Tk::Or, "repeat" => Tk::Repeat,
      "return" => Tk::Return, "then" => Tk::Then, "true" => Tk::True,
      "until" => Tk::Until, "while" => Tk::While,
    }

    def initialize(@src : String, @chunkname : String = "chunk")
      @s = @src.to_slice
      @pos = 0
      @line = 1
      @eol_tail = false
      @started = false
    end

    def tokens : Array(Token)
      out = [] of Token
      loop do
        t = next_token
        out << t
        break if t.kind.eof?
      end
      out
    end

    private def eof? : Bool
      @pos >= @s.size
    end

    # Byte at relative offset i, or -1 past EOF.
    private def c(i = 0) : Int32
      p = @pos + i
      p < @s.size ? @s[p].to_i : -1
    end

    # @eol_tail: the byte being consumed is the second half of a line end
    # already counted (the \n of \r\n, or the \r of \n\r).
    @eol_tail : Bool = false

    private def adv : Int32
      ch = @s[@pos].to_i
      @pos += 1
      if @eol_tail
        @eol_tail = false
      elsif ch == 0x0A || ch == 0x0D
        # llex.c inclinenumber: \n, \r, \r\n and \n\r each count as ONE
        # line — pair detection looks FORWARD from the counted byte
        @line += 1
        nxt = @pos < @s.size ? @s[@pos].to_i : -1
        @eol_tail = (ch == 0x0A && nxt == 0x0D) || (ch == 0x0D && nxt == 0x0A)
      end
      ch
    end

    private def err(msg, line = @line)
      raise SyntaxError.new(line, "#{Lua.short_src(@chunkname)}:#{line}: #{msg}")
    end

    private def skip_shebang
      return if eof? || @s[0] != 0x23 # '#'
      until eof? || @s[@pos] == 0x0A
        adv
      end
    end

    private def skip_ws_and_comments
      loop do
        ch = c
        if ch == -1
          return
        elsif ch == 0x20 || (0x09 <= ch <= 0x0D) # space, \t..\r
          adv
        elsif ch == 0x2D && c(1) == 0x2D # "--"
          adv; adv
          if c == 0x5B && (tstart = @pos) && (lvl = long_open_level)
            read_long_string(lvl, @line, tstart)
          else
            # comment runs to end of line (\n, \r or a \r\n / \n\r pair)
            until eof? || @s[@pos] == 0x0A || @s[@pos] == 0x0D
              adv
            end
          end
        elsif ch == 0x2F && c(1) == 0x2F # xray LuaJIT ext: "//" line comment
          adv; adv
          until eof? || @s[@pos] == 0x0A || @s[@pos] == 0x0D
            adv
          end
        elsif ch == 0x2F && c(1) == 0x2A # xray LuaJIT ext: "/* */" comment
          adv; adv
          until eof? || (c == 0x2A && c(1) == 0x2F)
            adv
          end
          break if eof? # xray lexer ends an unterminated /* comment at EOF silently
          adv; adv # consume '*' '/'
        else
          return
        end
      end
    end

    # If current position is `[=*[` consume the opener and return its level.
    private def long_open_level : Int32?
      i = 1
      lvl = 0
      while c(i) == 0x3D # '='
        lvl += 1
        i += 1
      end
      if c(i) == 0x5B # '['
        (i + 1).times { adv }
        lvl
      end
    end

    private def read_long_string(lvl : Int32, opener_line : Int32, tstart : Int32) : Token
      # Skip one newline right after the opener (\n, \r, \r\n or \n\r —
      # each counts as ONE line, like 5.1 inclinenumber).
      if c == 0x0D && c(1) == 0x0A
        adv; adv
      elsif c == 0x0A && c(1) == 0x0D
        adv; adv
      elsif c == 0x0A || c == 0x0D
        adv
      end
      start = @pos
      content = IO::Memory.new
      loop do
        ch = c
        if ch == -1
          err("unfinished long string/comment (starting at line #{opener_line})", opener_line)
        elsif ch == 0x5D # ']'
          i = 1
          l = 0
          while c(i) == 0x3D # '='
            l += 1
            i += 1
          end
          if c(i) == 0x5D && l == lvl
            content.write(@s[start, @pos - start])
            (l + 2).times { adv }
            raw = String.new(@s[tstart, @pos - tstart])
            return Token.new(Tk::Str, opener_line, String.new(content.to_slice), 0.0, raw)
          else
            adv
          end
        elsif ch == 0x0D || ch == 0x0A
          # interior line ends normalize to '\n' (5.1 read_long_string:
          # "save(ls, '\n'); inclinenumber(ls)")
          content.write(@s[start, @pos - start])
          adv
          adv if (ch == 0x0D && c == 0x0A) || (ch == 0x0A && c == 0x0D)
          content.write_byte(0x0A)
          start = @pos
        else
          adv
        end
      end
    end

    # Public + self-starting: the parser pulls tokens as it parses (see
    # TokenStream in parser.cr), so a lexical error past the parse
    # failure point cannot preempt a syntax error earlier in the source —
    # the way LuaJIT's streaming lexer/parser pair behaves.
    def next_token : Token
      unless @started
        skip_shebang
        @started = true
      end
      skip_ws_and_comments
      line = @line
      ch = c
      return Token.new(Tk::Eof, line) if ch == -1
      case ch
      when 0x2B then sym(Tk::Plus, "+", line)
      when 0x2D then sym(Tk::Minus, "-", line)
      when 0x2A then sym(Tk::Star, "*", line)
      when 0x2F then sym(Tk::Slash, "/", line)
      when 0x25 then sym(Tk::Percent, "%", line)
      when 0x5E then sym(Tk::Caret, "^", line)
      when 0x23 then sym(Tk::Hash, "#", line)
      when 0x28 then sym(Tk::LParen, "(", line)
      when 0x29 then sym(Tk::RParen, ")", line)
      when 0x7B then sym(Tk::LBrace, "{", line)
      when 0x7D then sym(Tk::RBrace, "}", line)
      when 0x5D then sym(Tk::RBracket, "]", line)
      when 0x3B then sym(Tk::Semi, ";", line)
      when 0x2C then sym(Tk::Comma, ",", line)
      when 0x3A then sym(Tk::Colon, ":", line)
      when 0x3D
        adv
        if c == 0x3D
          sym(Tk::Eq, "==", line, 1)
        else
          sym(Tk::Assign, "=", line, 1)
        end
      when 0x7E
        adv
        if c == 0x3D
          sym(Tk::Ne, "~=", line, 1)
        else
          err("unexpected symbol near '~'")
        end
      when 0x3C
        adv
        if c == 0x3D
          sym(Tk::Le, "<=", line, 1)
        else
          sym(Tk::Lt, "<", line, 1)
        end
      when 0x3E
        adv
        if c == 0x3D
          sym(Tk::Ge, ">=", line, 1)
        else
          sym(Tk::Gt, ">", line, 1)
        end
      when 0x2E # '.'
        if c(1) == 0x2E
          adv; adv
          if c == 0x2E
            sym(Tk::Dots, "...", line, 2)
          else
            sym(Tk::DDot, "..", line, 2)
          end
        elsif digit?(c(1))
          read_number(line)
        else
          sym(Tk::Dot, ".", line)
        end
      when 0x22, 0x27
        read_string(ch, line)
      when 0x5B # '['
        tstart = @pos
        if (lvl = long_open_level)
          read_long_string(lvl, line, tstart)
        else
          sym(Tk::LBracket, "[", line)
        end
      else
        if name_start?(ch)
          read_name(line)
        elsif digit?(ch)
          read_number(line)
        else
          # raw byte, not ch.chr: Char interpolation UTF-8-encodes >0x7F
          # bytes, but Lua strings are byte strings
          err("unexpected symbol near '#{String.new(Bytes[ch.to_u8])}'")
        end
      end
    end

    # Emit a symbol token. `pre` = bytes of `text` already consumed by the
    # caller; `sym` consumes the rest so `adv`'s newline accounting stays right.
    private def sym(kind : Tk, text : String, line : Int32, pre = 0) : Token
      (text.bytesize - pre).times { adv }
      Token.new(kind, line, text)
    end

    private def digit?(ch : Int32) : Bool
      ch >= 0x30 && ch <= 0x39
    end

    private def name_start?(ch : Int32) : Bool
      # lj_char.c: all bytes 0x80-0xFF carry LJ_CHAR_IDENT (ident, not
      # alpha) — cp1251 text lexes as a name, matching the engine oracle
      # ("copy of _test.script": "\xEF\xF0\xE8\xE2\xE5\xF2" is a NAME).
      (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x41 && ch <= 0x5A) || ch == 0x5F || ch >= 0x80
    end

    private def name_char?(ch : Int32) : Bool
      name_start?(ch) || digit?(ch)
    end

    private def hexval(ch : Int32) : Int32
      return ch - 0x30 if ch >= 0x30 && ch <= 0x39
      return ch - 0x61 + 10 if ch >= 0x61 && ch <= 0x66
      return ch - 0x41 + 10 if ch >= 0x41 && ch <= 0x46
      -1
    end

    private def read_name(line : Int32) : Token
      start = @pos
      while name_char?(c)
        adv
      end
      text = String.new(@s[start, @pos - start])
      if kw = KEYWORDS[text]?
        Token.new(kw, line, text)
      else
        Token.new(Tk::Name, line, text)
      end
    end

    private def read_number(line : Int32) : Token
      start = @pos
      text = ""
      val : Float64 = 0.0
      if c == 0x30 && (c(1) == 0x78 || c(1) == 0x58) # 0x
        adv; adv
        while hexval(c) >= 0 || c == 0x2E
          adv
        end
        text = String.new(@s[start, @pos - start])
        digits = text[2..]
        n = digits.to_i64?(16)
        err("malformed number near '#{text}'") if n.nil?
        val = n.not_nil!.to_f64
      else
        while digit?(c) || c == 0x2E # digits and dots (validated by to_f64?)
          adv
        end
        if c == 0x65 || c == 0x45 # e E
          adv
          adv if c == 0x2B || c == 0x2D
          while digit?(c)
            adv
          end
        end
        text = String.new(@s[start, @pos - start])
        n = text.to_f64?
        if n.nil?
          # Crystal rejects out-of-range doubles; strtod (and Lua) accept
          # them as +inf. Our scan guarantees the syntax, so nil = overflow
          # (a stray "1.2.3" fails the check below and stays malformed).
          err("malformed number near '#{text}'") unless text.matches?(/\A\d+\.?\d*([eE][+-]?\d+)?\z/)
          val = Float64::INFINITY
        else
          val = n
        end
      end
      Token.new(Tk::Num, line, text, val)
    end

    private def read_string(quote : Int32, line : Int32) : Token
      tstart = @pos
      adv
      buf = IO::Memory.new
      loop do
        ch = c
        if ch == -1 || ch == 0x0A || ch == 0x0D
          # lj_lex: the shown token is the raw partial string INCLUDING the
          # opening quote, control bytes and all (no escaping)
          err("unfinished string near '#{String.new(@s[tstart, @pos - tstart])}'", line)
        elsif ch == quote
          adv
          break
        elsif ch == 0x5C # '\\'
          adv
          read_escape(buf, line, tstart)
        else
          buf.write_byte(adv.to_u8)
        end
      end
      raw = String.new(@s[tstart, @pos - tstart])
      Token.new(Tk::Str, line, String.new(buf.to_slice), 0.0, raw)
    end

    private def read_escape(buf : IO::Memory, line : Int32, tstart : Int32)
      if eof?
        err("unfinished string near '#{String.new(@s[tstart, @pos - tstart])}'", line)
      end
      case e = adv
      when 0x61 then buf.write_byte(7)
      when 0x62 then buf.write_byte(8)
      when 0x66 then buf.write_byte(12)
      when 0x6E then buf.write_byte(10)
      when 0x72 then buf.write_byte(13)
      when 0x74 then buf.write_byte(9)
      when 0x76 then buf.write_byte(11)
      when 0x5C, 0x22, 0x27 then buf.write_byte(e.to_u8)
      when 0x0A, 0x0D
        # line continuation: consume the full line end (\r\n / \n\r count as
        # one) and append a single \n (5.1 read_string "line ends are turned
        # into \n")
        adv if c == 0x0D || c == 0x0A
        buf.write_byte(0x0A)
      when 0x78 # \xHH (LuaJIT extension)
        h1 = hexval(c)
        h2 = hexval(c(1))
        err("hexadecimal digit expected") if h1 < 0 || h2 < 0
        adv; adv
        buf.write_byte((h1 * 16 + h2).to_u8)
      when 0x7A # \z: skip whitespace (LuaJIT extension)
        loop do
          ch = c
          if ch == 0x20 || (0x09 <= ch <= 0x0D)
            adv
          else
            break
          end
        end
      when 0x30..0x39 # \ddd
        v = e - 0x30
        n = 1
        while n < 3 && digit?(c)
          v = v * 10 + (adv - 0x30)
          n += 1
        end
        err("decimal escape too large near '\\#{v}'") if v > 255
        buf.write_byte(v.to_u8)
      else
        # lj_lex invalid-escape error token: just the opening quote
        err(%(invalid escape sequence near '"'))
      end
    end
  end
end
