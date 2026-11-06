# Minimal os library (Phase 2 completes date formats etc.).
module Lua::Stdlib
  module OsLib
    CLOCK_START = Time.instant

    def self.install(i : Interp)
      tbl = LuaTable.new

      tbl.raw_set("time", LuaFunction.new("os.time", ->(_i2 : Interp, args : Array(LuaValue)) {
        if (a = args[0]?).is_a?(LuaTable)
          # 5.1: fields year, month, day, hour, min, sec (defaults 1/1/1/0/0/0)
          f = ->(k : String, d : Int32) { (Lua.tonumber(a.raw_get(k)) || d).to_i }
          t = Time.local(f.call("year", 0), f.call("month", 1), f.call("day", 1),
            f.call("hour", 0), f.call("min", 0), f.call("sec", 0))
          [t.to_unix.to_f64] of LuaValue
        else
          [Time.local.to_unix.to_f64] of LuaValue
        end
      }))

      tbl.raw_set("clock", LuaFunction.new("os.clock", ->(_i2 : Interp, _args : Array(LuaValue)) {
        span = Time.instant - CLOCK_START
        [span.total_seconds] of LuaValue
      }))

      tbl.raw_set("difftime", LuaFunction.new("os.difftime", ->(_i2 : Interp, args : Array(LuaValue)) {
        a = args.size > 0 && (x = Lua.tonumber(args[0])) ? x : 0.0
        b = args.size > 1 && (y = Lua.tonumber(args[1])) ? y : 0.0
        [a - b] of LuaValue
      }))

      tbl.raw_set("setlocale", LuaFunction.new("os.setlocale", ->(_i2 : Interp, args : Array(LuaValue)) {
        # we always run in the "C" locale; setting anything else fails
        l = args[0]?
        [l.nil? || l == "C" ? "C" : nil] of LuaValue
      }))

      tbl.raw_set("tmpname", LuaFunction.new("os.tmpname", ->(_i2 : Interp, _args : Array(LuaValue)) {
        [File.tempname("lua5_", ".tmp")] of LuaValue
      }))

      tbl.raw_set("remove", LuaFunction.new("os.remove", ->(_i2 : Interp, args : Array(LuaValue)) {
        n = args[0]?
        if n.is_a?(String)
          begin
            File.delete(n)
            [true] of LuaValue
          rescue e : Exception
            [nil, "#{n}: #{e.message || "cannot remove"}"] of LuaValue
          end
        else
          _i2.arg_error(1, "remove", "string expected")
        end
      }))

      tbl.raw_set("rename", LuaFunction.new("os.rename", ->(_i2 : Interp, args : Array(LuaValue)) {
        a = args[0]?
        b = args[1]?
        if a.is_a?(String) && b.is_a?(String)
          begin
            File.rename(a, b)
            [true] of LuaValue
          rescue e : Exception
            [nil, "#{a}: #{e.message || "cannot rename"}"] of LuaValue
          end
        else
          _i2.arg_error(2, "rename", "string expected")
        end
      }))

      tbl.raw_set("getenv", LuaFunction.new("os.getenv", ->(_i2 : Interp, args : Array(LuaValue)) {
        v = args[0]?
        if v.is_a?(String) && (e = ENV[v]?)
          [e] of LuaValue
        else
          [nil] of LuaValue
        end
      }))

      tbl.raw_set("date", LuaFunction.new("os.date", ->(i2 : Interp, args : Array(LuaValue)) {
        fmt = args.size > 0 && (v = args[0]?).is_a?(String) ? v : "%c"
        # "!" prefix: UTC (5.1 os.date)
        utc = fmt.starts_with?('!')
        fmt = fmt[1..] if utc
        t = args.size > 1 && (ts = Lua.tonumber(args[1])) ? Time.unix(ts.not_nil!.to_i64).to_local : Time.local
        t = t.to_utc if utc
        if fmt == "*t"
          [date_table(t)] of LuaValue
        else
          [format_date(i2, fmt, t)] of LuaValue
        end
      }))

      i.globals.raw_set("os", tbl)
    end

    def self.format_date(i2 : Interp, fmt : String, t : Time) : String
      out = String::Builder.new
      k = 0
      bytes = fmt.bytes
      while k < bytes.size
        c = bytes[k]
        if c != 0x25 # '%'
          out.write_byte(c)
          k += 1
          next
        end
        k += 1
        if k >= bytes.size
          out << "%"
          break
        end
        case bytes[k]
        when 0x59 then out << t.year.to_s.rjust(4, '0')   # %Y
        when 0x79 then out << (t.year % 100).to_s.rjust(2, '0') # %y
        when 0x6D then out << t.month.to_s.rjust(2, '0')  # %m
        when 0x64 then out << t.day.to_s.rjust(2, '0')    # %d
        when 0x48 then out << t.hour.to_s.rjust(2, '0')   # %H
        when 0x4D then out << t.minute.to_s.rjust(2, '0') # %M
        when 0x53 then out << t.second.to_s.rjust(2, '0') # %S
        when 0x58 # %X -> %H:%M:%S
          out << t.hour.to_s.rjust(2, '0') << ":" << t.minute.to_s.rjust(2, '0') << ":" << t.second.to_s.rjust(2, '0')
        when 0x78 # %x -> %m/%d/%y
          out << t.month.to_s.rjust(2, '0') << "/" << t.day.to_s.rjust(2, '0') << "/" << (t.year % 100).to_s.rjust(2, '0')
        when 0x63 # %c -> date+time
          out << t.to_s("%Y-%m-%d %H:%M:%S")
        when 0x70 # %p
          out << (t.hour < 12 ? "AM" : "PM")
        when 0x41 then out << DAY_NAMES[t.day_of_week.value % 7]
        when 0x61 then out << DAY_NAMES[t.day_of_week.value % 7][0, 3]
        when 0x42 then out << MONTH_NAMES[t.month - 1]
        when 0x62 then out << MONTH_NAMES[t.month - 1][0, 3]
        when 0x25 then out << "%"
        when 0x77 then out << (t.day_of_week.value % 7).to_s # %w: 0=Sunday
        when 0x6A then out << t.day_of_year.to_s.rjust(3, '0') # %j
        else
          i2.raise_lua("bad argument #1 to 'date' (invalid conversion specifier '%#{bytes[k].chr}')")
        end
        k += 1
      end
      out.to_s
    end

    # 5.1 getfieldtags: os.date("*t") result table
    def self.date_table(t : Time) : LuaTable
      tt = LuaTable.new
      tt.raw_set("year", t.year.to_f64)
      tt.raw_set("month", t.month.to_f64)
      tt.raw_set("day", t.day.to_f64)
      tt.raw_set("hour", t.hour.to_f64)
      tt.raw_set("min", t.minute.to_f64)
      tt.raw_set("sec", t.second.to_f64)
      tt.raw_set("wday", (t.day_of_week.value % 7 + 1).to_f64) # 1 = Sunday
      tt.raw_set("yday", t.day_of_year.to_f64)
      tt.raw_set("isdst", false)
      tt
    end

    DAY_NAMES  = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    MONTH_NAMES = ["January", "February", "March", "April", "May", "June",
                   "July", "August", "September", "October", "November", "December"]
  end
end
