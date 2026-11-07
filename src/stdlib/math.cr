# math library. Port of lmathlib.c (subset + LuaJIT tointeger).
module Lua::Stdlib
  module MathLib
    def self.one(tbl : LuaTable, fname : String, &f : Float64 -> Float64)
      lf = LuaFunction.new("math.#{fname}", ->(i2 : Interp, args : Array(LuaValue)) {
        i2.ret1(f.call(i2.num!(args, 0, fname)))
      })
      lf.fast1 = f # allocation-free fast path for JIT call sites
      tbl.raw_set(fname, lf)
    end

    def self.install(i : Interp)
      tbl = LuaTable.new

      one(tbl, "floor", &.floor)
      one(tbl, "ceil", &.ceil)
      one(tbl, "abs", &.abs)
      one(tbl, "sqrt") { |x| Math.sqrt(x) }
      one(tbl, "sin") { |x| Math.sin(x) }
      one(tbl, "cos") { |x| Math.cos(x) }
      one(tbl, "tan") { |x| Math.tan(x) }
      one(tbl, "asin") { |x| Math.asin(x) }
      one(tbl, "acos") { |x| Math.acos(x) }
      one(tbl, "exp") { |x| Math.exp(x) }
      one(tbl, "sinh") { |x| Math.sinh(x) }
      one(tbl, "cosh") { |x| Math.cosh(x) }
      one(tbl, "tanh") { |x| Math.tanh(x) }
      one(tbl, "deg") { |x| x * 180.0 / Math::PI }
      one(tbl, "rad") { |x| x * Math::PI / 180.0 }

      tbl.raw_set("atan", LuaFunction.new("math.atan", ->(i2 : Interp, args : Array(LuaValue)) {
        y = i2.num!(args, 0, "atan")
        x = args.size > 1 ? i2.num!(args, 1, "atan") : 1.0
        [Math.atan2(y, x)] of LuaValue
      }))

      tbl.raw_set("atan2", LuaFunction.new("math.atan2", ->(i2 : Interp, args : Array(LuaValue)) {
        y = i2.num!(args, 0, "atan2")
        x = i2.num!(args, 1, "atan2")
        [Math.atan2(y, x)] of LuaValue
      }))

      # x = m * 2^e with |m| in [0.5, 1) — 5.1 l_mathop(frexp)
      tbl.raw_set("frexp", LuaFunction.new("math.frexp", ->(i2 : Interp, args : Array(LuaValue)) {
        x = i2.num!(args, 0, "frexp")
        if x == 0 || !x.finite?
          [x, 0.0] of LuaValue
        else
          e = Math.frexp(x)[1].to_f64
          [x / (2.0 ** e), e] of LuaValue
        end
      }))

      tbl.raw_set("ldexp", LuaFunction.new("math.ldexp", ->(i2 : Interp, args : Array(LuaValue)) {
        m = i2.num!(args, 0, "ldexp")
        e = i2.num!(args, 1, "ldexp").to_i
        [m * (2.0 ** e)] of LuaValue
      }))

      tbl.raw_set("log", LuaFunction.new("math.log", ->(i2 : Interp, args : Array(LuaValue)) {
        x = i2.num!(args, 0, "log")
        if args.size > 1
          b = i2.num!(args, 1, "log")
          [Math.log(x, b)] of LuaValue
        else
          [Math.log(x)] of LuaValue
        end
      }))

      tbl.raw_set("log10", LuaFunction.new("math.log10", ->(i2 : Interp, args : Array(LuaValue)) {
        [Math.log(i2.num!(args, 0, "log10"), 10)] of LuaValue
      }))

      tbl.raw_set("pow", LuaFunction.new("math.pow", ->(i2 : Interp, args : Array(LuaValue)) {
        [i2.num!(args, 0, "pow") ** i2.num!(args, 1, "pow")] of LuaValue
      }))

      tbl.raw_set("fmod", LuaFunction.new("math.fmod", ->(i2 : Interp, args : Array(LuaValue)) {
        a = i2.num!(args, 0, "fmod")
        b = i2.num!(args, 1, "fmod")
        q = (a / b).trunc
        [a - b * q] of LuaValue
      }))

      # 5.1 deprecated alias
      tbl.raw_set("mod", tbl.raw_get("fmod"))

      tbl.raw_set("modf", LuaFunction.new("math.modf", ->(i2 : Interp, args : Array(LuaValue)) {
        v = i2.num!(args, 0, "modf")
        ip = v.trunc
        [ip, v - ip] of LuaValue
      }))

      tbl.raw_set("max", LuaFunction.new("math.max", ->(i2 : Interp, args : Array(LuaValue)) {
        i2.raise_lua("bad argument #1 to 'max' (number expected, got no value)") if args.empty?
        best = i2.num!(args, 0, "max")
        (1...args.size).each do |k|
          v = i2.num!(args, k, "max")
          best = v if v > best
        end
        [best] of LuaValue
      }))

      tbl.raw_set("min", LuaFunction.new("math.min", ->(i2 : Interp, args : Array(LuaValue)) {
        i2.raise_lua("bad argument #1 to 'min' (number expected, got no value)") if args.empty?
        best = i2.num!(args, 0, "min")
        (1...args.size).each do |k|
          v = i2.num!(args, k, "min")
          best = v if v < best
        end
        [best] of LuaValue
      }))

      tbl.raw_set("random", LuaFunction.new("math.random", ->(i2 : Interp, args : Array(LuaValue)) {
        # xray's LuaJIT lib_math.c: NO interval validation —
        #   d = prng_double() - 1.0 (in [0,1))
        #   0 args: d | 1 arg: floor(d*r1) + 1 | 2 args: floor(d*(r2-r1+1)) + r1
        # (engine corpus: math.random(1, 0) == 1, math.random(5, 5) == 5)
        d = i2.rng.next_double
        case args.size
        when 0 then [d] of LuaValue
        when 1
          r1 = i2.num!(args, 0, "random")
          [(d * r1).floor + 1.0] of LuaValue
        else
          r1 = i2.num!(args, 0, "random")
          r2 = i2.num!(args, 1, "random")
          [(d * (r2 - r1 + 1.0)).floor + r1] of LuaValue
        end
      }))

      tbl.raw_set("randomseed", LuaFunction.new("math.randomseed", ->(i2 : Interp, args : Array(LuaValue)) {
        seed = i2.num!(args, 0, "randomseed")
        i2.rng.seed(seed)
        [] of LuaValue
      }))

      tbl.raw_set("tointeger", LuaFunction.new("math.tointeger", ->(i2 : Interp, args : Array(LuaValue)) {
        n = Lua.tonumber(args[0]?)
        if n && n == n.trunc && n.abs < 2.0**63
          [n] of LuaValue
        else
          [nil] of LuaValue
        end
      }))

      tbl.raw_set("pi", Math::PI)
      tbl.raw_set("huge", Float64::INFINITY)
      i.globals.raw_set("math", tbl)
    end
  end
end
