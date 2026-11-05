# table library. Port of ltablib.c (insert/remove/concat/sort).
module Lua::Stdlib
  module TableLib
    def self.install(i : Interp)
      tbl = LuaTable.new

      tbl.raw_set("insert", LuaFunction.new("table.insert", ->(i2 : Interp, args : Array(LuaValue)) {
        t = i2.table!(args, 0, "insert")
        n = t.raw_length
        case args.size
        when 2
          t.raw_set((n + 1).to_f64, args[1]?)
        when 3
          pos = i2.num!(args, 1, "insert").to_i
          i2.raise_lua("bad argument #2 to 'insert' (position out of bounds)") if pos < 1 || pos > n + 1
          x = n
          while x >= pos
            t.raw_set((x + 1).to_f64, t.raw_get(x.to_f64))
            x -= 1
          end
          t.raw_set(pos.to_f64, args[2]?)
        else
          i2.arg_error(2, "insert", "wrong number of arguments")
        end
        [] of LuaValue
      }))

      tbl.raw_set("remove", LuaFunction.new("table.remove", ->(i2 : Interp, args : Array(LuaValue)) {
        t = i2.table!(args, 0, "remove")
        n = t.raw_length
        pos = args.size > 1 ? i2.num!(args, 1, "remove").to_i : n
        i2.raise_lua("bad argument #2 to 'remove' (position out of bounds)") if pos < 1 || pos > n + 1
        # Lua allows pos == n+1: removes nothing, returns nil
        old = t.raw_get(pos.to_f64)
        x = pos
        while x < n
          t.raw_set(x.to_f64, t.raw_get((x + 1).to_f64))
          x += 1
        end
        t.raw_set(n.to_f64, nil) if pos <= n
        [old] of LuaValue
      }))

      tbl.raw_set("concat", LuaFunction.new("table.concat", ->(i2 : Interp, args : Array(LuaValue)) {
        t = i2.table!(args, 0, "concat")
        sep = args.size > 1 ? i2.str!(args, 1, "concat") : ""
        n = t.raw_length
        from = args.size > 2 ? i2.num!(args, 2, "concat").to_i : 1
        to = args.size > 3 ? i2.num!(args, 3, "concat").to_i : n
        buf = String::Builder.new
        x = from
        while x <= to
          v = t.raw_get(x.to_f64)
          case v
          when String  then buf << v
          when Float64 then buf << Lua.fmt_num(v)
          else
            i2.raise_lua("invalid value (at index #{x}) in table for 'concat'")
          end
          buf << sep if x != to
          x += 1
        end
        [buf.to_s] of LuaValue
      }))

      tbl.raw_set("sort", LuaFunction.new("table.sort", ->(i2 : Interp, args : Array(LuaValue)) {
        t = i2.table!(args, 0, "sort")
        comp = args[1]?
        has_comp = !comp.nil?
        lt : LuaValue, LuaValue -> Bool
        if has_comp
          lt = ->(a : LuaValue, b : LuaValue) : Bool {
            r = i2.call(comp.not_nil!, [a, b])[0]?
            Lua.truthy(r)
          }
        else
          lt = ->(a : LuaValue, b : LuaValue) : Bool { i2.lua_compare(a, b, "<") }
        end
        n = t.raw_length
        vals = Array(LuaValue).new(n)
        (1..n).each { |k| vals << t.raw_get(k.to_f64) }
        sorted = merge_sort(i2, vals, lt)
        (1..n).each { |k| t.raw_set(k.to_f64, sorted[k - 1]) }
        [] of LuaValue
      }))

      tbl.raw_set("getn", LuaFunction.new("table.getn", ->(i2 : Interp, args : Array(LuaValue)) {
        t = i2.table!(args, 0, "getn")
        [t.raw_length.to_f64] of LuaValue
      }))

      i.globals.raw_set("table", tbl)
    end

    # Stable merge sort (Lua's sort is unstable, but order of equal elements
    # is unspecified anyway; stability keeps differential tests friendly).
    def self.merge_sort(i2 : Interp, vals : Array(LuaValue), lt : LuaValue, LuaValue -> Bool) : Array(LuaValue)
      return vals if vals.size <= 1
      mid = vals.size // 2
      left = merge_sort(i2, vals[0, mid], lt)
      right = merge_sort(i2, vals[mid..], lt)
      out = Array(LuaValue).new(vals.size)
      li = 0
      ri = 0
      while li < left.size && ri < right.size
        # right < left => take right (strict less keeps stability)
        if lt.call(right[ri], left[li])
          out << right[ri]
          ri += 1
        else
          out << left[li]
          li += 1
        end
      end
      out.concat(left[li..]) if li < left.size
      out.concat(right[ri..]) if ri < right.size
      out
    end
  end
end
