# string library. Port of lstrlib.c: byte-oriented basics + full pattern
# matching (find/match/gmatch/gsub) + format.
module Lua::Stdlib
  module StringLib
    def self.install(i : Interp)
      tbl = i.string_lib

      tbl.raw_set("len", LuaFunction.new("string.len", ->(i2 : Interp, args : Array(LuaValue)) {
        [i2.str!(args, 0, "len").bytesize.to_f64] of LuaValue
      }))

      tbl.raw_set("sub", LuaFunction.new("string.sub", ->(i2 : Interp, args : Array(LuaValue)) {
        s = i2.str!(args, 0, "sub").to_slice
        len = s.size
        a = posrelat((Lua.tonumber(args[1]?) || 1).to_i, len, true)
        b = args.size > 1 ? posrelat((Lua.tonumber(args[2]?) || -1).to_i, len, false) : len
        if a > b || a > len
          [""] of LuaValue
        else
          [String.new(s[a - 1, b - a + 1])] of LuaValue
        end
      }))

      tbl.raw_set("upper", LuaFunction.new("string.upper", ->(i2 : Interp, args : Array(LuaValue)) {
        [ascii_map(i2.str!(args, 0, "upper"), &.upcase)] of LuaValue
      }))

      tbl.raw_set("lower", LuaFunction.new("string.lower", ->(i2 : Interp, args : Array(LuaValue)) {
        [ascii_map(i2.str!(args, 0, "lower"), &.downcase)] of LuaValue
      }))

      tbl.raw_set("rep", LuaFunction.new("string.rep", ->(i2 : Interp, args : Array(LuaValue)) {
        s = i2.str!(args, 0, "rep")
        n = i2.num!(args, 1, "rep").to_i
        sep = args.size > 2 ? i2.str!(args, 2, "rep") : ""
        if n <= 0
          [""] of LuaValue
        elsif s.bytesize.to_i64 * n + (n - 1).to_i64 * sep.bytesize > 2_i64**31
          i2.raise_lua("resulting string too large")
        else
          [s + (sep + s) * (n - 1)] of LuaValue
        end
      }))

      tbl.raw_set("reverse", LuaFunction.new("string.reverse", ->(i2 : Interp, args : Array(LuaValue)) {
        sl = i2.str!(args, 0, "reverse").to_slice.dup
        sl.reverse!
        [String.new(sl)] of LuaValue
      }))

      tbl.raw_set("byte", LuaFunction.new("string.byte", ->(i2 : Interp, args : Array(LuaValue)) {
        s = i2.str!(args, 0, "byte").to_slice
        len = s.size
        a = posrelat((Lua.tonumber(args[1]?) || 1).to_i, len, true)
        b = args.size > 1 ? posrelat((Lua.tonumber(args[2]?) || a).to_i, len, false) : a
        res = [] of LuaValue
        x = a
        while x <= b && x <= len
          res << s[x - 1].to_f64
          x += 1
        end
        res
      }))

      tbl.raw_set("char", LuaFunction.new("string.char", ->(i2 : Interp, args : Array(LuaValue)) {
        buf = IO::Memory.new
        args.each_with_index do |v, k|
          n = i2.num!(args, k, "char")
          i2.raise_lua("bad argument ##{k + 1} to 'char' (value out of range)") if n < 0 || n > 255 || n != n.trunc
          buf.write_byte(n.to_u8)
        end
        [String.new(buf.to_slice)] of LuaValue
      }))

      tbl.raw_set("format", LuaFunction.new("string.format", ->(i2 : Interp, args : Array(LuaValue)) {
        [format(i2, args)] of LuaValue
      }))

      tbl.raw_set("find", LuaFunction.new("string.find", ->(i2 : Interp, args : Array(LuaValue)) {
        find(i2, args)
      }))

      tbl.raw_set("match", LuaFunction.new("string.match", ->(i2 : Interp, args : Array(LuaValue)) {
        s = i2.str!(args, 0, "match").to_slice
        p = i2.str!(args, 1, "match").to_slice
        init = init_arg(i2, args, 2, "match", s.size)
        pat, anchored = strip_anchor(p)
        pos = init
        while pos <= s.size
          m = Pattern::Matcher.new(pat, s).match_at(pos)
          if m
            return captures_or(i2, s, m, pos, false)
          end
          break if anchored
          pos += 1
        end
        [nil] of LuaValue
      }))

      tbl.raw_set("gmatch", LuaFunction.new("string.gmatch", ->(i2 : Interp, args : Array(LuaValue)) {
        s = i2.str!(args, 0, "gmatch").to_slice
        p = i2.str!(args, 1, "gmatch").to_slice
        pat, anchored = strip_anchor(p)
        st = GmatchState.new(s, pat, anchored)
        iter = LuaFunction.new("gmatch_iter", ->(i3 : Interp, _a : Array(LuaValue)) {
          st.next_match(i3)
        })
        [iter] of LuaValue
      }))

      tbl.raw_set("gsub", LuaFunction.new("string.gsub", ->(i2 : Interp, args : Array(LuaValue)) {
        s = i2.str!(args, 0, "gsub").to_slice
        p = i2.str!(args, 1, "gsub").to_slice
        repl = args[2]?
        max = args.size > 3 ? (Lua.tonumber(args[3]) || -1).to_i : -1
        pat, anchored = strip_anchor(p)
        buf = IO::Memory.new
        count = 0
        pos = 0
        while count != max
          m = Pattern::Matcher.new(pat, s).match_at(pos)
          if m
            count += 1
            add_replacement(i2, buf, s, pos, m, repl)
            e = m.end_pos
            if e > pos
              pos = e
            elsif pos < s.size # empty match: copy one byte and advance
              buf.write_byte(s[pos])
              pos += 1
            else # empty match at end of subject: done (lstrlib breaks here)
              break
            end
          elsif pos < s.size
            buf.write_byte(s[pos])
            pos += 1
          else
            break
          end
          break if anchored
        end
        buf.write(s[pos..]) if pos < s.size
        [String.new(buf.to_slice), count.to_f64] of LuaValue
      }))

      i.globals.raw_set("string", tbl)
    end

    # --- helpers ---

    class GmatchState
      def initialize(@s : Bytes, @p : Bytes, @anchored : Bool)
        @pos = 0
      end

      def next_match(i2 : Interp) : Array(LuaValue)
        while @pos <= @s.size
          m = Pattern::Matcher.new(@p, @s).match_at(@pos)
          if m
            start = @pos
            e = m.end_pos
            @pos = e > start ? e : e + 1
            return StringLib.captures_or(i2, @s, m, start, false)
          end
          break if @anchored
          @pos += 1
        end
        [] of LuaValue
      end
    end

    def self.ascii_map(s : String, &f : Char -> Char) : String
      buf = IO::Memory.new
      s.each_byte do |b|
        c = b.unsafe_chr
        buf.write_byte((f.call(c).ord).to_u8)
      end
      String.new(buf.to_slice)
    end

    # posrelat: translate 1-based (possibly negative) index into [lo, hi].
    private def self.posrelat(p : Int32, len : Int32, is_start : Bool) : Int32
      if p >= 0
        p
      else
        len + p + 1
      end.clamp(is_start ? 1 : 0, len + 1)
    end

    private def self.init_arg(i2 : Interp, args : Array(LuaValue), idx : Int32, fname : String, len : Int32) : Int32
      init = args.size > idx ? (Lua.tonumber(args[idx]) || 1).to_i : 1
      init = posrelat(init, len, false) - 1 # 0-based byte offset
      return init if init >= 0 && init <= len
      i2.arg_error(idx + 1, fname, "out of range")
    end

    private def self.strip_anchor(p : Bytes) : {Bytes, Bool}
      if p.size > 0 && p[0] == 0x5E # '^'
        {p[1..], true}
      else
        {p, false}
      end
    end

    # Lua semantics: return captures if present, else whole match (find also
    # prepends start/end positions).
    def self.captures_or(i2 : Interp, s : Bytes, m : Pattern::MatchResult, start : Int32, is_find : Bool)
      res = [] of LuaValue
      if m.caps.empty?
        if is_find
          res << (start + 1).to_f64 << m.end_pos.to_f64
        else
          res << String.new(s[start, m.end_pos - start])
        end
      else
        res << (start + 1).to_f64 << m.end_pos.to_f64 if is_find
        m.caps.each do |cap|
          res << (cap.position? ? cap.start.to_f64 : String.new(s[cap.start, cap.len]))
        end
      end
      res
    end

    private def self.find(i2 : Interp, args : Array(LuaValue)) : Array(LuaValue)
      s = i2.str!(args, 0, "find").to_slice
      p = i2.str!(args, 1, "find").to_slice
      init = init_arg(i2, args, 2, "find", s.size)
      plain = Lua.truthy(args[3]?)
      if plain
        if p.size == 0
          return [(init + 1).to_f64, init.to_f64] of LuaValue
        end
        pos = init
        while pos + p.size <= s.size
          if s[pos, p.size] == p
            return [(pos + 1).to_f64, (pos + p.size).to_f64] of LuaValue
          end
          pos += 1
        end
        return [nil] of LuaValue
      end
      pat, anchored = strip_anchor(p)
      pos = init
      while pos <= s.size
        m = Pattern::Matcher.new(pat, s).match_at(pos)
        if m
          return captures_or(i2, s, m, pos, true)
        end
        break if anchored
        pos += 1
      end
      [nil] of LuaValue
    end

    private def self.add_replacement(i2 : Interp, buf : IO::Memory, s : Bytes, start : Int32, m : Pattern::MatchResult, repl : LuaValue)
      whole = String.new(s[start, m.end_pos - start])
      val : LuaValue = nil
      case repl
      when String
        # walk replacement, handling %n / %% / %0
        rb = repl.to_slice
        k = 0
        while k < rb.size
          c = rb[k]
          if c != 0x25 # '%'
            buf.write_byte(c)
            k += 1
            next
          end
          k += 1
          d = rb[k]?
          i2.raise_lua("invalid use of '%' in replacement string") if d.nil?
          if d == 0x25 # '%'
            buf.write_byte(0x25)
          elsif d >= 0x30 && d <= 0x39 # digit
            n = d - 0x30
            if n == 0
              buf << whole
            else
              cap = m.caps[n - 1]?
              i2.raise_lua("invalid capture index") if cap.nil?
              if cap.position?
                buf << cap.start.to_s
              else
                buf.write(s[cap.start, cap.len])
              end
            end
          else
            i2.raise_lua("invalid use of '%' in replacement string")
          end
          k += 1
        end
        return
      when LuaTable
        val = i2.getindex(repl, whole)
      when LuaClosure, LuaFunction
        r = i2.call(repl, [whole] of LuaValue)
        val = r[0]?
      else
        i2.arg_error(3, "gsub", "string/function/table expected")
      end
      if val.nil?
        buf << whole
      else
        unless val.is_a?(String) || val.is_a?(Float64)
          i2.raise_lua("invalid replacement value (a #{Lua.type_name(val)})")
        end
        buf << (val.is_a?(String) ? val : Lua.fmt_num(val))
      end
    end

    # --- string.format ---

    def self.format(i2 : Interp, args : Array(LuaValue)) : String
      fmt = i2.str!(args, 0, "format")
      fmt_out = IO::Memory.new
      argi = 1
      fb = fmt.to_slice
      k = 0
      while k < fb.size
        c = fb[k]
        if c != 0x25 # '%'
          fmt_out.write_byte(c)
          k += 1
          next
        end
        k += 1
        if k >= fb.size
          i2.raise_lua("invalid conversion '%' to 'format'")
        end
        if fb[k] == 0x25 # '%%'
          fmt_out.write_byte(0x25)
          k += 1
          next
        end
        spec_start = k
        # flags
        while k < fb.size && "-+ #0".includes?(fb[k].chr)
          k += 1
        end
        # width
        if k < fb.size && fb[k] == 0x2A # '*'
          w = int_from(i2, args, argi, "format")
          argi += 1
          spec_width = w.abs.to_s
          spec_width = "-#{spec_width}" if w < 0
          k += 1
        else
          spec_width = ""
          while k < fb.size && fb[k] >= 0x30 && fb[k] <= 0x39
            k += 1
          end
          spec_width = width_from(fb, spec_start, k)
        end
        spec_prec = ""
        if k < fb.size && fb[k] == 0x2E # '.'
          k += 1
          if k < fb.size && fb[k] == 0x2A # '*'
            pr = int_from(i2, args, argi, "format")
            argi += 1
            spec_prec = ".#{pr < 0 ? 0 : pr}"
            k += 1
          else
            ps = k
            while k < fb.size && fb[k] >= 0x30 && fb[k] <= 0x39
              k += 1
            end
            spec_prec = "." + String.new(fb[ps, k - ps])
          end
        end
        if k >= fb.size
          i2.raise_lua("invalid conversion to 'format'")
        end
        conv = fb[k].chr
        k += 1
        case conv
        when 'd', 'i'
          fmt_out << ("%" + spec_width + spec_prec + "d") % int_from(i2, args, argi, "format")
          argi += 1
        when 'u'
          i2.raise_lua("invalid conversion '%u' to 'format'")
        when 'x', 'X', 'o'
          fmt_out << ("%" + spec_width + spec_prec + conv) % int_from(i2, args, argi, "format")
          argi += 1
        when 'c'
          n = int_from(i2, args, argi, "format")
          i2.raise_lua("bad argument ##{argi + 1} to 'format' (value out of range)") if n < 0 || n > 255
          fmt_out.write_byte(n.to_u8)
          argi += 1
        when 'e', 'E', 'f', 'F', 'g', 'G'
          fmt_out << ("%" + spec_width + spec_prec + conv) % i2.num!(args, argi, "format")
          argi += 1
        when 'q'
          v = args[argi]?
          argi += 1
          if v.is_a?(Float64)
            fmt_out << Lua.fmt_num(v)
          else
            quote(i2, fmt_out, i2.str!(args, argi - 1, "format"))
          end
          fmt_out << ""
        when 's'
          sv = args[argi]?
          argi += 1
          s = i2.lua_tostring(sv)
          fmt_out << ("%" + spec_width + spec_prec + "s") % s
        when 'a', 'A'
          i2.raise_lua("invalid conversion '%#{conv}' to 'format'")
        else
          i2.raise_lua("invalid conversion '%#{conv}' to 'format'")
        end
      end
      String.new(fmt_out.to_slice)
    end

    private def self.width_from(fb : Bytes, from : Int32, to : Int32) : String
      String.new(fb[from, to - from])
    end

    private def self.int_from(i2 : Interp, args : Array(LuaValue), idx : Int32, fname : String) : Int64
      n = i2.num!(args, idx, fname)
      if n.nan? || n.infinite? || n != n.trunc || n.abs >= 2.0**63
        i2.raise_lua("bad argument ##{idx + 1} to 'format' (number has no integer representation)")
      end
      n.to_i64
    end

    private def self.quote(i2 : Interp, fmt_out : IO::Memory, s : String)
      fmt_out << 0x22.chr
      s.each_byte do |b|
        case b
        when 0x22 then fmt_out << "\\\""
        when 0x5C then fmt_out << "\\\\"
        when 0x0A then fmt_out << "\\n"
        when 0x0D then fmt_out << "\\r"
        when 0x00
          fmt_out << "\\0"
        else
          if b < 0x20 || b == 0x7F
            fmt_out << "\\" << b.to_s.rjust(3, '0')
          else
            fmt_out.write_byte(b)
          end
        end
      end
      fmt_out << 0x22.chr
    end
  end
end
