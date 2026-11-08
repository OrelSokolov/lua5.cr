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
            r = i2.call2(comp.not_nil!, a, b)
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

      # 5.1 deprecated: iterate table/array calling f(k, v); a non-nil
      # return from f stops the iteration and becomes the result
      tbl.raw_set("foreach", LuaFunction.new("table.foreach", ->(i2 : Interp, args : Array(LuaValue)) {
        t = i2.table!(args, 0, "foreach")
        f = args[1]?
        i2.func!(args, 1, "foreach")
        result : LuaValue = nil
        t.raw_keys.each do |k|
          r = i2.call(f.not_nil!, [k, t.raw_get(k)] of LuaValue)[0]?
          unless r.nil?
            result = r
            break
          end
        end
        [result] of LuaValue
      }))

      tbl.raw_set("foreachi", LuaFunction.new("table.foreachi", ->(i2 : Interp, args : Array(LuaValue)) {
        t = i2.table!(args, 0, "foreachi")
        f = args[1]?
        i2.func!(args, 1, "foreachi")
        n = t.raw_length
        result : LuaValue = nil
        x = 1
        while x <= n
          r = i2.call(f.not_nil!, [x.to_f64, t.raw_get(x.to_f64)] of LuaValue)[0]?
          unless r.nil?
            result = r
            break
          end
          x += 1
        end
        [result] of LuaValue
      }))

      # 5.1 deprecated: largest positive NUMERIC key (0 when none);
      # string keys convertible to numbers don't count
      tbl.raw_set("maxn", LuaFunction.new("table.maxn", ->(i2 : Interp, args : Array(LuaValue)) {
        t = i2.table!(args, 0, "maxn")
        m = 0.0
        t.raw_keys.each do |k|
          if k.is_a?(Float64) && !k.nan? && k > m
            m = k
          end
        end
        [m] of LuaValue
      }))

      i.globals.raw_set("table", tbl)
    end

    # Stable merge sort (Lua's sort is unstable, but order of equal elements
    # is unspecified anyway; stability keeps differential tests friendly).
    # Bottom-up (iterative): one scratch buffer of size n per table.sort
    # call instead of a copy per recursion level — the recursive version
    # allocated ~10M arrays per merge_sort(2000) run and half the profile
    # was Boehm marking that garbage (NBF3). Taking the right run only on a
    # strict less keeps the merge stable, same as the top-down form.
    def self.merge_sort(i2 : Interp, vals : Array(LuaValue), lt : LuaValue, LuaValue -> Bool) : Array(LuaValue)
      n = vals.size
      return vals if n <= 1
      src = vals
      dst = Array(LuaValue).new(n)
      width = 1
      while width < n
        dst.clear
        i = 0
        while i < n
          mid = {i + width, n}.min
          fin = {i + width * 2, n}.min
          li = i
          ri = mid
          while li < mid && ri < fin
            if lt.call(src[ri], src[li])
              dst << src[ri]
              ri += 1
            else
              dst << src[li]
              li += 1
            end
          end
          while li < mid
            dst << src[li]
            li += 1
          end
          while ri < fin
            dst << src[ri]
            ri += 1
          end
          i = fin
        end
        src, dst = dst, src
        width *= 2
      end
      src
    end
  end
end
