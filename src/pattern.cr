# Lua 5.1 pattern matching engine — a faithful port of the matcher in
# lstrlib.c (match/class_end/singlematch/matchbracketclass/max_expand/
# min_expand/matchbalance/start_capture/end_capture/match_capture).
# Byte-oriented: positions are 0-based indices into Bytes.
module Lua::Pattern
  # Raised as a Lua error (not wrapped as a Crystal failure at the boundary)
  class PatternError < LuaError
    def initialize(msg : String)
      super(msg)
    end
  end

  struct Cap
    getter start : Int32
    # len == -1: open (unfinished) capture; used internally only.
    # len == -2: position capture "()" — `start` is the 1-based position.
    getter len : Int32

    def initialize(@start, @len)
    end

    def position? : Bool
      @len == -2
    end
  end

  class MatchResult
    getter end_pos : Int32          # 0-based, exclusive
    getter caps : Array(Cap)

    def initialize(@end_pos, @caps)
    end
  end

  class Matcher
    def initialize(@p : Bytes, @s : Bytes)
      @cap_start = [] of Int32
      @cap_len = [] of Int32
    end

    # Try to match the pattern at position init. Returns result or nil.
    def match_at(init : Int32) : MatchResult?
      res = m(init, 0)
      return nil if res.nil?
      caps = [] of Cap
      @cap_start.each_with_index do |st, idx|
        len = @cap_len[idx]
        raise PatternError.new("unfinished capture") if len == -1
        caps << (len == -2 ? Cap.new(st + 1, -2) : Cap.new(st, len))
      end
      MatchResult.new(res, caps)
    end

    def whole_capture(s : Bytes, cap : Cap) : String | Float64
      # position captures "()" are NUMBERS in 5.1
      cap.position? ? cap.start.to_f64 : String.new(s[cap.start, cap.len])
    end

    # --- the matcher (port of lstrlib match()) ---

    private def m(sp : Int32, pp : Int32) : Int32?
      s = sp
      p = pp
      while true
        # Pattern exhausted => match succeeded (Lua 5.2+ does this with
        # ms->p_end; 5.1 relied on the '\0' terminator, which Bytes lack).
        return s if p >= @p.size
        pc = @p[p]?
        if pc == 0x28 # '('
          if @p[p + 1]? == 0x29 # ')'
            return start_capture(s, p + 2, true)
          else
            return start_capture(s, p + 1, false)
          end
        elsif pc == 0x29 # ')'
          return end_capture(s, p + 1)
        elsif pc == 0x24 && @p[p + 1]?.nil? # '$' at end of pattern
          return s == @s.size ? s : nil
        elsif pc == 0x25 # '%'
          case @p[p + 1]?
          when 0x62 # 'b' — %bxy balance
            r = match_balance(s, p + 1)
            return nil if r.nil?
            s = r.not_nil!
            p += 4
            next
          when 0x66 # 'f' — frontier %f[set]
            p += 2
            unless @p[p]? == 0x5B # '['
              raise PatternError.new("missing '[' after '%f' in pattern")
            end
            ep = class_end(p)
            prev = s == 0 ? 0_u8 : @s[s - 1]
            cur = s < @s.size ? @s[s] : 0_u8
            if !match_bracket(prev, p, ep - 1) && match_bracket(cur, p, ep - 1)
              p = ep
              next
            else
              return nil
            end
          else
            d = @p[p + 1]?
            if d == 0x30 # '0' — not a valid capture reference in patterns
              raise PatternError.new("invalid capture index")
            elsif d && d >= 0x31 && d <= 0x39 # '1'..'9' backreference
              r = match_capture(s, d - 0x30)
              return nil if r.nil?
              s = r.not_nil!
              p += 2
              next
            end
            # else: %x class, falls through to default handling
          end
        end
        # default: single class at p, optional quantifier at ep
        ep = class_end(p)
        case @p[ep]?
        when 0x3F # '?'
          if single_match(s, p, ep)
            r = m(s + 1, ep + 1)
            return r unless r.nil?
          end
          return m(s, ep + 1)
        when 0x2B # '+'
          return single_match(s, p, ep) ? max_expand(s + 1, p, ep) : nil
        when 0x2A # '*'
          return max_expand(s, p, ep)
        when 0x2D # '-'
          return min_expand(s, p, ep)
        else
          return nil unless single_match(s, p, ep)
          s += 1
          p = ep
        end
      end
    end

    # --- helpers (port of lstrlib statics) ---

    private def class_end(p : Int32) : Int32
      c = @p[p]?
      raise PatternError.new("malformed pattern (ends with '%')") if c.nil?
      if c == 0x25 # '%'
        raise PatternError.new("malformed pattern (ends with '%')") if @p[p + 1]?.nil?
        return p + 2
      elsif c == 0x5B # '['
        pp = p + 1
        pp += 1 if @p[pp]? == 0x5E # '^'
        loop do
          x = @p[pp]?
          raise PatternError.new("malformed pattern (missing ']')") if x.nil?
          pp += 1
          if x == 0x25 # '%'
            raise PatternError.new("malformed pattern") if @p[pp]?.nil?
            pp += 1
          end
          break if @p[pp]? == 0x5D # ']'
        end
        pp + 1
      else
        p + 1
      end
    end

    private def single_match(sp : Int32, p : Int32, ep : Int32) : Bool
      return false if sp >= @s.size
      c = @s[sp]
      case @p[p]?
      when 0x2E then true # '.' matches any char
      when 0x25 then match_class(c, @p[p + 1]?.not_nil!)
      when 0x5B then match_bracket(c, p, ep - 1)
      else           c == @p[p]?
      end
    end

    private def match_class(c : UInt8, cl : UInt8) : Bool
      res =
        case cl | 0x20 # ASCII tolower: 'S' shares 's's predicate
        when 0x61 then alpha?(c)                 # a/A
        when 0x63 then cntrl?(c)                 # c/C
        when 0x64 then digit?(c)                 # d/D
        when 0x6C then lower?(c)                 # l/L
        when 0x70 then punct?(c)                 # p/P
        when 0x73 then space?(c)                 # s/S
        when 0x75 then upper?(c)                 # u/U
        when 0x77 then alpha?(c) || digit?(c)    # w/W
        when 0x78 then xdigit?(c)                # x/X
        when 0x7A then c == 0_u8                 # z/Z (5.1: the zero byte)
        else          cl == c
        end
      # an uppercase non-class letter (e.g. %Z) negates the literal char
      # match — quirky but exact lstrlib behavior
      upper?(cl) ? !res : res
    end

    private def match_bracket(c : UInt8, p : Int32, ec : Int32) : Bool
      sig = true
      p += 1
      if @p[p]? == 0x5E # '^'
        sig = false
        p += 1
      end
      while p < ec
        if @p[p]? == 0x25 # '%'
          p += 1
          return sig if match_class(c, @p[p]?.not_nil!)
          p += 1
        elsif @p[p + 1]? == 0x2D && p + 2 < ec # '-' range
          lo = @p[p]?
          hi = @p[p + 2]?
          return sig if lo && hi && lo <= c && c <= hi
          p += 3
        elsif @p[p]? == c
          return sig
        else
          p += 1
        end
      end
      !sig
    end

    private def max_expand(sp : Int32, p : Int32, ep : Int32) : Int32?
      i = 0
      while single_match(sp + i, p, ep)
        i += 1
      end
      while i >= 0
        r = m(sp + i, ep + 1)
        return r unless r.nil?
        i -= 1
      end
      nil
    end

    private def min_expand(sp : Int32, p : Int32, ep : Int32) : Int32?
      s = sp
      loop do
        r = m(s, ep + 1)
        return r unless r.nil?
        return nil unless single_match(s, p, ep)
        s += 1
      end
    end

    # p_at_b points at 'b' of "%b"
    private def match_balance(sp : Int32, p_at_b : Int32) : Int32?
      b = @p[p_at_b + 1]?
      e = @p[p_at_b + 2]?
      raise PatternError.new("malformed pattern (missing arguments to '%b')") if b.nil? || e.nil?
      return nil if sp >= @s.size || @s[sp] != b.not_nil!
      cont = 1
      i = sp + 1
      while i < @s.size
        if @s[i] == e
          cont -= 1
          return i + 1 if cont == 0
        elsif @s[i] == b
          cont += 1
        end
        i += 1
      end
      nil
    end

    private def start_capture(sp : Int32, p : Int32, position : Bool) : Int32?
      raise PatternError.new("too many captures") if @cap_start.size >= 32
      @cap_start << sp
      @cap_len << (position ? -2 : -1)
      r = m(sp, p)
      if r.nil?
        @cap_start.pop
        @cap_len.pop
      end
      r
    end

    private def end_capture(sp : Int32, p : Int32) : Int32?
      i = (@cap_len.size - 1).downto(0).find { |k| @cap_len[k] == -1 }
      raise PatternError.new("invalid pattern capture") if i.nil?
      @cap_len[i.not_nil!] = sp - @cap_start[i.not_nil!]
      r = m(sp, p)
      @cap_len[i.not_nil!] = -1 if r.nil?
      r
    end

    private def match_capture(sp : Int32, l : Int32) : Int32?
      idx = l - 1
      if idx < 0 || idx >= @cap_len.size || @cap_len[idx] == -1
        raise PatternError.new("invalid capture index")
      end
      len = @cap_len[idx]
      return nil if len < 0 # position captures cannot be backreferenced
      if @s.size - sp >= len && @s[@cap_start[idx], len] == @s[sp, len]
        sp + len
      end
    end

    # --- byte classification (C locale, like lstrlib) ---

    private def alpha?(c : UInt8) : Bool
      (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    end

    private def digit?(c : UInt8) : Bool
      c >= 0x30 && c <= 0x39
    end

    private def lower?(c : UInt8) : Bool
      c >= 0x61 && c <= 0x7A
    end

    private def upper?(c : UInt8) : Bool
      c >= 0x41 && c <= 0x5A
    end

    private def space?(c : UInt8) : Bool
      c == 0x20 || (c >= 0x09 && c <= 0x0D)
    end

    private def punct?(c : UInt8) : Bool
      (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) ||
        (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    end

    private def cntrl?(c : UInt8) : Bool
      c < 0x20 || c == 0x7F
    end

    private def xdigit?(c : UInt8) : Bool
      digit?(c) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
    end
  end
end
